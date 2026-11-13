local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Core = require("ganjoor_core")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local Trapper = require("ui/trapper")
local UI = require("ganjoor_ui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local ffiutil = require("ffi/util")
local _ = require("gettext")
local T = ffiutil.template

-- Sibling modules can only be require()d while the plugin is being loaded, so everything that
-- needs the plugin folder is resolved here, at load time.
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

local BASE_URL = "https://cdn.jsdelivr.net/gh/ganjoor/ganjoor-data@main/"

-- ---------------------------------------------------------------------------
-- file helpers handed to the core module
-- ---------------------------------------------------------------------------

local env = {
    json_decode = json.decode,
    read_file = function(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end,
    write_file = function(path, data)
        local tmp = path .. ".tmp"
        local f = io.open(tmp, "wb")
        if not f then return false end
        f:write(data)
        f:close()
        return os.rename(tmp, path)
    end,
    exists = function(path)
        return lfs.attributes(path, "mode") == "file"
    end,
    list_dir = function(path)
        local names = {}
        if lfs.attributes(path, "mode") == "directory" then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    names[#names + 1] = name
                end
            end
        end
        return names
    end,
    mkdir_p = function(path) util.makePath(path) end,
    remove_dir = function(path) ffiutil.purgeDir(path) end,
    remove_file = function(path) os.remove(path) end,
}

local function megabytes(bytes)
    return string.format("%.1f MB", (bytes or 0) / 1048576)
end

local Ganjoor = WidgetContainer:extend{
    name = "ganjoor",
    is_doc_only = false,
}

-- System actions: they show up in KOReader's gesture/profile lists and in Simple UI's
-- "Quick Action → System Actions" picker, so Ganjoor can be a tab of Simple UI's navigation bar.
function Ganjoor:onDispatcherRegisterActions()
    Dispatcher:registerAction("ganjoor_open", { category = "none", event = "Ganjoor",
        title = _("Ganjoor poetry"), general = true })
    Dispatcher:registerAction("ganjoor_continue", { category = "none", event = "GanjoorContinue",
        title = _("Ganjoor: continue reading"), general = true })
    Dispatcher:registerAction("ganjoor_fal", { category = "none", event = "GanjoorFal",
        title = _("Ganjoor: Hafez fal"), general = true })
    Dispatcher:registerAction("ganjoor_search", { category = "none", event = "GanjoorSearch",
        title = _("Ganjoor: search poems"), general = true })
end

-- Event handlers of those actions. `onGanjoor` is also the method name Simple UI's
-- "Quick Action → Plugin" picker looks for (on + capitalised plugin name).
function Ganjoor:onGanjoor()
    self:showPoets()
    return true
end

function Ganjoor:onGanjoorContinue()
    self:continueReading()
    return true
end

function Ganjoor:onGanjoorFal()
    self:hafezFal()
    return true
end

function Ganjoor:onGanjoorSearch()
    self:promptSearch()
    return true
end

function Ganjoor:init()
    self:onDispatcherRegisterActions()
    local data_dir = DataStorage:getDataDir()
    self.cache_dir = data_dir .. "/cache/ganjoor"
    self.ganjoor_dir = data_dir .. "/ganjoor"
    self.download_dir = self.ganjoor_dir .. "/poets"
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ganjoor.lua")
    self.store = Core.newStore(env, PLUGIN_DIR .. "/data", self.download_dir)
    math.randomseed(os.time())
    self.ui.menu:registerToMainMenu(self)
end

function Ganjoor:addToMainMenu(menu_items)
    menu_items.ganjoor = {
        text = _("Ganjoor poetry"),
        sorting_hint = "search",
        sub_item_table = {
            { text = _("Continue reading"), callback = function() self:continueReading() end },
            { text = _("Poets"), callback = function() self:showPoets() end },
            { text = _("Hafez fal (random ghazal)"), callback = function() self:hafezFal() end },
            { text = _("Random poem"), callback = function() self:randomPoem() end },
            { text = _("Search poems"), callback = function() self:promptSearch() end },
            { text = _("Bookmarks"), callback = function() self:showBookmarks() end },
            { text = _("Reading settings"), callback = function() self:showReadingSettings() end },
            { text = _("Poets and downloads"), callback = function() self:showManagePoets() end },
        },
    }
end

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------

function Ganjoor:getReadingSettings()
    local s = self.settings
    return {
        face = s:readSetting("font_face"),
        size = s:readSetting("font_size") or 22,
        layout = s:readSetting("layout") or "columns",
        harakat = s:readSetting("harakat") ~= false,
    }
end

function Ganjoor:saveSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

-- ---------------------------------------------------------------------------
-- network
-- ---------------------------------------------------------------------------

function Ganjoor:cacheFile(rel_path)
    return self.cache_dir .. "/" .. rel_path:gsub("/", "__")
end

function Ganjoor:httpGet(rel_path)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = BASE_URL .. rel_path,
        method = "GET",
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("Ganjoor: HTTP", code, "for", rel_path)
        return nil
    end
    return table.concat(sink)
end

-- Used by the downloader: no cache, returns the decoded table or nil.
function Ganjoor:fetchRemote(rel_path)
    local body = self:httpGet(rel_path)
    if not body then return nil end
    local ok, parsed = pcall(json.decode, body)
    if ok and type(parsed) == "table" then
        return parsed
    end
    return nil
end

-- Cache is consulted first so anything browsed online once keeps working offline.
function Ganjoor:fetchJSON(rel_path)
    local cache_file = self:cacheFile(rel_path)
    local body = env.read_file(cache_file)
    if not body or body == "" then
        if not NetworkMgr:isOnline() then
            return nil, _("Not available offline. Connect to Wi-Fi and try again.")
        end
        body = self:httpGet(rel_path)
        if not body then
            return nil, _("Download failed. Check your connection and try again.")
        end
        util.makePath(self.cache_dir)
        env.write_file(cache_file, body)
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok or type(parsed) ~= "table" then
        os.remove(cache_file)
        return nil, _("Could not parse server response.")
    end
    return parsed
end

function Ganjoor:loadAndShow(rel_path, show_fn)
    local run = function()
        local info = InfoMessage:new{ text = _("Loading…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local data, err = self:fetchJSON(rel_path)
        UIManager:close(info)
        if not data then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        show_fn(data)
    end
    if not NetworkMgr:isOnline() and lfs.attributes(self:cacheFile(rel_path), "mode") ~= "file" then
        NetworkMgr:runWhenOnline(run)
    else
        run()
    end
end

-- ---------------------------------------------------------------------------
-- poet list
-- ---------------------------------------------------------------------------

function Ganjoor:getManifest()
    if self.manifest then
        return self.manifest
    end
    local best = self.store:decodeFile(PLUGIN_DIR .. "/data/all_poets.json")
    local updated = self.store:decodeFile(self.ganjoor_dir .. "/manifest.json")
    if updated and updated.Poets and (not best or (updated.GeneratedAtUtc or "") > (best.GeneratedAtUtc or "")) then
        best = updated
    end
    self.manifest = best or { Poets = {}, IdIndexShardSize = 2000 }
    return self.manifest
end

function Ganjoor:updatePoetList()
    local run = function()
        local info = InfoMessage:new{ text = _("Loading…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local m = self:fetchRemote("manifest.json")
        UIManager:close(info)
        if not m or not m.Poets then
            UIManager:show(InfoMessage:new{ text = _("Download failed. Check your connection and try again.") })
            return
        end
        local poets = {}
        for _i, p in ipairs(m.Poets) do
            poets[#poets + 1] = { Id = p.Id, Nickname = p.Nickname, FullUrl = p.FullUrl }
        end
        util.makePath(self.ganjoor_dir)
        env.write_file(self.ganjoor_dir .. "/manifest.json", Core.encode({
            GeneratedAtUtc = m.GeneratedAtUtc or "", IdIndexShardSize = m.IdIndexShardSize or 2000, Poets = poets }))
        self.manifest = nil
        UIManager:show(InfoMessage:new{ text = T(_("Poet list updated: %1 poets."), #poets) })
    end
    NetworkMgr:runWhenOnline(run)
end

function Ganjoor:showPoets()
    local manifest = self:getManifest()
    self.store:refresh()
    local here, elsewhere = {}, {}
    for _i, poet in ipairs(manifest.Poets or {}) do
        local state = self.store:poetState(Core.slugOf(poet.FullUrl))
        local on_device = state == "bundled" or state == "downloaded"
        local item = {
            text = (on_device and "" or "\u{2193} ") .. poet.Nickname,
            callback = function() self:onPoetTap(poet) end,
        }
        table.insert(on_device and here or elsewhere, item)
    end
    local items = {}
    for _i, item in ipairs(here) do items[#items + 1] = item end
    for _i, item in ipairs(elsewhere) do items[#items + 1] = item end
    if self.grid then
        UIManager:close(self.grid)
    end
    self.grid = UI.Grid:new{
        title = _("Ganjoor — poets"),
        items = items,
        on_menu = function() self:showMainActions() end,
    }
    UIManager:show(self.grid)
end

function Ganjoor:onPoetTap(poet)
    local slug = Core.slugOf(poet.FullUrl)
    local state = self.store:poetState(slug)
    if state == "bundled" or state == "downloaded" then
        self:showLocalCategory(slug, poet.FullUrl, poet.Nickname)
    else
        self:showDownloadDialog(poet, state == "partial")
    end
end

function Ganjoor:showMainActions()
    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = _("Ganjoor"),
        buttons = {
            {{ text = _("Continue reading"), callback = act(function() self:continueReading() end) }},
            {{ text = _("Hafez fal (random ghazal)"), callback = act(function() self:hafezFal() end) }},
            {{ text = _("Random poem"), callback = act(function() self:randomPoem() end) }},
            {{ text = _("Search poems"), callback = act(function() self:promptSearch() end) }},
            {{ text = _("Bookmarks"), callback = act(function() self:showBookmarks() end) }},
            {{ text = _("Reading settings"), callback = act(function() self:showReadingSettings() end) }},
            {{ text = _("Poets and downloads"), callback = act(function() self:showManagePoets() end) }},
            {{ text = _("Open poem by Ganjoor ID"), callback = act(function() self:promptPoemId() end) }},
            {{ text = _("Update poet list"), callback = act(function() self:updatePoetList() end) }},
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- browsing local (bundled / downloaded) poets
-- ---------------------------------------------------------------------------

function Ganjoor:pushMenu(title, item_table)
    local menu
    menu = UI.Menu:new{
        title = title,
        item_table = item_table,
        base_title = title,
        all_items = item_table,
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
    return menu
end

function Ganjoor:showLocalCategory(slug, cat_url, title)
    local meta = self.store:getMeta(slug)
    local node = meta and meta.cats[cat_url]
    if not node then
        UIManager:show(InfoMessage:new{ text = _("This poet's data could not be read.") })
        return
    end
    local nick = meta.nick or title
    local items = {}
    if cat_url == meta.url then
        table.insert(items, {
            text = T(_("Search in %1"), nick),
            callback = function() self:promptSearch(slug, nick) end,
        })
        if meta.desc and meta.desc ~= "" then
            table.insert(items, {
                text = "\u{24D8} " .. _("About"),
                callback = function()
                    UIManager:show(UI.Viewer:new{ title = nick, text = meta.desc })
                end,
            })
        end
    end
    for _i, child_url in ipairs(node.c or {}) do
        local child = meta.cats[child_url]
        if child then
            table.insert(items, {
                text = child.t,
                bold = true,
                callback = function() self:showLocalCategory(slug, child_url, child.t) end,
            })
        end
    end
    local entries = {}
    for _i, entry in ipairs(node.p or {}) do
        entries[#entries + 1] = { url = Core.poemUrl(cat_url, entry[2]), title = entry[1] }
    end
    local subtitle = nick .. " \u{00BB} " .. (node.t or title)
    for i, e in ipairs(entries) do
        table.insert(items, {
            text = e.title,
            callback = function()
                self:openPoemByUrl(e.url, { entries = entries, index = i, subtitle = subtitle })
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("(empty)") })
    end
    self:pushMenu((node.t and node.t ~= "") and node.t or title, items)
end

-- ---------------------------------------------------------------------------
-- browsing online (poets that are not downloaded)
-- ---------------------------------------------------------------------------

function Ganjoor:showOnlineCategory(full_url, title, nick)
    self:loadAndShow("poets" .. full_url .. "/_cat.json", function(cat)
        local items = {}
        nick = nick or cat.Title or title
        if cat.Description and cat.Description ~= "" then
            table.insert(items, {
                text = "\u{24D8} " .. _("About"),
                callback = function()
                    UIManager:show(UI.Viewer:new{ title = title, text = cat.Description })
                end,
            })
        end
        for _i, child in ipairs(cat.ChildCats or {}) do
            table.insert(items, {
                text = child.Title,
                bold = true,
                callback = function() self:showOnlineCategory(child.FullUrl, child.Title, nick) end,
            })
        end
        local entries = {}
        for _i, poem in ipairs(cat.Poems or {}) do
            entries[#entries + 1] = { url = poem.FullUrl, title = poem.Title }
        end
        local subtitle = nick .. " \u{00BB} " .. (cat.Title or title)
        for i, e in ipairs(entries) do
            table.insert(items, {
                text = e.title,
                callback = function()
                    self:openPoemByUrl(e.url, { entries = entries, index = i, subtitle = subtitle })
                end,
            })
        end
        if #items == 0 then
            table.insert(items, { text = _("(empty)") })
        end
        self:pushMenu(cat.Title or title, items)
    end)
end

-- ---------------------------------------------------------------------------
-- opening poems
-- ---------------------------------------------------------------------------

-- Local data first, then a bookmark snapshot, then the network (with the page cache).
function Ganjoor:resolvePoem(url, snapshot)
    local poem = self.store:getPoem(url)
    if poem then
        return poem
    end
    if snapshot then
        return snapshot
    end
    local data, err = self:fetchJSON("poets" .. url .. ".json")
    if not data then
        return nil, err
    end
    return Core.convertRemotePoem(data, data.Title)
end

-- ctx: { entries =, index =, subtitle =, focus_row =, snapshot = }
-- Neighbouring poems of a local poem (same category), so prev/next work from search results,
-- bookmarks and "continue reading" too.
function Ganjoor:localSiblings(url)
    local meta = self.store:getMeta(Core.slugOf(url))
    local parent = url:match("^(.*)/[^/]+$")
    local node = meta and parent and meta.cats[parent]
    if not node or not node.p then
        return nil
    end
    local entries, index = {}, nil
    for i, e in ipairs(node.p) do
        local u = Core.poemUrl(parent, e[2])
        entries[i] = { url = u, title = e[1] }
        if u == url then index = i end
    end
    if index then
        return entries, index, (meta.nick or "") .. " \u{00BB} " .. (node.t or "")
    end
end

function Ganjoor:openPoemByUrl(url, ctx)
    ctx = ctx or {}
    if not ctx.entries then
        local entries, index, subtitle = self:localSiblings(url)
        if entries then
            local c = {}
            for k, v in pairs(ctx) do c[k] = v end
            c.entries, c.index, c.subtitle = entries, index, subtitle
            ctx = c
        end
    end
    local function run()
        local info = InfoMessage:new{ text = _("Loading…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local poem, err = self:resolvePoem(url, ctx.snapshot)
        UIManager:close(info)
        if not poem then
            UIManager:show(InfoMessage:new{ text = err or _("Could not load the poem.") })
            return
        end
        local c = {}
        for k, v in pairs(ctx) do c[k] = v end
        c.url, c.poem = url, poem
        self:showPoemView(c)
    end
    local available = self.store:getPoem(url) ~= nil or ctx.snapshot ~= nil
        or lfs.attributes(self:cacheFile("poets" .. url .. ".json"), "mode") == "file"
    if not available and not NetworkMgr:isOnline() then
        NetworkMgr:runWhenOnline(run)
    else
        run()
    end
end

function Ganjoor:poemViewArgs(view, c)
    local prev, nxt
    if c.entries and c.index then
        if c.index > 1 then
            prev = function(v, from_edge) self:stepPoem(v, -1, from_edge) end
        end
        if c.index < #c.entries then
            nxt = function(v) self:stepPoem(v, 1) end
        end
    end
    view.ctx = c
    return {
        poem = c.poem,
        title = (c.poem.t and c.poem.t ~= "") and c.poem.t or (c.title or ""),
        subtitle = c.subtitle,
        focus_row = c.focus_row,
        start_row = c.start_row,
        at_end = c.at_end,
        on_prev = prev,
        on_next = nxt,
        get_marked = function() return self:markedRows(c.url) end,
        is_bookmarked = function() return self:isBookmarked(c.url) end,
    }
end

function Ganjoor:showPoemView(c)
    local view = UI.PoemView:new{
        get_settings = function() return self:getReadingSettings() end,
        on_toggle_bookmark = function(v) self:toggleBookmark(v, nil) end,
        on_hold_row = function(v, row) self:askCoupletBookmark(v, row) end,
        on_menu = function(v) self:showPoemMenu(v) end,
        on_edge = function(v, delta) self:onPoemEdge(v, delta) end,
        on_position = function(v, row, final) self:saveLastRead(v, row, final) end,
    }
    view:loadPoem(self:poemViewArgs(view, c))
    UIManager:show(view)
end

function Ganjoor:stepPoem(view, delta, from_edge)
    local c = view.ctx
    local target = c.entries[c.index + delta]
    if not target then return end
    local poem, err = self:resolvePoem(target.url)
    if not poem then
        UIManager:show(InfoMessage:new{ text = err or _("Could not load the poem.") })
        return
    end
    local nc = {}
    for k, v in pairs(c) do nc[k] = v end
    nc.url, nc.poem, nc.index, nc.snapshot = target.url, poem, c.index + delta, nil
    nc.focus_row, nc.start_row = nil, nil
    nc.at_end = (from_edge and delta < 0) or nil -- going back by page lands on the end of the previous poem
    view:loadPoem(self:poemViewArgs(view, nc))
    UIManager:show(InfoMessage:new{
        text = T(delta > 0 and _("Next poem: %1") or _("Previous poem: %1"), poem.t),
        timeout = 2,
    })
end

function Ganjoor:onPoemEdge(view, delta)
    local in_list = view.ctx and view.ctx.entries
    local text
    if delta > 0 then
        text = in_list and _("This is the last poem in this list.") or _("End of the poem.")
    else
        text = in_list and _("This is the first poem in this list.") or _("Start of the poem.")
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 1.5 })
end

-- Tap in the middle of the page.
function Ganjoor:showPoemMenu(view)
    local c = view.ctx
    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local bookmarked = self:isBookmarked(c.url)
    dialog = ButtonDialog:new{
        title = c.poem.t,
        buttons = {
            {{ text = _("Reading settings (font, size, layout)"),
               callback = act(function() self:showReadingSettings(function() view:relayout() end) end) }},
            {{ text = bookmarked and _("Remove bookmark") or _("Bookmark this poem"),
               callback = act(function() self:toggleBookmark(view, nil) end) }},
            {
                { text = _("Previous poem"), enabled = view.on_prev ~= nil,
                  callback = act(function() view.on_prev(view) end) },
                { text = _("Next poem"), enabled = view.on_next ~= nil,
                  callback = act(function() view.on_next(view) end) },
            },
            {{ text = _("Close"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- random poem / Hafez fal
-- ---------------------------------------------------------------------------

-- A random poem of a local poet (any local poet when slug is nil), optionally limited to one category.
function Ganjoor:randomPoem(slug, cat_url)
    local locals = self.store:localSlugs()
    if #locals == 0 then
        UIManager:show(InfoMessage:new{ text = _("No poets are stored on this device yet.") })
        return
    end
    slug = slug or locals[math.random(#locals)]
    local meta = self.store:getMeta(slug)
    if not meta then
        UIManager:show(InfoMessage:new{ text = _("This poet is not stored on this device. Download it first.") })
        return
    end
    local urls = {}
    for url, node in pairs(meta.cats) do
        if not cat_url or url == cat_url or url:sub(1, #cat_url + 1) == cat_url .. "/" then
            for _i, e in ipairs(node.p or {}) do
                urls[#urls + 1] = Core.poemUrl(url, e[2])
            end
        end
    end
    if #urls == 0 then
        UIManager:show(InfoMessage:new{ text = _("No poems found.") })
        return
    end
    self:openPoemByUrl(urls[math.random(#urls)], {})
end

function Ganjoor:hafezFal()
    self.store:refresh()
    self:randomPoem("hafez", "/hafez/ghazal")
end

-- ---------------------------------------------------------------------------
-- continue reading
-- ---------------------------------------------------------------------------

function Ganjoor:saveLastRead(view, row, final)
    local c = view.ctx
    if not c then return end
    self.settings:saveSetting("last_read", { url = c.url, row = row, title = c.poem.t, subtitle = c.subtitle,
        snapshot = (self.store:getPoem(c.url) == nil) and c.poem or nil })
    if final then
        self.settings:flush()
    end
end

function Ganjoor:continueReading()
    local last = self.settings:readSetting("last_read")
    if not last then
        UIManager:show(InfoMessage:new{ text = _("Nothing to continue yet. Open a poem first.") })
        return
    end
    self:openPoemByUrl(last.url, { start_row = last.row, subtitle = last.subtitle, snapshot = last.snapshot })
end

-- ---------------------------------------------------------------------------
-- bookmarks
-- ---------------------------------------------------------------------------

function Ganjoor:getBookmarks()
    local list = self.settings:readSetting("bookmarks")
    if not list then
        list = {}
        self.settings:saveSetting("bookmarks", list)
    end
    return list
end

function Ganjoor:findBookmark(url, row)
    for i, b in ipairs(self:getBookmarks()) do
        if b.url == url and b.row == row then
            return i, b
        end
    end
end

function Ganjoor:isBookmarked(url)
    return self:findBookmark(url, nil) ~= nil
end

function Ganjoor:markedRows(url)
    local set = {}
    for _i, b in ipairs(self:getBookmarks()) do
        if b.url == url and b.row then
            set[b.row] = true
        end
    end
    return set
end

function Ganjoor:toggleBookmark(view, row)
    local c = view.ctx
    local list = self:getBookmarks()
    local idx = self:findBookmark(c.url, row)
    if idx then
        table.remove(list, idx)
    else
        local poet = (c.subtitle or ""):match("^(.-) \u{00BB}") or c.subtitle
        local entry = { url = c.url, row = row, title = c.poem.t, poet = poet, ts = os.time() }
        if self.store:getPoem(c.url) == nil then
            entry.snapshot = c.poem -- poems browsed online stay readable offline
        end
        table.insert(list, entry)
    end
    self.settings:flush()
    view:refresh()
end

function Ganjoor:askCoupletBookmark(view, row)
    local exists = self:findBookmark(view.ctx.url, row) ~= nil
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Couplet %1"), row),
        buttons = {
            {{
                text = exists and _("Remove bookmark") or _("Bookmark this couplet"),
                callback = function()
                    UIManager:close(dialog)
                    self:toggleBookmark(view, row)
                end,
            }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

function Ganjoor:showBookmarks()
    if self.bookmarks_menu then
        UIManager:close(self.bookmarks_menu)
        self.bookmarks_menu = nil
    end
    local list = self:getBookmarks()
    local sorted = {}
    for _i, b in ipairs(list) do sorted[#sorted + 1] = b end
    table.sort(sorted, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    local items = {}
    for _i, b in ipairs(sorted) do
        table.insert(items, {
            text = b.title .. ((b.poet and b.poet ~= "") and (" \u{2014} " .. b.poet) or ""),
            mandatory = b.row and T(_("Couplet %1"), b.row) or nil,
            callback = function()
                self:openPoemByUrl(b.url, { focus_row = b.row, snapshot = b.snapshot, subtitle = b.poet })
            end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove the bookmark “%1”?"), b.title),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        local idx = self:findBookmark(b.url, b.row)
                        if idx then
                            table.remove(list, idx)
                            self.settings:flush()
                        end
                        self:showBookmarks()
                    end,
                })
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No bookmarks yet. Tap the star in a poem; long-press a couplet to bookmark it.") })
    end
    self.bookmarks_menu = self:pushMenu(_("Bookmarks"), items)
end

-- ---------------------------------------------------------------------------
-- reading settings and fonts
-- ---------------------------------------------------------------------------

function Ganjoor:fontLabel(face)
    if not face then
        return _("Default")
    end
    return self.settings:readSetting("font_name") or face:match("([^/]+)$")
end

local LAYOUTS = {
    { id = "columns", label = _("two columns (like a poem page)") },
    { id = "staggered", label = _("staggered: 1st hemistich right, 2nd on the next line left") },
    { id = "stacked", label = _("centered, one hemistich per line") },
}

function Ganjoor:layoutLabel(id)
    for _i, l in ipairs(LAYOUTS) do
        if l.id == id then return l.label end
    end
    return LAYOUTS[1].label
end

function Ganjoor:showLayoutChoice(on_done)
    local current = self:getReadingSettings().layout
    local dialog
    local buttons = {}
    for _i, l in ipairs(LAYOUTS) do
        buttons[#buttons + 1] = {{
            text = (l.id == current and "\u{2713} " or "") .. l.label,
            callback = function()
                UIManager:close(dialog)
                self:saveSetting("layout", l.id)
                on_done()
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = _("Reading style"), buttons = buttons }
    UIManager:show(dialog)
end

function Ganjoor:showReadingSettings(on_change)
    local s = self:getReadingSettings()
    local dialog
    local function again()
        UIManager:close(dialog)
        if on_change then on_change() end
        self:showReadingSettings(on_change)
    end
    dialog = ButtonDialog:new{
        title = _("Reading settings"),
        buttons = {
            {{
                text = T(_("Font: %1"), self:fontLabel(s.face)),
                callback = function()
                    UIManager:close(dialog)
                    self:showFontMenu(function()
                        if on_change then on_change() end
                        self:showReadingSettings(on_change)
                    end)
                end,
            }},
            {{
                text = T(_("Font size: %1"), s.size),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Font size"),
                        value = s.size,
                        value_min = 12,
                        value_max = 48,
                        value_step = 1,
                        value_hold_step = 4,
                        default_value = 22,
                        ok_text = _("Apply"),
                        callback = function(spin)
                            self:saveSetting("font_size", spin.value)
                            if on_change then on_change() end
                            self:showReadingSettings(on_change)
                        end,
                        cancel_callback = function() self:showReadingSettings(on_change) end,
                    })
                end,
            }},
            {{
                text = T(_("Layout: %1"), self:layoutLabel(s.layout)),
                callback = function()
                    UIManager:close(dialog)
                    self:showLayoutChoice(function()
                        if on_change then on_change() end
                        self:showReadingSettings(on_change)
                    end)
                end,
            }},
            {{
                text = s.harakat and _("Diacritics: shown") or _("Diacritics: hidden"),
                callback = function()
                    self:saveSetting("harakat", not s.harakat)
                    again()
                end,
            }},
            {{ text = _("Close"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

function Ganjoor:showFontMenu(on_done)
    local ok, FontList = pcall(require, "fontlist")
    local paths = ok and FontList:getFontList() or {}
    local fonts = {}
    for _i, path in ipairs(paths) do
        local info = FontList.fontinfo and FontList.fontinfo[path]
        local face = info and info[1]
        if face and face.name then
            local label = face.name
            if face.bold then label = label .. " Bold" end
            if face.italic then label = label .. " Italic" end
            local persian = face.langs and (face.langs.fa or face.langs.ar) and true or false
            fonts[#fonts + 1] = { path = path, name = label, persian = persian }
        end
    end
    table.sort(fonts, function(a, b)
        if a.persian ~= b.persian then return a.persian end
        return a.name < b.name
    end)
    local menu
    local function use(path, name)
        self:saveSetting("font_face", path)
        self:saveSetting("font_name", name)
        UIManager:close(menu)
        on_done()
    end
    local items = {{
        text = _("Default (KOReader UI font)"),
        callback = function()
            self.settings:delSetting("font_face")
            self.settings:delSetting("font_name")
            self.settings:flush()
            UIManager:close(menu)
            on_done()
        end,
    }}
    for _i, f in ipairs(fonts) do
        table.insert(items, {
            text = f.name,
            mandatory = f.persian and "\u{0641}\u{0627}\u{0631}\u{0633}\u{06CC}" or nil, -- "فارسی"
            callback = function()
                UIManager:show(UI.FontPreview:new{
                    font_path = f.path,
                    font_name = f.name,
                    size = self:getReadingSettings().size,
                    on_use = function() use(f.path, f.name) end,
                })
            end,
        })
    end
    if #fonts == 0 then
        table.insert(items, { text = _("No extra fonts found. Copy .ttf files into koreader/fonts.") })
    end
    menu = self:pushMenu(_("Choose a font"), items)
end

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------

function Ganjoor:promptSearch(scope_slug, nick)
    self.store:refresh()
    if #self.store:localSlugs() == 0 then
        UIManager:show(InfoMessage:new{ text = _("No poets are stored on this device yet.") })
        return
    end
    local dialog
    local function go()
        local query = dialog:getInputText()
        UIManager:close(dialog)
        if query and query ~= "" then
            self:runSearch(query, scope_slug, nick)
        end
    end
    dialog = InputDialog:new{
        title = nick and T(_("Search in %1"), nick) or _("Search poems"),
        description = _("Searches the poets stored on this device. Spaces, half-spaces and diacritics don't matter."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = go },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ganjoor:runSearch(query, scope_slug, nick)
    local info = InfoMessage:new{ text = _("Searching…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local results, truncated = self.store:search(query, scope_slug, 100, 500)
    UIManager:close(info)
    if #results == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matches.") })
        return
    end
    local items = {}
    if truncated then
        table.insert(items, { text = _("Many matches: showing the first ones. Try a longer phrase.") })
    end
    for _i, r in ipairs(results) do
        table.insert(items, {
            text = r.title .. " \u{2014} " .. (r.nick or ""),
            mandatory = r.row == 0 and _("title") or T(_("Couplet %1"), r.row),
            callback = function()
                self:openPoemByUrl(r.url, { focus_row = r.row > 0 and r.row or nil, subtitle = r.nick })
            end,
        })
    end
    self:pushMenu(T(_("Search: %1"), query), items)
end

-- ---------------------------------------------------------------------------
-- downloads
-- ---------------------------------------------------------------------------

function Ganjoor:showDownloadDialog(poet, partial)
    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = T(_("%1 is not stored on this device."), poet.Nickname),
        buttons = {
            {{
                text = partial and _("Resume download") or _("Download for offline reading"),
                callback = act(function() self:downloadPoet(poet) end),
            }},
            {{
                text = _("Browse online (needs Wi-Fi)"),
                callback = act(function() self:showOnlineCategory(poet.FullUrl, poet.Nickname, poet.Nickname) end),
            }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

function Ganjoor:downloadPoet(poet)
    if not NetworkMgr:isOnline() then
        NetworkMgr:runWhenOnline(function() self:downloadPoet(poet) end)
        return
    end
    local nick = poet.Nickname
    Trapper:wrap(function()
        Trapper:setPausedText(_("Pause the download? You can resume it later."), _("Pause"), _("Continue"))
        Trapper:info(T(_("Reading the collections of %1…"), nick))
        local seen = 0
        local ok, res = Core.downloadPoet(self.store, poet,
            function(rel) return self:fetchRemote(rel) end,
            function(phase, done, total)
                seen = seen + 1
                if phase == "tree" then
                    if seen % 4 == 0 then
                        return Trapper:info(T(_("Reading the collections of %1…"), nick))
                    end
                    return true
                end
                if done % 6 == 0 or done == total then
                    return Trapper:info(T(_("Downloading %1: %2 / %3 poems\nTap the screen to pause."), nick, done, total))
                end
                return true
            end)
        Trapper:clear()
        local message
        if ok then
            message = T(_("%1 is now available offline (%2 poems)."), nick, res.poems)
            if res.failed > 0 then
                message = message .. "\n" .. T(_("%1 poems could not be downloaded."), res.failed)
            end
        elseif res == "cancelled" then
            message = _("Download paused. Open the poet again to resume.")
        elseif res == "network" then
            message = _("The connection was lost. Open the poet again to resume.")
        else
            message = _("Could not read the list of collections. Check your connection and try again.")
        end
        UIManager:show(InfoMessage:new{ text = message })
        if self.grid then
            self:showPoets()
        end
    end)
end

function Ganjoor:showManagePoets()
    self.store:refresh()
    local manifest = self:getManifest()
    local entries = {}
    for i, poet in ipairs(manifest.Poets or {}) do
        local state, e = self.store:poetState(Core.slugOf(poet.FullUrl))
        entries[#entries + 1] = { poet = poet, state = state, e = e, order = i }
    end
    local function rank(s) return (s == "bundled" and 1) or (s == "downloaded" and 2) or (s == "partial" and 3) or 4 end
    table.sort(entries, function(a, b)
        if rank(a.state) ~= rank(b.state) then return rank(a.state) < rank(b.state) end
        return a.order < b.order
    end)
    local menu
    local items = {}
    for _i, it in ipairs(entries) do
        local poet, state, e = it.poet, it.state, it.e
        local mandatory
        if state == "bundled" then
            mandatory = _("built-in")
        elseif state == "downloaded" then
            mandatory = megabytes(e.bytes)
        elseif state == "partial" then
            mandatory = e.total > 0 and string.format("%d%%", math.floor(100 * e.done / e.total)) or "…"
        else
            mandatory = "\u{2193}"
        end
        table.insert(items, {
            text = poet.Nickname,
            mandatory = mandatory,
            callback = function()
                if state == "bundled" then
                    UIManager:show(InfoMessage:new{ text = _("This poet is built into the plugin.") })
                elseif state == "downloaded" then
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete the downloaded poems of %1 (%2)?"), poet.Nickname, megabytes(e.bytes)),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self.store:deleteDownloaded(Core.slugOf(poet.FullUrl))
                            UIManager:close(menu)
                            self:showManagePoets()
                        end,
                    })
                else
                    UIManager:close(menu)
                    self:showDownloadDialog(poet, state == "partial")
                end
            end,
        })
    end
    menu = self:pushMenu(_("Poets and downloads"), items)
end

-- ---------------------------------------------------------------------------
-- open by Ganjoor id (needs the network for the id index)
-- ---------------------------------------------------------------------------

function Ganjoor:promptPoemId()
    local dialog
    dialog = InputDialog:new{
        title = _("Open poem by Ganjoor ID"),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Open"),
                is_enter_default = true,
                callback = function()
                    local id = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if id then self:openPoemById(id) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ganjoor:openPoemById(id)
    local shard_size = self:getManifest().IdIndexShardSize or 2000
    local shard = math.floor(id / shard_size)
    self:loadAndShow("index/poems-by-id/" .. shard .. ".json", function(index)
        local entry = index[tostring(id)]
        local full_url = type(entry) == "table" and entry.FullUrl or entry
        if not full_url then
            UIManager:show(InfoMessage:new{ text = T(_("No poem with ID %1."), id) })
            return
        end
        self:openPoemByUrl(full_url, {})
    end)
end

return Ganjoor

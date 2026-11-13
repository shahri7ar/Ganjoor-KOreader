-- Smoke test of main.lua / ganjoor_ui.lua against stubbed KOReader modules (strict globals).
-- luajit tests/smoke_ui.lua <plugin dir with data/> <ganjoor-data checkout>
package.cpath = package.cpath .. ";/usr/lib/x86_64-linux-gnu/lua/5.1/?.so"
local cjson = require("cjson")
local PLUG, SRC = arg[1], arg[2]
package.path = PLUG .. "/?.lua;" .. package.path

local failures, checks = 0, 0
local function check(c, m) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. m) end end
local shown = {}
local function sh(c) return os.execute(c) end

local function class(base)
    local C = {}
    C.__index = C
    if base then setmetatable(C, { __index = base }) end
    function C:extend(t)
        t = t or {}
        t.__index = t
        return setmetatable(t, { __index = self })
    end
    function C:new(o)
        o = setmetatable(o or {}, self)
        if o.ges_events == nil and rawget(self, "ges_events") == nil then o.ges_events = {} end
        o.key_events = o.key_events or {}
        if o.init then o:init() end
        return o
    end
    function C:handleEvent() return false end
    function C:getSize() return { w = self.width or 100, h = self.height or 40 } end
    function C:getHeight() return 50 end
    function C:free() end
    function C:paintTo() end
    return C
end
local function stubmod(name, v) package.preload[name] = function() return v end end
local Widget = class()
local function widget() return class(Widget) end

stubmod("ui/bidi", { mirroredUILayout = function() return false end, invert = function() end, resetInvert = function() end })
stubmod("ffi/blitbuffer", { COLOR_WHITE = 1, COLOR_BLACK = 0, COLOR_GRAY_E = 2, COLOR_DARK_GRAY = 3 })
local Screen = { getWidth = function() return 800 end, getHeight = function() return 1000 end, scaleBySize = function(_, n) return n end }
stubmod("device", { screen = Screen, isTouchDevice = function() return true end, hasKeys = function() return true end,
    input = { group = { Back = "Back", PgFwd = "PgFwd", PgBack = "PgBack" } } })
stubmod("ui/font", { getFace = function(_, name, size) return { size = size or 22, name = name } end })
local Geom = class(); stubmod("ui/geometry", Geom)
stubmod("ui/size", { padding = { large = 10 }, radius = { window = 5 }, border = { window = 2 }, line = { medium = 1 } })
stubmod("ui/gesturerange", class())
local TB = widget()
function TB:getSize()
    local per_line = math.max(1, math.floor(self.width / 12))
    return { w = self.width, h = 30 * math.ceil(#self.text / (per_line * 2)) }
end
stubmod("ui/widget/textboxwidget", TB)
for _, n in ipairs({ "button", "buttontable", "textwidget", "horizontalspan", "verticalspan", "spinwidget", "infomessage", "inputdialog", "confirmbox", "buttondialog" }) do
    stubmod("ui/widget/" .. n, widget())
end
local ID = package.preload["ui/widget/inputdialog"]() ; function ID:onShowKeyboard() end; function ID:getInputText() return "" end
stubmod("ui/widget/inputdialog", ID)
local TitleBar = widget(); stubmod("ui/widget/titlebar", TitleBar)
stubmod("ui/widget/widget", Widget)
for _, n in ipairs({ "centercontainer", "framecontainer", "inputcontainer", "widgetcontainer" }) do
    stubmod("ui/widget/container/" .. n, widget())
end
stubmod("ui/widget/horizontalgroup", widget()); stubmod("ui/widget/verticalgroup", widget())
local Menu = widget(); function Menu:switchItemTable() end; function Menu:init() end; function Menu:updateItems() end; function Menu:onSwipe() end; stubmod("ui/widget/menu", Menu)
local TV = widget(); function TV:init() end; stubmod("ui/widget/textviewer", TV)
local UIM = { shown = {}, dirty = 0 }
function UIM:show(w) table.insert(self.shown, w); shown[#shown + 1] = w end
function UIM:close(w) for i = #self.shown, 1, -1 do if self.shown[i] == w then table.remove(self.shown, i) end end end
function UIM:setDirty() self.dirty = self.dirty + 1 end
function UIM:forceRePaint() end
stubmod("ui/uimanager", UIM)
stubmod("ui/network/manager", { isOnline = function() return true end, runWhenOnline = function(_, cb) cb() end })
stubmod("ui/trapper", { wrap = function(_, f) f() end, info = function() return true end, clear = function() end, setPausedText = function() end })
local registered = {}
stubmod("dispatcher", { registerAction = function(_, name, def) registered[name] = def; return true end })
stubmod("gettext", function(s) return s end)
stubmod("datastorage", { getDataDir = function() return "/tmp/kodata" end, getSettingsDir = function() return "/tmp/kodata/settings" end })
local function settings()
    local S = { data = {} }
    function S:readSetting(k, d) if self.data[k] == nil and d ~= nil then self.data[k] = d end return self.data[k] end
    function S:saveSetting(k, v) self.data[k] = v end
    function S:delSetting(k) self.data[k] = nil end
    function S:flush() end
    return S
end
stubmod("luasettings", { open = function() return settings() end })
stubmod("json", { decode = cjson.decode })
stubmod("logger", { warn = function() end, info = function() end })
stubmod("ltn12", { sink = { table = function() end } })
stubmod("socket", { skip = function() return 404 end })
stubmod("socket.http", { request = function() return 1, 404 end })
stubmod("socketutil", { set_timeout = function() end, reset_timeout = function() end })
stubmod("libs/libkoreader-lfs", {
    attributes = function(p, what)
        if os.execute('test -f "' .. p .. '"') == 0 then return "file" end
        if os.execute('test -d "' .. p .. '"') == 0 then return "directory" end
    end,
    dir = function(p)
        local t = {}
        local h = io.popen('ls -1 "' .. p .. '" 2>/dev/null')
        for l in h:lines() do t[#t + 1] = l end
        h:close()
        local i = 0
        return function() i = i + 1; return t[i] end
    end,
})
stubmod("util", { makePath = function(p) sh('mkdir -p "' .. p .. '"') end })
stubmod("ffi/util", {
    template = function(s, ...) local a = { ... }; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end,
    purgeDir = function(p) sh('rm -rf "' .. p .. '"') end,
})
stubmod("fontlist", { getFontList = function() return { "/f/Vazir.ttf", "/f/Plain.ttf" } end,
    fontinfo = { ["/f/Vazir.ttf"] = { { name = "Vazirmatn", langs = { fa = 1 } } }, ["/f/Plain.ttf"] = { { name = "Plain", bold = true } } } })

-- strict globals from here on
G_reader_settings = { readSetting = function() end, nilOrTrue = function() return true end }
setmetatable(_G, { __index = function(_, k) error("undefined global: " .. tostring(k), 2) end })

sh("rm -rf /tmp/kodata; mkdir -p /tmp/kodata/settings")
-- load the plugin exactly like KOReader: dofile(main.lua)
local Ganjoor = dofile(PLUG .. "/main.lua")
local plugin = Ganjoor:new{ ui = { menu = { registerToMainMenu = function() end } } }
check(registered.ganjoor_open and registered.ganjoor_open.event == "Ganjoor" and registered.ganjoor_open.category == "none", "dispatcher action registered")
check(registered.ganjoor_continue and registered.ganjoor_fal and registered.ganjoor_search, "all dispatcher actions registered")
for name, def in pairs(registered) do
    check(type(plugin["on" .. def.event]) == "function", "handler exists for event " .. def.event)
end
-- the name Simple UI's plugin picker looks for
check(type(plugin["on" .. plugin.name:sub(1, 1):upper() .. plugin.name:sub(2)]) == "function", "Simple UI plugin-picker method (onGanjoor)")
local menu_items = {}
plugin:addToMainMenu(menu_items)
check(#menu_items.ganjoor.sub_item_table == 8, "main menu entries")

local function last(t) return t[#t] end
local function itemByText(items, pat)
    for _, it in ipairs(items) do if it.text and it.text:find(pat, 1, true) then return it end end
end
local function dialogButton(dialog, pat)
    for _, row in ipairs(dialog.buttons) do for _, b in ipairs(row) do if b.text:find(pat, 1, true) then return b end end end
end

plugin:onGanjoor()
check(last(UIM.shown).items ~= nil, "onGanjoor opens the poets grid")

-- poets grid: bundled poets first, others marked
plugin:showPoets()
local grid = last(UIM.shown)
check(grid.items and #grid.items > 100, "grid lists all poets (" .. tostring(grid.items and #grid.items) .. ")")
check(grid.items[1].text == "حافظ", "bundled poet first")
local down = itemByText(grid.items, "\u{2193} ")
check(down ~= nil, "non-local poets are marked")

-- open a bundled poet -> categories -> poems
grid.items[1].callback()
local menu = last(UIM.shown)
check(menu.item_table[1].text:find("Search in"), "poet menu starts with search entry")
local about = itemByText(menu.item_table, "About"); check(about ~= nil, "about entry")
local ghazal = itemByText(menu.item_table, "غزلیات"); check(ghazal ~= nil, "category entry")
ghazal.callback()
local poems_menu = last(UIM.shown)
check(#poems_menu.item_table == 495, "ghazal list has 495 poems (" .. #poems_menu.item_table .. ")")
poems_menu.item_table[1].callback()
local view = last(UIM.shown)
check(view.poem and view.poem.t == "غزل شمارهٔ ۱", "poem view opened")
check(#view.placed > 3, "page has rows (" .. #view.placed .. ")")
check(view.subtitle == "حافظ \u{00BB} غزلیات", "subtitle")
check(view.on_next ~= nil and view.on_prev == nil, "first poem: next only")
local before = view.title
view:nextPage()  -- poem fits on one page? then goes to next poem
-- paging inside a long poem + navigation to next poem at the end
local safety = 0
while view.title == before and safety < 50 do view:nextPage(); safety = safety + 1 end
check(view.title == "غزل شمارهٔ ۲", "forward past the end opens the next poem (" .. tostring(view.title) .. ")")
check(view.on_prev ~= nil, "prev available now")
view:prevPage()
check(view.title == "غزل شمارهٔ ۱", "back from first page goes to previous poem")

-- bookmark toggle + couplet bookmark
view:onClose()
check(plugin:isBookmarked(view.ctx.url) == false, "not bookmarked")
plugin:toggleBookmark(view, nil)
check(plugin:isBookmarked(view.ctx.url) == true, "bookmarked")
plugin:toggleBookmark(view, 2)
check(plugin:markedRows(view.ctx.url)[2] == true, "couplet bookmark")
check(#plugin:getBookmarks() == 2, "two bookmarks")
plugin:showBookmarks()
local bm = last(UIM.shown)
check(#bm.item_table == 2 and bm.item_table[1].mandatory ~= bm.item_table[2].mandatory, "bookmark list")
local with_row
for _, it in ipairs(bm.item_table) do if it.mandatory then with_row = it end end
with_row.callback()
local v2 = last(UIM.shown)
check(v2.focus_row == 2 or v2.page >= 1, "bookmark opens poem")
check(v2.ctx.focus_row == 2, "focus row passed")

-- long poem: pagination and gotoRow
local shahnameh_url
local meta = plugin.store:getMeta("hafez")
local long_poem = { t = "long", v = {} }
for i = 1, 120 do long_poem.v[i] = { "مصرع اول شماره " .. i, "مصرع دوم شماره " .. i } end
long_poem.v[60] = { 1, string.rep("کلمه ", 500) } -- long prose gets split
plugin:showPoemView({ url = "/x/long", poem = long_poem, subtitle = "t » c", focus_row = 100 })
local lv = last(UIM.shown)
check(lv.page > 1, "focus row on a later page (page " .. lv.page .. ")")
local found = false
for _, p in ipairs(lv.placed) do if p.item.src == 100 then found = true end end
check(found, "focused row is on the shown page")
local pages = 1
local start_page = lv.page
for i = 1, 30 do if not lv.at_end then lv:nextPage() end end
check(lv.at_end, "reached the end")
lv:relayout()
check(#lv.placed > 0, "relayout keeps a page")
plugin:saveSetting("layout", "stacked"); lv:relayout(); check(#lv.placed > 0, "stacked layout")
plugin:saveSetting("layout", "staggered"); lv:relayout()
do
    local pair
    for _, p in ipairs(lv.placed) do if p.item.kind == "pair" then pair = p.widget break end end
    check(pair and pair.first and pair.first.alignment == "right" and pair.second.alignment == "left", "staggered: 1st hemistich right-aligned, 2nd left-aligned")
    check(pair.first.text:find("اول", 1, true) and pair.second.text:find("دوم", 1, true), "staggered: first hemistich on the first line")
end
plugin:saveSetting("layout", "columns"); lv:relayout()
do
    local pair
    for _, p in ipairs(lv.placed) do if p.item.kind == "pair" then pair = p.widget break end end
    check(pair and pair.right and pair.left, "columns layout still side by side")
end
plugin:saveSetting("harakat", false); lv:relayout(); check(#lv.placed > 0, "no harakat")
check(lv:rowAtY(lv.body_dimen.y + lv.placed[1].y + 1) == lv.placed[1].item.src, "rowAtY")

-- search
plugin:runSearch("الا یا ایها الساقی")
local res = last(UIM.shown)
check(res.item_table[1].mandatory:find("Couplet 1"), "search result couplet label: " .. tostring(res.item_table[1].mandatory))
res.item_table[1].callback()
local sv = last(UIM.shown)
check(sv.ctx.focus_row == 1 and sv.poem.t:find("غزل"), "search result opens poem at the couplet")
check(sv.on_next ~= nil and sv.ctx.subtitle == "حافظ \u{00BB} غزلیات", "search result gets siblings and subtitle")
sv:onClose()
-- continue reading: saved on close, reopens at the same place
plugin.settings:saveSetting("last_read", nil)
plugin:showPoemView({ url = "/x/long", poem = long_poem, subtitle = "t » c", focus_row = 100 })
local cv = last(UIM.shown)
cv:onClose()
local lr = plugin.settings:readSetting("last_read")
check(lr and lr.url == "/x/long" and lr.row and lr.row > 1 and lr.snapshot ~= nil, "last read saved (row " .. tostring(lr and lr.row) .. ")")
plugin:continueReading()
local rv = last(UIM.shown)
check(rv.ctx.start_row == lr.row and rv.focus_row == nil, "continue reading restores the position without highlight")
local shown_ok = false
for _, p in ipairs(rv.placed) do if p.item.src == lr.row then shown_ok = true end end
check(shown_ok, "restored page shows the saved row")
plugin:runSearch("zzzzzz")


-- ---- RTL navigation: right = forward, left = back, middle = menu; edges move between poems with a message
do
    local function tap(v, x) v:onPoemTap(nil, { pos = { x = x, y = 500 } }) end
    local function swipe(v, d) v:onPoemSwipe(nil, { direction = d }) end
    local function lastText() local w = last(UIM.shown); return w.text end
    -- a long poem (several pages) inside a list of three poems
    local mk = function(title, n) local p = { t = title, v = {} } for i = 1, n do p.v[i] = { "مصرع اول " .. i, "مصرع دوم " .. i } end return p end
    local polys = { mk("A", 60), mk("B", 60), mk("C", 10) }
    local entries = { { url = "/t/a", title = "A" }, { url = "/t/b", title = "B" }, { url = "/t/c", title = "C" } }
    local orig = plugin.resolvePoem
    function plugin:resolvePoem(url) for i, e in ipairs(entries) do if e.url == url then return polys[i] end end end
    plugin:showPoemView({ url = "/t/a", poem = polys[1], entries = entries, index = 1, subtitle = "x » y" })
    local v = last(UIM.shown)
    check(v.page == 1 and not v.at_end, "long poem starts on page 1 (not at end)")
    tap(v, 790)                       -- right edge = forward
    check(v.page == 2 and v.title == "A", "tap on the right moves to the next part, same poem")
    tap(v, 10)                        -- left edge = back
    check(v.page == 1 and v.title == "A", "tap on the left moves back a part")
    swipe(v, "east"); check(v.page == 2, "swipe east (towards the right) is forward")
    swipe(v, "west"); check(v.page == 1, "swipe west is back")
    local n = 0
    while v.title == "A" and n < 40 do tap(v, 790); n = n + 1 end
    check(v.title == "B" and v.page == 1, "after the last part the next poem opens (" .. n .. " taps)")
    check(lastText() and lastText():find("Next poem: B", 1, true) ~= nil, "message announces the next poem: " .. tostring(lastText()))
    tap(v, 10)                        -- back past the first part of B
    check(v.title == "A" and v.at_end, "going back from the first part lands on the END of the previous poem")
    check(lastText():find("Previous poem: A", 1, true) ~= nil, "message announces the previous poem")
    -- the middle of the page opens the menu (no footer buttons any more)
    tap(v, 400)
    local d = last(UIM.shown)
    check(d.buttons and dialogButton(d, "Reading settings") and dialogButton(d, "Bookmark this poem") and dialogButton(d, "Next poem"), "middle tap opens the poem menu")
    dialogButton(d, "Next poem").callback()
    check(v.title == "B", "menu: next poem")
    -- list edges
    while v.on_next do v.on_next(v) end
    check(v.title == "C" and v.on_next == nil, "last poem of the list has no next")
    local n2 = 0
    while not v.at_end and n2 < 40 do tap(v, 790); n2 = n2 + 1 end
    tap(v, 790)
    check(lastText():find("last poem in this list", 1, true) ~= nil, "message at the end of the list: " .. tostring(lastText()))
    plugin.resolvePoem = orig
end

-- Hafez fal and random poem
for i = 1, 5 do
    plugin:hafezFal()
    check(last(UIM.shown).ctx.url:find("^/hafez/ghazal/") ~= nil, "fal opens a Hafez ghazal")
end
plugin:randomPoem()
check(last(UIM.shown).poem ~= nil, "random poem opens")

-- layout choice dialog
plugin:showReadingSettings(function() end)
do
    local sd2 = last(UIM.shown)
    dialogButton(sd2, "Layout:").callback()
    local ld = last(UIM.shown)
    check(dialogButton(ld, "staggered") ~= nil and dialogButton(ld, "two columns") ~= nil, "layout dialog lists the styles")
    dialogButton(ld, "staggered").callback()
    check(plugin:getReadingSettings().layout == "staggered", "staggered chosen from the dialog")
    plugin:saveSetting("layout", "columns")
end

-- settings dialogs & fonts
plugin:showReadingSettings(function() end)
local sd = last(UIM.shown)
check(dialogButton(sd, "Font: Default") ~= nil, "settings dialog shows default font")
dialogButton(sd, "Font:").callback()
local fm = last(UIM.shown)
check(fm.item_table[2].text == "Vazirmatn" and fm.item_table[2].mandatory ~= nil, "Persian fonts listed first")
fm.item_table[2].callback()
local prev = last(UIM.shown)
prev.on_use()
check(plugin:getReadingSettings().face == "/f/Vazir.ttf", "font saved")
check(plugin:fontLabel("/f/Vazir.ttf") == "Vazirmatn", "font label")

-- downloads UI
plugin.store:refresh()
local dl_poet
for _, p in ipairs(plugin:getManifest().Poets) do if p.FullUrl == "/mahsati" then dl_poet = p end end
plugin:onPoetTap(dl_poet)
local dd = last(UIM.shown)
check(dialogButton(dd, "Download") ~= nil and dialogButton(dd, "Browse online") ~= nil, "download dialog")
plugin:showManagePoets()
check(last(UIM.shown).item_table[1].mandatory == "built-in", "manage list starts with built-in poets")
plugin:showMainActions()
check(#last(UIM.shown).buttons >= 9, "main actions dialog")
plugin:promptSearch("hafez", "حافظ")
plugin:promptPoemId()

-- real download through the plugin (fetchRemote reads the local checkout)
function plugin:fetchRemote(rel)
    local f = io.open(SRC .. "/" .. rel, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return cjson.decode(s)
end
plugin:downloadPoet(dl_poet)
check(plugin.store:poetState("mahsati") == "downloaded", "poet downloaded through the plugin")
check(#plugin.store:search("دل", "mahsati") > 0, "downloaded poet is readable/searchable")
plugin:showPoets()
check(last(UIM.shown).items[1].text == "حافظ", "grid rebuilt after download")
local obeyd_item
for _, it in ipairs(last(UIM.shown).items) do if it.text == "مهستی گنجوی" then obeyd_item = it end end
check(obeyd_item ~= nil, "downloaded poet now listed without the arrow")

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

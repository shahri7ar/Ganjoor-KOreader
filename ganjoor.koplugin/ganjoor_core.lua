--[[
Pure-Lua logic of the Ganjoor plugin (no KOReader UI dependencies, so it can be unit tested
with plain LuaJIT, see tests/).

Local data layout, shared by the poets bundled with the plugin (data/<slug>/) and by poets
downloaded on the device (<koreader data dir>/ganjoor/poets/<slug>/):

  cats.json  {"id":..,"nick":..,"url":"/hafez","desc":"..","chunks":N,
              "cats":{ "/hafez": {"t":title,"c":[childCatUrl..],"p":[[title,leaf,chunk],..]} }}
             poem url = catUrl .. "/" .. leaf   (a leaf that starts with "/" is a full url)
  info.json  {"nick":..,"chunks":N,"poems":N,"bytes":N}
  p<N>.json  { "<poem url>": {"t":title,"m":metre?,"v":[row..]} }
             row = ["right","left"]   couplet (two hemistichs)
                 | [1,"text"]         paragraph / prose
                 | [2,"text"]         centered verse line
                 | [3,"text"]         comment / footnote
  s<N>.txt   search index of p<N>.json, one poem per line:
             url \t title \t normTitle|normRow1|normRow2|...   (segment k == row k, 0 == title)

tools/build_offline_data.py produces exactly the same format (normalize() must stay identical).
]]

local Core = {}

local CHUNK_BYTES = 120000 -- target size of one p<N>.json
Core.CHUNK_BYTES = CHUNK_BYTES

-- ---------------------------------------------------------------------------
-- UTF-8 helpers / Persian text normalisation
-- ---------------------------------------------------------------------------

local function U(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
Core.utf8char = U

local DELETE, MAP = {}, {}
for cp = 0x064B, 0x065F do DELETE[U(cp)] = true end -- harakat, hamza marks
for _i, cp in ipairs({
    0x0670, 0x0640, 0x200C, 0x200D, 0x200E, 0x200F, 0x00A0, 0x202A, 0x202B, 0x202C, 0xFEFF,
    0x20, 0x09, 0x0D, 0x0A, 0x066B, 0x066C, 0x06D4,
}) do
    DELETE[U(cp)] = true
end
for ch in ("،؛؟!.,;:?()[]{}«»\"'-–—…*_/\\"):gmatch("[\1-\127\194-\244][\128-\191]*") do
    DELETE[ch] = true
end
for from, to in pairs({
    [0x064A] = 0x06CC, [0x0649] = 0x06CC, [0x0643] = 0x06A9, [0x06D5] = 0x0647,
    [0x0623] = 0x0627, [0x0625] = 0x0627, [0x0622] = 0x0627, [0x0671] = 0x0627,
    [0x06C0] = 0x0647, [0x0629] = 0x0647,
}) do
    MAP[U(from)] = U(to)
end
for i = 0, 9 do
    MAP[U(0x06F0 + i)] = tostring(i)
    MAP[U(0x0660 + i)] = tostring(i)
end

local CHAR_PATTERN = "[\1-\127\194-\244][\128-\191]*"

-- Search key: no spaces, ZWNJ, harakat or punctuation; Arabic ي/ك folded into ی/ک ...
-- Must stay identical to normalize() in tools/build_offline_data.py.
function Core.normalize(s)
    return (s:gsub(CHAR_PATTERN, function(ch)
        if DELETE[ch] then
            return ""
        end
        return MAP[ch] -- nil keeps the character
    end))
end

-- Removes only the diacritics (keeps ZWNJ, spaces, ...), for the "show diacritics: off" option.
function Core.stripHarakat(s)
    return (s:gsub("\217[\139-\159]", ""):gsub("\217\176", ""))
end

-- ---------------------------------------------------------------------------
-- Minimal JSON encoder (decoding uses KOReader's `json`)
-- ---------------------------------------------------------------------------

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    return '"' .. s:gsub('[\1-\31"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encode(v, out)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = encodeString(v)
    elseif t == "number" then
        out[#out + 1] = (v == math.floor(v)) and string.format("%d", v) or string.format("%.14g", v)
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "table" then
        if v[1] ~= nil then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = encodeString(tostring(k))
                out[#out + 1] = ":"
                encode(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        error("cannot encode " .. t)
    end
end

function Core.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Poem conversion (remote ganjoor-data poem -> compact local poem)
-- ---------------------------------------------------------------------------

local KIND_BY_POSITION = { Paragraph = 1, CenteredVerse1 = 2, CenteredVerse2 = 2, Comment = 3 }

function Core.convertRemotePoem(d, fallback_title)
    local rows, pending = {}, nil
    for _i, verse in ipairs(d.Verses or {}) do
        local text = (verse.Text or ""):match("^%s*(.-)%s*$")
        if text ~= "" then
            local pos = verse.Position
            if pos == "Right" then
                if pending then
                    rows[#rows + 1] = { pending, "" }
                end
                pending = text
            elseif pos == "Left" then
                rows[#rows + 1] = { pending or "", text }
                pending = nil
            else
                if pending then
                    rows[#rows + 1] = { pending, "" }
                    pending = nil
                end
                rows[#rows + 1] = { KIND_BY_POSITION[pos] or 1, text }
            end
        end
    end
    if pending then
        rows[#rows + 1] = { pending, "" }
    end
    if #rows == 0 then -- prose-only poems keep their plain text
        for _i, section in ipairs(d.Sections or {}) do
            local plain = section.PlainText
            if plain then
                plain = plain:gsub("\r\n", "\n")
                for para in plain:gmatch("[^\n]+") do
                    para = para:match("^%s*(.-)%s*$")
                    if para ~= "" then
                        rows[#rows + 1] = { 1, para }
                    end
                end
            end
        end
    end
    local poem = { t = (d.Title and d.Title ~= "" and d.Title) or fallback_title or "", v = rows }
    if d.Metre and d.Metre.Rhythm and d.Metre.Rhythm ~= "" then
        poem.m = d.Metre.Rhythm
    end
    return poem
end

function Core.rowText(row)
    if type(row[1]) == "number" then
        return row[2]
    end
    return row[1] .. row[2]
end

function Core.searchLine(url, poem)
    local segs = { Core.normalize(poem.t) }
    for i, row in ipairs(poem.v) do
        segs[i + 1] = Core.normalize(Core.rowText(row))
    end
    local title = poem.t:gsub("[\t\n]", " ")
    return url .. "\t" .. title .. "\t" .. table.concat(segs, "|")
end

-- Splits long prose into pieces of at most `maxlen` bytes at spaces, so it can be paginated.
function Core.splitProse(text, maxlen)
    if #text <= maxlen then
        return { text }
    end
    local pieces, start = {}, 1
    while #text - start + 1 > maxlen do
        local cut
        -- prefer the last sentence end within the window, else the last space
        local window = text:sub(start, start + maxlen - 1)
        local last_end
        for _i, pat in ipairs({ "%.%s()", "!%s()", "\216\159%s()", "\216\155%s()" }) do -- . ! ؟ ؛
            for pos in window:gmatch(pat) do
                if not last_end or pos > last_end then
                    last_end = pos
                end
            end
        end
        if last_end and last_end > maxlen * 0.5 then
            cut = start + last_end - 1
        else
            local last_space
            for pos in window:gmatch("%s()") do
                last_space = pos
            end
            cut = last_space and (start + last_space - 1) or (start + maxlen)
        end
        -- never cut inside a UTF-8 sequence
        while cut <= #text and text:byte(cut) and text:byte(cut) >= 0x80 and text:byte(cut) < 0xC0 do
            cut = cut + 1
        end
        pieces[#pieces + 1] = text:sub(start, cut - 1):gsub("%s+$", "")
        start = cut
    end
    local rest = text:sub(start):gsub("^%s+", "")
    if rest ~= "" then
        pieces[#pieces + 1] = rest
    end
    return pieces
end

-- ---------------------------------------------------------------------------
-- Search over s<N>.txt blobs
-- ---------------------------------------------------------------------------

-- Appends matches in `blob` to `out` (at most `limit`); returns true when the limit was hit.
-- Each match: { url=, title=, row= } where row 0 means the title, k the k-th row of the poem.
function Core.searchBlob(blob, needle, out, limit, extra)
    for line in blob:gmatch("[^\n]+") do
        local url, title, body = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
        if body then
            local pos = body:find(needle, 1, true)
            if pos then
                local seg, init = 0, 1
                while true do
                    local bar = body:find("|", init, true)
                    if not bar or bar >= pos then break end
                    seg = seg + 1
                    init = bar + 1
                end
                local hit = { url = url, title = title, row = seg }
                if extra then
                    for k, v in pairs(extra) do hit[k] = v end
                end
                out[#out + 1] = hit
                if #out >= limit then
                    return true
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Local data store (bundled + downloaded poets)
--
-- env = {
--   json_decode(str) -> table, read_file(path) -> str|nil, write_file(path, str) -> bool,
--   exists(path) -> bool, list_dir(path) -> {names}, mkdir_p(path), remove_dir(path),
--   remove_file(path)
-- }
-- ---------------------------------------------------------------------------

local Store = {}
Store.__index = Store

function Core.newStore(env, bundled_dir, downloaded_dir)
    return setmetatable({
        env = env,
        bundled_dir = bundled_dir,
        dl_dir = downloaded_dir,
        registry = nil,
        meta_cache = {},   -- slug -> meta (last two kept)
        meta_order = {},
        chunk_cache = {},  -- "slug/N" -> chunk table (last two kept)
        chunk_order = {},
    }, Store)
end

function Store:decodeFile(path)
    local raw = self.env.read_file(path)
    if not raw or raw == "" then
        return nil
    end
    local ok, t = pcall(self.env.json_decode, raw)
    if ok and type(t) == "table" then
        return t
    end
    return nil
end

function Core.slugOf(url)
    return (url:gsub("^/", ""):match("^[^/]+"))
end

-- Scans the bundled list and the download folder. Cheap; called again after every change.
function Store:refresh()
    local reg = { by_slug = {}, order = {} }
    local function add(slug, entry)
        if not reg.by_slug[slug] then
            reg.order[#reg.order + 1] = slug
        end
        reg.by_slug[slug] = entry
    end
    -- downloaded first, so that bundled poets win when both exist
    local names = self.env.list_dir(self.dl_dir)
    table.sort(names)
    for _i, name in ipairs(names) do
        local dir = self.dl_dir .. "/" .. name
        if self.env.exists(dir .. "/info.json") and self.env.exists(dir .. "/cats.json") then
            local info = self:decodeFile(dir .. "/info.json") or {}
            add(name, { kind = "downloaded", dir = dir, nick = info.nick, chunks = info.chunks or 0,
                poems = info.poems or 0, bytes = info.bytes or 0 })
        elseif self.env.exists(dir .. "/progress.json") then
            local prog = self:decodeFile(dir .. "/progress.json") or {}
            add(name, { kind = "partial", dir = dir, done = prog.done or 0, total = prog.queue and #prog.queue or 0,
                nick = prog.nick })
        end
    end
    local bundled = self:decodeFile(self.bundled_dir .. "/poets.json")
    if bundled and bundled.poets then
        for _i, p in ipairs(bundled.poets) do
            local slug = p.slug or Core.slugOf(p.url or "")
            add(slug, { kind = "bundled", dir = self.bundled_dir .. "/" .. slug, nick = p.nick,
                chunks = p.chunks or 0, poems = p.poems or 0, bytes = p.bytes or 0 })
        end
    end
    -- bundled poets first in the order list, in the order of poets.json
    local ordered, seen = {}, {}
    if bundled and bundled.poets then
        for _i, p in ipairs(bundled.poets) do
            local slug = p.slug or Core.slugOf(p.url or "")
            if not seen[slug] then
                seen[slug] = true
                ordered[#ordered + 1] = slug
            end
        end
    end
    for _i, slug in ipairs(reg.order) do
        if not seen[slug] then
            seen[slug] = true
            ordered[#ordered + 1] = slug
        end
    end
    reg.order = ordered
    self.registry = reg
    self.meta_cache, self.meta_order, self.chunk_cache, self.chunk_order = {}, {}, {}, {}
end

-- Returns "bundled" | "downloaded" | "partial" | nil, plus the registry entry.
function Store:poetState(slug)
    if not self.registry then self:refresh() end
    local e = self.registry.by_slug[slug]
    return e and e.kind or nil, e
end

function Store:localSlugs()
    if not self.registry then self:refresh() end
    local list = {}
    for _i, slug in ipairs(self.registry.order) do
        local kind = self.registry.by_slug[slug].kind
        if kind == "bundled" or kind == "downloaded" then
            list[#list + 1] = slug
        end
    end
    return list
end

local function remember(cache, order, key, value, keep)
    cache[key] = value
    for i = #order, 1, -1 do
        if order[i] == key then table.remove(order, i) end
    end
    table.insert(order, key)
    while #order > keep do
        cache[table.remove(order, 1)] = nil
    end
end

function Store:getMeta(slug)
    if self.meta_cache[slug] then
        return self.meta_cache[slug]
    end
    local kind, entry = self:poetState(slug)
    if kind ~= "bundled" and kind ~= "downloaded" then
        return nil
    end
    local meta = self:decodeFile(entry.dir .. "/cats.json")
    if meta then
        remember(self.meta_cache, self.meta_order, slug, meta, 2)
    end
    return meta
end

function Store:getChunk(slug, n)
    local key = slug .. "/" .. n
    if self.chunk_cache[key] then
        return self.chunk_cache[key]
    end
    local _kind, entry = self:poetState(slug)
    if not entry then
        return nil
    end
    local chunk = self:decodeFile(entry.dir .. "/p" .. n .. ".json")
    if chunk then
        remember(self.chunk_cache, self.chunk_order, key, chunk, 3)
    end
    return chunk
end

function Core.poemUrl(cat_url, leaf)
    if leaf:sub(1, 1) == "/" then
        return leaf
    end
    return cat_url .. "/" .. leaf
end

function Store:poemUrlFor(cat_url, entry)
    return Core.poemUrl(cat_url, entry[2])
end

-- Finds a poem by its full url in the local data.
function Store:getPoem(url)
    local slug = Core.slugOf(url)
    local kind = self:poetState(slug)
    if kind ~= "bundled" and kind ~= "downloaded" then
        return nil
    end
    local meta = self:getMeta(slug)
    if not meta then
        return nil
    end
    local parent = url:match("^(.*)/[^/]+$")
    local node = parent and meta.cats[parent]
    if node and node.p then
        for _i, entry in ipairs(node.p) do
            if Core.poemUrl(parent, entry[2]) == url then
                local chunk = self:getChunk(slug, entry[3])
                return chunk and chunk[url] or nil
            end
        end
    end
    -- fallback (a url that doesn't follow cat/leaf): look in every category
    for cat_url, n in pairs(meta.cats) do
        for _i, entry in ipairs(n.p or {}) do
            if Core.poemUrl(cat_url, entry[2]) == url then
                local chunk = self:getChunk(slug, entry[3])
                return chunk and chunk[url] or nil
            end
        end
    end
    return nil
end

-- Full-text search over local poets. scope_slug limits it to one poet.
-- Returns results {url,title,row,slug,nick} and a flag telling whether the limit cut the list.
function Store:search(query, scope_slug, per_poet_limit, total_limit)
    per_poet_limit = per_poet_limit or 100
    total_limit = total_limit or 500
    local needle = Core.normalize(query):gsub("|", "")
    if needle == "" then
        return {}, false
    end
    local results, truncated = {}, false
    for _i, slug in ipairs(self:localSlugs()) do
        if not scope_slug or scope_slug == slug then
            local _kind, entry = self:poetState(slug)
            local found = {}
            for n = 1, entry.chunks do
                local blob = self.env.read_file(entry.dir .. "/s" .. n .. ".txt")
                if blob then
                    local hit_limit = Core.searchBlob(blob, needle, found, per_poet_limit,
                        { slug = slug, nick = entry.nick })
                    if hit_limit then
                        truncated = true
                        break
                    end
                end
            end
            for _j, hit in ipairs(found) do
                results[#results + 1] = hit
                if #results >= total_limit then
                    return results, true
                end
            end
        end
    end
    return results, truncated
end

function Store:deleteDownloaded(slug)
    local kind, entry = self:poetState(slug)
    if kind == "downloaded" or kind == "partial" then
        self.env.remove_dir(entry.dir)
        self:refresh()
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Resumable poet downloader
--
-- fetch(rel_path) -> decoded json table | nil     (e.g. "poets/hafez/_cat.json")
-- progress(phase, done, total) -> false to cancel (phase: "tree" | "poems")
-- Returns true, summary | false, reason ("cancelled" | "network" | "tree")
-- ---------------------------------------------------------------------------

local function leafOf(cat_url, poem_url)
    local prefix = cat_url .. "/"
    if poem_url:sub(1, #prefix) == prefix then
        return poem_url:sub(#prefix + 1)
    end
    return poem_url
end

function Core.downloadPoet(store, poet, fetch, progress)
    local env = store.env
    local slug = Core.slugOf(poet.FullUrl)
    local dir = store.dl_dir .. "/" .. slug
    env.mkdir_p(dir)
    local prog_path = dir .. "/progress.json"

    local state
    local raw = env.read_file(prog_path)
    if raw then
        local ok, t = pcall(env.json_decode, raw)
        if ok and type(t) == "table" and t.queue and t.cats then
            state = t
        end
    end

    local cancelled = false
    local function report(phase, done, total)
        if progress and progress(phase, done, total) == false then
            cancelled = true
        end
        return not cancelled
    end

    -- Phase 1: crawl the category tree (cheap: one small request per category)
    if not state then
        local cats, queue, desc = {}, {}, ""
        local failed = false
        local function walk(cat_url)
            if cancelled or failed then return end
            local data
            for _attempt = 1, 3 do
                data = fetch("poets" .. cat_url .. "/_cat.json")
                if data then break end
            end
            if not data then
                failed = true
                return
            end
            if cat_url == poet.FullUrl then
                desc = data.Description or ""
            end
            local node = { t = data.Title or "" }
            local children = {}
            for _i, child in ipairs(data.ChildCats or {}) do
                children[#children + 1] = child.FullUrl
            end
            if #children > 0 then
                node.c = children
            end
            cats[cat_url] = node
            report("tree", 0, 0)
            for _i, child_url in ipairs(children) do
                walk(child_url)
            end
            for _i, p in ipairs(data.Poems or {}) do
                node.p = node.p or {}
                node.p[#node.p + 1] = { p.Title or "", leafOf(cat_url, p.FullUrl), 0 }
                queue[#queue + 1] = { cat_url, #node.p }
            end
        end
        walk(poet.FullUrl)
        if cancelled then
            env.remove_dir(dir)
            return false, "cancelled"
        end
        if failed then
            env.remove_dir(dir)
            return false, "tree"
        end
        state = { queue = queue, cats = cats, desc = desc, done = 0, chunk = 1, failed = 0, bytes = 0,
            nick = poet.Nickname, id = poet.Id }
        env.write_file(prog_path, Core.encode(state))
    end

    -- Phase 2: poems
    local queue, cats = state.queue, state.cats
    local buf, buf_search, buf_size = {}, {}, 0
    local flushed_through = state.done

    local function flush()
        if #buf > 0 then
            env.write_file(dir .. "/p" .. state.chunk .. ".json", "{" .. table.concat(buf, ",") .. "}")
            env.write_file(dir .. "/s" .. state.chunk .. ".txt", table.concat(buf_search, "\n") .. "\n")
            state.bytes = state.bytes + buf_size
            state.chunk = state.chunk + 1
            buf, buf_search, buf_size = {}, {}, 0
        end
        state.done = flushed_through
        env.write_file(prog_path, Core.encode(state))
    end

    local consecutive_failures = 0
    local total = #queue
    local i = state.done
    while i < total do
        i = i + 1
        local cat_url, idx = queue[i][1], queue[i][2]
        local entry = cats[cat_url].p[idx]
        local url = Core.poemUrl(cat_url, entry[2])
        local data
        for _attempt = 1, 3 do
            data = fetch("poets" .. url .. ".json")
            if data then break end
        end
        if data then
            consecutive_failures = 0
            local poem = Core.convertRemotePoem(data, entry[1])
            if #poem.v > 0 then
                local enc = Core.encode(poem)
                if buf_size + #enc > CHUNK_BYTES and #buf > 0 then
                    -- the poem we just fetched goes to the next chunk: flush what we have first
                    flushed_through = i - 1
                    flush()
                end
                entry[3] = state.chunk
                buf[#buf + 1] = Core.encode(url) .. ":" .. enc
                buf_search[#buf_search + 1] = Core.searchLine(url, poem)
                buf_size = buf_size + #enc + #url + 4
            else
                entry[3] = -1 -- empty poem: dropped at the end
            end
        else
            entry[3] = -1
            state.failed = state.failed + 1
            consecutive_failures = consecutive_failures + 1
        end
        flushed_through = i
        if consecutive_failures >= 5 then
            -- the network went away: forget those failures so that a resume retries them
            for k = i - consecutive_failures + 1, i do
                local q = queue[k]
                cats[q[1]].p[q[2]][3] = 0
            end
            state.failed = state.failed - consecutive_failures
            flushed_through = i - consecutive_failures
            flush()
            return false, "network"
        end
        if not report("poems", i, total) then
            flush()
            return false, "cancelled"
        end
    end
    flushed_through = total
    flush()

    -- Finish: drop poems that couldn't be fetched, write cats.json / info.json
    local poems = 0
    for _url, node in pairs(cats) do
        if node.p then
            local kept = {}
            for _i, entry in ipairs(node.p) do
                if entry[3] and entry[3] > 0 then
                    kept[#kept + 1] = entry
                end
            end
            node.p = #kept > 0 and kept or nil
            poems = poems + #kept
        end
    end
    local chunks = state.chunk - 1
    local meta = { id = state.id or poet.Id, nick = poet.Nickname, url = poet.FullUrl, desc = state.desc,
        chunks = chunks, cats = cats }
    local meta_json = Core.encode(meta)
    env.write_file(dir .. "/cats.json", meta_json)
    env.write_file(dir .. "/info.json", Core.encode({ nick = poet.Nickname, chunks = chunks, poems = poems,
        bytes = state.bytes + #meta_json }))
    env.remove_file(prog_path)
    store:refresh()
    return true, { poems = poems, failed = state.failed, chunks = chunks }
end

return Core

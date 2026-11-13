-- Run with:  luajit tests/test_core.lua <ganjoor-data checkout> <python-built data dir (hafez, babataher)>
-- Needs lua-cjson (only for the tests; the plugin uses KOReader's json module).
package.path = "ganjoor.koplugin/?.lua;" .. package.path
package.cpath = package.cpath .. ";/usr/lib/x86_64-linux-gnu/lua/5.1/?.so"
local cjson = require("cjson")
local Core = require("ganjoor_core")

local SRC, PYDATA = arg[1], arg[2]
local TMP = "/tmp/ganjoor_test_" .. os.time()
local failures, checks = 0, 0

local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function sh(cmd) return os.execute(cmd) end

local env = {
    json_decode = cjson.decode,
    read_file = function(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end,
    write_file = function(path, data)
        local tmp = path .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        f:write(data)
        f:close()
        return os.rename(tmp, path)
    end,
    exists = function(path)
        local f = io.open(path, "rb")
        if f then f:close() return true end
        return false
    end,
    list_dir = function(path)
        local t = {}
        local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
        for name in p:lines() do t[#t + 1] = name end
        p:close()
        return t
    end,
    mkdir_p = function(path) sh('mkdir -p "' .. path .. '"') end,
    remove_dir = function(path) sh('rm -rf "' .. path .. '"') end,
    remove_file = function(path) os.remove(path) end,
}

-- deep compare of decoded json values
local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ---------------------------------------------------------------- normalisation
do
    local f = assert(io.open("/tmp/norm_cases.tsv", "rb"))
    local bad, n = 0, 0
    for line in f:lines() do
        local orig, expected = line:match("^(.-)\t(.*)$")
        if orig then
            n = n + 1
            local got = Core.normalize(orig)
            if got ~= expected then
                bad = bad + 1
                if bad <= 3 then print("normalize mismatch for: " .. orig .. "\n  lua:    " .. got .. "\n  python: " .. expected) end
            end
        end
    end
    f:close()
    check(n > 1000, "normalisation corpus loaded (" .. n .. ")")
    check(bad == 0, "normalize() identical to Python on " .. n .. " lines (" .. bad .. " differ)")
    check(Core.normalize("می\u{200C}روم") == Core.normalize("می روم"), "ZWNJ/space insensitive")
    check(Core.normalize("كتاب") == Core.normalize("کتاب"), "Arabic kaf folded")
    check(Core.stripHarakat("اَلا یا اَیُّهَا") == "الا یا ایها", "stripHarakat")
end

-- ---------------------------------------------------------------- encode / decode round trip
do
    local v = { t = 'a"b\\c\n\1', v = { { "x", "y" }, { 1, "z" } }, n = 3 }
    local back = cjson.decode(Core.encode(v))
    check(deepEqual(back, v), "encode/decode round trip")
end

-- ---------------------------------------------------------------- splitProse
do
    local words = {}
    for i = 1, 400 do words[#words + 1] = "کلمه" .. i end
    local text = table.concat(words, " ") .. ". پایان؟ بله"
    local pieces = Core.splitProse(text, 300)
    check(#pieces > 3, "splitProse splits long text (" .. #pieces .. " pieces)")
    local ok = true
    for _i, p in ipairs(pieces) do
        if #p > 310 or #p == 0 then ok = false end
    end
    check(ok, "splitProse pieces respect max length")
    check((table.concat(pieces, " "):gsub("%s+", "")) == (text:gsub("%s+", "")), "splitProse loses nothing")
    check(#Core.splitProse("کوتاه", 300) == 1, "short text untouched")
end

-- ---------------------------------------------------------------- downloader == python builder
local function fetchFromCheckout(counter)
    return function(rel)
        counter.n = counter.n + 1
        if counter.fail_after and counter.n > counter.fail_after then
            return nil
        end
        local raw = env.read_file(SRC .. "/" .. rel)
        if not raw then return nil end
        return cjson.decode(raw)
    end
end

local manifest = cjson.decode(env.read_file(SRC .. "/manifest.json"))
local poets = {}
for _i, p in ipairs(manifest.Poets) do poets[Core.slugOf(p.FullUrl)] = p end

local function compareWithPython(slug)
    local dl = TMP .. "/dl"
    local store = Core.newStore(env, TMP .. "/none", dl)
    local counter = { n = 0 }
    local ok, summary = Core.downloadPoet(store, poets[slug], fetchFromCheckout(counter), nil)
    check(ok == true, slug .. ": download finished")
    if not ok then return end
    check(store:poetState(slug) == "downloaded", slug .. ": registered as downloaded")
    local mine, ref = dl .. "/" .. slug, PYDATA .. "/" .. slug
    local mine_files, ref_files = env.list_dir(mine), env.list_dir(ref)
    table.sort(mine_files); table.sort(ref_files)
    check(table.concat(mine_files, ",") == table.concat(ref_files, ","),
        slug .. ": same file list (" .. #mine_files .. " vs " .. #ref_files .. ")")
    for _i, name in ipairs(ref_files) do
        local a, b = env.read_file(mine .. "/" .. name), env.read_file(ref .. "/" .. name)
        if name:match("%.txt$") then
            check(a == b, slug .. "/" .. name .. ": search index identical")
        elseif name == "info.json" then
            -- "bytes" legitimately differs (key order does not change size, but state bytes are estimates)
            local ja, jb = cjson.decode(a), cjson.decode(b)
            check(ja.poems == jb.poems and ja.chunks == jb.chunks and ja.nick == jb.nick, slug .. ": info.json")
        else
            check(a and b and deepEqual(cjson.decode(a), cjson.decode(b)), slug .. "/" .. name .. ": json identical")
        end
    end
    return store, summary
end

sh("rm -rf " .. TMP)
local store_babataher = compareWithPython("babataher")
local store_hafez = compareWithPython("hafez")

-- ---------------------------------------------------------------- store reading + search on the python-built data
do
    local bundled = TMP .. "/bundled"
    sh("mkdir -p " .. bundled)
    sh("cp -r " .. PYDATA .. "/hafez " .. PYDATA .. "/babataher " .. bundled .. "/")
    local meta_listing = '{"poets":[{"slug":"hafez","nick":"حافظ","chunks":7,"poems":695,"bytes":1},' ..
        '{"slug":"babataher","nick":"باباطاهر","chunks":2,"poems":368,"bytes":1}]}'
    env.write_file(bundled .. "/poets.json", meta_listing)
    local store = Core.newStore(env, bundled, TMP .. "/nodl")
    check(store:poetState("hafez") == "bundled", "bundled poet detected")
    check(store:poetState("saadi") == nil, "unknown poet is nil")
    local poem = store:getPoem("/hafez/ghazal/sh1")
    check(poem and poem.t == "غزل شمارهٔ ۱" and #poem.v >= 6, "getPoem hafez sh1 (" .. tostring(poem and #poem.v) .. " couplets)")
    check(poem and poem.v[1][1]:find("اَلا", 1, true) ~= nil and poem.v[1][2] ~= "", "couplet has two hemistichs")
    check(store:getPoem("/hafez/dibache") ~= nil, "root-level poem found")
    check(store:getPoem("/hafez/ghazal/nope") == nil, "missing poem is nil")

    local res = store:search("الا یا ایها الساقی")
    local found
    for _i, r in ipairs(res) do if r.url == "/hafez/ghazal/sh1" then found = r end end
    check(found and found.row == 1, "search finds the first couplet of ghazal 1 (row=" .. tostring(found and found.row) .. ")")
    check(found and found.nick == "حافظ" and found.slug == "hafez", "result carries poet info")
    local res2 = store:search("ال\u{200C}ا يا ايها الساقى")
    check(#res2 == #res and #res > 0, "search ignores ZWNJ and Arabic ي/ى")
    local res3 = store:search("غزل شماره ۱")
    local title_hit
    for _i, r in ipairs(res3) do if r.url == "/hafez/ghazal/sh1" and r.row == 0 then title_hit = true end end
    check(title_hit, "title matches are row 0")
    local scoped = store:search("الا یا ایها الساقی", "babataher")
    check(#scoped == 0, "scoped search stays inside the poet")
    local limited, truncated = store:search("ا", nil, 5, 8)
    check(#limited <= 8 and truncated, "limits are honoured")
    -- the poem of the result opens
    check(store:getPoem(found.url) ~= nil, "result url resolves to a poem")
    -- poem row = the couplet that matched
    local r1 = store:getPoem(found.url).v[found.row]
    check(Core.normalize(Core.rowText(r1)):find(Core.normalize("الا یا ایها الساقی"), 1, true) ~= nil, "row index points at the matching couplet")
end


-- Same poems / same tree / same search hits, regardless of how the poems were split into chunks.
local function semanticallyEqual(store_a, store_b, slug, label)
    local ma, mb = store_a:getMeta(slug), store_b:getMeta(slug)
    check(ma and mb and ma.desc == mb.desc and ma.nick == mb.nick, label .. ": same poet meta")
    local n_poems, mismatch = 0, 0
    for cat_url, node in pairs(mb.cats) do
        local other = ma.cats[cat_url]
        if not other or other.t ~= node.t or not deepEqual(other.c, node.c) then
            mismatch = mismatch + 1
        else
            local pa, pb = other.p or {}, node.p or {}
            if #pa ~= #pb then mismatch = mismatch + 1 end
            for i, entry in ipairs(pb) do
                n_poems = n_poems + 1
                if not pa[i] or pa[i][1] ~= entry[1] or pa[i][2] ~= entry[2] then
                    mismatch = mismatch + 1
                else
                    local url = Core.poemUrl(cat_url, entry[2])
                    if not deepEqual(store_a:getPoem(url), store_b:getPoem(url)) then mismatch = mismatch + 1 end
                end
            end
        end
    end
    check(n_poems > 100 and mismatch == 0, label .. ": " .. n_poems .. " poems identical (" .. mismatch .. " mismatches)")
    for _i, q in ipairs({ "عشق", "دل", "من" }) do
        local ra, rb = store_a:search(q, slug, 1000, 1000), store_b:search(q, slug, 1000, 1000)
        local function key(r) return r.url .. "#" .. r.row end
        local sa, sb = {}, {}
        for _j, r in ipairs(ra) do sa[#sa + 1] = key(r) end
        for _j, r in ipairs(rb) do sb[#sb + 1] = key(r) end
        table.sort(sa); table.sort(sb)
        check(#sa > 0 and table.concat(sa, ",") == table.concat(sb, ","), label .. ": same search hits for '" .. q .. "' (" .. #sa .. ")")
    end
end

local ref_bundled = TMP .. "/refbundled"
sh("mkdir -p " .. ref_bundled)
sh("cp -r " .. PYDATA .. "/babataher " .. ref_bundled .. "/")
env.write_file(ref_bundled .. "/poets.json", '{"poets":[{"slug":"babataher","nick":"باباطاهر","chunks":2,"poems":368,"bytes":1}]}')
local ref_store = Core.newStore(env, ref_bundled, TMP .. "/nodl2")

-- ---------------------------------------------------------------- resume + cancel + network failure
do
    local dl = TMP .. "/dl2"
    local store = Core.newStore(env, TMP .. "/none", dl)
    local counter = { n = 0 }
    local fetch = fetchFromCheckout(counter)
    local polled = 0
    local ok, why = Core.downloadPoet(store, poets["babataher"], fetch, function(phase, done)
        if phase == "poems" and done >= 120 then return false end
        return true
    end)
    check(ok == false and why == "cancelled", "cancel mid-download")
    check(store:poetState("babataher") == nil or store:poetState("babataher") == "partial", "cancelled download is partial")
    store:refresh()
    check(store:poetState("babataher") == "partial", "partial detected after refresh")
    local calls_before = counter.n
    local ok2, summary = Core.downloadPoet(store, poets["babataher"], fetch, nil)
    check(ok2 == true, "resume finishes")
    check(counter.n - calls_before < 300, "resume did not refetch everything (" .. (counter.n - calls_before) .. " calls)")
    store:refresh()
    semanticallyEqual(store, ref_store, "babataher", "resumed after cancel")
    check(not env.exists(dl .. "/babataher/progress.json"), "progress file removed when done")

    -- network drops after a while, then comes back
    local dl3 = TMP .. "/dl3"
    local store3 = Core.newStore(env, TMP .. "/none", dl3)
    local c3 = { n = 0, fail_after = 150 }
    local ok3, why3 = Core.downloadPoet(store3, poets["babataher"], fetchFromCheckout(c3), nil)
    check(ok3 == false and why3 == "network", "network failure reported (" .. tostring(why3) .. ")")
    local c4 = { n = 0 }
    local ok4, s4 = Core.downloadPoet(store3, poets["babataher"], fetchFromCheckout(c4), nil)
    check(ok4 == true and s4.failed == 0, "resume after network failure retries the failed poems (failed=" .. tostring(s4 and s4.failed) .. ")")
    store3:refresh()
    semanticallyEqual(store3, ref_store, "babataher", "resumed after network failure")

    -- delete
    check(store3:deleteDownloaded("babataher") and store3:poetState("babataher") == nil, "delete downloaded poet")
end

sh("rm -rf " .. TMP)
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

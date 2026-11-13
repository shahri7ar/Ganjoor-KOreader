#!/usr/bin/env python3
"""Build the compact offline data bundled with the Ganjoor KOReader plugin.

Input : a checkout of https://github.com/ganjoor/ganjoor-data (needs poets/<slug>/...)
Output: ganjoor.koplugin/data/<slug>/{cats.json, info.json, p<N>.json, s<N>.txt}
        ganjoor.koplugin/data/poets.json (bundled poets) and data/all_poets.json (poet list)

Format (identical to what the plugin itself writes when downloading a poet):

cats.json  {"id":..,"nick":..,"url":"/hafez","desc":"..","chunks":N,
            "cats":{ "/hafez": {"t":title,"c":[childCatUrl..],"p":[[title,leaf,chunk],..]} }}
           poem url = catUrl .. "/" .. leaf   (a leaf starting with "/" is already a full url)
info.json  {"nick":..,"chunks":N,"poems":N,"bytes":N}
p<N>.json  { "<slug-path>": {"t":title,"m":metre?,"v":[row..]} }   key = poem FullUrl
           row = ["right","left"]          a couplet (two hemistichs)
               | [1,"text"]                paragraph / prose
               | [2,"text"]                centered verse line
               | [3,"text"]                comment / footnote
s<N>.txt   search index of p<N>.json, one poem per line:
           url \t title \t normTitle|normRow1|normRow2|...   (segment k == row k, segment 0 == title)

The normalisation (`normalize`) MUST stay identical to normalizeFa() in main.lua.
"""
import argparse, json, os, re, sys, shutil

CHUNK_BYTES = 120_000  # target size of one p<N>.json

# --- normalisation shared with main.lua --------------------------------------
_DEL = set()
_DEL.update(chr(c) for c in range(0x064B, 0x0660))   # harakat, hamza marks
_DEL.update(["\u0670", "\u0640", "\u200c", "\u200d", "\u200e", "\u200f",
             "\u00a0", "\u202a", "\u202b", "\u202c", "\ufeff", " ", "\t", "\r", "\n"])
_DEL.update(list("،؛؟!.,;:?()[]{}«»\"'-–—…*_/\\"))
_DEL.update(["\u066b", "\u066c", "\u06d4"])
_MAP = {"\u064a": "\u06cc", "\u0649": "\u06cc", "\u0643": "\u06a9", "\u06d5": "\u0647",
        "\u0623": "\u0627", "\u0625": "\u0627", "\u0622": "\u0627", "\u0671": "\u0627",
        "\u06c0": "\u0647", "\u0629": "\u0647"}
_DIGITS = {chr(0x06F0 + i): str(i) for i in range(10)}
_DIGITS.update({chr(0x0660 + i): str(i) for i in range(10)})

def normalize(s: str) -> str:
    out = []
    for ch in s:
        if ch in _DEL:
            continue
        out.append(_MAP.get(ch) or _DIGITS.get(ch) or ch)
    return "".join(out)

# --- poem conversion ----------------------------------------------------------
def convert_poem(d):
    rows = []
    pending = None
    for v in d.get("Verses") or []:
        pos, text = v.get("Position"), (v.get("Text") or "").strip(" \t\r\n\f\v")
        if not text:
            continue
        if pos == "Right":
            if pending is not None:
                rows.append([pending, ""])
            pending = text
        elif pos == "Left":
            rows.append([pending or "", text])
            pending = None
        else:
            if pending is not None:
                rows.append([pending, ""]); pending = None
            rows.append([{"Paragraph": 1, "CenteredVerse1": 2, "CenteredVerse2": 2, "Comment": 3}.get(pos, 1), text])
    if pending is not None:
        rows.append([pending, ""])
    if not rows:  # prose-only poems keep their plain text
        for s in d.get("Sections") or []:
            t = (s.get("PlainText") or "").replace("\r\n", "\n").strip(" \t\r\n\f\v")
            if t:
                for para in t.split("\n"):
                    if para.strip(" \t\r\n\f\v"):
                        rows.append([1, para.strip(" \t\r\n\f\v")])
    out = {"t": d.get("Title") or ""}
    m = (d.get("Metre") or {}).get("Rhythm")
    if m:
        out["m"] = m
    out["v"] = rows
    return out

def row_text(r):
    return r[1] if isinstance(r[0], int) else (r[0] + r[1])

def search_line(url, poem):
    title = poem["t"].replace("\t", " ").replace("\n", " ")
    segs = [normalize(poem["t"])] + [normalize(row_text(r)) for r in poem["v"]]
    return f"{url}\t{title}\t" + "|".join(segs)

def jdump(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))

def leaf_of(cat_url, poem_url):
    prefix = cat_url + "/"
    return poem_url[len(prefix):] if poem_url.startswith(prefix) else poem_url

def build_poet(src_root, out_root, poet):
    slug = poet["FullUrl"].strip("/")
    out = os.path.join(out_root, slug)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    cats = {}
    cur, cur_search, cur_size, chunk_no = {}, [], 0, 1
    stats = {"poems": 0}

    def flush():
        nonlocal cur, cur_search, cur_size, chunk_no
        if cur:
            with open(os.path.join(out, f"p{chunk_no}.json"), "w", encoding="utf-8") as f:
                f.write(jdump(cur))
            with open(os.path.join(out, f"s{chunk_no}.txt"), "w", encoding="utf-8") as f:
                f.write("\n".join(cur_search) + "\n")
            chunk_no += 1
            cur, cur_search, cur_size = {}, [], 0

    def walk(cat_url):
        nonlocal cur, cur_search, cur_size
        with open(os.path.join(src_root, "poets", cat_url.strip("/"), "_cat.json"), encoding="utf-8") as f:
            c = json.load(f)
        node = {"t": c.get("Title") or ""}
        children = [ch["FullUrl"] for ch in c.get("ChildCats") or []]
        if children:
            node["c"] = children
        cats[cat_url] = node
        for child in children:
            walk(child)
        plist = []
        for p in c.get("Poems") or []:
            pf = os.path.join(src_root, "poets", p["FullUrl"].strip("/") + ".json")
            if not os.path.exists(pf):
                continue
            with open(pf, encoding="utf-8") as f:
                pd = json.load(f)
            poem = convert_poem(pd)
            if not poem["v"]:
                continue
            poem["t"] = poem["t"] or p["Title"]
            enc = jdump(poem)
            if cur_size + len(enc.encode()) > CHUNK_BYTES and cur:
                flush()
            cur[p["FullUrl"]] = poem
            cur_size += len(enc.encode()) + len(p["FullUrl"]) + 4
            cur_search.append(search_line(p["FullUrl"], poem))
            plist.append([p["Title"], leaf_of(cat_url, p["FullUrl"]), chunk_no])
            stats["poems"] += 1
        if plist:
            node["p"] = plist

    walk(poet["FullUrl"])
    flush()
    with open(os.path.join(src_root, "poets", slug, "_cat.json"), encoding="utf-8") as f:
        root = json.load(f)
    chunks = chunk_no - 1
    with open(os.path.join(out, "cats.json"), "w", encoding="utf-8") as f:
        f.write(jdump({"id": poet["Id"], "nick": poet["Nickname"], "url": poet["FullUrl"],
                       "desc": root.get("Description") or "", "chunks": chunks, "cats": cats}))
    size = sum(os.path.getsize(os.path.join(out, n)) for n in os.listdir(out))
    info = {"nick": poet["Nickname"], "chunks": chunks, "poems": stats["poems"], "bytes": size}
    with open(os.path.join(out, "info.json"), "w", encoding="utf-8") as f:
        f.write(jdump(info))
    return info

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="path to a ganjoor-data checkout")
    ap.add_argument("--out", required=True, help="output data directory (ganjoor.koplugin/data)")
    ap.add_argument("--poets", nargs="+", required=True, help="poet slugs to bundle (e.g. hafez saadi)")
    a = ap.parse_args()
    with open(os.path.join(a.src, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    by_slug = {p["FullUrl"].strip("/"): p for p in manifest["Poets"]}
    os.makedirs(a.out, exist_ok=True)
    listing, total = [], 0
    for slug in a.poets:
        p = by_slug[slug]
        info = build_poet(a.src, a.out, p)
        total += info["bytes"]
        listing.append({"id": p["Id"], "slug": slug, **info})
        print(f"{slug:14s} poems={info['poems']:6d} chunks={info['chunks']:4d} size={info['bytes']/1e6:7.2f} MB",
              file=sys.stderr)
    with open(os.path.join(a.out, "poets.json"), "w", encoding="utf-8") as f:
        f.write(jdump({"poets": listing}))
    # the complete poet list, so the poets grid works offline from the very first launch
    with open(os.path.join(a.out, "all_poets.json"), "w", encoding="utf-8") as f:
        f.write(jdump({"GeneratedAtUtc": manifest.get("GeneratedAtUtc", ""),
                       "IdIndexShardSize": manifest.get("IdIndexShardSize", 2000),
                       "Poets": [{"Id": p["Id"], "Nickname": p["Nickname"], "FullUrl": p["FullUrl"]}
                                 for p in manifest["Poets"]]}))
    print(f"TOTAL {total/1e6:.1f} MB for {len(listing)} poets", file=sys.stderr)

if __name__ == "__main__":
    main()

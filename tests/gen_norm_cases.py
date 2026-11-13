#!/usr/bin/env python3
"""Writes tab-separated (original, normalize(original)) cases for tests/test_core.lua."""
import glob, json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from build_offline_data import normalize

src, out = sys.argv[1], sys.argv[2]
cases = ["كتاب يك ى", "می‌روم  می روم", "آأإ ٱ ة ۀ ہ", "۰۱۲۳۴۵۶۷۸۹ ٠١٢٣٤٥٦٧٨٩", "«سلام»، (دنیا)! ؟ ؛ - – — … *",
         "اَلا یا اَیُّهَا السّاقی", "كـــلام", "abc DEF 123 \u00a0x\u200fy"]
n = 0
for f in sorted(glob.glob(os.path.join(src, "poets", "hafez", "**", "*.json"), recursive=True))[:120] + \
         sorted(glob.glob(os.path.join(src, "poets", "moulavi", "**", "*.json"), recursive=True))[:80] + \
         sorted(glob.glob(os.path.join(src, "poets", "ferdousi", "**", "*.json"), recursive=True))[:20]:
    if f.endswith("_cat.json") or f.endswith("poet.json"):
        continue
    d = json.load(open(f, encoding="utf-8"))
    cases.append(d.get("Title") or "")
    for v in d.get("Verses") or []:
        cases.append(v.get("Text") or "")
with open(out, "w", encoding="utf-8") as fh:
    for c in cases:
        c = c.replace("\t", " ").replace("\n", " ")
        fh.write(c + "\t" + normalize(c) + "\n")
print(len(cases), "cases")

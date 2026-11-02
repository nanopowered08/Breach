#!/usr/bin/env python3
"""Extract the scripts of the Mission Exporter plugin (.rbxmx, also fine if saved as .txt) into
flat files named SerializationTools__<Path__To__Module>.lua, which is what the other tools read.
Usage: extract.py SerializationTools.rbxmx <outdir>"""
import sys, os
import xml.etree.ElementTree as ET
root = ET.fromstring(open(sys.argv[1], "rb").read())
out = sys.argv[2]; os.makedirs(out, exist_ok=True); n = 0
def walk(item, path):
    global n
    props = {p.get("name"): p.text for p in item.find("Properties")}
    full = path + "/" + (props.get("Name") or "?")
    if props.get("Source") is not None:
        open(os.path.join(out, full.strip("/").replace("/", "__") + ".lua"), "w", encoding="utf-8").write(props["Source"]); n += 1
    for c in item.findall("Item"): walk(c, full)
for it in root.findall("Item"): walk(it, "")
print(f"extracted {n} scripts to {out}")

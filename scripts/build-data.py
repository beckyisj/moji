#!/usr/bin/env python3
"""Merge emojibase (CLDR labels + keywords + skin tones), iamcal (Slack shortcodes)
and gemoji (GitHub aliases + tags) into Resources/emoji.json."""
import json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "data-src")
base = json.load(open(os.path.join(src, "emojibase.json")))
slack = json.load(open(os.path.join(src, "iamcal.json")))
gemoji = {g["emoji"].replace("️", ""): g for g in json.load(open(os.path.join(src, "gemoji.json")))}

def as_list(v):
    return [] if v is None else (v if isinstance(v, list) else [v])

out = []
for e in base:
    if e.get("group") in (None, 2):  # regional indicators, skin-tone components
        continue
    g = gemoji.get(e["emoji"].replace("️", ""), {})
    codes = []
    for c in as_list(slack.get(e["hexcode"])) + g.get("aliases", []):
        if c not in codes:
            codes.append(c)
    keywords = sorted(set(as_list(e.get("tags")) + g.get("tags", [])))
    item = {"e": e["emoji"], "n": e["label"], "s": codes, "k": keywords, "o": e.get("order", 99999)}
    skins = [s["emoji"] for s in e.get("skins", []) if isinstance(s.get("tone"), int)]
    if len(skins) == 5:
        item["t"] = skins
    out.append(item)

out.sort(key=lambda x: x["o"])
path = os.path.join(root, "Resources", "emoji.json")
json.dump(out, open(path, "w"), ensure_ascii=False, separators=(",", ":"))
print(f"{len(out)} emoji -> {path}")

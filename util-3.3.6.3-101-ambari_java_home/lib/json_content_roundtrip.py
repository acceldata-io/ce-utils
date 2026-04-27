#!/usr/bin/env python3.11
"""Used by patch_ambari_java_home.sh: extract or write back configs.py JSON 'properties.content'."""
import json
import sys

USAGE = "Usage: json_content_roundtrip.py extract <config.json> <content.txt>\n       json_content_roundtrip.py merge <config.json> <content.txt> <out.json>\n"


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write(USAGE)
        return 1
    cmd = sys.argv[1]
    if cmd == "extract":
        if len(sys.argv) != 4:
            sys.stderr.write(USAGE)
            return 1
        _, _, jpath, outpath = sys.argv
        with open(jpath, encoding="utf-8") as f:
            data = json.load(f)
        props = data.get("properties")
        if not isinstance(props, dict) or "content" not in props:
            sys.stderr.write("JSON missing properties.content\n")
            return 1
        c = props["content"]
        if c is None:
            c = ""
        with open(outpath, "w", encoding="utf-8") as f:
            f.write(c)
        return 0
    if cmd == "merge":
        if len(sys.argv) != 5:
            sys.stderr.write(USAGE)
            return 1
        _, _, jpath, contentpath, outpath = sys.argv
        with open(jpath, encoding="utf-8") as f:
            data = json.load(f)
        if "properties" not in data or not isinstance(data["properties"], dict):
            sys.stderr.write("JSON missing properties object\n")
            return 1
        with open(contentpath, encoding="utf-8") as f:
            data["properties"]["content"] = f.read()
        with open(outpath, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        return 0
    sys.stderr.write(USAGE)
    return 1


if __name__ == "__main__":
    sys.exit(main())

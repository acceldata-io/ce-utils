#!/usr/bin/env python3.11
"""Print SHA-256 hex digest of a file (single path argument)."""
import hashlib
import pathlib
import sys

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: file_sha256.py <path>\n")
        raise SystemExit(1)
    print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())

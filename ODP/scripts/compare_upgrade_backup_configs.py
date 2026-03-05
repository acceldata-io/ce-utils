#!/usr/bin/env python
"""
Compare Ambari config backup directories and report keys newly added in target.

Example:
  python compare_upgrade_backup_configs.py \
    --old /path/to/pinot-1.3.0/upgrade_backup \
    --new /path/to/pinot-1.4.0/upgrade_backup
"""

from __future__ import print_function

import argparse
import json
import os
import sys


def parse_args():
    parser = argparse.ArgumentParser(
        description="List newly added key-value configs in new backup directory."
    )
    parser.add_argument(
        "--old",
        required=True,
        help="Old backup directory (ex: pinot 1.3.0 upgrade_backup).",
    )
    parser.add_argument(
        "--new",
        required=True,
        help="New backup directory (ex: pinot 1.4.0 upgrade_backup).",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Optional output report path (JSON format).",
    )
    return parser.parse_args()


def list_json_files(base_dir):
    paths = []
    for root, _, files in os.walk(base_dir):
        for name in files:
            if name.endswith(".json"):
                abs_path = os.path.join(root, name)
                rel_path = os.path.relpath(abs_path, base_dir)
                paths.append(rel_path)
    paths.sort()
    return paths


def load_json(path):
    with open(path, "r") as handle:
        return json.load(handle)


def is_simple_map(data):
    if not isinstance(data, dict):
        return False
    if not data:
        return True
    for value in data.values():
        if isinstance(value, (dict, list)):
            return False
    return True


def find_properties_map(node):
    """
    Try to return the best properties map from Ambari backup JSON.
    """
    if isinstance(node, dict):
        if isinstance(node.get("properties"), dict):
            return node["properties"]
        # Some payloads are already plain key-value maps.
        if is_simple_map(node):
            return node
        for value in node.values():
            found = find_properties_map(value)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = find_properties_map(item)
            if found is not None:
                return found
    return None


def compare_file(old_file, new_file):
    old_data = load_json(old_file) if os.path.exists(old_file) else {}
    new_data = load_json(new_file)

    old_props = find_properties_map(old_data) or {}
    new_props = find_properties_map(new_data) or {}

    added = {}
    for key in sorted(new_props.keys()):
        if key not in old_props:
            added[key] = new_props[key]
    return added


def main():
    args = parse_args()

    old_dir = os.path.abspath(args.old)
    new_dir = os.path.abspath(args.new)

    if not os.path.isdir(old_dir):
        print("ERROR: old directory not found: {0}".format(old_dir), file=sys.stderr)
        return 2
    if not os.path.isdir(new_dir):
        print("ERROR: new directory not found: {0}".format(new_dir), file=sys.stderr)
        return 2

    new_files = list_json_files(new_dir)
    if not new_files:
        print("No JSON files found in new directory: {0}".format(new_dir))
        return 0

    report = {}
    total_new_keys = 0

    for rel_path in new_files:
        old_file = os.path.join(old_dir, rel_path)
        new_file = os.path.join(new_dir, rel_path)
        try:
            added = compare_file(old_file, new_file)
        except Exception as exc:
            report[rel_path] = {"__error__": str(exc)}
            continue

        if added:
            report[rel_path] = added
            total_new_keys += len(added)

    print("=" * 80)
    print("Newly added key-value pairs in NEW backup directory")
    print("OLD: {0}".format(old_dir))
    print("NEW: {0}".format(new_dir))
    print("=" * 80)

    if not report:
        print("No newly added keys found.")
    else:
        for rel_path in sorted(report.keys()):
            print("\n[{0}]".format(rel_path))
            entry = report[rel_path]
            if "__error__" in entry:
                print("  ERROR: {0}".format(entry["__error__"]))
                continue
            for key in sorted(entry.keys()):
                value_str = json.dumps(entry[key], ensure_ascii=True)
                print("  {0} = {1}".format(key, value_str))

    print("\nTotal newly added keys: {0}".format(total_new_keys))

    if args.output_json:
        with open(args.output_json, "w") as out:
            json.dump(report, out, indent=2, sort_keys=True)
        print("Saved JSON report: {0}".format(args.output_json))

    return 0


if __name__ == "__main__":
    sys.exit(main())

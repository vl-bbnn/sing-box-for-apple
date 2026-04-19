#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file")
    parser.add_argument("--stdin", action="store_true")
    parser.add_argument("--infoplist", required=True)
    parser.add_argument("--setting", required=True)
    return parser.parse_args()


def read_content(args: argparse.Namespace) -> str:
    if args.stdin:
        return sys.stdin.read()
    if not args.file:
        raise SystemExit("--file or --stdin is required")
    return Path(args.file).read_text(encoding="utf-8")


def main() -> None:
    args = parse_args()
    content = read_content(args)
    block_pattern = re.compile(r"buildSettings = \{(?P<body>.*?)\n\s*\};", re.S)
    setting_pattern = re.compile(rf"\b{re.escape(args.setting)} = ([^;]+);")

    for match in block_pattern.finditer(content):
        body = match.group("body")
        if f"INFOPLIST_FILE = {args.infoplist};" not in body:
            continue
        value_match = setting_pattern.search(body)
        if not value_match:
            continue
        value = value_match.group(1).strip().strip('"')
        print(value)
        return

    raise SystemExit(f"failed to find {args.setting} for {args.infoplist}")


if __name__ == "__main__":
    main()

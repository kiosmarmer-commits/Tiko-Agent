#!/usr/bin/env python3
"""Script tool contoh — baca JSON dari stdin, tulis JSON ke stdout."""
import json
import sys

def main():
    raw = sys.stdin.read()
    try:
        args = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        print(json.dumps({"content": f"invalid json: {e}", "is_error": True}))
        sys.exit(1)
    msg = args.get("message", "")
    print(json.dumps({"content": f"echo: {msg}", "is_error": False}))

if __name__ == "__main__":
    main()

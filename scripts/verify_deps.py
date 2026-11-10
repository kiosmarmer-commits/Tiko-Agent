#!/usr/bin/env python3
"""Verifikasi versi paket Dart di pub.dev (AGD-08 §4)."""
import json
import sys
import urllib.request
from datetime import datetime, timezone

PKGS = [
    "openai_dart", "ollama_dart", "anthropic_sdk_dart", "googleai_dart",
    "dart_mcp", "drift", "sqlite3", "televerse", "nyxx", "enough_mail",
    "dart_frog", "shelf", "dio", "http", "cron", "workmanager",
    "riverpod", "flutter_secure_storage", "args", "logging", "html",
    "yaml", "path", "uuid", "mcp_dart",
]

def get(url: str):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)

now = datetime.now(timezone.utc)
print(f"{'paket':28} {'versi':12} {'umur(hari)':>10}  status")
for p in PKGS:
    try:
        d = get(f"https://pub.dev/api/packages/{p}")
        latest = d["latest"]
        pub = datetime.fromisoformat(latest["published"].replace("Z", "+00:00"))
        age = (now - pub).days
        flag = "DISCONTINUED" if d.get("isDiscontinued") else (
            "PERIKSA(>365h)" if age > 365 else "ok"
        )
        print(f"{p:28} {latest['version']:12} {age:>10}  {flag}")
    except Exception as e:
        print(f"{p:28} {'-':12} {'-':>10}  ERROR {e}")

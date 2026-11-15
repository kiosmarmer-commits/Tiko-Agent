#!/usr/bin/env python3
"""Audit supply-chain dependensi Dart/pub.dev (AGD-08 §4, hardened).

Pemindaian:
1. Semua pubspec.lock di repo → paket hosted + versi ter-pin + sha256.
2. pub.dev API → tanggal publish per versi ter-pin (usia rilis),
   status discontinued, dan archive_sha256 (integritas pin lockfile).
3. OSV API (api.osv.dev, ecosystem "Pub", batch ≤1000/query) →
   kerentanan yang diketahui untuk kombinasi paket@versi.

Mode:
- default      : temuan dicetak, exit 0 (kecuali kesalahan jaringan total).
- --strict     : exit 1 bila ada kerentanan OSV atau mismatch sha256
                 (fail-closed); usia rilis tetap peringatan.

Referensi:
- https://google.github.io/osv.dev/post-v1-querybatch/
- https://github.com/actions/attest-build-provenance (SLSA provenance)
"""
import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PUB_API = "https://pub.dev/api/packages/{name}"
OSV_BATCH = "https://api.osv.dev/v1/querybatch"
OSV_VULN = "https://api.osv.dev/v1/vulns/{id}"
OSV_ECOSYSTEM = "Pub"
OSV_BATCH_SIZE = 1000

DEFAULT_MIN_RELEASE_AGE_DAYS = 7
DEFAULT_STALE_DAYS = 365

# Fallback bila tidak ada pubspec.lock (perilaku lama AGD-08 §4).
PKGS = [
    "openai_dart", "ollama_dart", "anthropic_sdk_dart", "googleai_dart",
    "dart_mcp", "drift", "sqlite3", "televerse", "nyxx", "enough_mail",
    "dart_frog", "shelf", "dio", "http", "cron", "workmanager",
    "riverpod", "flutter_secure_storage", "args", "logging", "html",
    "yaml", "path", "uuid", "mcp_dart",
]


def http_get_json(url: str, timeout: int = 20):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def http_post_json(url: str, payload: dict, timeout: int = 60):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def parse_lockfile(path: Path) -> list:
    """Ambil paket hosted (name, version, sha256) dari satu pubspec.lock."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"  GAGAL baca {path}: {e}")
        return []
    pkgs = []
    for m in re.finditer(
        r"^  ([A-Za-z0-9_]+):\n"
        r"    dependency: (?:\"?direct (?:main|dev)\"?|transitive)\n"
        r"    description:\n"
        r"      name: ([A-Za-z0-9_]+)\n"
        r"      sha256: ([0-9a-f]{64})\n"
        r"      url: \"(https://[^\"]+)\"\n"
        r"    source: hosted\n"
        r"    version: \"([^\"]+)\"\n",
        text,
        re.MULTILINE,
    ):
        pkgs.append(
            {
                "name": m.group(2),
                "sha256": m.group(3),
                "url": m.group(4),
                "version": m.group(5),
                "lockfile": str(path),
            }
        )
    return pkgs


def collect_locked_packages(root: Path) -> list:
    """Kumpulkan paket hosted unik dari semua pubspec.lock di bawah root."""
    seen = {}
    for lock in sorted(root.rglob("pubspec.lock")):
        if any(part in {".dart_tool", "node_modules", "build"} for part in lock.parts):
            continue
        for p in parse_lockfile(lock):
            key = (p["name"], p["version"])
            if key not in seen:
                seen[key] = p
    return sorted(seen.values(), key=lambda p: p["name"])


def classify_release_age(published: datetime, now: datetime, min_age_days: int, stale_days: int) -> str:
    age = (now - published).days
    if age < min_age_days:
        return f"TERLALU-BARU(<{min_age_days}h)"
    if age > stale_days:
        return f"TUAB(>{stale_days}h)"
    return "ok"


def osv_batch_scan(packages: list) -> dict:
    """Kembalikan {(name, version): [vuln_id, ...]} via querybatch ber-chunk."""
    found = {}
    queries = [
        {
            "package": {"name": p["name"], "ecosystem": OSV_ECOSYSTEM},
            "version": p["version"],
        }
        for p in packages
    ]
    for i in range(0, len(queries), OSV_BATCH_SIZE):
        chunk = queries[i : i + OSV_BATCH_SIZE]
        resp = http_post_json(OSV_BATCH, {"queries": chunk})
        results = resp.get("results", [])
        if len(results) != len(chunk):
            raise ValueError(
                f"OSV querybatch: {len(results)} hasil untuk {len(chunk)} query"
            )
        for q, r in zip(chunk, results):
            vulns = r.get("vulns") or []
            if vulns:
                key = (q["package"]["name"], q["version"])
                found.setdefault(key, []).extend(v["id"] for v in vulns)
    return found


def osv_fixed_versions(vuln_ids: list) -> dict:
    """Ambil versi perbaikan (bila ada) untuk daftar ID kerentanan."""
    fixed = {}
    for vid in vuln_ids:
        try:
            rec = http_get_json(OSV_VULN.format(id=vid))
        except Exception:
            continue
        fixes = set()
        for aff in rec.get("affected", []):
            if aff.get("package", {}).get("ecosystem") != OSV_ECOSYSTEM:
                continue
            for r in aff.get("ranges", []):
                for ev in r.get("events", []):
                    if "fixed" in ev:
                        fixes.add(ev["fixed"])
        if fixes:
            fixed[vid] = ", ".join(sorted(fixes))
    return fixed


def audit_locked(packages: list, now, min_age_days: int, stale_days: int) -> dict:
    """Audit paket ter-pin. Return laporan {failures, warnings, infos, rows}."""
    failures, warnings, infos, rows = [], [], [], []

    pub_meta = {}
    for name in sorted({p["name"] for p in packages}):
        try:
            pub_meta[name] = http_get_json(PUB_API.format(name=name))
        except Exception as e:
            pub_meta[name] = {"error": str(e)}

    osv_hits = {}
    osv_error = None
    try:
        osv_hits = osv_batch_scan(packages)
    except Exception as e:
        osv_error = str(e)

    for p in packages:
        name, version = p["name"], p["version"]
        meta = pub_meta.get(name, {})
        if "error" in meta:
            warnings.append(f"{name} {version}: pub.dev tidak terjangkau ({meta['error']})")
            rows.append((name, version, "-", "PUB-ERROR"))
            continue
        if meta.get("isDiscontinued"):
            warnings.append(f"{name} {version}: DISCONTINUED di pub.dev")
        vmeta = next(
            (v for v in meta.get("versions", []) if v.get("version") == version),
            None,
        )
        if vmeta is None:
            failures.append(
                f"{name} {version}: versi tidak ada di pub.dev (pin lockfile mencurigakan)"
            )
            rows.append((name, version, "-", "TIDAK-ADA-DI-REGISTRY"))
            continue
        published = datetime.fromisoformat(vmeta["published"].replace("Z", "+00:00"))
        age = classify_release_age(published, now, min_age_days, stale_days)
        registry_sha = vmeta.get("archive_sha256")
        status = age
        if registry_sha and registry_sha != p["sha256"]:
            status = "SHA-MISMATCH"
            failures.append(
                f"{name} {version}: sha256 lockfile {p['sha256'][:12]}… ≠ registry {registry_sha[:12]}… (pin dimanipulasi?)"
            )
        if age.startswith("TERLALU-BARU"):
            warnings.append(
                f"{name} {version}: rilis terlalu baru ({(now - published).days} hari) — jendela kompromi supply-chain"
            )
        elif age.startswith("TUAB"):
            infos.append(f"{name} {version}: versi ter-pin berumur {(now - published).days} hari")
        ids = sorted(set(osv_hits.get((name, version), [])))
        if ids:
            status = "VULNERABLE"
            fixed = osv_fixed_versions(ids)
            remediation = "".join(
                f"; {vid} → naikkan ke {fixed[vid]}" for vid in ids if vid in fixed
            )
            failures.append(
                f"{name} {version}: {len(ids)} kerentanan OSV: {', '.join(ids)}{remediation}"
            )
        rows.append((name, version, str((now - published).days), status))

    if osv_error is not None:
        if packages:
            failures.append(f"OSV scan gagal (fail-closed): {osv_error}")
        else:
            warnings.append(f"OSV scan dilewati (tidak ada paket ter-pin): {osv_error}")

    return {"failures": failures, "warnings": warnings, "infos": infos, "rows": rows}


def audit_latest_fallback(now, stale_days: int) -> dict:
    """Perilaku lama: cek versi latest daftar PKGS (tanpa lockfile)."""
    failures, warnings, infos, rows = [], [], [], []
    for p in PKGS:
        try:
            d = http_get_json(PUB_API.format(name=p))
        except Exception as e:
            warnings.append(f"{p}: pub.dev tidak terjangkau ({e})")
            continue
        latest = d["latest"]
        published = datetime.fromisoformat(latest["published"].replace("Z", "+00:00"))
        age = classify_release_age(published, now, DEFAULT_MIN_RELEASE_AGE_DAYS, stale_days)
        if d.get("isDiscontinued"):
            warnings.append(f"{p} {latest['version']}: DISCONTINUED")
        if age.startswith("TUAB"):
            infos.append(f"{p} {latest['version']}: latest berumur {(now - published).days} hari")
        rows.append((p, latest["version"], str((now - published).days), age))
    return {"failures": failures, "warnings": warnings, "infos": infos, "rows": rows}


def print_report(report: dict, header: str) -> None:
    print(f"\n== {header} ==")
    print(f"{'paket':28} {'versi':14} {'umur(hari)':>10}  status")
    for name, version, age, status in report["rows"]:
        print(f"{name:28} {version:14} {age:>10}  {status}")
    for level, items in (("GAGAL", report["failures"]), ("PERINGATAN", report["warnings"]), ("INFO", report["infos"])):
        for item in items:
            print(f"[{level}] {item}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--strict",
        action="store_true",
        help="exit 1 bila ada kerentanan OSV / mismatch sha256 / OSV gagal",
    )
    ap.add_argument("--root", default=".", help="root repo untuk pencarian pubspec.lock")
    ap.add_argument(
        "--min-release-age",
        type=int,
        default=int(os.environ.get("TIKO_MIN_RELEASE_AGE", DEFAULT_MIN_RELEASE_AGE_DAYS)),
        help="usia minimum rilis (hari) sebelum dianggap aman di-install",
    )
    args = ap.parse_args(argv)

    now = datetime.now(timezone.utc)
    root = Path(args.root).resolve()
    packages = collect_locked_packages(root)

    if packages:
        report = audit_locked(packages, now, args.min_release_age, DEFAULT_STALE_DAYS)
        header = f"audit {len(packages)} paket ter-pin dari pubspec.lock"
    else:
        report = audit_latest_fallback(now, DEFAULT_STALE_DAYS)
        header = f"fallback: latest {len(PKGS)} paket (tidak ada pubspec.lock)"
    print_report(report, header)

    if report["failures"]:
        if args.strict:
            print(f"\nSTRICT: {len(report['failures'])} kegagalan audit supply-chain")
            return 1
        print(f"\n(non-strict: {len(report['failures'])} temuan tidak menggagalkan build)")
    else:
        print("\nAudit supply-chain bersih.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

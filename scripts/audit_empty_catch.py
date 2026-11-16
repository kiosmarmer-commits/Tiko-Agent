#!/usr/bin/env python3
"""A8: audit blok catch kosong di seluruh kode produksi.

Kebijakan:
- Blok catch yang benar-benar kosong (`catch (_) {}`) hanya diizinkan bila
  ditandai `// best-effort` pada baris yang sama (penyengajaan yang sudah
  direview: cleanup sementara, dispose, callback sekunder).
- Kegagalan yang menyentuh persistensi/state harus di-log (stderr), bukan
  kosong — blok semacam itu tidak lagi kosong sehingga lolos audit alami.

Pemakaian:
  python3 scripts/audit_empty_catch.py            # laporan + exit 1 bila ada pelanggaran
  python3 scripts/audit_empty_catch.py --report   # hanya laporan, selalu exit 0
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

EMPTY_CATCH = re.compile(r'catch\s*\([^)]*\)\s*\{\s*\}')

EXCLUDE_DIRS = {'.git', 'build', '.dart_tool', 'node_modules'}
EXCLUDE_PARTS = ('/test/', '/integration_test/')


def iter_sources():
    for dirpath, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for name in files:
            if not name.endswith('.dart') or name.endswith('_test.dart'):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
            if any(part in f'/{rel}' for part in EXCLUDE_PARTS):
                continue
            yield rel, path


def main() -> int:
    report_only = '--report' in sys.argv
    violations = []
    ok_marked = 0
    for rel, path in iter_sources():
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().split('\n')
        for i, line in enumerate(lines):
            if not EMPTY_CATCH.search(line):
                continue
            if 'best-effort' in line:
                ok_marked += 1
                continue
            violations.append(f'{rel}:{i + 1}: {line.strip()}')

    print(f'catch kosong bertanda best-effort: {ok_marked}')
    if violations:
        print(f'catch kosong TANPA penanda ({len(violations)}):')
        for v in violations:
            print(f'  {v}')
        if report_only:
            return 0
        print('\nGAGAL: tandai // best-effort atau ganti dengan logging.')
        return 1
    print('AUDIT EMPTY-CATCH PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())

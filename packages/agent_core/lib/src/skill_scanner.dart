import 'dart:io';

/// Static skill scan before activation (PRD §9.5 subset).
class SkillScanResult {
  SkillScanResult({required this.ok, required this.findings});
  final bool ok;
  final List<String> findings;

  Map<String, dynamic> toJson() => {'ok': ok, 'findings': findings};
}

class SkillScanner {
  static SkillScanResult scanFile(String path) {
    try {
      return scanContent(File(path).readAsStringSync());
    } catch (e) {
      return SkillScanResult(ok: false, findings: ['cannot read: $e']);
    }
  }

  static SkillScanResult scanContent(String text) {
    final findings = <String>[];
    final lower = text.toLowerCase();
    final patterns = {
      r'rm\s+-rf\s+/': 'destructive rm -rf /',
      r'curl\s+[^\n]*\|\s*sh': 'pipe remote script to shell',
      r'process\.env': 'env access pattern',
      r'eval\s*\(': 'eval usage',
      r'\.\./\.\.': 'path traversal pattern',
      r'-----begin.*private key': 'private key material',
    };
    for (final entry in patterns.entries) {
      if (RegExp(entry.key, caseSensitive: false).hasMatch(text)) {
        findings.add(entry.value);
      }
    }
    if (lower.contains('child_process') || lower.contains('process.run')) {
      findings.add('process execution API');
    }
    return SkillScanResult(ok: findings.isEmpty, findings: findings);
  }

  static SkillScanResult scanDirectory(String dir) {
    final findings = <String>[];
    final d = Directory(dir);
    if (!d.existsSync()) {
      return SkillScanResult(ok: false, findings: ['dir missing']);
    }
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.md') || f.path.endsWith('.dart') || f.path.endsWith('.yaml')) {
        final r = scanFile(f.path);
        findings.addAll(r.findings.map((x) => '${f.path}: $x'));
      }
    }
    return SkillScanResult(ok: findings.isEmpty, findings: findings);
  }
}

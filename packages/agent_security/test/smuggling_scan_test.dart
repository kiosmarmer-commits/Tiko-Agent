import 'package:agent_security/agent_security.dart';
import 'package:test/test.dart';

void main() {
  test('ANSI escape sequence (CSI) terdeteksi', () {
    final cmd = 'echo "ok\x1B[31mmerah\x1B[0m"';
    final hits = SmugglingScan.scan(cmd);
    expect(hits.map((h) => h.kind), contains('ansi_escape'));
    expect(SmugglingScan.isClean(cmd), isFalse);
  });

  test('OSC sequence (hyperlink/title) diklasifikasikan tersendiri', () {
    final cmd = 'echo \x1B]8;;http://evil.example\x07klik\x1B]8;;\x07';
    final kinds = SmugglingScan.scan(cmd).map((h) => h.kind).toSet();
    expect(kinds, contains('osc_sequence'));
  });

  test('newline di dalam quoted string terdeteksi', () {
    final cmd = 'echo "satu\ndua; rm -rf /"';
    final hits = SmugglingScan.scan(cmd);
    expect(hits.map((h) => h.kind), contains('quoted_newline'));
  });

  test('newline di luar quoted string tidak ditandai quoted_newline', () {
    final cmd = 'echo satu\necho dua';
    final kinds = SmugglingScan.scan(cmd).map((h) => h.kind).toSet();
    expect(kinds, isNot(contains('quoted_newline')));
  });

  test('karakter unicode tak terlihat terdeteksi (zero-width, bidi, VS16)',
      () {
    const zeroWidth = 'echo "ha\u200Brusial"';
    const bidi = 'echo "\u202Egnp.exe"';
    const vs16 = 'echo "\uFE0F"';
    for (final cmd in [zeroWidth, bidi, vs16]) {
      final hits = SmugglingScan.scan(cmd);
      expect(hits.map((h) => h.kind), contains('invisible_unicode'),
          reason: cmd);
      expect(hits.first.description, contains('U+'), reason: cmd);
    }
  });

  test('karakter unicode normal tidak false-positive', () {
    expect(
      SmugglingScan.isClean('echo "Héllo wörld — 日本語 ✓"'),
      isTrue,
    );
  });

  test('perintah bersih → scan kosong', () {
    expect(SmugglingScan.isClean('git status'), isTrue);
    expect(SmugglingScan.isClean('ls -la src/'), isTrue);
    expect(SmugglingScan.scan(''), isEmpty);
  });

  test('ShellPolicy menolak perintah dengan pola smuggling', () {
    final policy = ShellPolicy(allowlist: const [['echo']]);
    expect(
      policy.check('echo \x1B[31mhi'),
      contains('terminal-smuggling'),
    );
    expect(
      policy.check('echo "baris\nlain"'),
      contains('terminal-smuggling'),
    );
    expect(
      policy.check('echo ha\u200Brusial'),
      contains('terminal-smuggling'),
    );
    // Perintah allowlist polos tetap lolos.
    expect(policy.check('echo halo'), isNull);
  });

  test('hasil scan bisa diserialisasi (audit JSON)', () {
    final hits = SmugglingScan.scan('echo \x1B[2J');
    expect(hits, hasLength(1));
    final json = hits.first.toJson();
    expect(json['kind'], 'ansi_escape');
    expect(json['position'], isA<int>());
    expect(json['snippet'], isA<String>());
  });
}

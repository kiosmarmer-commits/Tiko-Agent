import 'package:agent_tools/agent_tools.dart';
import 'package:test/test.dart';

void main() {
  test('memilih konten utama dan membuang boilerplate', () {
    final html = [
      '<html><body>',
      '<nav>Home About Contact</nav>',
      '<article><h1>Judul</h1>',
      '<p>Paragraf&nbsp;satu.</p>',
      '<p>Paragraf dua &amp; tiga.</p>',
      '<script>alert(1)</script></article>',
      '<footer>(c) 2026</footer>',
      '</body></html>',
    ].join();
    final text = htmlToText(html);
    expect(text, contains('# Judul'));
    expect(text, contains('Paragraf satu.'));
    expect(text, contains('Paragraf dua & tiga.'));
    expect(text, isNot(contains('alert(1)')));
    expect(text, isNot(contains('Home About')));
    expect(text, isNot(contains('(c) 2026')));
  });

  test('entitas numerik desimal dan heksadesimal didekode', () {
    expect(htmlToText('<p>caf&#233; &#x2603;</p>'), 'café ☃');
  });

  test('baris kosong dan duplikat berurutan dihapus', () {
    expect(
      htmlToText('<div>aa</div><div>aa</div><p>bb</p><br><br><p>bb</p>'),
      'aa\nbb',
    );
  });

  test('halaman tanpa article tetap terbaca', () {
    expect(
      htmlToText('<html><body><p>Halo&nbsp;dunia</p></body></html>'),
      'Halo dunia',
    );
  });
}

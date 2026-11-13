import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Deterministic synthetic vault generator (BM-01).
///
/// Notes are linked with preferential attachment (Barabási–Albert style), so
/// the in-degree distribution approximates a power law like real vaults.
/// Same [seed] → byte-identical vault (AC of BM-01).
class VaultGenerator {
  VaultGenerator({this.seed = 42});

  final int seed;

  static const _folders = ['catatan', 'proyek', 'riset', 'jurnal'];
  static const _topics = [
    'algoritma', 'basis-data', 'jaringan', 'kriptografi', 'kecerdasan',
    'sistem', 'bahasa', 'statistika', 'optimasi', 'visualisasi',
    'memori', 'paralel', 'kompilator', 'graf', 'logika',
  ];
  static const _filler = [
    'Ide ini berkembang dari diskusi sebelumnya dan perlu diuji lebih lanjut.',
    'Catatan penting: pendekatan sederhana lebih mudah dirawat jangka panjang.',
    'Rujukan silang dengan catatan lain masih perlu dilengkapi.',
    'Hipotesis awal belum terbukti; kumpulkan data tambahan terlebih dahulu.',
    'Ringkasan eksperimen menunjukkan perbaikan konsisten namun kecil.',
    'Pertimbangkan trade-off antara kecepatan dan konsumsi memori.',
    'Tulis ulang bagian ini setelah membaca referensi yang dirujuk.',
    'Tautan antar topik di sini membentuk klaster pengetahuan yang padat.',
  ];

  /// Generates [count] notes under [outDir]. Returns a manifest.
  Future<GeneratorManifest> generate(
    String outDir,
    int count, {
    int attachments = 0,
    double brokenLinkRate = 0.03,
    double embedRate = 0.05,
  }) async {
    final rng = Random(seed);
    final dir = Directory(outDir);
    if (await dir.exists()) {
      throw ArgumentError('direktori sudah ada: $outDir');
    }
    await dir.create(recursive: true);

    final titles = <String>[];
    final paths = <String>[];
    final used = <String>{};
    for (var i = 0; i < count; i++) {
      String title;
      do {
        final topic = _topics[rng.nextInt(_topics.length)];
        final suffix = rng.nextInt(1000);
        title = '$topic-$suffix';
      } while (!used.add(title));
      final folder = _folders[rng.nextInt(_folders.length)];
      titles.add(title);
      paths.add('$folder/$title.md');
    }

    // Preferential attachment: each new note links to `linksPerNote` earlier
    // notes chosen with probability proportional to current degree.
    final degree = List<int>.filled(count, 0);
    final targetsPerNote = List<List<int>>.generate(count, (_) => <int>[], growable: false);
    const linksPerNote = 3;
    var cumulativeLinks = 0;
    for (var i = 1; i < count; i++) {
      for (var l = 0; l < linksPerNote && cumulativeLinks > 0; l++) {
        var pick = rng.nextInt(cumulativeLinks);
        var target = 0;
        for (; target < i; target++) {
          pick -= degree[target];
          if (pick < 0) break;
        }
        if (target >= i) target = rng.nextInt(i);
        if (targetsPerNote[i].contains(target)) continue;
        targetsPerNote[i].add(target);
        degree[target]++;
        degree[i]++;
        cumulativeLinks++;
      }
      if (targetsPerNote[i].isEmpty && i > 0) {
        final target = rng.nextInt(i);
        targetsPerNote[i].add(target);
        degree[target]++;
        degree[i]++;
        cumulativeLinks++;
      }
    }

    var brokenLinks = 0;
    var embeds = 0;
    for (var i = 0; i < count; i++) {
      final buffer = StringBuffer();
      final day = 1 + (i % 28);
      final month = 1 + (i % 12);
      buffer
        ..writeln('---')
        ..writeln('title: ${titles[i]}')
        ..writeln('created: 2026-$month-${day.toString().padLeft(2, '0')}');
      final tagCount = 1 + rng.nextInt(2);
      buffer.writeln('tags:');
      for (var t = 0; t < tagCount; t++) {
        buffer.writeln('  - ${_topics[rng.nextInt(_topics.length)]}');
      }
      if (rng.nextInt(8) == 0) {
        buffer.writeln('aliases:');
        buffer.writeln('  - ${titles[i]} alias');
      }
      buffer
        ..writeln('---')
        ..writeln()
        ..writeln('# ${titles[i]}')
        ..writeln()
        ..writeln(_filler[rng.nextInt(_filler.length)])
        ..writeln();

      final headingCount = 1 + rng.nextInt(2);
      for (var h = 0; h < headingCount; h++) {
        buffer
          ..writeln('## Bagian ${h + 1}')
          ..writeln()
          ..writeln(_filler[rng.nextInt(_filler.length)])
          ..writeln();
      }

      for (final target in targetsPerNote[i]) {
        if (rng.nextDouble() < brokenLinkRate) {
          buffer
            ..writeln('Lihat juga: [[topik-hapus-${rng.nextInt(1000)}]].')
            ..writeln();
          brokenLinks++;
          continue;
        }
        final link = '[[${titles[target]}]]';
        if (rng.nextDouble() < embedRate) {
          buffer
            ..writeln('!$link')
            ..writeln();
          embeds++;
        } else {
          buffer
            ..writeln('Terkait: $link.')
            ..writeln();
        }
      }

      final file = File(p.join(outDir, 'catatan_vault', paths[i]));
      await file.parent.create(recursive: true);
      await file.writeAsString(buffer.toString());
    }

    for (var a = 0; a < attachments; a++) {
      final file = File(p.join(outDir, 'catatan_vault', 'lampiran', 'gambar-$a.png'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.generate(64, (i) => (i * a) % 256));
    }

    await Directory(p.join(outDir, '.obsidian')).create();
    await File(p.join(outDir, '.obsidian', 'app.json')).writeAsString('{}');

    return GeneratorManifest(
      seed: seed,
      noteCount: count,
      linkCount: cumulativeLinks,
      brokenLinks: brokenLinks,
      embeds: embeds,
      attachments: attachments,
    );
  }
}

class GeneratorManifest {
  const GeneratorManifest({
    required this.seed,
    required this.noteCount,
    required this.linkCount,
    required this.brokenLinks,
    required this.embeds,
    required this.attachments,
  });

  final int seed;
  final int noteCount;
  final int linkCount;
  final int brokenLinks;
  final int embeds;
  final int attachments;

  Map<String, Object?> toJson() => {
        'seed': seed,
        'note_count': noteCount,
        'link_count': linkCount,
        'broken_links': brokenLinks,
        'embeds': embeds,
        'attachments': attachments,
      };
}

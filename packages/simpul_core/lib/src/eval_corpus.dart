import 'dart:math' as math;
import 'dart:typed_data';

import 'embedding.dart';
import 'note_parser.dart';
import 'vault_index.dart';

/// One evaluation query with its gold note paths (AI-E01).
class EvalCase {
  const EvalCase(this.query, this.relevantPaths);

  final String query;
  final List<String> relevantPaths;
}

/// Aggregate retrieval metrics (AI-E02): recall@k and MRR over [EvalCase]s.
class EvalResult {
  const EvalResult({
    required this.modelVersion,
    required this.caseCount,
    required this.recallAtK,
    required this.mrr,
    required this.k,
  });

  final String modelVersion;
  final int caseCount;
  final double recallAtK;
  final double mrr;
  final int k;

  Map<String, Object?> toJson() => {
        'model': modelVersion,
        'cases': caseCount,
        'k': k,
        'recall_at_k': recallAtK,
        'mrr': mrr,
      };
}

/// Deterministic multilingual evaluation set (AI-E01 lite): 42 notes across
/// 7 topic clusters written in Indonesian and English, plus 28 queries whose
/// gold notes are known. Cross-lingual queries (EN query over an Indonesian
/// note and vice versa) are included on purpose.
abstract final class EvalCorpus {
  static const topics = [
    (
      'machine-learning',
      [
        (
          'neural-networks',
          'jaringan saraf tiruan belajar dari data gambar berlabel melalui backpropagation',
          'neural networks learn from labeled image data through backpropagation',
        ),
        (
          'decision-trees',
          'pohon keputusan membagi data dengan information gain dan gini impurity',
          'decision trees split data using information gain and gini impurity',
        ),
        (
          'clustering',
          'klasterisasi k-means mengelompokkan titik data berdasarkan jarak euclidean ke centroid',
          'k-means clustering groups data points by euclidean distance to centroids',
        ),
        (
          'overfitting',
          'overfitting terjadi saat model menghafal data latih dan gagal generalisasi, diatasi dengan regularisasi dan dropout',
          'overfitting happens when a model memorizes training data and fails to generalize, mitigated by regularization and dropout',
        ),
        (
          'transformers',
          'arsitektur transformer memakai self-attention untuk memproses urutan token secara paralel',
          'the transformer architecture uses self-attention to process token sequences in parallel',
        ),
        (
          'evaluation',
          'metrik evaluasi model klasifikasi mencakup precision, recall, dan f1 score pada confusion matrix',
          'classification model evaluation metrics include precision, recall, and f1 score from the confusion matrix',
        ),
      ],
    ),
    (
      'cooking',
      [
        (
          'rendang',
          'rendang padang dimasak dari daging sapi santan kelapa dengan api kecil berjam-jam hingga kering',
          'beef rendang from padang is slow cooked in coconut milk over low heat for hours until dry',
        ),
        (
          'sushi',
          'sushi nasi jepang dibumbui cuka beras dan dibalut nori dengan isian ikan salmon segar',
          'japanese sushi rice is seasoned with rice vinegar and rolled in nori with fresh salmon filling',
        ),
        (
          'pasta',
          'pasta italia al dente dimasak dengan saus tomat san marzano dan keju parmesan',
          'italian pasta cooked al dente is served with san marzano tomato sauce and parmesan cheese',
        ),
        (
          'roti-sourdough',
          'roti sourdough difermentasi dengan starter alami selama dua belas jam menghasilkan rasa asam',
          'sourdough bread ferments with a natural starter for twelve hours producing a tangy flavor',
        ),
        (
          'sate',
          'sate ayam dibakar di atas arang dengan bumbu kacang dan kecap manis',
          'chicken satay is grilled over charcoal with peanut sauce and sweet soy glaze',
        ),
        (
          'kimchi',
          'kimchi korea sayur kol fermentasi gochugaru bawang putih jahe asin',
          'korean kimchi is fermented napa cabbage with gochugaru chili garlic ginger and salt',
        ),
      ],
    ),
    (
      'football',
      [
        (
          'offside',
          'posisi offside dalam sepak bola terjadi saat penyerang lebih dekat ke gawang daripada bek terakhir',
          'the offside position in football occurs when an attacker is nearer the goal than the last defender',
        ),
        (
          'penalty-kick',
          'tendangan penalti diambil dari titik sebelas meter melawan penjaga gawang',
          'a penalty kick is taken from eleven meters against the goalkeeper',
        ),
        (
          'world-cup',
          'piala dunia fifa diselenggarakan setiap empat tahun dengan 32 tim nasional',
          'the fifa world cup runs every four years with thirty two national teams',
        ),
        (
          'var',
          'video assistant referee meninjau gol, penalti, dan kartu merah melalui rekaman layar',
          'the video assistant referee reviews goals penalties and red cards using screen recordings',
        ),
        (
          'tiki-taka',
          'tiki-taka gaya possession passing pendek cepat yang dipopulerkan barcelona',
          'tiki-taka is the short quick possession passing style popularized by barcelona',
        ),
        (
          'transfer-window',
          'jendela transfer pemain dibuka dua kali setahun dengan mekanisme buyout clause',
          'the player transfer window opens twice a year with buyout clause mechanics',
        ),
      ],
    ),
    (
      'personal-finance',
      [
        (
          'compound-interest',
          'bunga majemuk membuat tabungan tumbuh eksponensial karena bunga ikut berbunga',
          'compound interest makes savings grow exponentially because interest earns interest',
        ),
        (
          'index-funds',
          'dana indeks mengikuti indeks pasar saham dengan biaya kelola rendah',
          'index funds track the stock market index with low management fees',
        ),
        (
          'emergency-fund',
          'dana darurat idealnya menutup enam bulan pengeluaran rutin',
          'an emergency fund ideally covers six months of routine expenses',
        ),
        (
          'inflation',
          'inflasi mengikis daya beli uang sehingga nilai riil tabungan menurun',
          'inflation erodes the purchasing power of money so real savings value declines',
        ),
        (
          'debt-snowball',
          'metode debt snowball melunasi utang terkecil lebih dulu untuk momentum psikologis',
          'the debt snowball method pays the smallest debt first for psychological momentum',
        ),
        (
          'diversification',
          'diversifikasi portofolio menyebarkan risiko ke banyak kelas aset',
          'portfolio diversification spreads risk across many asset classes',
        ),
      ],
    ),
    (
      'travel',
      [
        (
          'visa-on-arrival',
          'visa on arrival diperoleh di bandara tujuan tanpa pengajuan kedutaan',
          'visa on arrival is obtained at the destination airport without an embassy application',
        ),
        (
          'budget-backpacking',
          'backpacking hemat memakai hostel, transportasi umum, dan makanan jalanan',
          'budget backpacking uses hostels, public transport, and street food',
        ),
        (
          'jet-lag',
          'jet lag muncul karena perbedaan zona waktu mengganggu ritme sirkadian',
          'jet lag arises because time zone differences disrupt the circadian rhythm',
        ),
        (
          'travel-insurance',
          'asuransi perjalanan menanggung pembatalan penerbangan dan biaya medis di luar negeri',
          'travel insurance covers flight cancellations and medical costs abroad',
        ),
        (
          'packing-light',
          'prinsip packing light: kabin saja, pakaian serbaguna, dan dokumen digital',
          'packing light means carry on only, versatile clothing, and digital documents',
        ),
        (
          'hidden-gems',
          'destinasi hidden gems jauh dari keramaian wisatawan populer',
          'hidden gem destinations lie far from popular tourist crowds',
        ),
      ],
    ),
    (
      'health',
      [
        (
          'hiit',
          'latihan hiit interval intensitas tinggi membakar kalori dalam waktu singkat',
          'hiit high intensity interval training burns calories in short sessions',
        ),
        (
          'sleep-hygiene',
          'kebersihan tidur: jadwal konsisten, kamar gelap, tanpa layar sebelum tidur',
          'sleep hygiene means consistent schedule, dark room, no screens before bed',
        ),
        (
          'hydration',
          'hidrasi harian yang cukup menjaga keseimbangan elektrolit tubuh',
          'adequate daily hydration maintains the body electrolyte balance',
        ),
        (
          'meditation',
          'meditasi mindfulness menurunkan kadar kortisol stres',
          'mindfulness meditation lowers stress cortisol levels',
        ),
        (
          'protein-intake',
          'asupan protein harian mendukung pemulihan otot setelah latihan beban',
          'daily protein intake supports muscle recovery after strength training',
        ),
        (
          'posture',
          'postur duduk ergonomis mencegah nyeri leher dan punggung',
          'an ergonomic sitting posture prevents neck and back pain',
        ),
      ],
    ),
    (
      'programming',
      [
        (
          'git-rebase',
          'git rebase menulis ulang riwayat commit agar linear sebelum merge',
          'git rebase rewrites commit history to stay linear before merging',
        ),
        (
          'garbage-collection',
          'garbage collection membebaskan memori objek yang tidak lagi dirujuk',
          'garbage collection frees memory of objects no longer referenced',
        ),
        (
          'unit-testing',
          'unit testing memverifikasi perilaku fungsi secara terisolasi dengan mock',
          'unit testing verifies function behavior in isolation using mocks',
        ),
        (
          'sql-index',
          'indeks sql mempercepat query dengan struktur b-tree di kolom pencarian',
          'a sql index speeds queries with a b-tree structure on searched columns',
        ),
        (
          'async-await',
          'async await menjalankan operasi io tanpa memblokir event loop',
          'async await runs io operations without blocking the event loop',
        ),
        (
          'code-review',
          'code review menangkap bug dan menjaga konsistensi gaya sebelum merge',
          'code review catches bugs and keeps style consistent before merging',
        ),
      ],
    ),
  ];

  static String _path(String topic, String slug) =>
      'eval/$topic/$slug.md';

  /// The deterministic mini-vault; note text mixes Indonesian and English.
  static List<IndexedNote> notes() {
    final out = <IndexedNote>[];
    for (final (topic, subtopics) in topics) {
      for (final (slug, idText, enText) in subtopics) {
        final path = _path(topic, slug);
        final title = slug.replaceAll('-', ' ');
        final text = '$title\n$idText\n$enText';
        out.add(
          IndexedNote(
            path: path,
            title: title,
            mtimeNs: 0,
            sizeBytes: text.length,
            contentHash: 'eval-$path',
            wordCount: text.split(' ').length,
            props: const {},
            tags: [topic],
            aliases: const [],
            links: const [],
            chunks: [
              NoteChunk(
                headingPath: '',
                startChar: 0,
                endChar: text.length,
                text: text,
              ),
            ],
          ),
        );
      }
    }
    return out;
  }

  /// 28 gold queries: four per topic, alternating Indonesian and English
  /// phrasing, including cross-lingual pairs (AI-E01).
  static List<EvalCase> cases() => [
        for (final (topic, subtopics) in topics)
          for (var i = 0; i < 4; i++)
            i.isEven
                ? EvalCase(
                    _queryId(topic, subtopics[i].$1),
                    [_path(topic, subtopics[i].$1)],
                  )
                : EvalCase(
                    _queryEn(topic, subtopics[i].$1),
                    [_path(topic, subtopics[i].$1)],
                  ),
      ];

  static String _queryId(String topic, String slug) {
    final phrase = switch (slug) {
      'neural-networks' => 'bagaimana cara jaringan saraf belajar dari gambar?',
      'decision-trees' => 'apa itu information gain pada pohon keputusan?',
      'clustering' => 'cara kerja k-means mengelompokkan data?',
      'overfitting' => 'mengapa model menghafal data latih dan cara mengatasinya?',
      'transformers' => 'apa fungsi self-attention pada transformer?',
      'evaluation' => 'metrik apa saja untuk menilai model klasifikasi?',
      'rendang' => 'bagaimana memasak rendang daging yang benar?',
      'sushi' => 'bahan apa yang dipakai untuk membuat sushi?',
      'pasta' => 'cara memasak pasta italia yang al dente?',
      'roti-sourdough' => 'kenapa roti sourdough berasa asam?',
      'sate' => 'bumbu apa yang cocok untuk sate ayam bakar?',
      'kimchi' => 'kimchi dibuat dari bahan apa saja?',
      'offside' => 'kapan seorang penyerang dikatakan offside?',
      'penalty-kick' => 'dari jarak berapa tendangan penalti diambil?',
      'world-cup' => 'berapa tahun sekali piala dunia diselenggarakan?',
      'var' => 'apa saja yang ditinjau video assistant referee?',
      'tiki-taka' => 'gaya passing seperti apa yang dipakai barcelona?',
      'transfer-window' => 'kapan jendela transfer pemain dibuka?',
      'compound-interest' => 'kenapa tabungan bisa tumbuh eksponensial?',
      'index-funds' => 'reksa dana apa yang biaya kelolanya rendah?',
      'emergency-fund' => 'berapa lama pengeluaran yang harus ditutup dana darurat?',
      'inflation' => 'apa dampak inflasi terhadap nilai tabungan?',
      'debt-snowball' => 'utang yang mana yang harus dilunasi lebih dulu?',
      'diversification' => 'bagaimana cara menyebarkan risiko portofolio?',
      'visa-on-arrival' => 'bagaimana cara mendapat visa di bandara tujuan?',
      'budget-backpacking' => 'tips bepergian hemat dengan hostel?',
      'jet-lag' => 'kenapa tubuh lelah setelah melintasi zona waktu?',
      'travel-insurance' => 'asuransi perjalanan menangung apa saja?',
      'packing-light' => 'cara berpakaian agar bagasi kabin cukup?',
      'hidden-gems' => 'di mana destinasi sepi dari wisatawan populer?',
      'hiit' => 'latihan intensitas tinggi apa yang singkat tapi efektif?',
      'sleep-hygiene' => 'bagaimana kebiasaan tidur yang sehat?',
      'hydration' => 'apa manfaat minum cukup air setiap hari?',
      'meditation' => 'aktivitas apa yang menurunkan hormon stres?',
      'protein-intake' => 'nutrisi apa yang dibutuhkan untuk pemulihan otot?',
      'posture' => 'bagaimana posisi duduk agar punggung tidak sakit?',
      'git-rebase' => 'cara membuat riwayat commit tetap linear?',
      'garbage-collection' => 'bagaimana memori objek tak terpakai dibebaskan?',
      'unit-testing' => 'cara menguji fungsi secara terisolasi?',
      'sql-index' => 'struktur apa yang mempercepat query database?',
      'async-await' => 'bagaimana menjalankan io tanpa memblokir event loop?',
      'code-review' => 'kebiasaan apa yang menangkap bug sebelum merge?',
      _ => slug.replaceAll('-', ' '),
    };
    return '$phrase (topik $topic)';
  }

  static String _queryEn(String topic, String slug) {
    final phrase = switch (slug) {
      'neural-networks' => 'how do neural networks learn from images?',
      'decision-trees' => 'what is gini impurity used for?',
      'clustering' => 'how does k-means group data points?',
      'overfitting' => 'what reduces memorization in trained models?',
      'transformers' => 'how does self-attention process sequences?',
      'evaluation' => 'which metrics describe a confusion matrix?',
      'rendang' => 'how is beef rendang traditionally cooked?',
      'sushi' => 'what wraps the rice in sushi rolls?',
      'pasta' => 'what sauce pairs with al dente pasta?',
      'roti-sourdough' => 'what makes sourdough bread tangy?',
      'sate' => 'which sauce accompanies grilled chicken satay?',
      'kimchi' => 'what chili is used to ferment kimchi?',
      'offside' => 'when is an attacker in an offside position?',
      'penalty-kick' => 'how far is the penalty spot from the goal?',
      'world-cup' => 'how often is the fifa world cup held?',
      'var' => 'what does the video assistant referee review?',
      'tiki-taka' => 'which passing style did barcelona popularize?',
      'transfer-window' => 'when can clubs sign players with buyout clauses?',
      'compound-interest' => 'why does interest earn interest over time?',
      'index-funds' => 'which funds track the market with low fees?',
      'emergency-fund' => 'how many months should emergency savings cover?',
      'inflation' => 'how does inflation affect purchasing power?',
      'debt-snowball' => 'which debt gets paid first in the snowball method?',
      'diversification' => 'how do investors spread portfolio risk?',
      'visa-on-arrival' => 'where do travelers get a visa on arrival?',
      'budget-backpacking' => 'how do backpackers save money on lodging?',
      'jet-lag' => 'which rhythm is disrupted by time zones?',
      'travel-insurance' => 'what costs does travel insurance cover abroad?',
      'packing-light' => 'how do travelers pack only a carry on?',
      'hidden-gems' => 'where are destinations without tourist crowds?',
      'hiit' => 'what is high intensity interval training?',
      'sleep-hygiene' => 'what habits improve sleep quality?',
      'hydration' => 'what balance does daily water intake maintain?',
      'meditation' => 'which practice lowers stress hormones?',
      'protein-intake' => 'what nutrient supports muscle recovery?',
      'posture' => 'which sitting position prevents back pain?',
      'git-rebase' => 'how does git rebase change commit history?',
      'garbage-collection' => 'when is memory of unreferenced objects freed?',
      'unit-testing' => 'how are functions tested with mocks in isolation?',
      'sql-index' => 'which structure speeds up database queries?',
      'async-await' => 'how do async operations avoid blocking the loop?',
      'code-review' => 'what catches bugs before merging code?',
      _ => slug.replaceAll('-', ' '),
    };
    return '$phrase ($topic topic)';
  }
}

/// Runs retrieval evaluation over the [EvalCorpus] with any embedder (AI-E01,
/// AI-E02). Deterministic: cosine ranking over fixed notes and queries.
/// Vectors are L2-normalized, so cosine similarity reduces to a dot product.
abstract final class EvalHarness {
  static EvalResult run({
    EmbeddingProvider embedder = const _DefaultEvalEmbedder(),
    int k = 5,
  }) {
    final notes = EvalCorpus.notes();
    final noteVectors = [
      for (final note in notes) embedder.embed(_representative(note)),
    ];
    final cases = EvalCorpus.cases();
    final queryVectors = [
      for (final evalCase in cases) embedder.embed(evalCase.query),
    ];
    return _score(
      modelVersion: embedder.modelVersion,
      k: k,
      noteVectors: noteVectors,
      queryVectors: queryVectors,
    );
  }

  /// Same evaluation with a server-backed embedder (AI-03); notes and queries
  /// are sent in batches so the transport round-trips stay low (AI-12).
  static Future<EvalResult> runAsync({
    required AsyncEmbeddingProvider embedder,
    int k = 5,
  }) async {
    final notes = EvalCorpus.notes();
    final noteVectors = await embedder.embedBatch([
      for (final note in notes) _representative(note),
    ]);
    final cases = EvalCorpus.cases();
    final queryVectors = await embedder.embedBatch([
      for (final evalCase in cases) evalCase.query,
    ]);
    return _score(
      modelVersion: embedder.modelVersion,
      k: k,
      noteVectors: noteVectors,
      queryVectors: queryVectors,
    );
  }

  static EvalResult _score({
    required String modelVersion,
    required int k,
    required List<Float32List> noteVectors,
    required List<Float32List> queryVectors,
  }) {
    final notes = EvalCorpus.notes();
    final cases = EvalCorpus.cases();
    assert(noteVectors.length == notes.length);
    assert(queryVectors.length == cases.length);
    final pathToIndex = {
      for (var i = 0; i < notes.length; i++) notes[i].path: i,
    };

    var recallSum = 0.0;
    var mrrSum = 0.0;
    for (var c = 0; c < cases.length; c++) {
      final evalCase = cases[c];
      final queryVector = queryVectors[c];
      final ranked = List<int>.generate(notes.length, (i) => i)
        ..sort((a, b) {
          final cmp = _dot(queryVector, noteVectors[b])
              .compareTo(_dot(queryVector, noteVectors[a]));
          return cmp != 0 ? cmp : a.compareTo(b);
        });
      final rankOf = {
        for (var rank = 0; rank < ranked.length; rank++) ranked[rank]: rank + 1,
      };

      var hits = 0;
      var bestReciprocal = 0.0;
      for (final gold in evalCase.relevantPaths) {
        final idx = pathToIndex[gold];
        if (idx == null) continue;
        final rank = rankOf[idx] ?? notes.length + 1;
        if (rank <= k) hits++;
        bestReciprocal = math.max(bestReciprocal, 1 / rank);
      }
      recallSum += hits / evalCase.relevantPaths.length;
      mrrSum += bestReciprocal;
    }

    return EvalResult(
      modelVersion: modelVersion,
      caseCount: cases.length,
      recallAtK: recallSum / cases.length,
      mrr: mrrSum / cases.length,
      k: k,
    );
  }

  static double _dot(Float32List a, Float32List b) {
    final n = math.min(a.length, b.length);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  static String _representative(IndexedNote note) {
    final buffer = StringBuffer(note.title);
    for (final chunk in note.chunks) {
      buffer
        ..writeln()
        ..write(chunk.text);
    }
    return buffer.toString();
  }
}

class _DefaultEvalEmbedder implements EmbeddingProvider {
  const _DefaultEvalEmbedder();

  static final HashingEmbedder _inner = HashingEmbedder();

  @override
  int get dimension => _inner.dimension;

  @override
  String get modelVersion => _inner.modelVersion;

  @override
  Float32List embed(String text) => _inner.embed(text);
}

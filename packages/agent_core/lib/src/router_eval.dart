import 'models.dart';
import 'router.dart';

/// One deterministic routing evaluation case: an Indonesian utterance plus
/// the routing expectations derived from the tiered router contract
/// (ALG-06). Expectations follow the no-decision heuristic path so the
/// dataset runs without any model call.
class RouterEvalCase {
  const RouterEvalCase({
    required this.id,
    required this.text,
    required this.expectNeedTools,
    this.expectTier,
    this.expectComplexity,
    this.category = 'general',
  });

  final String id;
  final String text;
  final bool expectNeedTools;
  final int? expectTier;
  final String? expectComplexity;
  final String category;
}

/// Result of evaluating one [RouterEvalCase].
class RouterEvalResult {
  const RouterEvalResult({
    required this.caseId,
    required this.passed,
    required this.detail,
  });

  final String caseId;
  final bool passed;
  final String detail;
}

/// Deterministic routing harness: routes each case through [Router.route]
/// and compares the decision with the expectations. No LLM call, no
/// wall-clock dependency, no shared mutable router state.
abstract final class RouterEvalHarness {
  static Future<List<RouterEvalResult>> run(
    Router router,
    List<RouterEvalCase> cases,
  ) async {
    final session = Session(
      id: 'router-eval',
      channel: 'eval',
      userKey: 'router-eval',
    );
    final results = <RouterEvalResult>[];
    for (final evalCase in cases) {
      final decision = await router.route(evalCase.text, session);
      final problems = <String>[];
      if (decision.needTools != evalCase.expectNeedTools) {
        problems.add(
          'need_tools=${decision.needTools} '
          'expected ${evalCase.expectNeedTools}',
        );
      }
      final tier = evalCase.expectTier;
      if (tier != null && decision.tier != tier) {
        problems.add('tier=${decision.tier} expected $tier');
      }
      final complexity = evalCase.expectComplexity;
      if (complexity != null && decision.complexity != complexity) {
        problems.add(
          'complexity=${decision.complexity} expected $complexity',
        );
      }
      results.add(
        RouterEvalResult(
          caseId: evalCase.id,
          passed: problems.isEmpty,
          detail: problems.join('; '),
        ),
      );
    }
    return results;
  }

  /// Passed / total; 0 for an empty run.
  static double accuracy(List<RouterEvalResult> results) {
    if (results.isEmpty) return 0;
    final passed = results.where((r) => r.passed).length;
    return passed / results.length;
  }

  static List<RouterEvalResult> failures(List<RouterEvalResult> results) =>
      results.where((r) => !r.passed).toList();
}

/// 50 kalimat bahasa Indonesia dengan ekspektasi routing (dataset
/// evaluasi router). Kategori: smalltalk, knowledge, tools, slash, long,
/// edge.
const List<RouterEvalCase> indonesianRouterEval50 = [
    RouterEvalCase(
      id: 'ev-small-1',
      text: 'Halo, apa kabar hari ini?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-2',
      text: 'Terima kasih banyak atas bantuannya tadi.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-3',
      text: 'Selamat pagi, semoga harimu menyenangkan.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-4',
      text: 'Sampai jumpa besok ya.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-5',
      text: 'Aku sedang belajar bahasa Dart minggu ini.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-6',
      text: 'Ceritakan satu lelucon tentang programmer.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-7',
      text: 'Aku menikmati secangkir kopi sore ini.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-8',
      text: 'Musik apa yang sedang kamu dengarkan?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-9',
      text: 'Pendapatmu tentang perkembangan AI belakangan ini?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-small-10',
      text: 'Semoga lelahmu terbayar sudah.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'smalltalk',
    ),
    RouterEvalCase(
      id: 'ev-know-1',
      text: 'Apa itu fotosintesis pada tumbuhan?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-2',
      text: 'Jelaskan teori relativitas dengan bahasa sederhana.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-3',
      text: 'Siapa presiden pertama Republik Indonesia?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-4',
      text: 'Apa ibu kota negara Prancis?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-5',
      text: 'Sebutkan planet-planet di tata surya.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-6',
      text: 'Apa perbedaan demokrasi dan monarki?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-7',
      text: 'Bagaimana proses terjadinya hujan di atmosfer?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-8',
      text: 'Apa fungsi vitamin C bagi tubuh manusia?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-9',
      text: 'Jelaskan konsep blockchain secara umum.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-know-10',
      text: 'Mengapa langit tampak berwarna biru?',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'knowledge',
    ),
    RouterEvalCase(
      id: 'ev-tool-1',
      text: 'Hitung 234 dikali 567 lalu berikan hasilnya.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-2',
      text: 'Cari berita terbaru tentang peluncuran satelit.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-3',
      text: 'Baca isi berkas catatan saya lalu rangkum.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-4',
      text: 'Tulis laporan mingguan ke dokumen report.md.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-5',
      text: 'Jalankan skrip deploy di server produksi.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-6',
      text: 'Berapa lama waktu tempuh dari Jakarta ke Bandung?',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-7',
      text: 'Tanggal berapa hari ini menurut sistem?',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-8',
      text: 'Buat folder arsip untuk proyek baru ini.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-9',
      text: 'Jadwalkan rapat evaluasi setiap Senin pagi.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-10',
      text: 'Cek jadwal ferry ke Bali besok pagi.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-11',
      text: 'Cari resep rendang di web, lalu sebutkan bahannya.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-12',
      text: 'Hitung rata-rata nilai ulangan kelas ini.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-13',
      text: 'Baca surat elektronik masuk hari ini dan ringkas.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-14',
      text: 'Tulis ulang paragraf ini dengan gaya yang lebih formal.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-15',
      text: 'Jalankan seluruh pengujian sebelum rilis.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-tool-16',
      text: 'Simpan file laporan ke direktori cadangan.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'tools',
    ),
    RouterEvalCase(
      id: 'ev-slash-1',
      text: '/help',
      expectNeedTools: false,
      expectTier: 0,
      expectComplexity: 'ringan',
      category: 'slash',
    ),
    RouterEvalCase(
      id: 'ev-slash-2',
      text: '/status',
      expectNeedTools: false,
      expectTier: 0,
      expectComplexity: 'ringan',
      category: 'slash',
    ),
    RouterEvalCase(
      id: 'ev-slash-3',
      text: '/model list',
      expectNeedTools: false,
      expectTier: 0,
      expectComplexity: 'ringan',
      category: 'slash',
    ),
    RouterEvalCase(
      id: 'ev-slash-4',
      text: '/reset',
      expectNeedTools: false,
      expectTier: 0,
      expectComplexity: 'ringan',
      category: 'slash',
    ),
    RouterEvalCase(
      id: 'ev-slash-5',
      text: '/version',
      expectNeedTools: false,
      expectTier: 0,
      expectComplexity: 'ringan',
      category: 'slash',
    ),
    RouterEvalCase(
      id: 'ev-slash-6',
      text: '/tools list',
      expectNeedTools: false,
      expectTier: 0,
      expectComplexity: 'ringan',
      category: 'slash',
    ),
    RouterEvalCase(
      id: 'ev-long-1',
      text:
          'Pendidikan adalah fondasi utama bagi kemajuan sebuah' 
          'bangsa. Melalui pendidikan yang berkualitas, setiap' 
          'individu dapat mengembangkan potensi dirinya secara' 
          'maksimal, berpikir kritis, dan mengambil keputusan yang' 
          'bijaksana dalam kehidupan sehari-hari serta berkontribusi' 
          'bagi masyarakat luas.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'berat',
      category: 'long',
    ),
    RouterEvalCase(
      id: 'ev-long-2',
      text:
          'Budaya gotong royong menjadi perekat sosial yang menjaga' 
          'kebersamaan masyarakat di berbagai daerah. Tradisi ini' 
          'diwariskan antar generasi melalui kegiatan bersama' 
          'seperti kerja bakti membersihkan lingkungan, panen raya,' 
          'hingga perayaan hari besar yang diikuti seluruh warga' 
          'desa dengan penuh sukacita.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'berat',
      category: 'long',
    ),
    RouterEvalCase(
      id: 'ev-long-3',
      text:
          'Keuangan keluarga memerlukan perencanaan yang matang agar' 
          'seluruh kebutuhan harian tetap terpenuhi tanpa' 
          'mengorbankan tabungan masa depan, mulai dari pos makanan,' 
          'transportasi, pendidikan anak, kesehatan, hingga dana' 
          'darurat; karena itu tolong hitung total pengeluaran kita' 
          'bulan ini dan bandingkan dengan bulan sebelumnya supaya' 
          'terlihat pola belanja yang perlu dikurangi.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'berat',
      category: 'long',
    ),
    RouterEvalCase(
      id: 'ev-long-4',
      text:
          'Riset pasar yang baik memerlukan pengumpulan data dari' 
          'banyak sumber, verifikasi silang antar temuan, dan' 
          'sintesis yang hati-hati sebelum menarik kesimpulan;' 
          'karena itu tolong baca laporan penjualan kuartal terakhir' 
          'dari tim pemasaran, telusuri juga lampiran keuangan yang' 
          'menyertainya, lalu rangkum poin penting yang bisa menjadi' 
          'dasar keputusan strategi produk untuk semester depan.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'berat',
      category: 'long',
    ),
    RouterEvalCase(
      id: 'ev-edge-1',
      text: 'HITUNG LIMA BELAS PERSEN DARI DUA JUTA RUPIAH.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'edge',
    ),
    RouterEvalCase(
      id: 'ev-edge-2',
      text: 'Read the file config.yaml and print the contents.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'edge',
    ),
    RouterEvalCase(
      id: 'ev-edge-3',
      text: 'Kalkulator ilmiah itu milik laboratorium.',
      expectNeedTools: false,
      expectTier: 1,
      expectComplexity: 'ringan',
      category: 'edge',
    ),
    RouterEvalCase(
      id: 'ev-edge-4',
      text: 'Tolong tulis pengingat: baca berkas kontrak besok pagi.',
      expectNeedTools: true,
      expectTier: 2,
      expectComplexity: 'ringan',
      category: 'edge',
    ),
];

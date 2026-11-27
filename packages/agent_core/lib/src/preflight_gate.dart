// Hermes parity: `agent/turn_preflight_gate.py` — gerbang tekanan pra-API.
//
// Sebelum setiap panggilan API dalam satu turn, tekanan request diestimasi
// ulang: hasil tool tumbuh SETELAH estimasi `last_prompt_tokens` provider,
// jadi guard berbasis usage selalu tertinggal. Gerbang ini:
//   1. mengestimasi tekanan request penuh (pesan + system prompt + skema
//      tool — Hermes: bandingkan request terassembly utuh, bukan `messages`
//      mentah);
//   2. saat tekanan >= ambang kompresor, menjalankan kompresi preflight
//      (trigger `preflight`) sebelum request dikirim;
//   3. blocker progres-tidak-cukup (insufficient-progress): bila pass
//      kompresi sebelumnya tidak menurunkan tekanan secara berarti, pass
//      tambahan ditolak supaya turn tidak terjebak retry kompresi yang
//      sia-sia — recovery overflow provider tetap boleh berjalan.
//
// Never-raises: kegagalan kompresi preflight tidak boleh menggagalkan turn.

import 'compactor.dart';
import 'context_builder.dart';
import 'interfaces.dart';

/// Gerbang pra-API untuk satu turn; state `lastPressure` di-reset tiap
/// [AgentLoop.handle] agar blocker tidak membandingkan angka usang.
class PreflightGate {
  PreflightGate({this.enabled = true, this.progressMinTokens = 128});

  /// Matikan gerbang (mis. host yang sudah mengelola kompresi sendiri).
  final bool enabled;

  /// Penurunan tekanan minimum (token) yang dianggap "progres cukup"
  /// antar pass preflight.
  final int progressMinTokens;

  /// Tekanan pass preflight terakhir dalam turn ini (null = belum ada).
  int? lastPressure;

  /// True bila pass terakhir diblokir karena progres tidak cukup.
  bool blockedInsufficientProgress = false;

  /// Estimasi tekanan request penuh (token): pesan + system prompt +
  /// skema tool, ~4 char per token (konvensi estimasi repo).
  static int estimatePressureTokens(AgentContext ctx) {
    var chars = ctx.systemPrompt.length;
    for (final m in ctx.messages) {
      chars += m.content.length;
      if (m.toolCalls != null) {
        for (final c in m.toolCalls!) {
          chars += c.name.length + c.id.length;
          c.args.forEach((k, v) => chars += k.length + '$v'.length);
        }
      }
    }
    for (final t in ctx.tools) {
      chars += '${t.name}${t.description}'.length;
      chars += '${t.inputSchema}'.length;
    }
    return chars ~/ 4;
  }

  /// Ambang kompresor yang sama dipakai [Compactor.maybeCompact].
  static int thresholdOf(Compactor compactor) =>
      (compactor.maxSoftTokens * compactor.thresholdRatio).floor();

  /// Jalankan gerbang atas [ctx]. Mengembalikan konteks (mungkin hasil
  /// kompresi) beserta verdict pass ini.
  Future<PreflightVerdict> run(
    AgentContext ctx, {
    required Compactor compactor,
    LlmProvider? llmOverride,
  }) async {
    if (!enabled) {
      return PreflightVerdict(ctx: ctx, pressure: null, blocked: false);
    }
    final pressure = estimatePressureTokens(ctx);
    final threshold = thresholdOf(compactor);
    if (pressure < threshold) return PreflightVerdict(ctx: ctx, pressure: pressure, blocked: false);

    // Blocker progres-tidak-cukup: bandingkan request terassembly utuh,
    // bukan pesan mentah. Pass berikutnya hanya diizinkan bila pass
    // sebelumnya benar-benar menurunkan tekanan.
    final last = lastPressure;
    if (last != null && (last - pressure) < progressMinTokens) {
      blockedInsufficientProgress = true;
      return PreflightVerdict(ctx: ctx, pressure: pressure, blocked: true);
    }

    lastPressure = pressure;
    try {
      final compacted = await compactor.maybeCompact(
        ctx,
        llmOverride: llmOverride,
        trigger: 'preflight',
      );
      final after = estimatePressureTokens(compacted);
      lastPressure = after;
      return PreflightVerdict(ctx: compacted, pressure: after, blocked: false);
    } catch (_) {
      // Kompresi preflight gagal → lanjutkan request apa adanya; recovery
      // overflow di jalur provider tetap tersedia sebagai lapis kedua.
      return PreflightVerdict(ctx: ctx, pressure: pressure, blocked: false);
    }
  }
}

/// Hasil satu pass gerbang pra-API.
class PreflightVerdict {
  const PreflightVerdict({
    required this.ctx,
    required this.pressure,
    required this.blocked,
  });

  final AgentContext ctx;

  /// Tekanan terukur pass ini (null bila gerbang off).
  final int? pressure;

  /// True bila pass diblokir (progres tidak cukup) — request dikirim
  /// tanpa pass preflight tambahan.
  final bool blocked;
}

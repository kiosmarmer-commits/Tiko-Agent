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
import 'usage_anchor.dart';

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

  /// Hermes usage anchor (C5): di-set [AgentLoop] sebelum tiap request.
  /// Bila anchor fresh (prefix cocok), tekanan memakai angka ber-anchoring
  /// (usage nyata + delta) alih-alih heuristik chars/4 penuh.
  UsageAnchor? usageAnchor;

  /// Harga token per-gambar terikat turn (C7) — dipakai estimator.
  int imageTokenCost = defaultImageTokenCost;

  /// Estimasi tekanan request penuh (token): pesan + system prompt +
  /// skema tool, ~4 char per token (konvensi estimasi repo). Bila [anchor]
  /// diberikan dan masih cocok dengan transcript request, angka ber-
  /// anchoring (usage nyata + delta estimasi) MENGgantikan heuristik penuh
  /// — figur anchored adalah provider-exact dan tidak pernah di-floor
  /// (Hermes `turn_request_assembly`: anchored override).
  static int estimatePressureTokens(
    AgentContext ctx, {
    UsageAnchor? anchor,
    int imageCost = defaultImageTokenCost,
  }) {
    final request = ctx.toRequest();
    if (anchor != null) {
      final anchored = anchor.anchoredContextTokens(
        request.messages,
        imageCost: imageCost,
      );
      if (anchored != null) return anchored;
    }
    var chars = ctx.systemPrompt.length;
    for (final m in ctx.messages) {
      chars += m.content.length;
      if (m.images != null) {
        chars += m.images!.length * imageCost * 4;
      }
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
    // C5: angka ber-anchoring (usage nyata + delta) menggantikan heuristik
    // penuh bila anchor fresh; heuristik dipakai apa adanya bila tidak.
    final anchoredPressure = usageAnchor?.anchoredContextTokens(
      ctx.toRequest().messages,
      imageCost: imageTokenCost,
    );
    final anchored = anchoredPressure != null;
    final pressure = anchoredPressure ??
        estimatePressureTokens(ctx, imageCost: imageTokenCost);
    final threshold = thresholdOf(compactor);
    if (pressure < threshold) {
      return PreflightVerdict(
        ctx: ctx,
        pressure: pressure,
        blocked: false,
        anchored: anchored,
      );
    }

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
      // Kompresi menulis-ulang prefix → anchor menjadi kedaluwarsa;
      // anchoredContextTokens akan gagal-closed dan jatuh ke heuristik.
      final after = estimatePressureTokens(
        compacted,
        anchor: usageAnchor,
        imageCost: imageTokenCost,
      );
      lastPressure = after;
      return PreflightVerdict(
        ctx: compacted,
        pressure: after,
        blocked: false,
        anchored: anchored,
      );
    } catch (_) {
      // Kompresi preflight gagal → lanjutkan request apa adanya; recovery
      // overflow di jalur provider tetap tersedia sebagai lapis kedua.
      return PreflightVerdict(
        ctx: ctx,
        pressure: pressure,
        blocked: false,
        anchored: anchored,
      );
    }
  }
}

/// Hasil satu pass gerbang pra-API.
class PreflightVerdict {
  const PreflightVerdict({
    required this.ctx,
    required this.pressure,
    required this.blocked,
    this.anchored = false,
  });

  final AgentContext ctx;

  /// Tekanan terukur pass ini (null bila gerbang off).
  final int? pressure;

  /// True bila pass diblokir (progres tidak cukup) — request dikirim
  /// tanpa pass preflight tambahan.
  final bool blocked;

  /// True bila tekanan pass ini ber-anchoring usage nyata (C5), bukan
  /// heuristik chars/4.
  final bool anchored;
}

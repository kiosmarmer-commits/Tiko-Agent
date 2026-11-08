import 'dart:convert';

import 'errors.dart';

/// Hasil evaluasi lengkap dengan kontrak JSON (CALC-ARC-05):
/// structuredContent untuk tool, dan salinan teks JSON di content.
final class CalcResult {
  const CalcResult({
    required this.ok,
    this.value,
    this.display,
    this.normalizedExpr,
    this.approximate = false,
    this.precision = const {},
    this.warnings = const [],
    this.meta = const {},
    this.error,
  });

  final bool ok;
  final String? value;
  final String? display;
  final String? normalizedExpr;
  final bool approximate;
  final Map<String, Object> precision;
  final List<String> warnings;
  final Map<String, Object> meta;
  final CalcException? error;

  Map<String, Object?> toJson() {
    if (!ok) {
      return {
        'ok': false,
        'error': {
          'code': error!.code,
          'message': error!.message,
          if (error!.position != null) 'position': error!.position,
          if (error!.hint != null) 'hint': error!.hint,
        },
      };
    }
    return {
      'ok': true,
      'value': value,
      'display': display,
      'normalized_expr': normalizedExpr,
      'approximate': approximate,
      'precision': precision,
      'warnings': warnings,
      'meta': meta,
    };
  }

  String toJsonText() => jsonEncode(toJson());
}

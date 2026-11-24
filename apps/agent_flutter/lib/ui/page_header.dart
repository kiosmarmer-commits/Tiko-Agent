import 'package:flutter/material.dart';

import 'theme.dart';

/// Header halaman bersama (GUI-P1): judul + subjudul + status runtime.
/// Dipakai halaman admin di main.dart dan halaman fitur baru.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.online,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final bool online;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: BoxDecoration(
        color: context.simpulPanel,
        border: Border(bottom: BorderSide(color: context.simpulBorder)),
      ),
      child: Row(
        children: [
          if (Navigator.of(context).canPop())
            IconButton(
              tooltip: 'Kembali',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SimpulTheme.pageTitle.copyWith(fontSize: 18),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.simpulMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final label = online ? 'Online' : 'Offline';
              final status = Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: (online ? context.simpulSuccess : context.simpulDanger)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(SimpulTheme.radiusPill),
                  border: Border.all(
                    color: online ? context.simpulSuccess : context.simpulDanger,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online
                            ? context.simpulSuccess
                            : context.simpulDanger,
                      ),
                    ),
                    if (constraints.maxWidth >= 70) ...[
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: online
                              ? context.simpulSuccess
                              : context.simpulDanger,
                        ),
                      ),
                    ],
                  ],
                ),
              );
              return Semantics(
                label: 'Status koneksi: $label',
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: status,
                ),
              );
            },
          ),
          if (trailing != null) Flexible(child: trailing!),
        ],
      ),
    );
  }
}

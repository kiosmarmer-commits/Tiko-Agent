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
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? context.simpulAccent : context.simpulDanger,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

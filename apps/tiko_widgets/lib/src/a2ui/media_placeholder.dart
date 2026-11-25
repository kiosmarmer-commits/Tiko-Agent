import 'package:flutter/material.dart';

/// Placeholder non-web: kontrak jujur (tanpa klaim pemutaran).
Widget buildMediaPlaceholder({
  required String kind,
  required String src,
  String? poster,
}) {
  final isVideo = kind == 'video';
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isVideo ? Icons.videocam_outlined : Icons.audiotrack_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isVideo ? 'Video' : 'Audio',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            src,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Pemutaran media tersedia di GUI Flutter Web.',
            style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    ),
  );
}

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';

/// Runtime event feed (GUI-P1-02): live events via polling admin, dapat
/// difilter berdasarkan tipe event. Event terbaru di atas.
class EventsPage extends StatelessWidget {
  const EventsPage({
    super.key,
    required this.events,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
  });

  final List<RuntimeEvent> events;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final newestFirst = events.reversed.toList();
    return Column(
      children: [
        PageHeader(
          title: 'Events',
          subtitle: '${events.length} event runtime',
          online: online,
          trailing:
              onRefresh == null ? null : IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child:
                Text(error!, style: TextStyle(color: context.simpulDanger)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'Feed diperbarui tiap 15 detik; keputusan approval muncul di sini dari semua client.',
            style: TextStyle(color: context.simpulMuted, fontSize: 12),
          ),
        ),
        Expanded(
          child: newestFirst.isEmpty
              ? Center(
                  child: Text('Belum ada event.',
                      style: TextStyle(color: context.simpulMuted)))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: newestFirst.length,
                  itemBuilder: (context, i) {
                    final event = newestFirst[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.bolt_outlined,
                        color: event.type.startsWith('approval.')
                            ? context.simpulWarn
                            : context.simpulAccent,
                      ),
                      title: Text(event.type,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(event.at,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Kolom kanban identik dengan web UI (`KANBAN_STATES` di app.js).
const List<String> kKanbanStates = ['backlog', 'doing', 'done', 'failed'];

/// Task board (GUI-P1-01): read-only, sumber data sama dengan web UI
/// (`GET /v1/tasks`). Kontrol claim/run/pause ditunda sampai endpoint
/// scheduler CRUD tersedia (larangan audit GUI §3.8).
class TaskBoardPage extends StatelessWidget {
  const TaskBoardPage({
    super.key,
    required this.tasks,
    required this.online,
    required this.loading,
    this.error,
    this.onRefresh,
    this.surfaceSection,
  });

  final List<TaskItem> tasks;
  final bool online;
  final bool loading;
  final String? error;
  final Future<void> Function()? onRefresh;

  /// Hermes S8: seksi surface A2UI dinamis yang dirender di atas konten.
  final Widget? surfaceSection;

  List<TaskItem> _ofState(String state) =>
      tasks.where((task) => task.state == state).toList();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: 'Tasks',
          subtitle: '${tasks.length} tugas · read-only',
          online: online,
          trailing: onRefresh == null
              ? null
              : IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
        ),
        if (surfaceSection != null) surfaceSection!,
        if (loading) StatusViews.loadingBanner(context),
        if (error != null) StatusViews.errorBanner(context, error!),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= TikoTheme.wideGridBreakpoint;
              final columns = GridView.count(
                crossAxisCount: wide ? 4 : 2,
                childAspectRatio: 0.9,
                padding: const EdgeInsets.all(12),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final state in kKanbanStates)
                    _KanbanColumn(state: state, tasks: _ofState(state)),
                ],
              );
              return columns;
            },
          ),
        ),
      ],
    );
  }
}

class _KanbanColumn extends StatelessWidget {
  const _KanbanColumn({required this.state, required this.tasks});

  final String state;
  final List<TaskItem> tasks;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.simpulSurfaceRaised,
        borderRadius: BorderRadius.circular(SimpulTheme.radius),
        border: Border.all(color: context.simpulBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$state (${tasks.length})',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: tasks.isEmpty
                ? Text(
                    '(kosong)',
                    style: TextStyle(color: context.simpulMuted, fontSize: 12),
                  )
                : ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, i) {
                      final task = tasks[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: context.simpulPanel,
                          borderRadius: BorderRadius.circular(
                            SimpulTheme.radiusSmall,
                          ),
                          border: Border.all(color: context.simpulBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                task.id,
                                if (task.claimedBy.isNotEmpty)
                                  'by ${task.claimedBy}',
                                if (task.result.isNotEmpty) task.result,
                              ].join(' · '),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.simpulMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

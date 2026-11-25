/// Mission Control (swarm mode) — registri live run orkestra tim di dalam
/// satu proses runtime. Memberi snapshot status per-node untuk UI/REST tanpa
/// membaca file laporan, dan menjadi titik pembatalan kooperatif per run.
///
/// Prinsip:
/// - **Non-blocking:** mutasi state sinkron dan murah; kegagalan pemanggil
///   tidak pernah menggagalkan run yang sedang berjalan.
/// - **Bounded:** maksimum [maxRuns] entri; run non-aktif tertua diusir
///   lebih dulu sehingga daemon jangka panjang tidak bocor memori.
/// - **Jujur:** status dihitung dari event nyata (node_started/node_finished),
///   bukan proklamasi sukses; output hanya dipotong ke [maxNodeOutputTail].
class SwarmControl {
  SwarmControl({this.maxRuns = 100, this.maxNodeOutputTail = 400});

  final int maxRuns;
  final int maxNodeOutputTail;

  final List<TeamRunLive> _runs = [];

  List<TeamRunLive> get activeRuns => [
        for (final r in _runs.reversed)
          if (r.status == 'running' || r.status == 'cancelling') r,
      ];

  TeamRunLive? get(String runId) {
    for (final r in _runs) {
      if (r.runId == runId) return r;
    }
    return null;
  }

  /// Snapshot daftar run (terbaru dulu) dalam bentuk JSON map.
  List<Map<String, dynamic>> snapshot({int limit = 50}) => [
        for (final r in _runs.reversed.take(limit)) r.toJson(),
      ];

  /// Daftarkan run baru (dipanggil sebelum planning) dan usir run lama yang
  /// sudah selesai bila registri penuh.
  TeamRunLive startRun({
    required String runId,
    required String teamId,
    required String goal,
  }) {
    final live = TeamRunLive(runId: runId, teamId: teamId, goal: goal);
    _runs.add(live);
    while (_runs.length > maxRuns) {
      // Hanya run yang sudah selesai/berakhir yang boleh diusir; planning,
      // running, dan cancelling dianggap aktif (status masih berubah).
      final idx = _runs.indexWhere(
        (r) =>
            r.status != 'planning' &&
            r.status != 'running' &&
            r.status != 'cancelling',
      );
      if (idx < 0) break;
      _runs.removeAt(idx);
    }
    return live;
  }

  /// Rencana final masuk: susun ulang node sesuai DAG hasil planner dan
  /// naikkan status ke `running`.
  void setPlanned({required String runId, required List<String> nodeIds}) {
    final run = get(runId);
    if (run == null) return;
    final previous = {for (final n in run.nodes) n.id: n};
    run.nodes
      ..clear()
      ..addAll([
        for (final id in nodeIds)
          previous[id] ?? TeamNodeLive(id: id, status: 'pending'),
      ]);
    run.status = 'running';
  }

  void nodeStarted(String runId, String nodeId, String agentId) {
    final node = _node(runId, nodeId);
    if (node == null) return;
    node
      ..status = 'running'
      ..agentId = agentId
      ..startedAt = DateTime.now().toUtc();
  }

  void nodeFinished(
    String runId,
    String nodeId, {
    required bool ok,
    String? error,
    String? output,
  }) {
    final node = _node(runId, nodeId);
    if (node == null) return;
    node
      ..status = ok ? 'ok' : 'failed'
      ..finishedAt = DateTime.now().toUtc()
      ..error = error == null || error.isEmpty ? null : error
      ..outputTail = (output == null || output.isEmpty)
          ? null
          : (output.length > maxNodeOutputTail
              ? output.substring(output.length - maxNodeOutputTail)
              : output);
  }

  void runFinished(
    String runId, {
    required bool success,
    bool cancelled = false,
  }) {
    final run = get(runId);
    if (run == null) return;
    run
      ..status = cancelled ? 'cancelled' : (success ? 'finished' : 'failed')
      ..finishedAt = DateTime.now().toUtc();
    for (final node in run.nodes) {
      if (node.status == 'running' || node.status == 'pending') {
        node.status = 'cancelled';
      }
    }
  }

  void trackSession(String runId, String sessionId) {
    get(runId)?.sessionIds.add(sessionId);
  }

  /// Tandai run minta dibatalkan dan kembalikan daftar session id turn yang
  /// harus dibatalkan host via registri cancellation (kooperatif). Null
  /// berarti run tidak ditemukan atau sedang tidak aktif.
  List<String>? cancelRun(String runId) {
    final run = get(runId);
    if (run == null) return null;
    if (run.status != 'running' && run.status != 'cancelling') return null;
    run.status = 'cancelling';
    return List<String>.unmodifiable(run.sessionIds);
  }

  TeamNodeLive? _node(String runId, String nodeId) {
    final run = get(runId);
    if (run == null) return null;
    for (final n in run.nodes) {
      if (n.id == nodeId) return n;
    }
    return null;
  }
}

class TeamRunLive {
  TeamRunLive({
    required this.runId,
    required this.teamId,
    required this.goal,
  });

  final String runId;
  final String teamId;
  final String goal;

  final List<TeamNodeLive> nodes = [];

  /// Session id turn anggota yang tercatat selama run (untuk pembatalan).
  final List<String> sessionIds = [];

  String status = 'planning';
  DateTime startedAt = DateTime.now().toUtc();
  DateTime? finishedAt;

  Map<String, dynamic> toJson() => {
        'run_id': runId,
        'team_id': teamId,
        'goal': goal,
        'status': status,
        'started_at': startedAt.toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
        'nodes': [for (final n in nodes) n.toJson()],
        'session_ids': List<String>.unmodifiable(sessionIds),
      };
}

class TeamNodeLive {
  TeamNodeLive({
    required this.id,
    required this.status,
    this.agentId,
  });

  final String id;
  String? agentId;
  String status;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? error;
  String? outputTail;

  Map<String, dynamic> toJson() => {
        'id': id,
        'agent': agentId ?? '',
        'status': status,
        if (startedAt != null) 'started_at': startedAt!.toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
        if (error != null) 'error': error,
        if (outputTail != null) 'output_tail': outputTail,
      };
}

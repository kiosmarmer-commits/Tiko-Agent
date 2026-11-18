/// DTO typed untuk domain GUI (GUI-P0-03). Semua factory toleran terhadap
/// field yang hilang agar daemon versi lama tetap bisa dirender.
class SessionSummary {
  const SessionSummary({
    required this.id,
    this.title = '',
    this.channel = '',
    this.updatedAt = '',
    this.turns = 0,
  });

  final String id;
  final String title;
  final String channel;
  final String updatedAt;
  final int turns;

  factory SessionSummary.fromMap(Map<String, dynamic> map) => SessionSummary(
        id: '${map['id'] ?? ''}',
        title: '${map['title'] ?? ''}',
        channel: '${map['channel'] ?? ''}',
        updatedAt: '${map['updated_at'] ?? ''}',
        turns: map['turns'] is num ? (map['turns'] as num).toInt() : 0,
      );

  String get displayTitle => title.isEmpty ? id : title;
}

class SessionMessage {
  const SessionMessage({
    required this.role,
    required this.content,
    this.at = '',
  });

  final String role;
  final String content;
  final String at;

  factory SessionMessage.fromMap(Map<String, dynamic> map) => SessionMessage(
        role: '${map['role'] ?? 'user'}',
        content: '${map['content'] ?? ''}',
        at: '${map['at'] ?? map['ts'] ?? ''}',
      );
}

class ApprovalSummary {
  const ApprovalSummary({
    required this.id,
    this.tool = '',
    this.risk = '',
    this.args = '',
    this.state = '',
    this.actor = '',
    this.createdAt = '',
  });

  final String id;
  final String tool;
  final String risk;
  final String args;
  final String state;
  final String actor;
  final String createdAt;

  bool get isPending => state == 'pending';

  factory ApprovalSummary.fromMap(Map<String, dynamic> map) => ApprovalSummary(
        id: '${map['id'] ?? ''}',
        tool: '${map['tool'] ?? ''}',
        risk: '${map['risk'] ?? ''}',
        args: '${map['args'] ?? ''}',
        state: '${map['state'] ?? ''}',
        actor: '${map['actor'] ?? ''}',
        createdAt: '${map['created_at'] ?? ''}',
      );
}

class MemoryFact {
  const MemoryFact({
    required this.id,
    this.text = '',
    this.kind = '',
  });

  final String id;
  final String text;
  final String kind;

  factory MemoryFact.fromMap(Map<String, dynamic> map) => MemoryFact(
        id: '${map['id'] ?? ''}',
        text: '${map['text'] ?? ''}',
        kind: '${map['kind'] ?? ''}',
      );
}

class RuntimeEvent {
  const RuntimeEvent({
    required this.type,
    this.at = '',
  });

  final String type;
  final String at;

  factory RuntimeEvent.fromMap(Map<String, dynamic> map) => RuntimeEvent(
        type: '${map['type'] ?? ''}',
        at: '${map['at'] ?? ''}',
      );
}

/// Task kanban (GUI-P1-01): read-only, sumber data identik dengan web UI.
class TaskItem {
  const TaskItem({
    required this.id,
    this.title = '',
    this.state = 'backlog',
    this.claimedBy = '',
    this.result = '',
  });

  final String id;
  final String title;
  final String state;
  final String claimedBy;
  final String result;

  factory TaskItem.fromMap(Map<String, dynamic> map) => TaskItem(
        id: '${map['id'] ?? ''}',
        title: '${map['title'] ?? ''}',
        state: '${map['state'] ?? 'backlog'}',
        claimedBy: '${map['claimed_by'] ?? ''}',
        result: '${map['result'] ?? ''}',
      );
}

/// Satu file log daemon (GUI-P1-02).
class LogFileInfo {
  const LogFileInfo({
    required this.name,
    this.bytes = 0,
  });

  final String name;
  final int bytes;

  factory LogFileInfo.fromMap(Map<String, dynamic> map) => LogFileInfo(
        name: '${map['name'] ?? ''}',
        bytes: map['bytes'] is num ? (map['bytes'] as num).toInt() : 0,
      );
}

/// Isi satu file log (GUI-P1-02).
class LogFileContent {
  const LogFileContent({
    required this.name,
    this.bytes = 0,
    this.truncated = false,
    this.content = '',
  });

  final String name;
  final int bytes;
  final bool truncated;
  final String content;

  factory LogFileContent.fromMap(Map<String, dynamic> map) => LogFileContent(
        name: '${map['name'] ?? ''}',
        bytes: map['bytes'] is num ? (map['bytes'] as num).toInt() : 0,
        truncated: map['truncated'] == true,
        content: '${map['content'] ?? ''}',
      );
}

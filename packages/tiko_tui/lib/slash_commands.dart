/// Registry perintah slash untuk autocomplete TUI (Hermes `command_palette` /
/// slash-command registry): setiap perintah punya nama, deskripsi, dan
/// pola pakai; Tab di belakang `/` mengusulkan kandidat via fuzzy match
/// subsequence — huruf urut, tidak harus kontigu (`/hk` cocok `/help`).
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.description,
    this.usage = '',
  });

  /// Nama tanpa slash, mis. `help`.
  final String name;
  final String description;
  final String usage;

  String get display => usage.isEmpty ? '/$name' : '/$name $usage';
}

class SlashCommandRegistry {
  final List<SlashCommand> _commands = [];

  /// Perintah bawaan standar Tiko CLI.
  static const List<SlashCommand> builtin = [
    SlashCommand(name: 'help', description: 'Tampilkan bantuan perintah'),
    SlashCommand(name: 'clear', description: 'Bersihkan layar'),
    SlashCommand(name: 'exit', description: 'Keluar dari sesi'),
    SlashCommand(name: 'history', description: 'Riwayat percakapan'),
    SlashCommand(name: 'memory', description: 'Kelola memori jangka panjang'),
    SlashCommand(name: 'model', description: 'Ganti model/tier provider'),
    SlashCommand(name: 'plan', description: 'Mode rencana (plan/execute)'),
    SlashCommand(name: 'session', description: 'Info/switch sesi'),
    SlashCommand(name: 'skills', description: 'Daftar skill terpasang'),
    SlashCommand(name: 'usage', description: 'Pemakaian token & budget'),
  ];

  SlashCommandRegistry({List<SlashCommand>? commands}) {
    _commands.addAll(commands ?? builtin);
  }

  List<SlashCommand> get commands => List.unmodifiable(_commands);

  void register(SlashCommand command) {
    _commands.removeWhere((c) => c.name == command.name);
    _commands.add(command);
    _commands.sort((a, b) => a.name.compareTo(b.name));
  }

  SlashCommand? find(String name) {
    final lower = name.toLowerCase();
    for (final c in _commands) {
      if (c.name.toLowerCase() == lower) return c;
    }
    return null;
  }

  /// Kandidat untuk [TuiCompleter] `(prefix, token)`: aktif hanya bila
  /// prefix diawali `/` dan token adalah token terakhir. Return nama
  /// perintah lengkap ber-slash.
  List<String> completions(String prefix, String token) {
    if (!token.startsWith('/') && !prefix.trimLeft().startsWith('/')) {
      return const [];
    }
    final query = token.startsWith('/') ? token.substring(1) : token;
    if (query.isEmpty) {
      return [for (final c in _commands) '/${c.name}'];
    }
    final scored = <(int, String)>[];
    for (final c in _commands) {
      final score = fuzzyMatch(query, c.name);
      if (score != null) scored.add((score, '/${c.name}'));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final s in scored) s.$2];
  }

  /// Skor fuzzy subsequence: null = tidak cocok. Semakin kecil semakin
  /// mirip (awalan persis < batas kata < subsequence jarang).
  static int? fuzzyMatch(String query, String target) {
    if (query.isEmpty) return 0;
    final q = query.toLowerCase();
    final t = target.toLowerCase();
    if (t.startsWith(q)) return 0;
    final wordBoundary = t.indexOf(q);
    if (wordBoundary > 0 && t[wordBoundary - 1] == '_') return 1;
    var qi = 0;
    var score = 2;
    var lastMatch = -2;
    for (var ti = 0; ti < t.length && qi < q.length; ti++) {
      if (t[ti] == q[qi]) {
        score += ti == lastMatch + 1 ? 0 : 1;
        lastMatch = ti;
        qi++;
      }
    }
    if (qi < q.length) return null;
    return score;
  }
}

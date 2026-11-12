/// Schema versioning equivalent to Drift migrations (AGD-04).
/// Run on any sqlite3 Database.
class DriftStyleMigrations {
  static const currentVersion = 6;

  static void migrate(dynamic db) {
    // db is sqlite3 Database
    final row = db.select('PRAGMA user_version');
    final v = (row.first['user_version'] as int?) ?? 0;
    if (v < 1) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS messages (
          id TEXT NOT NULL PRIMARY KEY,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          tool_name TEXT,
          created_at TEXT NOT NULL
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS facts (
          id TEXT NOT NULL PRIMARY KEY,
          text TEXT NOT NULL,
          kind TEXT NOT NULL DEFAULT 'fact',
          importance REAL NOT NULL DEFAULT 0.5,
          source_session TEXT,
          created_at TEXT NOT NULL,
          provenance TEXT NOT NULL DEFAULT 'unknown',
          confidence REAL NOT NULL DEFAULT 0.7,
          ttl_days INTEGER,
          state TEXT NOT NULL DEFAULT 'active'
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT NOT NULL PRIMARY KEY,
          channel TEXT,
          user_key TEXT,
          summary TEXT,
          updated_at TEXT
        );
      ''');
      db.execute('PRAGMA user_version = 1');
    }
    if (v < 2) {
      try {
        db.execute(
          "CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(text, content='facts', content_rowid='rowid');",
        );
      } catch (_) {}
      db.execute('PRAGMA user_version = 2');
    }
    if (v < 3) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS embeddings (
          id TEXT NOT NULL PRIMARY KEY,
          dim INTEGER NOT NULL,
          vector BLOB NOT NULL,
          meta_json TEXT
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS kv (
          key TEXT NOT NULL PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      db.execute('PRAGMA user_version = 3');
    }
    if (v < 4) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS memories (
          id TEXT NOT NULL PRIMARY KEY,
          kind TEXT NOT NULL DEFAULT 'fact',
          text TEXT NOT NULL,
          source_session TEXT,
          importance REAL NOT NULL DEFAULT 0.5,
          created_at TEXT NOT NULL,
          last_used_at TEXT,
          expires_at TEXT,
          embedding BLOB,
          status TEXT NOT NULL DEFAULT 'active'
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS skills (
          slug TEXT NOT NULL PRIMARY KEY,
          version INTEGER NOT NULL,
          status TEXT NOT NULL,
          uses INTEGER NOT NULL DEFAULT 0,
          successes INTEGER NOT NULL DEFAULT 0,
          last_used_at TEXT,
          path TEXT,
          sha256 TEXT
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS jobs (
          id TEXT NOT NULL PRIMARY KEY,
          cron TEXT NOT NULL,
          prompt TEXT NOT NULL,
          channel TEXT NOT NULL,
          user_key TEXT NOT NULL,
          next_run INTEGER NOT NULL,
          last_run INTEGER,
          enabled INTEGER NOT NULL DEFAULT 1,
          missed_policy TEXT NOT NULL DEFAULT 'run_once'
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS tool_audit (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts INTEGER NOT NULL,
          session_id TEXT,
          tool TEXT NOT NULL,
          args_json TEXT,
          verdict TEXT,
          result_summary TEXT,
          duration_ms INTEGER,
          error TEXT
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS feedback (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT,
          message_id TEXT,
          rating INTEGER,
          note TEXT
        );
      ''');
      try {
        db.execute(
          "CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(text, content='memories', content_rowid='rowid');",
        );
      } catch (_) {}
      db.execute('PRAGMA user_version = 4');
    }
    if (v < 5) {
      _ensureColumn(db, 'facts', 'provenance', "TEXT NOT NULL DEFAULT 'unknown'");
      _ensureColumn(db, 'facts', 'confidence', 'REAL NOT NULL DEFAULT 0.7');
      _ensureColumn(db, 'facts', 'ttl_days', 'INTEGER');
      _ensureColumn(db, 'facts', 'state', "TEXT NOT NULL DEFAULT 'active'");
      db.execute('PRAGMA user_version = 5');
    }
    if (v < 6) {
      // Legacy facts remain owner_key=NULL and are intentionally excluded from
      // owner-scoped retrieval until a user explicitly re-saves them.
      _ensureColumn(db, 'facts', 'owner_key', 'TEXT');
      db.execute('CREATE INDEX IF NOT EXISTS facts_owner_created_idx ON facts(owner_key, created_at)');
      db.execute('PRAGMA user_version = 6');
    }
  }

  static void _ensureColumn(
    dynamic db,
    String table,
    String column,
    String declaration,
  ) {
    final columns = db.select('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (!exists) {
      db.execute('ALTER TABLE $table ADD COLUMN $column $declaration');
    }
  }
}

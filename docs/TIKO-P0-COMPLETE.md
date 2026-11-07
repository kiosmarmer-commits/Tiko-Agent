# Tiko P0 — status implementasi menyeluruh

## Satu pintu

```bash
cd agent_dart   # atau tiko_full root
dart pub get
dart run apps/tiko/bin/tiko.dart setup --provider mock
dart run apps/tiko/bin/tiko.dart calc 5+1          # -> 6
dart run apps/tiko/bin/tiko.dart doctor
dart run apps/tiko/bin/tiko.dart chat "halo"
dart run apps/tiko/bin/tiko.dart config set api.port 8787
dart run apps/tiko/bin/tiko.dart config history
dart run apps/tiko/bin/tiko.dart daemon start
dart run apps/tiko/bin/tiko.dart ui
```

## Modul baru/dilengkapi

| Modul | Path |
|-------|------|
| ConfigStore revision | `packages/tiko_runtime/lib/src/config_store.dart` |
| DaemonManager | `packages/tiko_runtime/lib/src/daemon_manager.dart` |
| CapabilityToken | `packages/tiko_runtime/lib/src/capability.dart` |
| EventBus | `packages/tiko_runtime/lib/src/event_bus.dart` |
| PathSafety | `packages/agent_tools/lib/src/path_safety.dart` |
| CLI tiko penuh | `apps/tiko/bin/tiko.dart` |
| API sessions/doctor | `HttpApiServer` |

## PRD P0 checklist

- [x] TikoRuntime composition root (chat, memory, sessions, doctor, tools)
- [x] Executable `tiko` + parser
- [x] Persistent session store + API list
- [x] Provider factory + typed config
- [x] Direct calc/datetime
- [x] Lifecycle lock + daemon start/stop/restart
- [x] doctor CLI (+ API hooks)
- [x] config set/diff/history/rollback
- [x] setup
- [x] fail-closed permission + sanitizer (dari P0 patch)
- [ ] Event bus fully wired to Flutter WS (bus ada; UI bind menyusul)
- [ ] Capability token enforced di setiap tool exec (mint API ada; gate penuh P2)
- [ ] Admin Flutter screens (masih chat-centric)

## Verifikasi wajib di mesin Anda

```bash
dart pub get
dart analyze
dart test
dart run apps/tiko/bin/tiko.dart calc 5+1
```

## Lanjutan (capability, path, eco, skills scan)

- CapabilityAwareGate + mint setelah konfirmasi + re-check di AgentLoop
- safeResolve dengan realpath/symlink jail
- Eco profile otomatis jika MemAvailable < 1GB
- `tiko skills list|scan`
- `/v1/events` + EventBus buffer
- SkillScanner static

```bash
dart run apps/tiko/bin/tiko.dart skills list
dart run apps/tiko/bin/tiko.dart doctor
```

## Tahap 1–2 selesai

### 1. agentd = TikoRuntime host
- Satu composition root: `TikoRuntime.create`
- Lock instance, scheduler channel-aware, API sessions/doctor/events/approvals
- Fail-closed confirm tanpa TTY

### 2. Approval ledger
- `data/approvals.json`
- `tiko approvals` / `tiko approve <id>` / `tiko deny <id>`
- `GET/POST /v1/approvals`
- Confirm di chat membuat pending + mint capability setelah approve

```bash
tiko daemon start
tiko approvals
tiko approve apr_xxxxxxxx
```


## Tahap 3 — Router fallback + explain

- `RouteDecision` + `reason` / `fallbackIds` / `score`
- Circuit breaker (3 gagal → open 60s)
- AgentLoop: error → `nextFallback` + catat health
- `tiko route explain --task "..."`
- `tiko status` menyertakan `provider_health`
- Web UI tabs Approvals + Sessions (refresh)

```bash
tiko route explain --task "hitung 5+1"
tiko status
```


## Tahap 4 — Flutter admin

Layar:
- Chat (sessionKey dari Sessions)
- Dashboard (status, doctor, events, pending approvals)
- Approvals (approve/deny)
- Sessions (pilih sesi → chat)
- Memory (list/delete)
- Settings (API URL + token)

```bash
tiko daemon start
cd apps/agent_flutter
flutter run -d chrome --dart-define=API_TOKEN=... --dart-define=API_BASE=http://127.0.0.1:8787
```

## Tahap 5 — Skill golden gate

- `SkillPromotionGate`: scan → golden → trial/canary → approve eksplisit
- Auto-approve dari usage **dinonaktifkan**
- CLI: `skills evaluate|approve|rollback`
- `test/golden/skills_smoke.yaml`

## Tahap 6 — Provenance + memory sanitization

- `Provenance` enum pada `Fact`
- `SafeMemoryStore`: redact secrets, strip injection, turunkan importance untrusted, state `pending`

## Tahap 7 — Termux / offline / native doctor

- `ResourceMonitor`: RAM, disk, Termux, sqlite native, network
- `OfflineQueue`: enqueue / drain
- `tiko doctor` menampilkan semua cek di atas
- `tiko offline status|enqueue|drain`
- Eco otomatis bila RAM < 768MB

```bash
tiko skills evaluate ringkas-waktu
tiko offline enqueue "ingat beli kopi"
tiko doctor
```

## Validasi & regresi (lanjutan)

Implementasi tambahan:
- ShellPolicy argv + metachar deny
- Context memory provenance badge
- TikoRemoteClient + mode auto/daemon remote chat (butuh API_TOKEN)
- CI GitHub Actions
- scripts/validate.sh

```bash
./scripts/validate.sh
API_TOKEN=... tiko daemon start
API_TOKEN=... tiko --mode daemon chat "halo"
```

# C8 — MCP OAuth Authorization Code (Kompatibilitas OAuth Luas)

Tanggal: 2026-11-16 · Status: Implemented (opt-in) · PR: vibe/mcp-oauth-authcode-563120

## Ringkasan

Sebelumnya MCP HTTP hanya mendukung grant `client_credentials` (machine-to-machine).
Banyak server MCP hosted pihak ketiga (GitHub, Notion, Google Drive, Slack, dsb.)
mewajibkan **login pengguna lewat browser** — sesuatu yang tidak bisa dilakukan
grant client-credentials. C8 menambahkan sumber token kedua:

- `McpOAuthTokenSource` (interface baru): kontrak `token()` + `invalidate()`
  yang dipakai `HttpMcpClient`/`EnhancedHttpMcpClient`.
- `McpOAuthClientCredentials`: implementasi lama (client_credentials), kini
  `implements McpOAuthTokenSource` — **100% backward compatible**.
- `McpOAuthAuthorizationCode` (baru): grant `authorization_code` + PKCE.

## Fitur kompatibilitas

| Kemampuan | Referensi | Catatan |
|---|---|---|
| Metadata discovery protected-resource | RFC 9728 | `{server}/.well-known/oauth-protected-resource` (path-aware + fallback root) → `authorization_servers[0]` |
| Metadata authorization server | RFC 8414 | `/.well-known/oauth-authorization-server` (path-aware + fallback root) |
| Dynamic Client Registration | RFC 7591 | Bila `client_id` tidak disediakan; `token_endpoint_auth_method: none` (public client) |
| PKCE S256 | RFC 7636 | Default aktif; fallback `plain` bila server hanya mengumumkan `plain`; bisa dimatikan (`use_pkce: false`) untuk penyedia lama |
| Resource Indicator | RFC 8707 | `resource=<server_url>` dikirim di authorize + token request |
| Client auth variatif | — | `auth_method: auto\|basic\|post\|none` — `auto` = Basic bila ada secret, selain itu none |
| Refresh token | — | Otomatis saat token kedaluwarsa atau setelah 401 (`invalidate()` hanya membuang access token, refresh token dipertahankan) |
| Redirect loopback | RFC 8252 | `http://127.0.0.1:<port>/callback`; port ephemeral (0) atau tetap; halaman konfirmasi HTML |
| Persistensi token | — | JSON mode 0600 (chmod, pola sama dengan SecretStore), atomik (tmp + rename); token endpoint hasil discovery ikut disimpan agar refresh bekerja lintas proses |

## Konfigurasi YAML

```yaml
mcp:
  servers:
    notion:
      type: http
      url: https://mcp.notion.com/mcp
      oauth:
        grant_type: authorization_code   # default: client_credentials
        # server_url: opsional; default = url server MCP (dipakai discovery + resource)
        # client_id / client_secret: opsional untuk public client (DCR otomatis);
        #   secret tetap lewat SecretRef (env:VAR) — tidak pernah hard-coded
        scopes: [read, write]
        redirect_port: 0                 # 0 = ephemeral
        auth_method: auto                # auto|basic|post|none
        use_discovery: true              # RFC 9728 + RFC 8414
        use_pkce: true                   # RFC 7636
        token_store: /path/tokens.json   # JSON 0600, atomik; null = memori saja
```

Grant `client_credentials` tidak berubah (token_url + client_id + client_secret wajib).

## Alur interaktif

1. Resolusi endpoint: URL manual menang; sisanya dari discovery.
2. Client ID: konfigurasi → registrasi tersimpan → DCR.
3. Server loopback 127.0.0.1 di-bind; URL otorisasi dibangkitkan
   (state acak 128-bit, challenge S256, `resource`).
4. Host menerima URL lewat callback (atau browser dibuka best-effort via
   `xdg-open`/`open`; kegagalan tidak fatal).
5. Redirect divalidasi **fail-closed**: `error` → `McpOAuthFlowException`
   berkoden; `state` tidak cocok → `state_mismatch`.
6. Code ditukar (client auth sesuai `auth_method`, verifier PKCE disertakan).
7. Token dipersist; pemakaian berikutnya tanpa interaksi (cache → persist →
   refresh_token → interaktif hanya bila refresh ditolak).

## Batasan (jujur)

- Token store berupa JSON 0600 di filesystem — bukan keychain OS. Host dengan
  penyimpanan lebih aman bisa menyuntik `persistOverride`/`loadOverride`.
- `completeCallback(Uri)` disediakan untuk test dan host ber-WebView sendiri;
  state tetap divalidasi.
- Discovery/DCR diuji terhadap fake server sesuai spesifikasi; interop live
  dengan vendor nyata (GitHub/Notion/Google) belum dieksekusi — klaim
  kompatibilitas didasarkan pada kepatuhan spesifikasi RFC, bukan uji live.
- Browser dibuka best-effort; di host headless tanpa browser, alur menunggu
  redirect sampai `authorize_timeout` (default 5 menit).

## Pengujian

`packages/agent_tools/test/mcp_oauth_authcode_test.dart` — 20 test:

- Vektor resmi PKCE RFC 7636 Appendix A (S256).
- Alur penuh: parameter URL otorisasi, `code_verifier` ↔ challenge cocok,
  Basic auth, Bearer token terpakai.
- State mismatch fail-closed; `error=access_denied` diteruskan berkoden.
- Refresh saat kedaluwarsa (fake clock) dan setelah `invalidate()`.
- `auth_method` basic/post/none/auto; tanpa PKCE (penyedia lama).
- Discovery chain (RFC 9728 → RFC 8414) tanpa URL manual.
- DCR: `client_name`, `redirect_uris`, `client_id` hasil registrasi dipakai.
- Persistensi: antar-instance (override) dan file (mode 0600, atomic rename).
- Redirect loopback nyata (GET HTTP ke server redirect, halaman konfirmasi).
- Integrasi `HttpMcpClient`: header `Authorization: Bearer` terkirim.

Regresi: seluruh `agent_tools` 300 test lulus; `dart analyze --fatal-warnings`
bersih untuk agent_tools, tiko_runtime, agent_core.

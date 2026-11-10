# Fallback Tavily untuk web_search — 2026-11-09

## Ringkasan
`web_search` kini punya mesin cadangan Tavily sesuai AGD-04 §7 ("Cadangan
berbayar/terkelola"). Sebelumnya tool hanya mengandalkan SearXNG self-host dan
gagal keras ketika instance tidak tersedia.

## Perilaku
- Mesin utama tetap SearXNG. Tavily hanya dicoba bila:
  1. API key terpasang (SecretRef `search.tavily_api_key: env:TAVILY_API_KEY`), dan
  2. SearXNG gagal pada level transport: exception jaringan/timeout atau HTTP >= 500.
- Tidak fallback untuk HTTP 403 (format=json dimatikan; masalah konfigurasi),
  4xx lain, atau hasil kosong (bukan kegagalan).
- Kedua mesin gagal → satu error gabungan menyebut keduanya.
- Output fallback diberi penanda `## Mesin: Tavily (cadangan; SearXNG tidak tersedia)`.

## Implementasi
- `packages/agent_tools/lib/src/web_search.dart`: parameter baru `tavilyApiKey` dan
  `tavilyBaseUrl` (default `https://api.tavily.com`); request `POST /search` dengan
  header `Authorization: Bearer` dan body `{query, search_depth: basic, max_results,
  topic, include_answer: false}` sesuai dokumentasi API Tavily terkini; hasil dipetakan
  ke format output yang sudah ada (satu jalur sitasi/fetch/cache).
- SSRF guard diterapkan juga pada base URL Tavily.
- Tanpa dependensi baru (AGD-08): murni `package:http`. Paket `tavily_dart` tidak
  dipakai karena API-nya sederhana dan tak perlu menambah dependensi monorepo.
- Wiring: `createBuiltinTools(tavilyApiKey: ...)`; `TikoConfig` membaca
  `search.tavily_api_key` sebagai SecretRef `env:` (secret mentah di YAML ditolak,
  pola sama dengan `decision.api_key`); `TikoRuntime.create` me-resolve lewat
  `TikoConfig.resolveSecretRef` dengan environment runtime.

## Contoh konfigurasi
~~~yaml
search:
  searxng_base_url: "http://127.0.0.1:8080"
  tavily_api_key: "env:TAVILY_API_KEY"
~~~

## Tes (packages/agent_tools/test/web_search_tavily_test.dart)
| Skenario | Ekspektasi |
|---|---|
| SearXNG mati + key | fallback Tavily; header Bearer dan body query benar |
| SearXNG HTTP 503 + key | fallback Tavily |
| SearXNG HTTP 403 + key | error konfigurasi; Tavily tidak dipanggil |
| SearXNG mati tanpa key | error SearXNG seperti sebelumnya |
| SearXNG mati + Tavily 401 | error gabungan kedua mesin |
| SearXNG sehat | Tavily tidak dipanggil |
| Tavily hasil kosong | "Tidak ada hasil." |

## Yang tidak berubah
- SearXNG sehat → output identik dengan versi sebelumnya.
- Cache sitasi (TTL 1 jam), SSRF guard halaman, format `<untrusted_data>` tetap.
- `tiko setup` belum menuliskan `tavily_api_key` (opsional; tambahkan manual).
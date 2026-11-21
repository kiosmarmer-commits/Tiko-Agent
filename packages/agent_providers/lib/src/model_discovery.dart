/// Hermes-parity model discovery: provider yang mampu mengambil daftar
/// model live dari endpoint-nya (mis. `GET /v1/models` OpenAI-compat,
/// `GET /api/tags` Ollama). Dipakai runtime + GUI untuk pengisi otomatis
/// pemilih model — hanya untuk provider yang terkonfigurasi.
abstract interface class ModelDiscovery {
  /// Daftar model tersedia; daftar kosong bila endpoint gagal (fail-open).
  Future<List<String>> discoverModels();
}

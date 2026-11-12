import 'openai_compat.dart';

/// Azure OpenAI / Azure AI Foundry adapter (Hermes-parity `azure-foundry`).
///
/// Azure authenticates with the `api-key` header (not `Authorization`) and
/// routes per deployment: `{base_url}/openai/deployments/{deployment}/
/// chat/completions?api-version={api_version}`. Here `model` is the
/// deployment name.
class AzureOpenAIProvider extends OpenAiCompatProvider {
  AzureOpenAIProvider({
    required super.id,
    required super.baseUrl,
    required super.model,
    super.apiKey,
    super.httpClient,
    super.promptCache,
    super.credentialPool,
    super.tokenProvider,
    super.requestTimeout,
    super.modelTimeouts,
    super.capabilities,
    this.apiVersion = '2024-10-21',
  });

  final String apiVersion;

  @override
  Uri get chatUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse(
      '$base/openai/deployments/$model/chat/completions',
    ).replace(queryParameters: {'api-version': apiVersion});
  }

  @override
  Future<Map<String, String>> headersFor(String? key) async => {
        'Content-Type': 'application/json',
        if (key != null && key.isNotEmpty) 'api-key': key,
      };
}

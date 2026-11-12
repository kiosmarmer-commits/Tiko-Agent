import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

void main() {
  test('operationForTool memetakan operasi sempit per tool', () {
    expect(CapabilityToken.operationForTool('shell'), 'exec');
    expect(CapabilityToken.operationForTool('write_file'), 'write');
    expect(CapabilityToken.operationForTool('patch_file'), 'patch');
    expect(CapabilityToken.operationForTool('http_request'), 'fetch');
    expect(CapabilityToken.operationForTool('mcp_lain'), 'execute');
  });

  test('boundRoots mengikat file absolut persis untuk tool file', () {
    expect(
      CapabilityToken.boundRoots(
        'write_file',
        const {'path': 'docs/a.md', 'content': 'x'},
        workspaceRoot: '/ws',
      ),
      ['/ws/docs/a.md'],
    );
    expect(
      CapabilityToken.boundRoots(
        'patch_file',
        const {'path': 'b.txt', 'old': 'a', 'new': 'b'},
        workspaceRoot: '/ws',
      ),
      ['/ws/b.txt'],
    );
    // Path absolut dipertahankan apa adanya; jail tetap tugas tool.
    expect(
      CapabilityToken.boundRoots(
        'write_file',
        const {'path': '/tmp/luar.txt', 'content': 'x'},
        workspaceRoot: '/ws',
      ),
      ['/tmp/luar.txt'],
    );
  });

  test('boundRoots jatuh ke workspace untuk tool tanpa path', () {
    expect(
      CapabilityToken.boundRoots(
        'shell',
        const {'cmd': 'ls'},
        workspaceRoot: '/ws',
      ),
      ['/ws'],
    );
    // path hilang/kosong pada tool file -> fail-closed ke workspace.
    expect(
      CapabilityToken.boundRoots(
        'write_file',
        const {'content': 'x'},
        workspaceRoot: '/ws',
      ),
      ['/ws'],
    );
  });

  test('boundDomains mengekstrak host persis dari URL', () {
    expect(
      CapabilityToken.boundDomains(
        'http_request',
        const {'url': 'https://Api.Example.COM/x'},
      ),
      ['api.example.com'],
    );
    expect(
      CapabilityToken.boundDomains('http_request', const {'url': 'bukan-url'}),
      isEmpty,
    );
    expect(
      CapabilityToken.boundDomains('write_file', const {'path': 'a.txt'}),
      isEmpty,
    );
  });

  test('mint sempit membawa binding operasi + sumber daya persis', () {
    final args = const {'path': 'a.txt', 'content': 'x'};
    final tok = CapabilityToken.mint(
      sessionId: 's',
      tool: 'write_file',
      operations: [CapabilityToken.operationForTool('write_file')],
      roots: CapabilityToken.boundRoots(
        'write_file',
        args,
        workspaceRoot: '/ws',
      ),
      domains: CapabilityToken.boundDomains('write_file', args),
      arguments: args,
    );
    expect(tok.operations, ['write']);
    expect(tok.roots, ['/ws/a.txt']);
    expect(tok.domains, isEmpty);
    expect(tok.toJson()['roots'], ['/ws/a.txt']);
    expect(tok.toJson()['operations'], ['write']);
  });

  test('token http terikat host persis yang disetujui', () {
    final args = const {'url': 'https://api.example.com/v1', 'method': 'GET'};
    final tok = CapabilityToken.mint(
      sessionId: 's',
      tool: 'http_request',
      operations: [CapabilityToken.operationForTool('http_request')],
      roots: CapabilityToken.boundRoots(
        'http_request',
        args,
        workspaceRoot: '/ws',
      ),
      domains: CapabilityToken.boundDomains('http_request', args),
      arguments: args,
    );
    expect(tok.operations, ['fetch']);
    expect(tok.domains, ['api.example.com']);
    // Token http tidak boleh bisa dipakai untuk menulis file: operasinya
    // 'fetch', bukan 'write'/'patch'.
    expect(tok.operations.contains('write'), isFalse);
  });
}

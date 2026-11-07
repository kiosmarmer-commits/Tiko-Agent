#!/usr/bin/env python3
"""Small MCP stdio fixture: standard JSONL, legacy and modern protocol eras."""
import json
import sys

MODERN = '--modern' in sys.argv[1:]


def read_message():
    line = sys.stdin.buffer.readline()
    if not line:
        return None
    if len(line) > 1024 * 1024:
        raise ValueError('message too large')
    return json.loads(line.decode('utf-8'))


def write_message(msg):
    body = json.dumps(msg, separators=(',', ':')).encode('utf-8')
    if len(body) > 1024 * 1024:
        raise ValueError('message too large')
    sys.stdout.buffer.write(body + b'\n')
    sys.stdout.buffer.flush()


def error(id_, code, message, data=None):
    result = {'jsonrpc': '2.0', 'id': id_, 'error': {'code': code, 'message': message}}
    if data is not None:
        result['error']['data'] = data
    write_message(result)


def main():
    while True:
        msg = read_message()
        if msg is None:
            break
        method = msg.get('method')
        id_ = msg.get('id')
        params = msg.get('params') or {}
        if method == 'server/discover':
            if not MODERN:
                error(id_, -32601, 'Method not found')
                continue
            meta = params.get('_meta') or {}
            if meta.get('io.modelcontextprotocol/protocolVersion') != '2026-07-28':
                error(id_, -32022, 'Unsupported protocol version', {
                    'supported': ['2026-07-28'], 'requested': meta.get('io.modelcontextprotocol/protocolVersion')
                })
                continue
            write_message({
                'jsonrpc': '2.0', 'id': id_,
                'result': {
                    'resultType': 'complete',
                    'supportedVersions': ['2026-07-28'],
                    'capabilities': {'tools': {}},
                    '_meta': {'io.modelcontextprotocol/serverInfo': {'name': 'modern-mock', 'version': '1.0'}},
                },
            })
        elif method == 'initialize':
            if MODERN:
                error(id_, -32601, 'Method not found')
                continue
            write_message({
                'jsonrpc': '2.0', 'id': id_,
                'result': {
                    'protocolVersion': '2025-11-25',
                    'capabilities': {'tools': {}},
                    'serverInfo': {'name': 'legacy-mock', 'version': '0.1'},
                },
            })
        elif method == 'notifications/initialized':
            pass
        elif method == 'tools/list':
            if MODERN and (params.get('_meta') or {}).get('io.modelcontextprotocol/protocolVersion') != '2026-07-28':
                error(id_, -32022, 'Unsupported protocol version', {'supported': ['2026-07-28']})
                continue
            write_message({
                'jsonrpc': '2.0', 'id': id_,
                'result': {'tools': [
                    {'name': 'ping', 'description': 'Return pong', 'inputSchema': {'type': 'object', 'properties': {}}},
                    {'name': 'echo', 'description': 'Echo text', 'inputSchema': {
                        'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']
                    }},
                ]},
            })
        elif method == 'tools/call':
            if MODERN and (params.get('_meta') or {}).get('io.modelcontextprotocol/protocolVersion') != '2026-07-28':
                error(id_, -32022, 'Unsupported protocol version', {'supported': ['2026-07-28']})
                continue
            name = params.get('name')
            arguments = params.get('arguments') or {}
            if name == 'ping':
                text = 'pong'
            elif name == 'echo':
                text = arguments.get('text', '')
            else:
                write_message({'jsonrpc': '2.0', 'id': id_, 'result': {
                    'content': [{'type': 'text', 'text': f'unknown tool {name}'}], 'isError': True,
                }})
                continue
            write_message({'jsonrpc': '2.0', 'id': id_, 'result': {
                'content': [{'type': 'text', 'text': text}], 'isError': False,
            }})
        elif id_ is not None:
            error(id_, -32601, f'Method not found: {method}')


if __name__ == '__main__':
    main()

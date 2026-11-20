import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// GitHub MCP server tool for accessing GitHub repositories.
///
/// GitHub MCP provides access to GitHub's API for managing
/// repositories, issues, pull requests, and other GitHub resources.
///
/// Configuration:
/// - token: GitHub personal access token (required)
/// - baseUrl: GitHub API base URL (default: https://api.github.com)
/// - timeout: Request timeout (default: 30 seconds)
class GitHubMcpTool implements Tool {
  GitHubMcpTool({
    required this.token,
    this.baseUrl = 'https://api.github.com',
    this.timeout = const Duration(seconds: 30),
  });

  final String token;
  final String baseUrl;
  final Duration timeout;

  @override
  String get name => 'github_mcp';

  @override
  String get description =>
      'GitHub MCP server for accessing GitHub repositories and resources.';

  @override
  ToolSpec get spec => ToolSpec(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'list_repos',
                'get_repo',
                'list_issues',
                'get_issue',
                'create_issue',
                'update_issue',
                'list_prs',
                'get_pr',
                'list_contents',
                'get_content',
                'search',
              ],
              'description': 'The GitHub action to perform',
            },
            'owner': {
              'type': 'string',
              'description': 'Repository owner (username or organization)',
            },
            'repo': {
              'type': 'string',
              'description': 'Repository name',
            },
            'issue_number': {
              'type': 'number',
              'description': 'Issue or PR number',
            },
            'pr_number': {
              'type': 'number',
              'description': 'Pull request number',
            },
            'path': {
              'type': 'string',
              'description': 'File path in repository',
            },
            'title': {
              'type': 'string',
              'description': 'Title for create_issue action',
            },
            'body': {
              'type': 'string',
              'description': 'Body/content for create_issue or update_issue',
            },
            'labels': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Labels for create_issue',
            },
            'assignees': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Assignees for create_issue',
            },
            'query': {
              'type': 'string',
              'description': 'Search query for search action',
            },
            'limit': {
              'type': 'number',
              'description': 'Maximum number of results to return',
              'default': 10,
            },
            'page': {
              'type': 'number',
              'description': 'Page number for pagination',
              'default': 1,
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(ToolCall call) async {
    try {
      final action = call.args['action'] as String?;
      
      switch (action) {
        case 'list_repos':
          return await _listRepos(call);
        case 'get_repo':
          return await _getRepo(call);
        case 'list_issues':
          return await _listIssues(call);
        case 'get_issue':
          return await _getIssue(call);
        case 'create_issue':
          return await _createIssue(call);
        case 'update_issue':
          return await _updateIssue(call);
        case 'list_prs':
          return await _listPullRequests(call);
        case 'get_pr':
          return await _getPullRequest(call);
        case 'list_contents':
          return await _listContents(call);
        case 'get_content':
          return await _getContent(call);
        case 'search':
          return await _search(call);
        default:
          return ToolResult(
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listRepos(ToolCall call) async {
    try {
      final limit = call.args['limit'] as num? ?? 10;
      final page = call.args['page'] as num? ?? 1;
      
      final response = await _makeRequest(
        'GET',
        '/user/repos',
        null,
        {'per_page': limit.toString(), 'page': page.toString()},
      );
      
      final repos = jsonDecode(response.body) as List<dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'repositories': repos,
          'count': repos.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list repositories: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getRepo(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo',
        null,
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'repository': data,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get repository: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listIssues(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final limit = call.args['limit'] as num? ?? 10;
      final page = call.args['page'] as num? ?? 1;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo/issues',
        null,
        {
          'state': 'all',
          'per_page': limit.toString(),
          'page': page.toString(),
        },
      );
      
      final issues = jsonDecode(response.body) as List<dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'issues': issues,
          'count': issues.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list issues: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getIssue(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final issueNumber = call.args['issue_number'] as num?;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      if (issueNumber == null) {
        return ToolResult(
          content: jsonEncode({'error': 'issue_number is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo/issues/$issueNumber',
        null,
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'issue': data,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get issue: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createIssue(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final title = call.args['title'] as String?;
      final body = call.args['body'] as String?;
      final labels = call.args['labels'] as List<dynamic>?;
      final assignees = call.args['assignees'] as List<dynamic>?;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      if (title == null || title.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'title is required'}),
          isError: true,
        );
      }
      
      final requestBody = <String, dynamic>{
        'title': title,
        if (body != null) 'body': body,
        if (labels != null) 'labels': labels,
        if (assignees != null) 'assignees': assignees,
      };
      
      final response = await _makeRequest(
        'POST',
        '/repos/$owner/$repo/issues',
        requestBody,
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'issue': data,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to create issue: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _updateIssue(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final issueNumber = call.args['issue_number'] as num?;
      final title = call.args['title'] as String?;
      final body = call.args['body'] as String?;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      if (issueNumber == null) {
        return ToolResult(
          content: jsonEncode({'error': 'issue_number is required'}),
          isError: true,
        );
      }
      
      final requestBody = <String, dynamic>{};
      if (title != null) requestBody['title'] = title;
      if (body != null) requestBody['body'] = body;
      
      if (requestBody.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'No fields to update'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'PATCH',
        '/repos/$owner/$repo/issues/$issueNumber',
        requestBody,
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'issue': data,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to update issue: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listPullRequests(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final limit = call.args['limit'] as num? ?? 10;
      final page = call.args['page'] as num? ?? 1;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo/pulls',
        null,
        {
          'state': 'all',
          'per_page': limit.toString(),
          'page': page.toString(),
        },
      );
      
      final prs = jsonDecode(response.body) as List<dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'pull_requests': prs,
          'count': prs.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list pull requests: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getPullRequest(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final prNumber = call.args['pr_number'] as num?;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      if (prNumber == null) {
        return ToolResult(
          content: jsonEncode({'error': 'pr_number is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo/pulls/$prNumber',
        null,
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'pull_request': data,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get pull request: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listContents(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final path = call.args['path'] as String? ?? '';
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo/contents/$path',
        null,
        null,
      );
      
      final contents = jsonDecode(response.body) as List<dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'contents': contents,
          'path': path,
          'count': contents.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to list contents: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getContent(ToolCall call) async {
    try {
      final owner = call.args['owner'] as String?;
      final repo = call.args['repo'] as String?;
      final path = call.args['path'] as String?;
      
      if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'owner and repo are required'}),
          isError: true,
        );
      }
      if (path == null || path.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'path is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/repos/$owner/$repo/contents/$path',
        null,
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'content': data,
          'path': path,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to get content: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _search(ToolCall call) async {
    try {
      final query = call.args['query'] as String?;
      final limit = call.args['limit'] as num? ?? 10;
      
      if (query == null || query.isEmpty) {
        return ToolResult(
          content: jsonEncode({'error': 'query is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/search/code',
        null,
        {
          'q': query,
          'per_page': limit.toString(),
        },
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = data['items'] as List<dynamic>? ?? [];
      
      return ToolResult(
        content: jsonEncode({
          'status': 'success',
          'query': query,
          'results': items,
          'count': items.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        content: jsonEncode({'error': 'Failed to search: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<http.Response> _makeRequest(
    String method,
    String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
  ) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: queryParams);
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    
    final client = http.Client();
    try {
      if (method == 'GET') {
        final response = await client.get(uri, headers: headers).timeout(timeout);
        return http.Response(response.body, response.statusCode);
      } else if (method == 'POST' || method == 'PATCH' || method == 'PUT' || method == 'DELETE') {
        final request = http.Request(method, uri)
          ..headers.addAll(headers)
          ..body = body != null ? jsonEncode(body) : null;
        
        final response = await client.send(request).timeout(timeout);
        final responseBody = await response.stream.bytesToString();
        return http.Response(responseBody, response.statusCode);
      } else {
        throw Exception('Unsupported HTTP method: $method');
      }
    } finally {
      client.close();
    }
  }
}

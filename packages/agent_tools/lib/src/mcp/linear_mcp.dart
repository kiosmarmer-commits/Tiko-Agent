import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

/// Linear MCP server tool for accessing Linear project management.
///
/// Linear is a project management tool for software teams.
/// This MCP server provides access to Linear's API for managing
/// issues, projects, teams, and users.
///
/// Configuration:
/// - apiKey: Linear API key (required)
/// - baseUrl: Linear API base URL (default: https://api.linear.app)
/// - timeout: Request timeout (default: 30 seconds)
class LinearMcpTool implements Tool {
  LinearMcpTool({
    required this.apiKey,
    this.baseUrl = 'https://api.linear.app',
    this.timeout = const Duration(seconds: 30),
  });

  final String apiKey;
  final String baseUrl;
  final Duration timeout;


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
                'list_issues',
                'get_issue',
                'create_issue',
                'update_issue',
                'list_projects',
                'get_project',
                'list_teams',
                'get_team',
                'list_users',
                'get_user',
                'search',
              ],
              'description': 'The Linear action to perform',
            },
            'issue_id': {
              'type': 'string',
              'description': 'Issue ID for get_issue and update_issue actions',
            },
            'project_id': {
              'type': 'string',
              'description': 'Project ID for get_project action',
            },
            'team_id': {
              'type': 'string',
              'description': 'Team ID for get_team action',
            },
            'user_id': {
              'type': 'string',
              'description': 'User ID for get_user action',
            },
            'title': {
              'type': 'string',
              'description': 'Title for create_issue action',
            },
            'description': {
              'type': 'string',
              'description': 'Description for create_issue action',
            },
            'team': {
              'type': 'string',
              'description': 'Team name or ID for create_issue action',
            },
            'priority': {
              'type': 'number',
              'description': 'Priority for create_issue (1-5)',
              'minimum': 1,
              'maximum': 5,
            },
            'assignee': {
              'type': 'string',
              'description': 'Assignee for create_issue action',
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
            'offset': {
              'type': 'number',
              'description': 'Offset for pagination',
              'default': 0,
            },
          },
          'required': ['action'],
        },
      );

  @override
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final action = args['action'] as String?;
      
      switch (action) {
        case 'list_issues':
          return await _listIssues(args, ctx);
        case 'get_issue':
          return await _getIssue(args, ctx);
        case 'create_issue':
          return await _createIssue(args, ctx);
        case 'update_issue':
          return await _updateIssue(args, ctx);
        case 'list_projects':
          return await _listProjects(args, ctx);
        case 'get_project':
          return await _getProject(args, ctx);
        case 'list_teams':
          return await _listTeams(args, ctx);
        case 'get_team':
          return await _getTeam(args, ctx);
        case 'list_users':
          return await _listUsers(args, ctx);
        case 'get_user':
          return await _getUser(args, ctx);
        case 'search':
          return await _search(args, ctx);
        default:
          return ToolResult(
            callId: '',
            content: jsonEncode({'error': 'Unknown action: $action'}),
            isError: true,
          );
      }
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': e.toString()}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listIssues(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final limit = args['limit'] as num? ?? 10;
      final offset = args['offset'] as num? ?? 0;
      final team = args['team'] as String?;
      
      final queryParams = <String, String>{};
      if (team != null && team.isNotEmpty) {
        queryParams['team'] = team;
      }
      queryParams['limit'] = limit.toString();
      queryParams['offset'] = offset.toString();
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        queryParams,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final issues = data['data']?['issues']?['nodes'] ?? [];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'issues': issues,
          'count': issues.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to list issues: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getIssue(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final issueId = args['issue_id'] as String?;
      
      if (issueId == null || issueId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'issue_id is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'issue(id: "$issueId") { id title description state priority assignee team project }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final issue = data['data']?['issue'];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'issue': issue,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get issue: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _createIssue(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final title = args['title'] as String?;
      final description = args['description'] as String?;
      final team = args['team'] as String?;
      final priority = args['priority'] as num?;
      final assignee = args['assignee'] as String?;
      
      if (title == null || title.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'title is required'}),
          isError: true,
        );
      }
      
      final mutation = '''
        mutation {
          issueCreate(
            input: {
              title: "${title.replaceAll('"', '\\"')}"
              ${description != null ? ', description: "${description.replaceAll('"', '\\"')}"' : ''}
              ${team != null ? ', teamId: "$team"' : ''}
              ${priority != null ? ', priority: $priority' : ''}
              ${assignee != null ? ', assigneeId: "$assignee"' : ''}
            }
          ) {
            success
            issue {
              id
              title
              description
              state
              priority
              assignee {
                id
                name
              }
              team {
                id
                name
              }
            }
          }
        }
      ''';
      
      final response = await _makeRequest(
        'POST',
        '/graphql',
        {'query': mutation},
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final issue = data['data']?['issueCreate']?['issue'];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'issue': issue,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to create issue: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _updateIssue(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final issueId = args['issue_id'] as String?;
      final title = args['title'] as String?;
      final description = args['description'] as String?;
      final priority = args['priority'] as num?;
      final assignee = args['assignee'] as String?;
      
      if (issueId == null || issueId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'issue_id is required'}),
          isError: true,
        );
      }
      
      final updates = <String, String>{};
      if (title != null) updates['title'] = title;
      if (description != null) updates['description'] = description;
      if (priority != null) updates['priority'] = priority.toString();
      if (assignee != null) updates['assigneeId'] = assignee;
      
      if (updates.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'No fields to update'}),
          isError: true,
        );
      }
      
      final updateString = updates.entries.map((e) => '${e.key}: "${e.value}"').join(', ');
      
      final mutation = '''
        mutation {
          issueUpdate(
            id: "$issueId"
            input: {$updateString}
          ) {
            success
            issue {
              id
              title
              description
              state
              priority
            }
          }
        }
      ''';
      
      final response = await _makeRequest(
        'POST',
        '/graphql',
        {'query': mutation},
        null,
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final issue = data['data']?['issueUpdate']?['issue'];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'issue': issue,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to update issue: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listProjects(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final limit = args['limit'] as num? ?? 10;
      final offset = args['offset'] as num? ?? 0;
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'projects(first: ${limit.toInt()}, offset: ${offset.toInt()}) { nodes { id name description state team { id name } } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final projects = data['data']?['projects']?['nodes'] ?? [];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'projects': projects,
          'count': projects.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to list projects: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getProject(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final projectId = args['project_id'] as String?;
      
      if (projectId == null || projectId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'project_id is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'project(id: "$projectId") { id name description state team { id name } issues { nodes { id title state } } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final project = data['data']?['project'];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'project': project,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get project: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listTeams(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final limit = args['limit'] as num? ?? 10;
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'teams(first: ${limit.toInt()}) { nodes { id name description key members { nodes { id name } } } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final teams = data['data']?['teams']?['nodes'] ?? [];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'teams': teams,
          'count': teams.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to list teams: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getTeam(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final teamId = args['team_id'] as String?;
      
      if (teamId == null || teamId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'team_id is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'team(id: "$teamId") { id name description key members { nodes { id name email } } projects { nodes { id name } } issues { nodes { id title state } } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final team = data['data']?['team'];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'team': team,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get team: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _listUsers(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final limit = args['limit'] as num? ?? 10;
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'users(first: ${limit.toInt()}) { nodes { id name email displayName } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final users = data['data']?['users']?['nodes'] ?? [];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'users': users,
          'count': users.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to list users: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _getUser(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final userId = args['user_id'] as String?;
      
      if (userId == null || userId.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'user_id is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'user(id: "$userId") { id name email displayName teams { nodes { id name } } assignedIssues { nodes { id title state } } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final user = data['data']?['user'];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'user': user,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
        content: jsonEncode({'error': 'Failed to get user: ${e.toString()}'}),
        isError: true,
      );
    }
  }

  Future<ToolResult> _search(Map<String, dynamic> args, ToolContext ctx) async {
    try {
      final query = args['query'] as String?;
      final limit = args['limit'] as num? ?? 10;
      
      if (query == null || query.isEmpty) {
        return ToolResult(
          callId: '',
          content: jsonEncode({'error': 'query is required'}),
          isError: true,
        );
      }
      
      final response = await _makeRequest(
        'GET',
        '/graphql',
        null,
        {'query': 'search(query: "$query", first: ${limit.toInt()}) { nodes { ... on Issue { id title description state team { name } } ... on Project { id name description } ... on User { id name email } } }'},
      );
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['data']?['search']?['nodes'] ?? [];
      
      return ToolResult(
        callId: '',
        content: jsonEncode({
          'status': 'success',
          'query': query,
          'results': results,
          'count': results.length,
        }),
        isError: false,
      );
    } catch (e) {
      return ToolResult(
        callId: '',
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
      'Authorization': apiKey,
    };
    
    final client = http.Client();
    try {
      if (method == 'GET') {
        final response = await client.get(uri, headers: headers).timeout(timeout);
        return http.Response(response.body, response.statusCode);
      } else {
        final request = http.Request(method, uri)
          ..headers.addAll(headers)
          ..body = body != null ? jsonEncode(body) : null;
        
        final response = await client.send(request).timeout(timeout);
        final responseBody = await response.stream.bytesToString();
        return http.Response(responseBody, response.statusCode);
      }
    } finally {
      client.close();
    }
  }
}

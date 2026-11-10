import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:path/path.dart' as p;

import 'permission_gate.dart';
import 'capability_gate.dart';
import 'audit_log.dart';
import 'sanitizer.dart';
import 'taint.dart';

/// Tirith Security Layer - Comprehensive security framework for Tiko-Agent
///
/// Inspired by Hermes Agent's Tirith security layer, this provides:
/// - Approval workflows for sensitive operations
/// - Permission controls with fine-grained policies
/// - Safety guardrails for autonomous operations
/// - Command approval with audit trails
/// - Container isolation tracking
/// - Credential management and access control
///
/// The name "Tirith" comes from "Tirith" (Sindarin for "guard") - a security
/// layer that protects the agent from harmful actions while allowing
/// legitimate operations.
class TirithSecurityLayer {
  TirithSecurityLayer({
    required this.auditLog,
    required this.permissionGate,
    required this.capabilityGate,
    required this.sanitizer,
    this.taintTracker,
    this.credentialManager,
    this.fallbackManager,
    this.config = const TirithConfig(),
  });

  /// Audit log for tracking all security decisions
  final AuditLog auditLog;

  /// Permission gate for tool-level access control
  final PermissionGate permissionGate;

  /// Capability gate for resource-level access control
  final CapabilityGate capabilityGate;

  /// Sanitizer for cleaning untrusted input
  final SecuritySanitizer sanitizer;

  /// Taint tracker for detecting contaminated sessions
  final TaintTracker? taintTracker;

  /// Credential manager for API key management
  final CredentialManager? credentialManager;

  /// Fallback manager for provider failover
  final FallbackManager? fallbackManager;

  /// Security configuration
  final TirithConfig config;

  /// Whether the security layer is enabled
  bool _enabled = true;

  /// Enable the security layer
  void enable() => _enabled = true;

  /// Disable the security layer (for testing only)
  void disable() => _enabled = false;

  /// Check if security layer is enabled
  bool get isEnabled => _enabled;

  /// Initialize the security layer
  Future<void> initialize() async {
    if (!_enabled) return;
    
    // Initialize components
    await auditLog.initialize();
    
    // Log initialization
    await auditLog.log(
      AuditEvent(
        type: AuditEventType.securityInitialization,
        action: 'tirith_initialized',
        details: {'config': config.toJson()},
        success: true,
      ),
    );
  }

  /// Check if a tool call should be allowed
  Future<SecurityDecision> checkToolCall({
    required ToolCall call,
    required Session session,
    required String channel,
  }) async {
    if (!_enabled) {
      return SecurityDecision.allow(reason: 'Security layer disabled');
    }

    // Step 1: Sanitize input
    final sanitizedCall = await _sanitizeCall(call, session);
    
    // Step 2: Check taint status
    final taintCheck = await _checkTaint(session, sanitizedCall);
    if (!taintCheck.allowed) {
      await auditLog.log(
        AuditEvent(
          type: AuditEventType.toolDenied,
          action: 'taint_check_failed',
          tool: call.name,
          sessionId: session.id,
          details: {'reason': taintCheck.reason},
          success: false,
        ),
      );
      return SecurityDecision.deny(reason: taintCheck.reason);
    }

    // Step 3: Check permissions
    final permissionResult = await permissionGate.check(sanitizedCall, session);
    if (!permissionResult.allowed) {
      await auditLog.log(
        AuditEvent(
          type: AuditEventType.toolDenied,
          action: 'permission_denied',
          tool: call.name,
          sessionId: session.id,
          details: {'reason': permissionResult.reason},
          success: false,
        ),
      );
      return SecurityDecision.deny(reason: permissionResult.reason);
    }

    // Step 4: Check capabilities
    final capabilityResult = await capabilityGate.check(sanitizedCall, session);
    if (!capabilityResult.allowed) {
      await auditLog.log(
        AuditEvent(
          type: AuditEventType.toolDenied,
          action: 'capability_denied',
          tool: call.name,
          sessionId: session.id,
          details: {'reason': capabilityResult.reason},
          success: false,
        ),
      );
      return SecurityDecision.deny(reason: capabilityResult.reason);
    }

    // Step 5: Check credential availability (if applicable)
    if (credentialManager != null) {
      final credentialCheck = await credentialManager!.checkCredentials(call);
      if (!credentialCheck.available) {
        await auditLog.log(
          AuditEvent(
            type: AuditEventType.toolDenied,
            action: 'credentials_unavailable',
            tool: call.name,
            sessionId: session.id,
            details: {'reason': credentialCheck.reason},
            success: false,
          ),
        );
        return SecurityDecision.deny(reason: credentialCheck.reason);
      }
    }

    // All checks passed
    await auditLog.log(
      AuditEvent(
        type: AuditEventType.toolAllowed,
        action: 'all_checks_passed',
        tool: call.name,
        sessionId: session.id,
        details: {'args': call.args},
        success: true,
      ),
    );
    
    return SecurityDecision.allow(reason: 'All security checks passed');
  }

  /// Sanitize a tool call
  Future<ToolCall> _sanitizeCall(ToolCall call, Session session) async {
    if (sanitizer.config.enabled) {
      return ToolCall(
        name: call.name,
        args: await sanitizer.sanitizeArgs(call.args, session),
        id: call.id,
      );
    }
    return call;
  }

  /// Check if session is tainted
  Future<SecurityDecision> _checkTaint(Session session, ToolCall call) async {
    if (taintTracker == null) {
      return SecurityDecision.allow();
    }

    if (taintTracker!.isTainted(session.id)) {
      // Tainted sessions require confirmation for medium+ risk
      final risk = _getRiskLevel(call);
      if (risk != 'low') {
        return SecurityDecision.deny(
          reason: 'Session tainted - confirmation required for $risk risk tool',
        );
      }
    }

    return SecurityDecision.allow();
  }

  /// Get risk level for a tool call
  String _getRiskLevel(ToolCall call) {
    // Try to get risk from tool spec
    if (call is ToolCallWithSpec && call.spec.risk.isNotEmpty) {
      return call.spec.risk;
    }
    
    // Fallback to known high-risk tools
    const highRiskTools = {
      'shell', 'execute_code', 'write_file', 'delete_file',
      'http_post', 'http_request', 'patch_file', 'rollback',
    };
    
    if (highRiskTools.contains(call.name)) {
      return 'high';
    }
    
    return 'medium';
  }

  /// Create an approval request for a tool call
  Future<ApprovalRequest> createApprovalRequest({
    required ToolCall call,
    required Session session,
    required String channel,
    String? toolCallId,
    Duration? ttl,
  }) async {
    final request = ApprovalRequest(
      id: const Uuid().v4(),
      sessionId: session.id,
      channel: channel,
      tool: call.name,
      toolCallId: toolCallId,
      args: call.args,
      argsHash: _hashArgs(call.args),
      risk: _getRiskLevel(call),
      createdAt: DateTime.now().toUtc(),
      expiresAt: ttl != null ? DateTime.now().toUtc().add(ttl) : null,
      state: ApprovalState.pending,
    );

    await auditLog.log(
      AuditEvent(
        type: AuditEventType.approvalCreated,
        action: 'approval_request_created',
        tool: call.name,
        sessionId: session.id,
        details: {'requestId': request.id, 'risk': request.risk},
        success: true,
      ),
    );

    return request;
  }

  /// Approve an approval request
  Future<SecurityDecision> approveRequest({
    required String requestId,
    required String actor,
    String? reason,
  }) async {
    // In a real implementation, this would update the approval ledger
    // For now, just log it
    
    await auditLog.log(
      AuditEvent(
        type: AuditEventType.approvalApproved,
        action: 'approval_approved',
        details: {
          'requestId': requestId,
          'actor': actor,
          'reason': reason,
        },
        success: true,
      ),
    );

    return SecurityDecision.allow(reason: 'Approved by $actor${reason != null ? ': $reason' : ''}');
  }

  /// Deny an approval request
  Future<SecurityDecision> denyRequest({
    required String requestId,
    required String actor,
    String? reason,
  }) async {
    await auditLog.log(
      AuditEvent(
        type: AuditEventType.approvalDenied,
        action: 'approval_denied',
        details: {
          'requestId': requestId,
          'actor': actor,
          'reason': reason,
        },
        success: true,
      ),
    );

    return SecurityDecision.deny(reason: 'Denied by $actor${reason != null ? ': $reason' : ''}');
  }

  /// Hash arguments for change detection
  String? _hashArgs(Map<String, dynamic> args) {
    try {
      final sortedKeys = args.keys.toList()..sort();
      final sortedArgs = <String, dynamic>{};
      for (final key in sortedKeys) {
        sortedArgs[key] = args[key];
      }
      final jsonString = jsonEncode(sortedArgs);
      // In production, use a proper hash function
      return jsonString.hashCode.toString();
    } catch (e) {
      return null;
    }
  }

  /// Check if a provider is available (with fallback)
  Future<ProviderCheckResult> checkProvider({
    required String providerName,
    required String model,
  }) async {
    if (fallbackManager == null) {
      return ProviderCheckResult(
        available: true,
        provider: providerName,
        model: model,
      );
    }

    return await fallbackManager!.checkProvider(providerName, model);
  }

  /// Get fallback provider
  Future<String?> getFallbackProvider(String primaryProvider) async {
    if (fallbackManager == null) {
      return null;
    }
    return await fallbackManager!.getFallback(primaryProvider);
  }
}

/// Configuration for Tirith Security Layer
class TirithConfig {
  const TirithConfig({
    this.enabled = true,
    this.requireApprovalForHighRisk = true,
    this.requireApprovalForMediumRisk = false,
    this.autoApproveLowRisk = true,
    this.approvalTtl = const Duration(minutes: 10),
    this.maxConcurrentApprovals = 10,
    this.auditRetentionDays = 30,
    this.enableCredentialPools = true,
    this.enableFallbackProviders = true,
    this.enableTaintTracking = true,
    this.sanitizationEnabled = true,
  });

  final bool enabled;
  final bool requireApprovalForHighRisk;
  final bool requireApprovalForMediumRisk;
  final bool autoApproveLowRisk;
  final Duration approvalTtl;
  final int maxConcurrentApprovals;
  final int auditRetentionDays;
  final bool enableCredentialPools;
  final bool enableFallbackProviders;
  final bool enableTaintTracking;
  final bool sanitizationEnabled;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'requireApprovalForHighRisk': requireApprovalForHighRisk,
        'requireApprovalForMediumRisk': requireApprovalForMediumRisk,
        'autoApproveLowRisk': autoApproveLowRisk,
        'approvalTtl': approvalTtl.inSeconds,
        'maxConcurrentApprovals': maxConcurrentApprovals,
        'auditRetentionDays': auditRetentionDays,
        'enableCredentialPools': enableCredentialPools,
        'enableFallbackProviders': enableFallbackProviders,
        'enableTaintTracking': enableTaintTracking,
        'sanitizationEnabled': sanitizationEnabled,
      };
}

/// Result of a security check
class SecurityDecision {
  const SecurityDecision._({
    required this.allowed,
    required this.reason,
    this.requiresApproval = false,
    this.approvalRequestId,
  });

  const SecurityDecision.allow({required String reason, String? approvalRequestId})
      : this._(allowed: true, reason: reason, approvalRequestId: approvalRequestId);

  const SecurityDecision.deny({required String reason, String? approvalRequestId})
      : this._(allowed: false, reason: reason, approvalRequestId: approvalRequestId);

  const SecurityDecision.requiresApproval({required String approvalRequestId})
      : this._(allowed: false, reason: 'Requires approval', 
                requiresApproval: true, approvalRequestId: approvalRequestId);

  final bool allowed;
  final String reason;
  final bool requiresApproval;
  final String? approvalRequestId;

  Map<String, dynamic> toJson() => {
        'allowed': allowed,
        'reason': reason,
        'requiresApproval': requiresApproval,
        'approvalRequestId': approvalRequestId,
      };
}

/// Result of credential check
class CredentialCheckResult {
  const CredentialCheckResult({
    required this.available,
    this.reason,
    this.credentials,
  });

  final bool available;
  final String? reason;
  final List<String>? credentials;
}

/// Result of provider check
class ProviderCheckResult {
  const ProviderCheckResult({
    required this.available,
    required this.provider,
    required this.model,
    this.fallbackProvider,
    this.reason,
  });

  final bool available;
  final String provider;
  final String model;
  final String? fallbackProvider;
  final String? reason;
}

/// Audit event types
enum AuditEventType {
  securityInitialization,
  toolAllowed,
  toolDenied,
  approvalCreated,
  approvalApproved,
  approvalDenied,
  approvalExpired,
  credentialAccess,
  providerSwitch,
  taintDetected,
  sanitizationApplied,
}

/// Audit event for security logging
class AuditEvent {
  const AuditEvent({
    required this.type,
    required this.action,
    required this.success,
    this.tool,
    this.sessionId,
    this.userId,
    this.details = const {},
    this.timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  final AuditEventType type;
  final String action;
  final bool success;
  final String? tool;
  final String? sessionId;
  final String? userId;
  final Map<String, dynamic> details;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'action': action,
        'success': success,
        'tool': tool,
        'sessionId': sessionId,
        'userId': userId,
        'details': details,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Audit log for security events
class AuditLog {
  AuditLog({required this.path, this.maxEntries = 1000});

  final String path;
  final int maxEntries;
  
  final List<AuditEvent> _events = [];
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        final lines = content.split('\n');
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            _events.add(AuditEvent.fromJson(json));
          } catch (e) {
            // Skip invalid lines
          }
        }
      }
      _initialized = true;
    } catch (e) {
      // Failed to initialize, but continue
    }
  }

  Future<void> log(AuditEvent event) async {
    _events.add(event);
    
    // Trim to max entries
    if (_events.length > maxEntries) {
      _events.removeRange(0, _events.length - maxEntries);
    }

    // Append to file
    try {
      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsString('${jsonEncode(event.toJson())}\n', mode: FileMode.append);
    } catch (e) {
      // Failed to write, but continue
    }
  }

  List<AuditEvent> get events => List.unmodifiable(_events);

  Stream<AuditEvent> watch() async* {
    // In a real implementation, this would watch the file for changes
    yield* Stream.fromIterable(_events);
  }

  static AuditEvent fromJson(Map<String, dynamic> json) {
    return AuditEvent(
      type: AuditEventType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => AuditEventType.toolAllowed,
      ),
      action: json['action'] as String,
      success: json['success'] as bool? ?? false,
      tool: json['tool'] as String?,
      sessionId: json['sessionId'] as String?,
      userId: json['userId'] as String?,
      details: json['details'] as Map<String, dynamic>? ?? {},
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String).toUtc()
          : null,
    );
  }
}

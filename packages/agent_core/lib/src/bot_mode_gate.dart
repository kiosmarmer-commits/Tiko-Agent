/// Applies Bot Mode to inbound gateway traffic.
///
/// Bot Mode is a group-chat feature. Private chat, and groups where no bot
/// is bound, keep the existing single-agent behaviour untouched.
library;

import 'bot_mode.dart';
import 'models.dart';

/// What the daemon should do with one inbound message.
enum BotModeAction { bypass, dispatch, drop }

class BotModeResult {
  const BotModeResult(this.action, {this.route, this.reason = ''});

  final BotModeAction action;
  final BotRoute? route;

  /// [BotRouteDecision] name when dropped, for logging.
  final String reason;

  bool get dispatches => action == BotModeAction.dispatch;
}

/// Decides whether Bot Mode governs a message, and who may answer it.
class BotModeGate {
  const BotModeGate(this.router);

  final BotRouter router;

  /// Group chat types as reported by Telegram.
  static const Set<String> groupTypes = <String>{'group', 'supergroup'};

  static bool isGroup(InboundMessage message) =>
      groupTypes.contains('${message.meta['chat_type'] ?? ''}');

  /// [hop] and [senderIsBot] carry bot-to-bot depth so chains terminate.
  BotModeResult evaluate(
    InboundMessage message, {
    int hop = 0,
    bool senderIsBot = false,
  }) {
    if (!isGroup(message)) {
      return const BotModeResult(BotModeAction.bypass);
    }
    if (router.registry.length == 0) {
      return const BotModeResult(BotModeAction.bypass);
    }
    final sender = '${message.meta['username'] ?? message.userKey}';
    final route = router.route(
      text: message.text,
      senderHandle: sender,
      hop: hop,
      senderIsBot: senderIsBot,
    );
    if (route.allowed) {
      return BotModeResult(BotModeAction.dispatch, route: route);
    }
    return BotModeResult(
      BotModeAction.drop,
      route: route,
      reason: route.decision.name,
    );
  }
}

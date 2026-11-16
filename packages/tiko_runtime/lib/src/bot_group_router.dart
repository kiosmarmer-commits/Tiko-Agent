import 'package:agent_core/agent_core.dart';

import 'bot_mode.dart';

/// Routing pesan grup ke persona bot dari [BotStore] — satu sumber kebenaran
/// bersama slash `/bot` (unifikasi sistem bot).
///
/// - Chat privat → bypass (perilaku single-agent tidak berubah).
/// - Pesan grup dengan mention handle yang cocok id bot → dispatch: sesi
///   diikat ke bot tersebut (semantik sama dengan `/bot use`), sehingga
///   persona + model bot disuntik otomatis oleh funnel `chatWithStatus`.
/// - Pesan grup tanpa mention bot → drop: agent utama tidak menjawab obrolan
///   grup yang tidak ditujukan ke bot.
class BotGroupRouter {
  BotGroupRouter(this.store);

  final BotStore store;

  BotGroupRoute route({required String text, required bool isGroup}) {
    if (!isGroup) return const BotGroupRoute(BotGroupAction.bypass);
    if (store.list().isEmpty) {
      return const BotGroupRoute(BotGroupAction.bypass);
    }
    for (final handle in MentionParser.parse(text)) {
      final bot = store.get(handle);
      if (bot != null) {
        return BotGroupRoute(BotGroupAction.dispatch, target: bot);
      }
    }
    return const BotGroupRoute(BotGroupAction.drop);
  }
}

enum BotGroupAction { bypass, dispatch, drop }

class BotGroupRoute {
  const BotGroupRoute(this.action, {this.target});

  final BotGroupAction action;

  /// Bot tujuan saat [action] == [BotGroupAction.dispatch].
  final BotProfile? target;

  bool get drops => action == BotGroupAction.drop;

  bool get dispatches => action == BotGroupAction.dispatch;
}

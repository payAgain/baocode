/// Built-ins and host tools available to isolated bot conversations.
abstract final class BotPermissions {
  // The runtime cannot scope built-in filesystem, shell or plugin access to a
  // chat. Both private and group workers receive only host-supplied tools.
  static const chatTools = <String>[];
  static const groupHostTools = {
    'bot_my_picture',
    'bot_send',
    'bot_history',
    'bot_remember',
    'bot_refine',
  };
}

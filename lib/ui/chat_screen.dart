import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen(this.controller, this.contact, {super.key});

  final AppController controller;
  final Contact contact;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  List<ChatMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reload);
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final ms = await widget.controller.store.messages(widget.contact.deviceId);
    if (!mounted) return;
    setState(() => _messages = ms);
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await widget.controller.sendText(widget.contact.deviceId, text);
  }

  Widget _statusIcon(MessageStatus s, ChatColors colors) {
    switch (s) {
      case MessageStatus.pending:
        return Icon(Icons.schedule, size: 14, color: colors.subtleText);
      case MessageStatus.sent:
        return Icon(Icons.done, size: 15, color: colors.subtleText);
      case MessageStatus.delivered:
      case MessageStatus.received:
        return Icon(Icons.done_all, size: 15, color: colors.tick);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final id = widget.contact.deviceId;
    final connected = c.isConnected(id);
    final colors = ChatColors.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.chatBackground,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.contact.name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            Text(
              connected ? 'connecté' : 'hors connexion',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          if (connected)
            TextButton(
              onPressed: () => c.disconnect(id),
              child: Text(
                'Couper',
                style: TextStyle(
                  color: Theme.of(context).appBarTheme.foregroundColor,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!connected)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.receivedBubble,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Hors connexion. Tes messages restent en attente et partent '
                'dès que vous êtes de nouveau connectés.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: colors.subtleText),
              ),
            ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[_messages.length - 1 - i];
                final mine = m.outgoing;
                return Align(
                  alignment: mine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.78,
                    ),
                    decoration: BoxDecoration(
                      color: mine ? colors.sentBubble : colors.receivedBubble,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(10),
                        topRight: const Radius.circular(10),
                        bottomLeft: Radius.circular(mine ? 10 : 2),
                        bottomRight: Radius.circular(mine ? 2 : 10),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            m.text,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.25,
                              color: colors.text,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              TimeOfDay.fromDateTime(m.at).format(context),
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.subtleText,
                              ),
                            ),
                            if (mine) ...[
                              const SizedBox(width: 4),
                              _statusIcon(m.status, colors),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(color: colors.text),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: TextStyle(color: colors.subtleText),
                        filled: true,
                        fillColor: colors.inputFill,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _send,
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

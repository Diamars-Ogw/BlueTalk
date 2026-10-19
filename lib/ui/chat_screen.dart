import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';

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

  Widget _statusIcon(MessageStatus s, Color color) {
    final icon = switch (s) {
      MessageStatus.pending => Icons.schedule,
      MessageStatus.sent => Icons.done,
      MessageStatus.delivered => Icons.done_all,
      MessageStatus.received => Icons.done_all,
    };
    return Icon(icon, size: 14, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final id = widget.contact.deviceId;
    final connected = c.isConnected(id);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.contact.name),
            Text(
              connected ? 'connecté' : 'hors connexion',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          if (connected)
            TextButton(
              onPressed: () => c.disconnect(id),
              child: const Text('Couper'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!connected)
            Container(
              width: double.infinity,
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(8),
              child: const Text(
                'Hors connexion. Tes messages restent en attente et partent '
                'à la prochaine connexion.',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(8),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[_messages.length - 1 - i];
                final mine = m.outgoing;
                final textColor = mine
                    ? scheme.onPrimaryContainer
                    : scheme.onSurface;
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
                      color: mine
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(m.text, style: TextStyle(color: textColor)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              TimeOfDay.fromDateTime(m.at).format(context),
                              style: TextStyle(fontSize: 11, color: textColor),
                            ),
                            if (mine) ...[
                              const SizedBox(width: 4),
                              _statusIcon(m.status, textColor),
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

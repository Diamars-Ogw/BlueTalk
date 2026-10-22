import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'theme.dart';

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
}

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

  // ---------- Pièces jointes ----------

  Future<void> _showAttachMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Image'),
              onTap: () => Navigator.pop(sheet, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Document'),
              onTap: () => Navigator.pop(sheet, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await _pick(image: choice == 'image');
  }

  Future<void> _pick({required bool image}) async {
    final result = await FilePicker.platform.pickFiles(
      type: image ? FileType.image : FileType.any,
    );
    final f = result?.files.single;
    final path = f?.path;
    if (f == null || path == null) return;
    final error = await widget.controller.sendFile(
      widget.contact.deviceId,
      sourcePath: path,
      name: f.name,
      image: image,
    );
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _open(String path) async {
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Impossible d\'ouvrir ce fichier avec les applications installées.',
          ),
        ),
      );
    }
  }

  // ---------- Affichage des messages ----------

  Widget _statusIcon(MessageStatus s, ChatColors colors) {
    switch (s) {
      case MessageStatus.pending:
        return Icon(Icons.schedule, size: 14, color: colors.subtleText);
      case MessageStatus.sent:
        return Icon(Icons.done, size: 15, color: colors.subtleText);
      case MessageStatus.delivered:
      case MessageStatus.received:
        return Icon(Icons.done_all, size: 15, color: colors.tick);
      case MessageStatus.receiving:
        return Icon(Icons.downloading, size: 14, color: colors.subtleText);
    }
  }

  Widget? _transferInfo(ChatMessage m, ChatColors colors) {
    final p = widget.controller.progress[m.id];
    if (p != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: p,
            minHeight: 4,
            backgroundColor: colors.subtleText.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 2),
          Text(
            '${(p * 100).round()} %',
            style: TextStyle(fontSize: 11, color: colors.subtleText),
          ),
        ],
      );
    }
    if (!m.outgoing && m.status == MessageStatus.receiving) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Réception interrompue, en attente du renvoi',
          style: TextStyle(fontSize: 11, color: colors.subtleText),
        ),
      );
    }
    return null;
  }

  Widget _imagePlaceholder(ChatColors colors, IconData icon) => Container(
    width: 230,
    height: 150,
    color: colors.subtleText.withValues(alpha: 0.15),
    child: Icon(icon, size: 40, color: colors.subtleText),
  );

  Widget _imageBody(ChatMessage m, ChatColors colors) {
    final path = m.filePath;
    final ready =
        path != null && (m.outgoing || m.status == MessageStatus.received);
    final info = _transferInfo(m, colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: ready ? () => _open(path!) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ready
                ? Image.file(
                    File(path!),
                    width: 230,
                    cacheWidth: 690,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _imagePlaceholder(colors, Icons.broken_image_outlined),
                  )
                : _imagePlaceholder(colors, Icons.image_outlined),
          ),
        ),
        if (info != null) info,
      ],
    );
  }

  Widget _fileBody(ChatMessage m, ChatColors colors) {
    final path = m.filePath;
    final ready =
        path != null && (m.outgoing || m.status == MessageStatus.received);
    final info = _transferInfo(m, colors);
    return InkWell(
      onTap: ready ? () => _open(path!) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 32,
                color: colors.subtleText,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.fileName ?? 'Fichier',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, color: colors.text),
                    ),
                    Text(
                      formatSize(m.fileSize ?? 0),
                      style: TextStyle(fontSize: 12, color: colors.subtleText),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (info != null) info,
        ],
      ),
    );
  }

  Widget _body(ChatMessage m, ChatColors colors) {
    switch (m.kind) {
      case MessageKind.text:
        return Text(
          m.text,
          style: TextStyle(fontSize: 16, height: 1.25, color: colors.text),
        );
      case MessageKind.image:
        return _imageBody(m, colors);
      case MessageKind.file:
        return _fileBody(m, colors);
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
                'Hors connexion. Tes messages et tes fichiers restent en '
                'attente et partent dès que vous êtes de nouveau connectés.',
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
                          child: _body(m, colors),
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
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: _showAttachMenu,
                    icon: Icon(Icons.attach_file, color: colors.subtleText),
                  ),
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

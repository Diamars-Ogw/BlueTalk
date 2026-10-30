import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import '../media/voice_bridge.dart';
import 'group_info_screen.dart';
import 'theme.dart';

/// Une couleur stable pour chaque auteur, pour reconnaître qui parle.
Color _senderColor(String id, Brightness b) {
  final hue = (id.hashCode & 0x7fffffff) % 360;
  return HSLColor.fromAHSL(
    1,
    hue.toDouble(),
    0.6,
    b == Brightness.dark ? 0.72 : 0.36,
  ).toColor();
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
}

/// Une discussion : avec une personne ([ChatScreen.new]) ou avec un groupe
/// ([ChatScreen.group]).
class ChatScreen extends StatefulWidget {
  const ChatScreen(this.controller, Contact this.contact, {super.key})
    : group = null;

  const ChatScreen.group(this.controller, Group this.group, {super.key})
    : contact = null;

  final AppController controller;
  final Contact? contact;
  final Group? group;

  String get conversationId => group?.id ?? contact!.deviceId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  List<ChatMessage> _messages = [];
  Group? _group;
  Map<String, DeliveryCount> _counts = {};

  // Message vocal : on maintient le micro pour enregistrer, on relâche pour
  // envoyer, on glisse vers la gauche pour annuler.
  bool _hasText = false;
  bool _holding = false;
  bool _recording = false;
  bool _cancelHint = false;
  int _recMs = 0;
  DateTime? _recStart;
  Timer? _recTimer;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    widget.controller.addListener(_reload);
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText && mounted) setState(() => _hasText = has);
    });
    _reload();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reload);
    _recTimer?.cancel();
    if (_recording || _holding) unawaited(VoiceBridge.instance.cancelRecording());
    _input.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _startRecording() async {
    _holding = true;
    final voice = VoiceBridge.instance;
    if (!await voice.ensurePermission()) {
      _holding = false;
      _snack('Autorise le micro pour envoyer des messages vocaux.');
      return;
    }
    // Relâché pendant la demande d'autorisation : pas d'enregistrement.
    if (!_holding || !mounted) return;
    await VoicePlayer.instance.stop();
    if (!await voice.startRecording()) {
      _holding = false;
      _snack('Impossible de démarrer l\'enregistrement.');
      return;
    }
    if (!_holding || !mounted) {
      await voice.cancelRecording();
      return;
    }
    _recStart = DateTime.now();
    setState(() {
      _recording = true;
      _cancelHint = false;
      _recMs = 0;
    });
    _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_recording || !mounted) return;
      final ms = DateTime.now().difference(_recStart!).inMilliseconds;
      if (ms >= 5 * 60 * 1000) {
        unawaited(_endRecording()); // durée maximale : on envoie
        return;
      }
      setState(() => _recMs = ms);
    });
  }

  void _dragRecording(double dx) {
    if (!_recording) return;
    final cancel = dx < -90;
    if (cancel != _cancelHint) setState(() => _cancelHint = cancel);
  }

  Future<void> _endRecording() async {
    _holding = false;
    _recTimer?.cancel();
    if (!_recording) return;
    final cancel = _cancelHint;
    if (mounted) {
      setState(() {
        _recording = false;
        _cancelHint = false;
      });
    }
    final voice = VoiceBridge.instance;
    if (cancel) {
      await voice.cancelRecording();
      return;
    }
    final clip = await voice.stopRecording();
    if (clip == null || clip.durationMs < 700) {
      if (clip != null) {
        try {
          await File(clip.path).delete();
        } catch (_) {}
      }
      _snack('Message vocal trop court : maintiens le micro plus longtemps.');
      return;
    }
    final error = await widget.controller.sendFile(
      widget.conversationId,
      sourcePath: clip.path,
      name: 'vocal_${DateTime.now().millisecondsSinceEpoch}.m4a',
      kind: MessageKind.audio,
      durationMs: clip.durationMs,
    );
    try {
      await File(clip.path).delete();
    } catch (_) {}
    if (error != null) _snack(error);
  }

  String _mmss(int ms) {
    final total = ms ~/ 1000;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _reload() async {
    final store = widget.controller.store;
    final ms = await store.messages(widget.conversationId);
    Group? g;
    var counts = <String, DeliveryCount>{};
    if (widget.group != null) {
      g = await store.group(widget.group!.id);
      counts = await store.deliveryCounts(widget.group!.id);
    }
    if (!mounted) return;
    setState(() {
      _messages = ms;
      _group = g ?? _group;
      _counts = counts;
    });
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await widget.controller.sendText(widget.conversationId, text);
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
      widget.conversationId,
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

  Widget _audioBody(ChatMessage m, ChatColors colors) {
    final path = m.filePath;
    final ready =
        path != null && (m.outgoing || m.status == MessageStatus.received);
    final info = _transferInfo(m, colors);
    final player = VoicePlayer.instance;
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final active = player.currentId == m.id;
        final total = (active && player.durationMs > 0)
            ? player.durationMs
            : (m.durationMs ?? 0);
        final pos = active ? player.positionMs : 0;
        final double fraction =
            total > 0 ? (pos / total).clamp(0.0, 1.0).toDouble() : 0.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 230,
              child: Row(
                children: [
                  IconButton(
                    onPressed: ready ? () => player.toggle(m.id, path) : null,
                    iconSize: 38,
                    padding: EdgeInsets.zero,
                    color: primary,
                    icon: Icon(
                      active && player.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 24,
                          child: Slider(
                            value: fraction,
                            onChanged: (ready && active)
                                ? (v) => player.seek(m.id, v)
                                : null,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            _mmss(active ? pos : total),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.subtleText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.mic, size: 18, color: colors.subtleText),
                ],
              ),
            ),
            if (info != null) info,
          ],
        );
      },
    );
  }

  Widget _recordingBar(ChatColors colors) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.inputFill,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
          const SizedBox(width: 8),
          Text(
            _mmss(_recMs),
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _cancelHint ? 'Relâche pour annuler' : '‹  Glisse pour annuler',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _cancelHint ? Colors.red : colors.subtleText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _micButton(ColorScheme scheme) {
    return GestureDetector(
      key: const ValueKey('mic'),
      onLongPressStart: (_) => unawaited(_startRecording()),
      onLongPressMoveUpdate: (d) => _dragRecording(d.offsetFromOrigin.dx),
      onLongPressEnd: (_) => unawaited(_endRecording()),
      onLongPressCancel: () {
        if (!_recording) _holding = false;
      },
      onTap: () => _snack('Maintiens le micro pour enregistrer un message vocal.'),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: _recording ? 60 : 48,
        height: _recording ? 60 : 48,
        decoration: BoxDecoration(
          color: _cancelHint ? Colors.red : scheme.primary,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.mic, color: scheme.onPrimary),
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
      case MessageKind.audio:
        return _audioBody(m, colors);
      case MessageKind.file:
        return _fileBody(m, colors);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final g = _group;
    final isGroup = widget.group != null;
    final id = widget.conversationId;
    final bool connected;
    final bool canWrite;
    String cannotWriteReason = 'Tu ne fais plus partie de ce groupe.';
    final String title;
    final String subtitle;
    if (isGroup) {
      final grp = g ?? widget.group!;
      final online = c.connectedMembers(grp);
      connected = online > 0;
      final myId = c.identity?.deviceId ?? '';
      canWrite = grp.canPost(myId);
      if (grp.closed) {
        cannotWriteReason = 'Ce groupe a été supprimé par son créateur.';
      } else if (grp.active && grp.adminsOnlyPost) {
        cannotWriteReason = 'Seuls les administrateurs peuvent écrire ici.';
      }
      title = grp.name;
      subtitle = grp.closed
          ? 'Groupe supprimé'
          : !grp.active
          ? 'Tu n\'es plus dans ce groupe'
          : '${grp.members.length} membres · $online connecté(s)';
    } else {
      connected = c.isConnected(id);
      canWrite = true;
      title = widget.contact!.name;
      subtitle = connected ? 'connecté' : 'hors connexion';
    }
    final colors = ChatColors.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.chatBackground,
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isGroup
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => GroupInfoScreen(c, id),
                  ),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
              ),
            ],
          ),
        ),
        actions: [
          if (isGroup)
            IconButton(
              tooltip: 'Infos du groupe',
              icon: const Icon(Icons.info_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GroupInfoScreen(c, id),
                ),
              ),
            )
          else if (connected)
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
          if (!connected && canWrite)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.receivedBubble,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isGroup
                    ? 'Aucun membre à portée. Tes messages restent en attente '
                          'et partent dès que quelqu\'un du groupe est connecté.'
                    : 'Hors connexion. Tes messages et tes fichiers restent en '
                          'attente et partent dès que vous êtes de nouveau '
                          'connectés.',
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
                        if (!mine && m.isGroupMessage)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                m.senderName ?? 'Membre',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: _senderColor(
                                    m.senderId ?? '',
                                    Theme.of(context).brightness,
                                  ),
                                ),
                              ),
                            ),
                          ),
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
                            if (mine && _counts[m.id] != null) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${_counts[m.id]!.delivered}/${_counts[m.id]!.total}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.subtleText,
                                ),
                              ),
                            ],
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
          if (!canWrite)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  cannotWriteReason,
                  style: TextStyle(color: colors.subtleText),
                ),
              ),
            )
          else
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_recording)
                    Expanded(child: _recordingBar(colors))
                  else ...[
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
                  ],
                  const SizedBox(width: 6),
                  if (_hasText && !_recording)
                    IconButton.filled(
                      onPressed: _send,
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.send),
                    )
                  else
                    _micButton(scheme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

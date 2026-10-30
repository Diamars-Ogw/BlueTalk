import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';
import 'devices_screen.dart';
import 'diagnostics_screen.dart';
import 'theme.dart';

/// Une ligne de la liste : une personne ou un groupe.
class _Entry {
  _Entry({this.contact, this.group, this.last});

  final Contact? contact;
  final Group? group;
  final ChatMessage? last;

  String get id => group?.id ?? contact!.deviceId;
  String get title => group?.name ?? contact!.name;
}

class ContactsScreen extends StatefulWidget {
  const ContactsScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<_Entry> _entries = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final store = widget.controller.store;
    final contacts = await store.contacts();
    final groups = await store.groups();
    final entries = <_Entry>[];
    for (final c in contacts) {
      final ms = await store.messages(c.deviceId);
      entries.add(_Entry(contact: c, last: ms.isEmpty ? null : ms.last));
    }
    for (final g in groups) {
      final ms = await store.messages(g.id);
      entries.add(_Entry(group: g, last: ms.isEmpty ? null : ms.last));
    }
    entries.sort((a, b) {
      final ta = a.last?.at;
      final tb = b.last?.at;
      if (ta == null && tb == null) return a.title.compareTo(b.title);
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  void _open(_Entry e) {
    final c = widget.controller;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => e.group != null
            ? ChatScreen.group(c, e.group!)
            : ChatScreen(c, e.contact!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    final colors = ChatColors.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      // Retour sur l'écran principal : on met l'application de côté au lieu de
      // la fermer, pour que les connexions restent ouvertes.
      canPop: !c.keepRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) c.goToBackground();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.identity?.name ?? 'BlueTalk'),
          actions: [
            IconButton(
              tooltip: 'Nouveau groupe',
              icon: const Icon(Icons.group_add_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CreateGroupScreen(c),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Journal',
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DiagnosticsScreen(),
                ),
              ),
            ),
            IconButton(
              tooltip: isDark ? 'Thème clair' : 'Thème sombre',
              icon: Icon(
                isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              ),
              onPressed: () =>
                  c.setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
            ),
          ],
        ),
        body: Column(
          children: [
            SwitchListTile(
              title: const Text('Visible à proximité'),
              subtitle: Text(
                c.visible
                    ? 'Les autres utilisateurs de BlueTalk peuvent te trouver'
                    : 'Invisible : personne ne peut te trouver',
              ),
              value: c.visible,
              onChanged: c.setVisible,
            ),
            SwitchListTile(
              title: const Text('Rester connecté en arrière-plan'),
              subtitle: Text(
                c.keepRunning
                    ? (c.connectedCount == 0
                          ? 'Les connexions restent ouvertes quand tu quittes '
                                'l\'application'
                          : '${c.connectedCount} connexion(s) ouverte(s)'
                                '${c.detectedLimit != null ? ' · ce téléphone en accepte ${c.detectedLimit} au plus' : ''}')
                    : 'Les connexions s\'arrêtent quand tu quittes '
                          'l\'application',
              ),
              value: c.keepRunning,
              onChanged: c.setKeepRunning,
            ),
            if (c.lastError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  c.lastError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const Divider(),
            Expanded(
              child: _entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Aucune discussion pour l\'instant.\n\n'
                          'Appuie sur « Rechercher » pour trouver les '
                          'utilisateurs de BlueTalk à proximité, puis crée un '
                          'groupe avec eux.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.subtleText),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) =>
                          const Divider(indent: 72, endIndent: 0),
                      itemBuilder: (context, i) => _tile(_entries[i], c, theme, colors),
                    ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => DevicesScreen(c)),
          ),
          icon: const Icon(Icons.bluetooth_searching),
          label: const Text('Rechercher'),
        ),
      ),
    );
  }

  Widget _tile(_Entry e, AppController c, ThemeData theme, ChatColors colors) {
    final m = e.last;
    final g = e.group;
    final initial = e.title.isEmpty
        ? '?'
        : String.fromCharCode(e.title.runes.first).toUpperCase();

    final String subtitle;
    if (m == null) {
      subtitle = g != null ? '${g.members.length} membres' : 'Nouveau contact';
    } else {
      subtitle = _preview(m, group: g != null);
    }

    final bool online;
    if (g != null) {
      online = g.active && c.connectedMembers(g) > 0;
    } else {
      online = c.isConnected(e.contact!.deviceId);
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.18),
        foregroundColor: theme.colorScheme.primary,
        child: g != null
            ? const Icon(Icons.group)
            : Text(
                initial,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
      title: Text(
        e.title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.subtleText),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (m != null)
            Text(
              TimeOfDay.fromDateTime(m.at).format(context),
              style: TextStyle(fontSize: 12, color: colors.subtleText),
            ),
          if (online)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(
                Icons.circle,
                size: 10,
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
      onTap: () => _open(e),
    );
  }
}

String _preview(ChatMessage m, {bool group = false}) {
  final String who;
  if (m.outgoing) {
    who = 'Toi : ';
  } else if (group && m.senderName != null) {
    who = '${m.senderName} : ';
  } else {
    who = '';
  }
  switch (m.kind) {
    case MessageKind.text:
      return '$who${m.text}';
    case MessageKind.image:
      return '${who}Image';
    case MessageKind.audio:
      return '${who}Message vocal';
    case MessageKind.file:
      return '$who${m.fileName ?? 'Fichier'}';
  }
}

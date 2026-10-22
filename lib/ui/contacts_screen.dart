import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'chat_screen.dart';
import 'devices_screen.dart';
import 'theme.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<Contact> _contacts = [];
  Map<String, ChatMessage> _last = {};

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
    final last = <String, ChatMessage>{};
    for (final c in contacts) {
      final ms = await store.messages(c.deviceId);
      if (ms.isNotEmpty) last[c.deviceId] = ms.last;
    }
    contacts.sort((a, b) {
      final ta = last[a.deviceId]?.at;
      final tb = last[b.deviceId]?.at;
      if (ta == null && tb == null) return a.name.compareTo(b.name);
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _last = last;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    final colors = ChatColors.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(c.identity?.name ?? 'BlueTalk'),
        actions: [
          IconButton(
            tooltip: isDark ? 'Thème clair' : 'Thème sombre',
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
            onPressed: () =>
                c.setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
          ),
          /*IconButton(
            tooltip: 'Test Bluetooth sans association',
            icon: const Icon(Icons.radar),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => BleTestScreen(c))),
          ),*/
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
            child: _contacts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Aucun contact pour l\'instant.\n\n'
                        'Appuie sur « Rechercher » pour trouver les '
                        'utilisateurs de BlueTalk à proximité.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.subtleText),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _contacts.length,
                    separatorBuilder: (_, _) =>
                        const Divider(indent: 72, endIndent: 0),
                    itemBuilder: (context, i) {
                      final k = _contacts[i];
                      final m = _last[k.deviceId];
                      final initial = k.name.isEmpty
                          ? '?'
                          : String.fromCharCode(k.name.runes.first)
                                .toUpperCase();
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: theme.colorScheme.primary.withValues(
                            alpha: 0.18,
                          ),
                          foregroundColor: theme.colorScheme.primary,
                          child: Text(
                            initial,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        title: Text(
                          k.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          m == null ? 'Nouveau contact' : _preview(m),
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
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.subtleText,
                                ),
                              ),
                            if (c.isConnected(k.deviceId))
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
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChatScreen(c, k),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => DevicesScreen(c))),
        icon: const Icon(Icons.bluetooth_searching),
        label: const Text('Rechercher'),
      ),
    );
  }
}

String _preview(ChatMessage m) {
  final who = m.outgoing ? 'Toi : ' : '';
  switch (m.kind) {
    case MessageKind.text:
      return '$who${m.text}';
    case MessageKind.image:
      return '${who}Image';
    case MessageKind.file:
      return '$who${m.fileName ?? 'Fichier'}';
  }
}

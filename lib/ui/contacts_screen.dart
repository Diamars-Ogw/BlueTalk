import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'chat_screen.dart';
import 'devices_screen.dart';

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
    // Les conversations les plus récentes en premier.
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
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(c.identity?.name ?? 'BlueTalk')),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Attendre une connexion'),
            subtitle: Text(
              c.hasActiveConnection
                  ? 'Connecté'
                  : c.listening
                  ? 'En attente d\'un autre téléphone…'
                  : 'Désactivé',
            ),
            value: c.listening,
            onChanged: (v) => v ? c.startListening() : c.stopListening(),
          ),
          if (c.lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(c.lastError!, style: TextStyle(color: scheme.error)),
            ),
          const Divider(height: 1),
          Expanded(
            child: _contacts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Aucun contact pour l\'instant.\n\n'
                        'Sur un téléphone, active « Attendre une connexion ». '
                        'Sur l\'autre, touche « Se connecter ».',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _contacts.length,
                    itemBuilder: (context, i) {
                      final k = _contacts[i];
                      final m = _last[k.deviceId];
                      final initial = k.name.isEmpty
                          ? '?'
                          : String.fromCharCode(k.name.runes.first)
                                .toUpperCase();
                      return ListTile(
                        leading: CircleAvatar(child: Text(initial)),
                        title: Text(k.name),
                        subtitle: Text(
                          m == null
                              ? 'Nouveau contact'
                              : '${m.outgoing ? 'Toi : ' : ''}${m.text}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: c.isConnected(k.deviceId)
                            ? const Icon(
                                Icons.circle,
                                size: 12,
                                color: Colors.green,
                              )
                            : null,
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
        label: const Text('Se connecter'),
      ),
    );
  }
}

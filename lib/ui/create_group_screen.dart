import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'chat_screen.dart';
import 'theme.dart';

/// Crée un groupe : un nom, et des personnes déjà rencontrées.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController _name = TextEditingController();
  List<Contact> _contacts = [];
  final Set<String> _chosen = {};
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await widget.controller.store.contacts();
    if (!mounted) return;
    setState(() {
      _contacts = list;
      _loaded = true;
    });
  }

  bool get _canCreate =>
      !_busy && _name.text.trim().isNotEmpty && _chosen.isNotEmpty;

  Future<void> _create() async {
    setState(() => _busy = true);
    final members = _contacts.where((c) => _chosen.contains(c.deviceId)).toList();
    final g = await widget.controller.createGroup(_name.text, members);
    if (!mounted) return;
    if (g == null) {
      setState(() => _busy = false);
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen.group(widget.controller, g),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ChatColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau groupe')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Nom du groupe',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Membres (${_chosen.length})',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colors.subtleText,
                ),
              ),
            ),
          ),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : _contacts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Tu n\'as encore rencontré personne.\n\n'
                        'Utilise « Rechercher » pour te connecter une première '
                        'fois à chaque personne : elle apparaîtra alors ici.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.subtleText),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final c in _contacts)
                        CheckboxListTile(
                          value: _chosen.contains(c.deviceId),
                          title: Text(c.name),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _chosen.add(c.deviceId);
                            } else {
                              _chosen.remove(c.deviceId);
                            }
                          }),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _canCreate ? _create : null,
                  child: const Text('Créer le groupe'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

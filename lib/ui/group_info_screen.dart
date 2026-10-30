import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../chat/models.dart';
import 'theme.dart';

/// Les membres d'un groupe et son administration.
///
/// - Le créateur peut tout faire : renommer, ajouter et retirer des membres,
///   nommer ou retirer des administrateurs, activer le mode annonces,
///   supprimer le groupe pour tout le monde.
/// - Un administrateur peut renommer, ajouter et retirer des membres (pas le
///   créateur ni un autre administrateur) et activer le mode annonces.
/// - Les autres membres peuvent quitter le groupe.
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen(this.controller, this.groupId, {super.key});

  final AppController controller;
  final String groupId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  Group? _group;

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
    final g = await widget.controller.store.group(widget.groupId);
    if (!mounted) return;
    setState(() => _group = g);
  }

  String get _me => widget.controller.identity?.deviceId ?? '';

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Applique une modification ; affiche une erreur si elle est refusée.
  Future<void> _apply(Future<Group?> Function() change) async {
    final result = await change();
    if (result == null) _snack('Modification refusée.');
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _rename(Group g) async {
    final text = TextEditingController(text: g.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nom du groupe'),
        content: TextField(
          controller: text,
          maxLength: 40,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, text.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    text.dispose();
    if (name == null || name.trim().isEmpty || name.trim() == g.name) return;
    await _apply(() => widget.controller.updateGroup(g, name: name));
  }

  Future<void> _add(Group g) async {
    final all = await widget.controller.store.contacts();
    final candidates = all.where((c) => !g.hasMember(c.deviceId)).toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      _snack('Tous tes contacts sont déjà dans le groupe.');
      return;
    }
    final picked = await showModalBottomSheet<Contact>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Ajouter au groupe')),
            for (final c in candidates)
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: Text(c.name),
                onTap: () => Navigator.pop(sheet, c),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _apply(() => widget.controller.addMember(g, picked));
  }

  Future<void> _memberAction(Group g, GroupMember m, String action) async {
    final c = widget.controller;
    switch (action) {
      case 'promote':
        await _apply(() => c.setAdmin(g, m.deviceId, true));
      case 'demote':
        await _apply(() => c.setAdmin(g, m.deviceId, false));
      case 'remove':
        if (await _confirm(
          'Retirer ${m.name} ?',
          'Il ne recevra plus les messages du groupe.',
          'Retirer',
        )) {
          await _apply(() => c.removeMember(g, m.deviceId));
        }
    }
  }

  Future<void> _leave(Group g) async {
    if (!await _confirm(
      'Quitter le groupe ?',
      'Tu ne recevras plus ses messages. L\'historique reste lisible.',
      'Quitter',
    )) {
      return;
    }
    await widget.controller.leaveGroup(g);
  }

  Future<void> _closeForAll(Group g) async {
    if (!await _confirm(
      'Supprimer le groupe pour tout le monde ?',
      'Plus personne ne pourra y écrire. Chacun garde son historique '
          'jusqu\'à ce qu\'il le supprime de son téléphone.',
      'Supprimer pour tous',
    )) {
      return;
    }
    final ok = await widget.controller.closeGroup(g);
    if (!ok) _snack('Suppression refusée.');
  }

  Future<void> _deleteLocal(Group g) async {
    if (!await _confirm(
      'Supprimer de ce téléphone ?',
      'Le groupe et son historique seront effacés de ce téléphone.',
      'Supprimer',
    )) {
      return;
    }
    await widget.controller.deleteGroup(g.id);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final g = _group;
    final c = widget.controller;
    final colors = ChatColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (g == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Groupe')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final iAmCreator = g.creatorId == _me;
    final iAmAdmin = g.isAdmin(_me);
    final canManage = iAmAdmin && g.active;

    String roleOf(GroupMember m) {
      if (m.deviceId == g.creatorId) return 'Créateur';
      if (g.admins.contains(m.deviceId)) return 'Administrateur';
      return '';
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Infos du groupe')),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: scheme.primary.withValues(alpha: 0.18),
              foregroundColor: scheme.primary,
              child: const Icon(Icons.group),
            ),
            title: Text(
              g.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
            subtitle: Text(
              g.closed
                  ? 'Groupe supprimé par son créateur'
                  : g.active
                  ? '${g.members.length} membres'
                  : 'Tu n\'es plus dans ce groupe',
              style: TextStyle(color: colors.subtleText),
            ),
            trailing: canManage
                ? IconButton(
                    tooltip: 'Renommer',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _rename(g),
                  )
                : null,
          ),
          if (g.active) ...[
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.campaign_outlined),
              title: const Text('Seuls les administrateurs peuvent écrire'),
              subtitle: Text(
                canManage
                    ? 'Mode annonces : les autres membres lisent seulement.'
                    : (g.adminsOnlyPost
                          ? 'Mode annonces activé par un administrateur.'
                          : 'Tous les membres peuvent écrire.'),
              ),
              value: g.adminsOnlyPost,
              onChanged: canManage
                  ? (v) => _apply(() => c.setAdminsOnlyPost(g, v))
                  : null,
            ),
          ],
          const Divider(),
          if (canManage)
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: const Text('Ajouter un membre'),
              onTap: () => _add(g),
            ),
          for (final m in g.members)
            ListTile(
              leading: CircleAvatar(
                child: Text(
                  m.name.isEmpty
                      ? '?'
                      : String.fromCharCode(m.name.runes.first).toUpperCase(),
                ),
              ),
              title: Text(m.deviceId == _me ? '${m.name} (toi)' : m.name),
              subtitle: Text(
                [
                  roleOf(m),
                  if (m.deviceId != _me && c.isConnected(m.deviceId))
                    'connecté',
                ].where((t) => t.isNotEmpty).join(' · '),
                style: TextStyle(color: colors.subtleText),
              ),
              trailing: _memberMenu(g, m, iAmCreator, canManage),
            ),
          const Divider(),
          if (g.active && !iAmCreator)
            ListTile(
              leading: Icon(Icons.logout, color: scheme.error),
              title: Text(
                'Quitter le groupe',
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => _leave(g),
            ),
          if (g.active && iAmCreator)
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
              title: Text(
                'Supprimer le groupe pour tout le monde',
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => _closeForAll(g),
            ),
          if (!g.active)
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(
                'Supprimer de ce téléphone',
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => _deleteLocal(g),
            ),
        ],
      ),
    );
  }

  /// Le menu d'un membre : ce que le créateur ou un administrateur peut faire.
  Widget? _memberMenu(
    Group g,
    GroupMember m,
    bool iAmCreator,
    bool canManage,
  ) {
    if (!canManage || m.deviceId == _me || m.deviceId == g.creatorId) {
      return null;
    }
    final targetIsAdmin = g.admins.contains(m.deviceId);
    final entries = <PopupMenuEntry<String>>[
      if (iAmCreator && !targetIsAdmin)
        const PopupMenuItem(value: 'promote', child: Text('Nommer administrateur')),
      if (iAmCreator && targetIsAdmin)
        const PopupMenuItem(
          value: 'demote',
          child: Text('Retirer des administrateurs'),
        ),
      if (iAmCreator || !targetIsAdmin)
        const PopupMenuItem(value: 'remove', child: Text('Retirer du groupe')),
    ];
    if (entries.isEmpty) return null;
    return PopupMenuButton<String>(
      tooltip: 'Gérer ${m.name}',
      onSelected: (a) => _memberAction(g, m, a),
      itemBuilder: (_) => entries,
    );
  }
}

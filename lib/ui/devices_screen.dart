import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../bluetooth/ble_bridge.dart';
import '../bluetooth/bluetooth_bridge.dart';
import 'theme.dart';

String _proximity(int rssi) =>
    rssi > -60 ? 'très proche' : (rssi > -75 ? 'proche' : 'plus loin');

class DevicesScreen extends StatefulWidget {
  const DevicesScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Timer? _tick;
  List<BtDevice>? _bonded;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    unawaited(widget.controller.startScan());
    // La liste se rafraîchit pour retirer ceux qui ne sont plus à portée.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.controller.removeListener(_refresh);
    unawaited(widget.controller.stopScan());
    super.dispose();
  }

  Future<void> _connectNearby(NearbyUser u) async {
    setState(() => _busy = true);
    final ok = await widget.controller.connectNearby(u);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadBonded() async {
    final d = await widget.controller.bondedDevices();
    if (!mounted) return;
    setState(() => _bonded = d);
  }

  Future<void> _connectBonded(BtDevice d) async {
    setState(() => _busy = true);
    await widget.controller.connectTo(d);
    if (!mounted) return;
    if (widget.controller.lastError == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final colors = ChatColors.of(context);
    final users = c.nearbyUsers;

    return Scaffold(
      appBar: AppBar(title: const Text('Rechercher')),
      body: ListView(
        children: [
          if (c.scanning || _busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Les utilisateurs de BlueTalk à proximité apparaissent ici. '
              'Chacun doit avoir l\'application ouverte et « Visible à '
              'proximité » activé.',
              style: TextStyle(color: colors.subtleText),
            ),
          ),
          if (c.lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                c.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (users.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  c.scanning
                      ? 'Recherche en cours…'
                      : 'Personne pour l\'instant.',
                  style: TextStyle(color: colors.subtleText),
                ),
              ),
            ),
          for (final u in users)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.18),
                foregroundColor: Theme.of(context).colorScheme.primary,
                child: Text(
                  u.name.isEmpty
                      ? '?'
                      : String.fromCharCode(u.name.runes.first).toUpperCase(),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              title: Text(
                u.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _proximity(u.rssi),
                style: TextStyle(color: colors.subtleText),
              ),
              onTap: _busy ? null : () => _connectNearby(u),
            ),
          const Divider(),
          ExpansionTile(
            title: const Text('Mode de secours (association Bluetooth)'),
            subtitle: const Text(
              'À utiliser si la recherche ne trouve personne',
            ),
            onExpansionChanged: (open) {
              if (open && _bonded == null) _loadBonded();
            },
            children: [
              SwitchListTile(
                title: const Text('Attendre une connexion'),
                subtitle: const Text(
                  'L\'autre téléphone doit déjà être associé au tien dans les '
                  'réglages Bluetooth d\'Android.',
                ),
                value: c.listening,
                onChanged: (v) => v ? c.startListening() : c.stopListening(),
              ),
              if (_bonded != null)
                for (final d in _bonded!)
                  ListTile(
                    leading: const Icon(Icons.phone_android),
                    title: Text(d.name),
                    subtitle: Text(d.address),
                    onTap: _busy ? null : () => _connectBonded(d),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

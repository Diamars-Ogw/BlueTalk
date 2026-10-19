import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../bluetooth/bluetooth_bridge.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<BtDevice>? _devices;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await widget.controller.bondedDevices();
    if (!mounted) return;
    setState(() => _devices = d);
  }

  Future<void> _connect(BtDevice d) async {
    setState(() => _busy = true);
    await widget.controller.connectTo(d);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    return Scaffold(
      appBar: AppBar(title: const Text('Se connecter')),
      body: devices == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_busy) const LinearProgressIndicator(),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Choisis le téléphone de ton contact. Il doit avoir activé '
                    '« Attendre une connexion ». Pour l\'instant, seuls les '
                    'appareils déjà associés apparaissent ; la recherche '
                    'automatique viendra ensuite.',
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final d in devices)
                        ListTile(
                          leading: const Icon(Icons.phone_android),
                          title: Text(d.name),
                          subtitle: Text(d.address),
                          onTap: _busy ? null : () => _connect(d),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

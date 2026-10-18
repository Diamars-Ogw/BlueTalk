import 'dart:async';

import 'package:flutter/material.dart';

import 'bluetooth/bluetooth_bridge.dart';
import 'protocol/session.dart';

void main() => runApp(const MaterialApp(home: BtTestPage()));

class BtTestPage extends StatefulWidget {
  const BtTestPage({super.key});
  @override
  State<BtTestPage> createState() => _BtTestPageState();
}

class _BtTestPageState extends State<BtTestPage> {
  final _bt = BluetoothBridge.instance;
  final _log = <String>[];
  final _input = TextEditingController();
  List<BtDevice> _devices = [];
  Session? _session;
  bool _listening = false;
  bool _busy = false;
  int _n = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _add(String s) {
    if (!mounted) return;
    setState(() => _log.insert(0, s));
  }

  Future<void> _prepare() async {
    try {
      if (!await _bt.ensurePermissions()) {
        _add('Permission Bluetooth refusée');
        return;
      }
      if (!await _bt.isEnabled()) {
        _add('Active le Bluetooth du téléphone');
        return;
      }
      final d = await _bt.bondedDevices();
      if (!mounted) return;
      setState(() => _devices = d);
      _add('${d.length} appareil(s) associé(s)');
    } catch (e) {
      _add('Erreur : $e');
    }
  }

  void _attach(BluetoothTransport t) {
    final s = Session(t);
    _session = s;
    _add('Connecté à ${t.remoteName}');
    s.frames.listen(
      (f) => _add('← trame ${f.type}, ${f.payload.length} octets'),
    );
    s.texts.listen((m) => _add('← ${m['text']}'));
    s.done.then((_) {
      if (identical(_session, s)) {
        _session = null;
        _add('Déconnecté');
        if (mounted) setState(() {});
      }
    });
    s.sendHello(deviceId: 'test', name: 'Téléphone').catchError((_) {});
    if (mounted) setState(() {});
  }

  Future<void> _listen() async {
    setState(() => _listening = true);
    _add('En attente d\'une connexion…');
    try {
      _attach(await _bt.listen());
    } catch (e) {
      _add('Attente : $e');
    }
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _connect(BtDevice d) async {
    setState(() => _busy = true);
    _add('Connexion à ${d.name}…');
    try {
      _attach(await _bt.connect(d.address));
    } catch (e) {
      _add('Connexion : $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _ping() async {
    final s = _session;
    if (s == null) return;
    try {
      final dt = await s.ping();
      _add('PONG reçu en ${dt.inMilliseconds} ms');
    } catch (e) {
      _add('PING : $e');
    }
  }

  Future<void> _sendText() async {
    final s = _session;
    final text = _input.text;
    if (s == null || text.isEmpty) return;
    _input.clear();
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_n++}';
    try {
      await s.sendText(id, text);
      _add('→ $text  (reçu ✓)');
    } on TimeoutException {
      _add('→ $text  (pas d\'accusé)');
    } catch (e) {
      _add('Envoi : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _session != null;
    return Scaffold(
      appBar: AppBar(title: const Text('BlueTalk – test Bluetooth')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (!connected) ...[
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: (_listening || _busy) ? null : _listen,
                    child: const Text('Attendre une connexion'),
                  ),
                  if (_listening)
                    OutlinedButton(
                      onPressed: _bt.stopListening,
                      child: const Text('Annuler'),
                    ),
                  TextButton(
                    onPressed: _prepare,
                    child: const Text('Actualiser'),
                  ),
                ],
              ),
              SizedBox(
                height: 150,
                child: ListView(
                  children: [
                    for (final d in _devices)
                      ListTile(
                        dense: true,
                        title: Text(d.name),
                        subtitle: Text(d.address),
                        onTap: (_listening || _busy) ? null : () => _connect(d),
                      ),
                  ],
                ),
              ),
            ] else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(hintText: 'Message'),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  IconButton(
                    onPressed: _sendText,
                    icon: const Icon(Icons.send),
                  ),
                  TextButton(onPressed: _ping, child: const Text('PING')),
                  TextButton(
                    onPressed: () => _session?.close(),
                    child: const Text('Couper'),
                  ),
                ],
              ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Text(_log[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

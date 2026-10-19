import 'package:flutter/material.dart';

import '../app/app_controller.dart';

class NameScreen extends StatefulWidget {
  const NameScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  final TextEditingController _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final n = _name.text.trim();
    if (n.length < 2 || _busy) return;
    setState(() => _busy = true);
    await widget.controller.setName(n);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Bienvenue sur BlueTalk',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text('Choisis le nom que les autres verront.'),
              const SizedBox(height: 24),
              TextField(
                controller: _name,
                maxLength: 30,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nom d\'utilisateur',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _continue(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _continue,
                child: const Text('Continuer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

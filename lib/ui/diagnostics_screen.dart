import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/diagnostics.dart';
import 'theme.dart';

/// Le journal de bord : connexions, coupures et transferts. Utile pour
/// comprendre pourquoi une liaison s'est coupée : on peut le copier et me
/// l'envoyer.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Diagnostics.instance.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = Diagnostics.instance.lines.reversed.toList();
    final colors = ChatColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Journal'),
        actions: [
          IconButton(
            tooltip: 'Copier tout',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: Diagnostics.instance.dump()),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Journal copié.')),
              );
            },
          ),
          IconButton(
            tooltip: 'Effacer',
            icon: const Icon(Icons.delete_outline),
            onPressed: Diagnostics.instance.clear,
          ),
        ],
      ),
      body: lines.isEmpty
          ? Center(
              child: Text(
                'Rien pour l\'instant.',
                style: TextStyle(color: colors.subtleText),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: lines.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  lines[i],
                  style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: colors.text,
                  ),
                ),
              ),
            ),
    );
  }
}

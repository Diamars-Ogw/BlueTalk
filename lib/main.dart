import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'ui/contacts_screen.dart';
import 'ui/name_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await AppController.start();
  runApp(BlueTalkApp(controller));
}

class BlueTalkApp extends StatelessWidget {
  const BlueTalkApp(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BlueTalk',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1F7A5C)),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.identity == null
            ? NameScreen(controller)
            : ContactsScreen(controller),
      ),
    );
  }
}

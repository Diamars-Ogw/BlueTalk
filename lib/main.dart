import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'ui/contacts_screen.dart';
import 'ui/name_screen.dart';
import 'ui/theme.dart';

import 'dart:async';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await AppController.start();
  runApp(BlueTalkApp(controller));
  unawaited(controller.restoreVisibility());
}

class BlueTalkApp extends StatelessWidget {
  const BlueTalkApp(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: 'BlueTalk',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: controller.themeMode,
        home: controller.identity == null
            ? NameScreen(controller)
            : ContactsScreen(controller),
      ),
    );
  }
}

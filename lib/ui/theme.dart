import 'package:flutter/material.dart';

/// Couleurs propres aux conversations, selon le thème.
class ChatColors {
  const ChatColors({
    required this.chatBackground,
    required this.sentBubble,
    required this.receivedBubble,
    required this.text,
    required this.subtleText,
    required this.tick,
    required this.inputFill,
  });

  final Color chatBackground;
  final Color sentBubble;
  final Color receivedBubble;
  final Color text;
  final Color subtleText;
  final Color tick;
  final Color inputFill;

  static const light = ChatColors(
    chatBackground: Color(0xFFEFEAE2),
    sentBubble: Color(0xFFD9FDD3),
    receivedBubble: Color(0xFFFFFFFF),
    text: Color(0xFF111B21),
    subtleText: Color(0xFF667781),
    tick: Color(0xFF1E7A4F),
    inputFill: Color(0xFFFFFFFF),
  );

  static const dark = ChatColors(
    chatBackground: Color(0xFF0B141A),
    sentBubble: Color(0xFF005C4B),
    receivedBubble: Color(0xFF1F2C34),
    text: Color(0xFFE9EDEF),
    subtleText: Color(0xFF8696A0),
    tick: Color(0xFF7FE3B0),
    inputFill: Color(0xFF1F2C34),
  );

  static ChatColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final green = dark ? const Color(0xFF2FB36D) : const Color(0xFF1E7A4F);
  final onGreen = dark ? const Color(0xFF06140D) : Colors.white;
  final surface = dark ? const Color(0xFF111B21) : Colors.white;
  final onSurface = dark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: green,
    onPrimary: onGreen,
    secondary: green,
    onSecondary: onGreen,
    error: dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E),
    onError: dark ? const Color(0xFF3B0A06) : Colors.white,
    surface: surface,
    onSurface: onSurface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Roboto',
    scaffoldBackgroundColor: surface,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF1F2C34) : const Color(0xFF1E7A4F),
      foregroundColor: dark ? const Color(0xFFE9EDEF) : Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF22303A) : const Color(0xFFE6E2DB),
      space: 1,
      thickness: 1,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: green,
      foregroundColor: onGreen,
      elevation: 2,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? onGreen : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? green : null,
      ),
    ),
  );
}

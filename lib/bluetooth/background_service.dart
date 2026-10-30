import 'dart:async';

import 'package:flutter/services.dart';

/// Présence en arrière-plan (Android) : service de premier plan avec sa
/// notification permanente, notifications de messages, et mise de côté de
/// l'application avec le bouton Retour.
class BackgroundService {
  BackgroundService._();

  static final BackgroundService instance = BackgroundService._();

  static const MethodChannel _channel = MethodChannel('bluetalk/service');

  /// Démarre le service (ou met à jour le texte de sa notification).
  /// Renvoie faux si Android l'a refusé.
  Future<bool> start(String text) async {
    try {
      return await _channel.invokeMethod<bool>('start', {'text': text}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Affiche une notification de message.
  Future<void> notify({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      await _channel.invokeMethod<void>('notify', {
        'id': id,
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  /// Demande l'autorisation d'afficher des notifications (Android 13+).
  Future<bool> ensureNotifications() async {
    try {
      return await _channel.invokeMethod<bool>('ensureNotifications') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Met l'application en arrière-plan sans la fermer.
  Future<void> moveToBack() async {
    try {
      await _channel.invokeMethod<void>('moveToBack');
    } catch (_) {}
  }
}

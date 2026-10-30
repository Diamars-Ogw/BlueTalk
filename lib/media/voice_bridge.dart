import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Un enregistrement terminé.
class VoiceClip {
  const VoiceClip({required this.path, required this.durationMs});

  final String path;
  final int durationMs;
}

/// Messages vocaux, côté Android : enregistrement et lecture.
class VoiceBridge {
  VoiceBridge._();

  static final VoiceBridge instance = VoiceBridge._();

  static const MethodChannel _channel = MethodChannel('bluetalk/audio');

  Future<bool> ensurePermission() async {
    try {
      return await _channel.invokeMethod<bool>('ensurePermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Démarre l'enregistrement. Renvoie faux si le micro est refusé ou occupé.
  Future<bool> startRecording() async {
    try {
      return await _channel.invokeMethod<String>('startRecording') != null;
    } catch (_) {
      return false;
    }
  }

  /// Arrête l'enregistrement. Renvoie null si rien d'exploitable n'a été capté.
  Future<VoiceClip?> stopRecording() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'stopRecording',
      );
      if (r == null) return null;
      return VoiceClip(
        path: r['path'] as String,
        durationMs: r['durationMs'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> cancelRecording() async {
    try {
      await _channel.invokeMethod<void>('cancelRecording');
    } catch (_) {}
  }

  /// Joue un fichier audio. Renvoie sa durée en millisecondes.
  Future<int> play(String path, {int from = 0}) async =>
      await _channel.invokeMethod<int>('play', {'path': path, 'from': from}) ??
      0;

  Future<void> pause() => _channel.invokeMethod<void>('pause');

  Future<void> resume() => _channel.invokeMethod<void>('resume');

  Future<void> stopPlayback() => _channel.invokeMethod<void>('stopPlayback');

  Future<void> seek(int ms) =>
      _channel.invokeMethod<void>('seek', {'ms': ms});

  Future<VoiceState> state() async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('state');
    if (r == null) return const VoiceState(false, 0, 0, true);
    return VoiceState(
      r['playing'] as bool,
      r['position'] as int,
      r['duration'] as int,
      r['done'] as bool,
    );
  }
}

class VoiceState {
  const VoiceState(this.playing, this.positionMs, this.durationMs, this.done);

  final bool playing;
  final int positionMs;
  final int durationMs;
  final bool done;
}

/// Lecture d'un message vocal à la fois, avec sa position, pour afficher la
/// barre de progression dans les bulles.
class VoicePlayer extends ChangeNotifier {
  VoicePlayer._();

  static final VoicePlayer instance = VoicePlayer._();

  final VoiceBridge _bridge = VoiceBridge.instance;
  Timer? _timer;

  /// Identifiant du message en cours de lecture (ou en pause).
  String? currentId;
  bool playing = false;
  int positionMs = 0;
  int durationMs = 0;

  /// Lance, met en pause ou reprend la lecture de ce message.
  Future<void> toggle(String id, String path) async {
    try {
      if (currentId == id) {
        if (playing) {
          await _bridge.pause();
          playing = false;
          _timer?.cancel();
        } else {
          await _bridge.resume();
          playing = true;
          _startTimer();
        }
        notifyListeners();
        return;
      }
      durationMs = await _bridge.play(path);
      currentId = id;
      playing = true;
      positionMs = 0;
      _startTimer();
      notifyListeners();
    } catch (_) {
      await stop();
    }
  }

  Future<void> seek(String id, double fraction) async {
    if (currentId != id || durationMs <= 0) return;
    final ms = (durationMs * fraction.clamp(0.0, 1.0)).round();
    try {
      await _bridge.seek(ms);
      positionMs = ms;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> stop() async {
    _timer?.cancel();
    currentId = null;
    playing = false;
    positionMs = 0;
    durationMs = 0;
    try {
      await _bridge.stopPlayback();
    } catch (_) {}
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
      try {
        final s = await _bridge.state();
        if (s.done) {
          await stop();
          return;
        }
        positionMs = s.positionMs;
        if (s.durationMs > 0) durationMs = s.durationMs;
        playing = s.playing;
        notifyListeners();
      } catch (_) {
        await stop();
      }
    });
  }
}

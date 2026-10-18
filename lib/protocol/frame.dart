import 'dart:convert';
import 'dart:typed_data';

/// Version du protocole, écrite dans chaque trame.
const int protocolVersion = 1;

/// Taille de l'en-tête : version (1) + type (1) + longueur (4).
const int headerSize = 6;

/// Taille maximale d'un contenu. Elle ne sert pas à limiter les messages
/// des utilisateurs, mais à refuser une longueur absurde venant d'une
/// trame corrompue, au lieu d'attendre des milliards d'octets.
const int maxPayloadSize = 8 * 1024 * 1024;

/// Identifiants des types de trames. Ce sont de simples entiers (et non un
/// enum) pour qu'une trame de type inconnu puisse être reçue sans erreur.
abstract final class FrameType {
  static const int hello = 1;
  static const int text = 2;
  static const int ack = 3;
  static const int ping = 4;
  static const int pong = 5;
  static const int fileOffer = 10;
  static const int fileChunk = 11;
  static const int fileEnd = 12;
  static const int fileAbort = 13;

  /// Octets bruts libres, utile pour le mode test.
  static const int raw = 20;
}

/// Erreur de protocole : la connexion doit être fermée, car on ne sait
/// plus où commence la trame suivante.
class ProtocolException implements Exception {
  final String message;
  ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

/// Une trame : un type et un contenu.
class Frame {
  final int type;
  final Uint8List payload;
  const Frame(this.type, this.payload);

  /// Trame dont le contenu est un objet JSON (trames de contrôle, texte).
  factory Frame.json(int type, Map<String, dynamic> data) =>
      Frame(type, Uint8List.fromList(utf8.encode(jsonEncode(data))));

  /// Message texte. Le texte est libre : rien n'est filtré ni interprété.
  factory Frame.text(String id, String text, {DateTime? at}) =>
      Frame.json(FrameType.text, {
        'id': id,
        'text': text,
        'ts': (at ?? DateTime.now()).millisecondsSinceEpoch,
      });

  /// Trame d'octets bruts.
  factory Frame.raw(List<int> bytes) =>
      Frame(FrameType.raw, Uint8List.fromList(bytes));

  /// Lit le contenu comme un objet JSON.
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
}

/// Transforme une trame en octets prêts à être écrits sur le canal.
Uint8List encodeFrame(Frame frame) {
  if (frame.type < 0 || frame.type > 255) {
    throw ProtocolException('Type de trame invalide : ${frame.type}');
  }
  if (frame.payload.length > maxPayloadSize) {
    throw ProtocolException(
        'Contenu trop grand : ${frame.payload.length} octets');
  }
  final out = Uint8List(headerSize + frame.payload.length);
  final header = ByteData.sublistView(out);
  header.setUint8(0, protocolVersion);
  header.setUint8(1, frame.type);
  header.setUint32(2, frame.payload.length, Endian.big);
  out.setRange(headerSize, out.length, frame.payload);
  return out;
}

/// Reconstitue les trames à partir d'un flux d'octets arrivant en morceaux
/// de taille quelconque. À chaque morceau reçu, appeler [feed].
class FrameDecoder {
  Uint8List _buf = Uint8List(4096);
  int _start = 0;
  int _end = 0;

  /// Ajoute des octets et renvoie toutes les trames désormais complètes
  /// (aucune, une, ou plusieurs). Lève [ProtocolException] si le flux est
  /// invalide : il faut alors fermer la connexion.
  List<Frame> feed(List<int> data) {
    _append(data);
    final frames = <Frame>[];
    while (true) {
      final available = _end - _start;
      if (available < headerSize) break;

      final header = ByteData.sublistView(_buf, _start, _start + headerSize);
      final version = header.getUint8(0);
      final type = header.getUint8(1);
      final length = header.getUint32(2, Endian.big);

      if (version != protocolVersion) {
        throw ProtocolException('Version non supportée : $version');
      }
      if (length > maxPayloadSize) {
        throw ProtocolException('Longueur invalide : $length');
      }
      if (available < headerSize + length) break; // trame pas encore complète

      final from = _start + headerSize;
      frames.add(Frame(type, _buf.sublist(from, from + length)));
      _start += headerSize + length;
    }
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return frames;
  }

  void _append(List<int> data) {
    if (data.isEmpty) return;
    final pending = _end - _start;
    final needed = pending + data.length;
    if (_end + data.length > _buf.length) {
      if (needed <= _buf.length) {
        // Assez de place : on ramène les octets en attente au début.
        _buf.setRange(0, pending, _buf, _start);
      } else {
        var size = _buf.length;
        while (size < needed) {
          size *= 2;
        }
        final bigger = Uint8List(size);
        bigger.setRange(0, pending, _buf, _start);
        _buf = bigger;
      }
      _start = 0;
      _end = pending;
    }
    _buf.setRange(_end, _end + data.length, data);
    _end += data.length;
  }
}
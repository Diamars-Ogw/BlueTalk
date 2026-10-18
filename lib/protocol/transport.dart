import 'dart:typed_data';

/// Un canal d'octets bidirectionnel. Le vrai Bluetooth et le faux canal
/// de test l'implémentent tous les deux.
abstract interface class Transport {
  /// Octets reçus, par morceaux de taille quelconque. Le flux se termine
  /// quand la connexion est coupée.
  Stream<Uint8List> get incoming;

  /// Écrit des octets sur le canal. Deux appels successifs ne se mélangent
  /// jamais : le deuxième attend la fin du premier.
  Future<void> send(Uint8List bytes);

  Future<void> close();
}
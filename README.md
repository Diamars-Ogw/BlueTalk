# BlueTalk

Messagerie hors ligne par Bluetooth pour Android : messages, images et documents
entre deux téléphones proches, sans Internet ni serveur.

## Fonctions

- Nom d'utilisateur choisi au premier lancement, visible des autres utilisateurs à proximité.
- Recherche des utilisateurs BlueTalk à proximité, sans association manuelle.
- Contacts et conversations conservés sur le téléphone, comme sur une messagerie classique.
- Messages et fichiers écrits hors connexion : ils restent « en attente » et partent
  automatiquement quand le contact est à portée (application ouverte).
- Accusés de réception (en attente, envoyé, reçu), envoi d'images et de documents
  (100 Mo maximum) avec progression et vérification d'intégrité SHA-256.
- Thèmes clair et sombre.

## Architecture

- `lib/protocol/` : trames (version, type, longueur, contenu), décodeur tolérant aux
  coupures, session (PING/PONG, accusés), canal abstrait et canal mémoire pour les tests.
- `lib/chat/` : modèles, stockage SQLite, logique d'une connexion (présentation,
  messages, accusés, transfert de fichiers).
- `lib/bluetooth/` + `android/.../kotlin/` : ponts Kotlin. Détection par balises
  Bluetooth basse consommation et canal L2CAP ; mode de secours RFCOMM (appareils associés).
- `lib/app/`, `lib/ui/` : contrôleur et écrans.

## Protocole

Chaque trame : version (1 octet), type (1 octet), longueur (4 octets), contenu.
Types : HELLO, TEXT, ACK, PING, PONG, FILE_OFFER, FILE_ACCEPT, FILE_CHUNK, FILE_END,
FILE_ABORT. Les types inconnus sont ignorés, ce qui permet de faire évoluer le protocole.

## Compiler

Prérequis : Flutter, Android SDK, un téléphone Android 10 ou plus récent.

    flutter pub get
    flutter test
    flutter build apk --release

L'APK est généré dans `build/app/outputs/flutter-apk/`.

## Limites connues

- Une seule connexion active à la fois.
- Un transfert interrompu repart du début.
- La livraison automatique fonctionne application ouverte, pas application fermée.
- Pas de chiffrement applicatif ni de notifications.
- Android uniquement.
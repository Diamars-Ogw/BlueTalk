# BlueTalk

Messagerie hors ligne par Bluetooth pour Android : messages, images et documents
entre téléphones proches, sans Internet ni serveur. Plusieurs personnes peuvent
être connectées en même temps, et discuter en groupe.

## Fonctions

- Nom d'utilisateur choisi au premier lancement, visible des autres utilisateurs à proximité.
- Recherche des utilisateurs BlueTalk à proximité, sans association manuelle.
- Contacts et conversations conservés sur le téléphone, comme sur une messagerie classique.
- Messages et fichiers écrits hors connexion : ils restent « en attente » et partent
  automatiquement quand le contact est à portée (application ouverte).
- Accusés de réception (en attente, envoyé, reçu), envoi d'images et de documents
  (100 Mo maximum) avec progression et vérification d'intégrité SHA-256.
- Thèmes clair et sombre.
- **Plusieurs connexions en même temps** : l'application en ouvre autant que le
  téléphone en accepte (plafond de 15). La limite réelle dépend de la puce
  Bluetooth de chaque modèle : quand le téléphone commence à refuser, l'application
  retient le nombre atteint (affiché sur l'écran principal) et réessaie plus tard.
- **Groupes de discussion** : le créateur choisit un nom et des personnes déjà
  rencontrées ; messages, images et documents vont à tous les membres. Chaque
  message de groupe montre son auteur et combien de membres l'ont reçu (« 3/4 »).
  Les autres peuvent quitter le groupe.
- **Administration du groupe** : le créateur peut nommer des administrateurs. Le
  créateur et les administrateurs renomment le groupe, ajoutent et retirent des
  membres (un administrateur ne retire ni le créateur ni un autre administrateur) et
  activent le **mode annonces** (seuls les administrateurs écrivent). Seul le créateur
  nomme ou retire les administrateurs et peut **supprimer le groupe pour tout le monde**.
- **Messages vocaux** : on maintient le micro, on relâche pour envoyer, on glisse
  vers la gauche pour annuler (5 minutes au plus). Lecture dans la bulle avec barre
  de progression. Enregistrement AAC mono léger (environ 240 Ko par minute).
- **Fichiers fiables** : un transfert interrompu **reprend là où il s'était arrêté**
  (vidéos, documents), les gros fichiers partent **un à la fois** depuis un téléphone,
  et les fichiers de groupe passent aussi par **relais** : un membre qui a reçu le
  fichier le transmet à ceux qu'il croise.
- **Journal** (icône en haut de l'écran principal) : connexions, coupures avec leur
  cause, transferts. Se copie pour analyser un problème.
- **Relais** : si deux membres ne sont pas à portée l'un de l'autre mais le sont
  d'un troisième, les messages texte passent par lui, et l'auteur finit par
  savoir qui les a reçus.
- **Connexions maintenues en arrière-plan** : un service Android de premier plan
  (notification permanente) garde les connexions ouvertes quand on quitte
  l'application. Le bouton Retour de l'écran principal met l'application de côté
  au lieu de la fermer. Une personne qui s'éloigne puis revient à portée est
  reconnectée automatiquement. Notification à chaque nouveau message reçu.

## Architecture

- `lib/protocol/` : trames (version, type, longueur, contenu), décodeur tolérant aux
  coupures, session (PING/PONG, accusés), canal abstrait et canal mémoire pour les tests.
- `lib/chat/` : modèles, stockage SQLite, logique d'une connexion (présentation,
  messages, accusés, transfert de fichiers, groupes), et `group_ops.dart`
  (création de groupe, écriture d'un message de groupe).
- `lib/bluetooth/` + `android/.../kotlin/` : ponts Kotlin. Détection par balises
  Bluetooth basse consommation et canaux L2CAP (un numéro `cid` par connexion) ;
  service de premier plan (`LinkService`) et notifications ; mode de secours RFCOMM
  (appareils associés, une seule connexion).
- `lib/app/`, `lib/ui/` : contrôleur et écrans.

## Protocole

Chaque trame : version (1 octet), type (1 octet), longueur (4 octets), contenu.
Types : HELLO, TEXT, ACK, PING, PONG, FILE_OFFER, FILE_ACCEPT, FILE_CHUNK, FILE_END,
FILE_ABORT, et pour les groupes : GROUP_INFO (30), GROUP_TEXT (31), GROUP_RECEIPT (32),
GROUP_LEAVE (33). Les types inconnus sont ignorés, ce qui permet de faire évoluer le protocole.

### Groupes

Un groupe n'existe sur aucun serveur : chaque membre en garde une copie (identifiant,
nom, créateur, **version**, membres). Seul le créateur le modifie, en augmentant la
version ; la copie de version la plus élevée l'emporte, et une description qui prétend
venir d'un autre créateur est refusée. À chaque connexion, on s'envoie les groupes
qu'on a en commun avant d'envoyer les messages.

Un message de groupe est enregistré tout de suite avec un suivi de livraison par membre
(en attente, envoyé, reçu). Il part vers chaque membre connecté ; un membre qui le reçoit
le garde et le retransmet à ceux qui ne l'ont pas (relais), puis diffuse un reçu
(GROUP_RECEIPT) que chacun fait suivre une seule fois, jusqu'à l'auteur. Les doublons
sont écartés par l'identifiant du message. Les fichiers de groupe suivent le même
principe : l'auteur les envoie, un membre qui les a reçus en entier et vérifiés les fait
suivre. Un fichier ne se reçoit que par une liaison à la fois.

### Fichiers

La proposition (FILE_OFFER) porte la taille, l'empreinte SHA-256 du fichier entier et
son type (image, document, audio avec sa durée). Le destinataire répond (FILE_ACCEPT)
en indiquant combien d'octets il a déjà : l'expéditeur reprend à cet endroit. À la fin,
le destinataire relit le fichier complet sur le disque et compare l'empreinte ; en cas
d'écart il l'efface et le transfert repart de zéro. Un téléphone n'envoie qu'un gros
fichier à la fois (les petits, comme les messages vocaux, partent aussitôt), et ne
cherche pas de nouveaux appareils pendant un transfert.

### Administration

Chaque version d'un groupe indique qui l'a publiée. Elle n'est acceptée que si son
auteur était créateur ou administrateur dans la version qu'on connaissait. Si deux
administrateurs modifient en même temps, l'identifiant le plus grand l'emporte (la
modification de l'autre est perdue). Sans chiffrement, un membre déterminé pourrait
falsifier ces indications.

## Compiler

Prérequis : Flutter, Android SDK, un téléphone Android 10 ou plus récent.

    flutter pub get
    flutter test
    flutter build apk --release

L'APK est généré dans `build/app/outputs/flutter-apk/`.

## Limites connues

- Le nombre de connexions simultanées est limité par la puce Bluetooth du téléphone
  (souvent entre 5 et 10, parfois plus). Les groupes plus grands passent par le
  relais des messages et des fichiers, plus lent qu'une liaison directe.
- Plus il y a de connexions ouvertes, moins chacune est rapide : la radio est partagée.
- Retirer l'application de la liste des applications récentes (balayage) arrête
  les connexions ; le bouton Retour, lui, les garde.
- L'ordre des messages d'un groupe est celui d'arrivée sur chaque téléphone : deux
  téléphones peuvent voir deux messages simultanés dans un ordre différent.
- Un membre qui quitte un groupe l'annonce aux membres à portée ; si le créateur
  ne l'apprend pas, il continue de lui réserver les messages.
- Le créateur d'un groupe ne peut pas le quitter : il peut le supprimer pour tout le monde.
- Les restrictions entre administrateurs (ne pas retirer un autre administrateur) sont
  appliquées par l'application de celui qui modifie, pas vérifiées par les autres.
- Pas de chiffrement applicatif : un membre pourrait se faire passer pour un autre.
- Sur Android 10 et 11, la recherche en arrière-plan peut demander la localisation
  « tout le temps » ; non vérifié ici.
- Une connexion Bluetooth ouverte et la recherche régulière consomment de la batterie :
  le réglage « Rester connecté en arrière-plan » permet de les arrêter.
- Android uniquement.
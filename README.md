# dt.app.flutter
# Impression mobile — Xprinter XP-P324B via Flutter

Guide complet pour intégrer l'imprimante thermique Xprinter XP-P324B (Bluetooth / WiFi)
dans l'application Dakar Terminal sur Android et iOS, sans machine intermédiaire,
en utilisant Flutter.

---

## Architecture de la solution

```
┌──────────────────────────────────────────────────────┐
│                 Application Flutter                   │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  WebView (webview_flutter)                     │  │
│  │  → charge https://votre-app.herokuapp.com      │  │
│  │                                                │  │
│  │  Bouton "Imprimer" (JavaScript)                │  │
│  │    → JavascriptChannel("XprinterBridge")       │  │
│  └───────────────────┬────────────────────────────┘  │
│                      │ pont JavaScript → Dart         │
│  ┌───────────────────▼────────────────────────────┐  │
│  │  PrinterService (Dart)                         │  │
│  │  • flutter_bluetooth_serial → connexion BT     │  │
│  │  • esc_pos_utils → conversion PNG → ESC/POS    │  │
│  │  • image → redimensionnement 559 × 401 px      │  │
│  └───────────────────┬────────────────────────────┘  │
└─────────────────────┼────────────────────────────────┘
                      │ Bluetooth Classique ou WiFi TCP
              ┌───────▼────────┐
              │  XP-P324B      │
              │  70 × 50 mm    │
              └────────────────┘
```

**Principe :** l'app Laravel tourne inchangée sur Heroku. Flutter l'affiche dans une
WebView et intercepte les commandes d'impression via un canal JavaScript. Le service
d'impression Dart se connecte directement à la XP-P324B en Bluetooth Classique (SPP)
ou WiFi sans avoir besoin du SDK officiel Xprinter.

---

## Prérequis

### Outils à installer sur la machine de développement

| Outil | Version minimale | Lien |
|---|---|---|
| Flutter SDK | 3.19+ | https://flutter.dev/docs/get-started/install |
| Dart SDK | 3.3+ | inclus avec Flutter |
| Android Studio | Hedgehog+ | https://developer.android.com/studio |
| Java JDK | 17+ | https://adoptium.net |
| Xcode (Mac, pour iOS) | 15+ | App Store Mac |
| CocoaPods (Mac, pour iOS) | 1.14+ | `sudo gem install cocoapods` |

Vérifier l'installation Flutter après setup :

```bash
flutter doctor
```

Tous les items doivent être cochés en vert avant de commencer.

### Côté imprimante

- Imprimante XP-P324B allumée et chargée en papier 70×50mm
- **Mode Bluetooth :** nom de l'appareil affiché sur l'écran OLED (ex : `XP-P324B`)
- **Mode WiFi :** IP fixe attribuée à l'imprimante dans les paramètres du routeur

---

## Étape 1 — Créer le projet Flutter

Ouvrir un terminal dans ce dossier (`xprinter/`) et exécuter :

```bash
flutter create dt_xprinter --org com.dakarterminal --platforms android,ios
cd dt_xprinter
```

Structure créée :

```
dt_xprinter/
├── lib/
│   └── main.dart          ← point d'entrée de l'app
├── android/               ← projet Android natif
├── ios/                   ← projet iOS natif
└── pubspec.yaml           ← dépendances
```

---

## Étape 2 — Ajouter les dépendances (`pubspec.yaml`)

Remplacer la section `dependencies` dans `pubspec.yaml` :

```yaml
dependencies:
  flutter:
    sdk: flutter

  # Afficher l'app Laravel dans une WebView
  webview_flutter: ^4.7.0

  # Connexion Bluetooth Classique (SPP) à la XP-P324B
  flutter_bluetooth_serial: ^0.4.0

  # Génération des commandes ESC/POS pour imprimantes thermiques
  esc_pos_utils: ^1.1.0

  # Traitement et redimensionnement d'images
  image: ^4.1.7

  # Connexion WiFi via socket TCP
  network_info_plus: ^5.0.3

  # Stockage local (mémoriser l'adresse de l'imprimante)
  shared_preferences: ^2.2.3

  # Gestion des permissions runtime (Bluetooth, réseau)
  permission_handler: ^11.3.1
```

Installer les dépendances :

```bash
flutter pub get
```

---

## Étape 3 — Configurer les permissions

### Android (`android/app/src/main/AndroidManifest.xml`)

Ajouter avant la balise `<application>` :

```xml
<!-- Bluetooth Classique (requis pour XP-P324B) -->
<uses-permission android:name="android.permission.BLUETOOTH"
    android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
    android:maxSdkVersion="30" />

<!-- Android 12+ -->
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />

<!-- Localisation requise pour le scan Bluetooth sur Android -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- WiFi et réseau -->
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

Dans la balise `<application>`, s'assurer que `android:usesCleartextTraffic="true"`
est présent si l'app Laravel tourne en HTTP (pas nécessaire en HTTPS/Heroku).

Changer le `minSdkVersion` dans `android/app/build.gradle` :

```groovy
android {
    defaultConfig {
        minSdkVersion 21    // requis par flutter_bluetooth_serial
        targetSdkVersion 34
    }
}
```

### iOS (`ios/Runner/Info.plist`)

Ajouter dans le dictionnaire principal :

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connexion à l'imprimante XP-P324B via Bluetooth</string>

<key>NSBluetoothPeripheralUsageDescription</key>
<string>Connexion à l'imprimante XP-P324B via Bluetooth</string>

<key>NSLocalNetworkUsageDescription</key>
<string>Connexion à l'imprimante XP-P324B via WiFi</string>
```

---

## Étape 4 — Créer le service d'impression (`lib/printer_service.dart`)

Ce fichier centralise toute la logique de connexion et d'impression.

```dart
import 'dart:typed_data';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:image/image.dart' as img;

class PrinterService {
  // Résolution de la XP-P324B : 203 DPI
  static const int dpi = 203;

  BluetoothConnection? _connection;
  String? _savedAddress;

  // ─── Bluetooth ────────────────────────────────────────────────────────────

  /// Retourne la liste des appareils Bluetooth déjà appairés.
  /// L'utilisateur doit avoir appairé la XP-P324B au préalable
  /// dans les paramètres Bluetooth du téléphone.
  Future<List<BluetoothDevice>> getPairedDevices() async {
    return await FlutterBluetoothSerial.instance.getBondedDevices();
  }

  /// Connexion à l'imprimante via son adresse MAC Bluetooth.
  Future<bool> connectBluetooth(String address) async {
    try {
      _connection = await BluetoothConnection.toAddress(address);
      _savedAddress = address;
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Vérifie si la connexion Bluetooth est active.
  bool get isConnected =>
      _connection != null && (_connection!.isConnected);

  /// Déconnexion propre.
  Future<void> disconnect() async {
    await _connection?.close();
    _connection = null;
  }

  // ─── Impression ───────────────────────────────────────────────────────────

  /// Imprime un PNG fourni en bytes, aux dimensions spécifiées en mm.
  Future<bool> printImage(
    Uint8List imageBytes, {
    int widthMm = 70,
    int heightMm = 50,
  }) async {
    if (!isConnected) return false;

    try {
      // 1. Calculer les dimensions en pixels selon le DPI de l'imprimante
      final int widthPx  = (widthMm  / 25.4 * dpi).round();  // 559 px
      final int heightPx = (heightMm / 25.4 * dpi).round();  // 401 px

      // 2. Décoder l'image et la redimensionner
      img.Image? original = img.decodeImage(imageBytes);
      if (original == null) return false;

      img.Image resized = img.copyResize(
        original,
        width: widthPx,
        height: heightPx,
        interpolation: img.Interpolation.linear,
      );

      // 3. Convertir en niveaux de gris puis en noir et blanc (1 bit)
      img.Image grayscale = img.grayscale(resized);

      // 4. Générer les commandes ESC/POS
      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.custom, profile);
      List<int> commands = [];

      // Réinitialisation imprimante
      commands += generator.reset();

      // Configurer la largeur de page en points (8 points par mm à 203 DPI)
      // widthPx / 8 = nombre d'octets de largeur
      commands += generator.imageRaster(
        img.Image.from(grayscale),
        align: PosAlign.center,
      );

      // Avancer le papier et couper (si l'imprimante supporte la coupe)
      commands += generator.feed(2);
      commands += generator.cut();

      // 5. Envoyer les bytes à l'imprimante
      _connection!.output.add(Uint8List.fromList(commands));
      await _connection!.output.allSent;

      return true;
    } catch (e) {
      return false;
    }
  }

  // ─── WiFi ─────────────────────────────────────────────────────────────────
  // Pour une connexion WiFi, remplacer BluetoothConnection par un Socket TCP :
  //
  //   import 'dart:io';
  //   final socket = await Socket.connect(ipAddress, 9100);
  //   socket.add(Uint8List.fromList(commands));
  //   await socket.flush();
  //   socket.destroy();
}
```

---

## Étape 5 — Créer l'écran principal avec la WebView (`lib/main.dart`)

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'printer_service.dart';
import 'settings_screen.dart';

void main() {
  runApp(const DtXprinterApp());
}

class DtXprinterApp extends StatelessWidget {
  const DtXprinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DT Xprinter',
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final WebViewController _webController;
  final PrinterService _printer = PrinterService();
  bool _isPrinting = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _autoConnectPrinter();
  }

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)

      // Canal de communication JavaScript → Flutter
      ..addJavaScriptChannel(
        'XprinterBridge',
        onMessageReceived: (JavaScriptMessage message) {
          _handlePrintRequest(message.message);
        },
      )

      // Charger l'app Laravel
      ..loadRequest(Uri.parse(
        'https://votre-app.herokuapp.com/escale-code-barres',
      ));
  }

  /// Reconnexion automatique à la dernière imprimante utilisée.
  Future<void> _autoConnectPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    final savedAddress = prefs.getString('printer_address');
    if (savedAddress != null) {
      await _printer.connectBluetooth(savedAddress);
    }
  }

  /// Traitement d'une demande d'impression reçue depuis le JavaScript.
  /// Le message attendu est un JSON : { "imageBase64": "...", "width": 70, "height": 50 }
  Future<void> _handlePrintRequest(String message) async {
    if (_isPrinting) return;
    setState(() => _isPrinting = true);

    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final String base64Image = data['imageBase64'] as String;
      final int widthMm  = data['width']  as int? ?? 70;
      final int heightMm = data['height'] as int? ?? 50;

      // Décoder le Base64 en bytes
      final imageBytes = base64Decode(base64Image);

      if (!_printer.isConnected) {
        _showSnackbar('Imprimante non connectée. Vérifiez les paramètres.', error: true);
        return;
      }

      final success = await _printer.printImage(
        imageBytes,
        widthMm: widthMm,
        heightMm: heightMm,
      );

      _showSnackbar(
        success ? 'Impression envoyée avec succès.' : 'Erreur lors de l\'impression.',
        error: !success,
      );
    } catch (e) {
      _showSnackbar('Erreur : $e', error: true);
    } finally {
      setState(() => _isPrinting = false);
    }
  }

  void _showSnackbar(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dakar Terminal'),
        actions: [
          // Indicateur de connexion
          Icon(
            Icons.bluetooth,
            color: _printer.isConnected ? Colors.greenAccent : Colors.white38,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Paramètres imprimante',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(printer: _printer),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _webController),
          if (_isPrinting)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
```

---

## Étape 6 — Écran de configuration imprimante (`lib/settings_screen.dart`)

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'printer_service.dart';

class SettingsScreen extends StatefulWidget {
  final PrinterService printer;
  const SettingsScreen({super.key, required this.printer});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<BluetoothDevice> _pairedDevices = [];
  bool _loading = true;
  String? _connectedAddress;

  @override
  void initState() {
    super.initState();
    _loadPairedDevices();
    _loadSavedAddress();
  }

  Future<void> _loadPairedDevices() async {
    final devices = await widget.printer.getPairedDevices();
    setState(() {
      _pairedDevices = devices;
      _loading = false;
    });
  }

  Future<void> _loadSavedAddress() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _connectedAddress = prefs.getString('printer_address');
    });
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _loading = true);

    final success = await widget.printer.connectBluetooth(device.address);

    if (success) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('printer_address', device.address);
      setState(() => _connectedAddress = device.address);
    }

    setState(() => _loading = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success
            ? 'Connecté à ${device.name ?? device.address}'
            : 'Connexion échouée. Vérifiez que l\'imprimante est allumée.'),
        backgroundColor: success ? Colors.green : Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres imprimante')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Appareils Bluetooth appairés',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Si la XP-P324B n\'apparaît pas, appairez-la d\'abord dans '
                    'les Paramètres Bluetooth de votre téléphone.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: _pairedDevices.length,
                    itemBuilder: (context, index) {
                      final device = _pairedDevices[index];
                      final isConnected = device.address == _connectedAddress;
                      return ListTile(
                        leading: Icon(
                          Icons.print,
                          color: isConnected ? Colors.green : Colors.grey,
                        ),
                        title: Text(device.name ?? 'Appareil inconnu'),
                        subtitle: Text(device.address),
                        trailing: isConnected
                            ? const Chip(
                                label: Text('Connecté'),
                                backgroundColor: Colors.green,
                                labelStyle: TextStyle(color: Colors.white),
                              )
                            : ElevatedButton(
                                onPressed: () => _connect(device),
                                child: const Text('Connecter'),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
```

---

## Étape 7 — Modifier le bouton "Imprimer" dans la vue Laravel

Dans `escale_code_barres.blade.php`, ajouter cette logique JavaScript
au bouton d'impression existant :

```javascript
/**
 * Détecte si l'app tourne dans Flutter (le canal XprinterBridge est injecté).
 * En dehors de Flutter (navigateur classique), on utilise window.print().
 */
const isFlutter = typeof XprinterBridge !== 'undefined';

async function imprimerCodeBarre(imageUrl) {

    if (!isFlutter) {
        // Navigateur classique (desktop) — impression standard
        window.print();
        return;
    }

    try {
        // 1. Télécharger l'image PNG depuis l'URL
        const response = await fetch(imageUrl);
        const blob = await response.blob();

        // 2. Convertir en Base64
        const base64 = await new Promise((resolve) => {
            const reader = new FileReader();
            reader.onloadend = () => resolve(reader.result.split(',')[1]);
            reader.readAsDataURL(blob);
        });

        // 3. Envoyer au canal Flutter
        XprinterBridge.postMessage(JSON.stringify({
            imageBase64: base64,
            width: 70,
            height: 50,
        }));

    } catch (e) {
        console.error('Erreur impression Flutter :', e);
    }
}
```

Remplacer l'attribut `onclick` du bouton "Imprimer" par :

```html
<button onclick="imprimerCodeBarre('{{ $imageUrl }}')" class="client-btn client-btn-primary">
    <i class="fa-solid fa-print"></i> Imprimer
</button>
```

---

## Étape 8 — Pairing initial de l'imprimante (première utilisation)

Avant d'ouvrir l'app Flutter, faire une seule fois depuis le téléphone :

1. Aller dans **Paramètres → Bluetooth** du téléphone
2. Allumer la XP-P324B
3. L'imprimante apparaît dans la liste (nom affiché sur son écran OLED)
4. Taper dessus → **Associer**
5. Si un code PIN est demandé, entrer `0000` ou `1234` (codes par défaut Xprinter)
6. Le pairing est mémorisé définitivement

Ensuite dans l'app Flutter :

1. Ouvrir l'app → icône **Paramètres** (engrenage en haut à droite)
2. La XP-P324B apparaît dans la liste des appareils appairés
3. Taper **Connecter**
4. L'app mémorise cette imprimante → connexion automatique aux prochains lancements

---

## Étape 9 — Tester l'app

### Sur Android (appareil physique)

```bash
# Lister les appareils connectés en USB
flutter devices

# Lancer l'app sur l'appareil
flutter run -d <device_id>
```

Activer le **mode développeur** sur le téléphone :
`Paramètres → À propos du téléphone → Numéro de build (taper 7 fois)`
puis activer le **Débogage USB**.

### Sur iOS (Mac requis)

```bash
flutter run -d <iphone_id>
```

Accepter la confiance au développeur sur l'iPhone :
`Réglages → Général → Gestion VPN et app → Faire confiance`

### Test d'impression complet

1. App lancée → connexion Bluetooth automatique à la XP-P324B ✓
2. Ouvrir `/escale-code-barres` dans la WebView
3. Générer un code barre
4. Appuyer sur **Imprimer**
5. L'image doit s'imprimer en 70×50mm sur l'étiquette

---

## Étape 10 — Compiler et distribuer

### Build Android (APK)

```bash
# APK de débogage (test interne)
flutter build apk --debug

# APK de production (distribution)
flutter build apk --release

# Fichier généré :
# build/app/outputs/flutter-apk/app-release.apk
```

Distribuer l'APK par email, WhatsApp ou lien de téléchargement.
Sur le téléphone : `Paramètres → Sécurité → Sources inconnues → Autoriser`.

### Build iOS (App Store ou TestFlight)

```bash
flutter build ios --release
```

Ouvrir `ios/Runner.xcworkspace` dans Xcode :
`Product → Archive → Distribute App → TestFlight ou App Store`

Compte Apple Developer requis (99 USD/an).

---

## Calcul des dimensions d'impression

La XP-P324B imprime à **203 DPI** (points par pouce).

| Dimension | Calcul | Résultat |
|---|---|---|
| Largeur 70 mm | (70 ÷ 25.4) × 203 | **559 pixels** |
| Hauteur 50 mm | (50 ÷ 25.4) × 203 | **401 pixels** |

Le `PrinterService` effectue ce calcul automatiquement à partir des mm passés
en paramètre — aucun calcul manuel nécessaire côté JavaScript.

---

## Structure finale du projet

```
xprinter/
├── README.md                          ← ce fichier
└── dt_xprinter/                       ← projet Flutter
    ├── pubspec.yaml                   ← dépendances
    ├── lib/
    │   ├── main.dart                  ← app Flutter + WebView + pont JS
    │   ├── printer_service.dart       ← Bluetooth, ESC/POS, WiFi
    │   └── settings_screen.dart      ← sélection et mémorisation imprimante
    ├── android/
    │   └── app/
    │       ├── build.gradle           ← minSdkVersion 21
    │       └── src/main/
    │           └── AndroidManifest.xml ← permissions Bluetooth/réseau
    └── ios/
        └── Runner/
            └── Info.plist             ← permissions Bluetooth iOS
```

---

## Dépannage

| Problème | Cause probable | Solution |
|---|---|---|
| `flutter doctor` signale des erreurs | Setup incomplet | Suivre les instructions affichées par `flutter doctor` |
| XP-P324B absente de la liste | Pas encore appairée | Faire le pairing dans Paramètres Bluetooth du téléphone d'abord |
| Connexion échouée à l'adresse MAC | Imprimante éteinte ou hors portée | Vérifier alimentation, rapprocher le téléphone |
| Image imprimée floue | Image source trop petite | S'assurer que le PNG source fait au minimum 559×401 px |
| Image tronquée à droite | Largeur de page mal gérée par `esc_pos_utils` | Vérifier le `PaperSize` ou passer en `imageRaster` avec `align: center` |
| WebView affiche une page blanche | URL incorrecte ou pas de réseau | Vérifier l'URL Heroku et la connexion internet du téléphone |
| Impression déclenche une erreur iOS | Permissions absentes dans `Info.plist` | Vérifier les 3 clés NSBluetooth* dans `Info.plist` |
| `flutter_bluetooth_serial` ne compile pas sur iOS | Compatibilité limitée iOS | Sur iOS, privilégier la connexion WiFi (Socket TCP) |

> **Note iOS importante :** `flutter_bluetooth_serial` est optimisé pour Android.
> Sur iPhone, la connexion WiFi (socket TCP port 9100) est plus fiable que le
> Bluetooth Classique. Configurer la XP-P324B en mode WiFi pour les utilisateurs iOS.

---

## Ressources

| Ressource | Lien |
|---|---|
| Documentation Flutter | https://flutter.dev/docs |
| Package webview_flutter | https://pub.dev/packages/webview_flutter |
| Package flutter_bluetooth_serial | https://pub.dev/packages/flutter_bluetooth_serial |
| Package esc_pos_utils | https://pub.dev/packages/esc_pos_utils |
| Package image (traitement) | https://pub.dev/packages/image |
| Commands ESC/POS référence | https://reference.epson-biz.com/modules/ref_escpos |

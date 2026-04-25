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

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
          // Indicateur de connexion Bluetooth
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

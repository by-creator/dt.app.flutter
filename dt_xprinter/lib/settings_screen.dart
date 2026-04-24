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

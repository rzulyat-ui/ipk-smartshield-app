import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String appName = "SmartShield App";
const String umbrellaNamePrefix = "Smart Umbrella";
const String prefsSavedIdKey = "saved_umbrella_id";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notif.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String status = "Not Connected";
  bool scanning = false;

  BluetoothDevice? connectedDevice;
  StreamSubscription<List<ScanResult>>? scanSub;
  StreamSubscription<BluetoothConnectionState>? connSub;

  final Map<String, ScanResult> found = {}; // id -> ScanResult

  Timer? reconnectTimer;
  Timer? alertTimer;
  bool lostMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAndTryAutoReconnect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanSub?.cancel();
    connSub?.cancel();
    reconnectTimer?.cancel();
    alertTimer?.cancel();
    super.dispose();
  }

  // When app resumes, try reconnect again if we were disconnected
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tryAutoReconnectOnce();
    }
  }

  // ---------------------------
  // Permissions
  // ---------------------------
  Future<bool> _requestPerms() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final loc = await Permission.locationWhenInUse.request();
    await Permission.notification.request();

    if (!scan.isGranted) {
      setState(() => status = "Permission denied: BLUETOOTH_SCAN");
      return false;
    }
    if (!connect.isGranted) {
      setState(() => status = "Permission denied: BLUETOOTH_CONNECT");
      return false;
    }
    if (!loc.isGranted) {
      setState(() => status = "Permission denied: LOCATION");
      return false;
    }

    if (!await FlutterBluePlus.isOn) {
      setState(() => status = "Bluetooth OFF. Turn it ON.");
      return false;
    }

    return true;
  }

  // ---------------------------
  // Start-up auto reconnect
  // ---------------------------
  Future<void> _initAndTryAutoReconnect() async {
    final ok = await _requestPerms();
    if (!ok) return;
    await _tryAutoReconnectOnce();
  }

  Future<void> _tryAutoReconnectOnce() async {
    // If already connected, nothing to do
    if (connectedDevice != null) return;

    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(prefsSavedIdKey);
    if (savedId == null) return;

    setState(() => status = "Auto reconnect scanning...");
    await _scanForSeconds(seconds: 6, autoConnectId: savedId);
  }

  // ---------------------------
  // Scan
  // ---------------------------
  Future<void> startScanManual() async {
    final ok = await _requestPerms();
    if (!ok) return;

    found.clear();

    setState(() {
      scanning = true;
      status = "Scanning...";
    });

    await _scanForSeconds(seconds: 10);
  }

  Future<void> _scanForSeconds({required int seconds, String? autoConnectId}) async {
    scanSub?.cancel();
    await FlutterBluePlus.stopScan();

    scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        // Use advName if available, else platformName
        final advName = r.advertisementData.advName;
        final devName = r.device.platformName;
        final name = advName.isNotEmpty ? advName : devName;

        // Only show umbrellas
        if (!name.startsWith(umbrellaNamePrefix)) continue;

        final id = r.device.remoteId.str;
        found[id] = r;

        if (mounted) setState(() {});

        // Auto connect to saved umbrella
        if (autoConnectId != null && id == autoConnectId) {
          await FlutterBluePlus.stopScan();
          await scanSub?.cancel();
          if (mounted) setState(() => scanning = false);
          await _connect(r.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: Duration(seconds: seconds));

    Future.delayed(Duration(seconds: seconds + 1), () async {
      await FlutterBluePlus.stopScan();
      await scanSub?.cancel();
      if (!mounted) return;

      setState(() {
        scanning = false;
        if (connectedDevice != null) return;
        status = found.isEmpty ? "No umbrellas found ❌" : "Select umbrella to connect ✅";
      });
    });
  }

  // ---------------------------
  // Connect / Disconnect
  // ---------------------------
  Future<void> _connect(BluetoothDevice dev) async {
    try {
      setState(() {
        status = "Connecting...";
        connectedDevice = dev;
      });

      // Important for FlutterBluePlus 2.x
      await dev.connect(license: License.free, timeout: const Duration(seconds: 10));

      // Save this umbrella so auto-reconnect works
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsSavedIdKey, dev.remoteId.str);

      _stopLostMode();
      _stopReconnectTimer();

      // Monitor state
      connSub?.cancel();
      connSub = dev.connectionState.listen((state) {
        if (!mounted) return;

        if (state == BluetoothConnectionState.connected) {
          setState(() => status = "Connected ✅ (${dev.platformName})");
          _stopLostMode();
          _stopReconnectTimer();
        } else if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            status = "Umbrella Lost ❌";
            connectedDevice = null;
          });
          _startLostMode();
          _startReconnectTimer();
        }
      });

      setState(() => status = "Connected ✅ (${dev.platformName})");
    } catch (e) {
      setState(() {
        status = "Connect failed ❌";
        connectedDevice = null;
      });
    }
  }

  Future<void> disconnect() async {
    _stopReconnectTimer();
    _stopLostMode();

    try {
      await connectedDevice?.disconnect();
    } catch (_) {}

    setState(() {
      connectedDevice = null;
      status = "Not Connected";
    });
  }

  Future<void> forgetSavedUmbrella() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsSavedIdKey);
    setState(() => status = "Saved umbrella cleared ✅");
  }

  // ---------------------------
  // Lost mode (Heads-up notification loop)
  // ---------------------------
  void _startLostMode() async {
    if (lostMode) return;
    lostMode = true;

    await Notif.showHeadsUp(
      title: "SmartShield Alert",
      body: "Umbrella disconnected! You left it behind.",
    );

    alertTimer?.cancel();
    alertTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await Notif.showHeadsUp(
        title: "SmartShield Alert",
        body: "Umbrella still missing ❌",
      );
    });
  }

  void _stopLostMode() {
    lostMode = false;
    alertTimer?.cancel();
    alertTimer = null;
    Notif.cancelAll();
  }

  // ---------------------------
  // Auto reconnect loop (scan every few seconds)
  // ---------------------------
  void _startReconnectTimer() async {
    reconnectTimer?.cancel();

    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(prefsSavedIdKey);
    if (savedId == null) return;

    reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (connectedDevice != null) {
        _stopReconnectTimer();
        return;
      }
      await _scanForSeconds(seconds: 4, autoConnectId: savedId);
    });
  }

  void _stopReconnectTimer() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }

  // ---------------------------
  // UI
  // ---------------------------
  @override
  Widget build(BuildContext context) {
    final items = found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text(appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "Forget paired umbrella",
            onPressed: forgetSavedUmbrella,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: ListTile(
                title: Text(
                  status,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text("Found: ${items.length}"),
                trailing: connectedDevice != null
                    ? const Icon(Icons.bluetooth_connected)
                    : const Icon(Icons.bluetooth),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: scanning ? null : startScanManual,
                    child: Text(scanning ? "Scanning..." : "Scan Umbrellas"),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: disconnect,
                    child: const Text("Disconnect"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Tap an umbrella to connect:",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text("No results yet"))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final r = items[i];
                        final advName = r.advertisementData.advName;
                        final devName = r.device.platformName;
                        final name = advName.isNotEmpty ? advName : (devName.isNotEmpty ? devName : "Unknown");
                        final id = r.device.remoteId.str;

                        return Card(
                          child: ListTile(
                            title: Text(name),
                            subtitle: Text("ID: $id  |  RSSI: ${r.rssi}"),
                            onTap: () => _connect(r.device),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------
// Notifications (Heads-up)
// ---------------------------
class Notif {
  static final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);
    await _p.initialize(initSettings);

    const channel = AndroidNotificationChannel(
      'smartshield_alerts',
      'SmartShield Alerts',
      description: 'Umbrella lost alerts',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    final androidPlugin = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(channel);
  }

  static Future<void> showHeadsUp({required String title, required String body}) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'smartshield_alerts',
        'SmartShield Alerts',
        channelDescription: 'Umbrella lost alerts',
        importance: Importance.max,
        priority: Priority.high,
        enableVibration: true,
        playSound: true,
      ),
    );
    await _p.show(1, title, body, details);
  }

  static Future<void> cancelAll() async {
    await _p.cancelAll();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart' hide Router;
import 'package:file_picker/file_picker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZShareApp());
}

class ZShareApp extends StatelessWidget {
  const ZShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          surface: Color(0xFF111827),
        ),
      ),
      home: const ZShareHome(),
    );
  }
}

class DiscoveredPeer {
  final String deviceName;
  final String ip;
  final int port;
  final int fileCount;
  DateTime lastSeen;

  DiscoveredPeer({
    required this.deviceName,
    required this.ip,
    required this.port,
    required this.fileCount,
    required this.lastSeen,
  });

  String get url => 'http://$ip:$port';
}

class ZShareHome extends StatefulWidget {
  const ZShareHome({super.key});

  @override
  State<ZShareHome> createState() => _ZShareHomeState();
}

class _ZShareHomeState extends State<ZShareHome> {
  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;
  Timer? _pruneTimer;
  StreamSubscription? _intentSub;

  String? _localIp;
  String _deviceName = 'Unknown Device';
  List<PlatformFile> _selectedFiles = [];
  final List<String> _receivedFiles = [];
  final Map<String, DiscoveredPeer> _nearbyPeers = {};

  bool _isSharing = false;
  final int _port = 8888;
  final int _discoveryPort = 8889;

  @override
  void initState() {
    super.initState();
    _initDeviceAndNetwork();
    _initSharingIntent();
  }

  void _initSharingIntent() {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    // Listen to media sharing when app is in memory
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedFiles(value);
      }
    }, onError: (err) {
      debugPrint("getMediaStream error: $err");
    });

    // Get media sharing when app was closed/opened fresh
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedFiles(value);
        ReceiveSharingIntent.instance.reset();
      }
    });
  }

  void _handleSharedFiles(List<SharedMediaFile> shared) {
    final List<PlatformFile> files = [];
    for (final s in shared) {
      final f = File(s.path);
      if (f.existsSync()) {
        files.add(
          PlatformFile(
            path: s.path,
            name: s.path.split('/').last,
            size: f.lengthSync(),
          ),
        );
      }
    }
    if (files.isNotEmpty) {
      setState(() {
        _selectedFiles = files;
      });
      _startShareServer();
    }
  }

  Future<void> _initDeviceAndNetwork() async {
    await _detectDeviceName();
    await _fetchLocalIp();
    await _startUdpDiscovery();
  }

  Future<void> _detectDeviceName() async {
    final info = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        _deviceName = '${android.manufacturer} ${android.model}';
      } else if (Platform.isLinux) {
        final linux = await info.linuxInfo;
        _deviceName = linux.prettyName.isNotEmpty ? linux.prettyName : 'Linux Device';
      } else {
        _deviceName = Platform.operatingSystem;
      }
    } catch (_) {
      _deviceName = 'Local Device';
    }
    if (mounted) setState(() {});
  }

  Future<void> _fetchLocalIp() async {
    try {
      final info = NetworkInfo();
      String? ip = await info.getWifiIP();
      if (ip == null || ip.isEmpty) {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
          ip = interfaces.first.addresses.first.address;
        }
      }
      setState(() => _localIp = ip ?? '127.0.0.1');
    } catch (_) {
      setState(() => _localIp = '127.0.0.1');
    }
  }

  Future<void> _startUdpDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket?.broadcastEnabled = true;

      _udpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket?.receive();
          if (datagram != null) {
            try {
              final raw = utf8.decode(datagram.data);
              final map = jsonDecode(raw) as Map<String, dynamic>;
              final ip = map['ip'] as String;

              if (ip == _localIp) return;

              final peerKey = '$ip:${map['port']}';
              setState(() {
                _nearbyPeers[peerKey] = DiscoveredPeer(
                  deviceName: map['deviceName'] ?? 'Peer',
                  ip: ip,
                  port: map['port'] ?? 8888,
                  fileCount: map['fileCount'] ?? 0,
                  lastSeen: DateTime.now(),
                );
              });
            } catch (_) {}
          }
        }
      });

      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        final threshold = DateTime.now().subtract(const Duration(seconds: 6));
        setState(() {
          _nearbyPeers.removeWhere((_, peer) => peer.lastSeen.isBefore(threshold));
        });
      });
    } catch (e) {
      debugPrint('UDP discovery socket error: $e');
    }
  }

  void _startBroadcasting() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_localIp == null || _udpSocket == null) return;
      final payload = jsonEncode({
        'deviceName': _deviceName,
        'ip': _localIp,
        'port': _port,
        'fileCount': _selectedFiles.length,
      });
      final data = utf8.encode(payload);
      _udpSocket?.send(data, InternetAddress('255.255.255.255'), _discoveryPort);
    });
  }

  void _stopBroadcasting() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.files.isNotEmpty) {
      setState(() => _selectedFiles = result.files);
      _startShareServer();
    }
  }

  Future<void> _startShareServer() async {
    await _stopShareServer();

    final router = shelf_router.Router();

    router.get('/', (Request request) {
      final fileListHtml = _selectedFiles.isEmpty
          ? '<p style="color: #6B7280; font-size: 13px;">No files currently shared.</p>'
          : _selectedFiles.map((file) {
              final encodedName = Uri.encodeComponent(file.name);
              final sizeMb = (file.size / (1024 * 1024)).toStringAsFixed(2);
              return '''
                <li style="margin-bottom: 10px; list-style: none;">
                  <a href="/download/$encodedName" download="$encodedName" 
                     style="background: #1F2937; color: #E0E7FF; padding: 12px 18px; border-radius: 10px; display: block; text-decoration: none; font-weight: 600; border: 1px solid #374151;">
                    📥 ${file.name} <span style="color: #9CA3AF; font-size: 12px; margin-left: 8px;">($sizeMb MB)</span>
                  </a>
                </li>
              ''';
            }).join();

      final html = '''
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>ZShare Portal</title>
          <style>
            body { background: #0B0F19; color: #F3F4F6; font-family: -apple-system, sans-serif; padding: 24px; text-align: center; }
            .card { background: #111827; border: 1px solid #1F2937; border-radius: 16px; padding: 20px; max-width: 500px; margin: 0 auto 20px auto; }
            .btn { background: #6366F1; color: white; border: none; padding: 10px 20px; border-radius: 8px; font-weight: bold; cursor: pointer; }
          </style>
        </head>
        <body>
          <h1 style="color: #818CF8; margin-bottom: 4px;">⚡ ZShare</h1>
          <p style="color: #9CA3AF; font-size: 13px; margin-bottom: 24px;">Connected to ${_deviceName}</p>

          <div class="card">
            <h3 style="margin-top: 0;">📤 Send Files to $_deviceName</h3>
            <form action="/upload" method="POST" enctype="multipart/form-data">
              <input type="file" name="file" required style="margin-bottom: 14px; display: block; width: 100%; color: #9CA3AF;">
              <button type="submit" class="btn">Upload to Device</button>
            </form>
          </div>

          <div class="card">
            <h3 style="margin-top: 0;">📥 Available Downloads</h3>
            <ul style="padding: 0; margin: 0;">$fileListHtml</ul>
          </div>
        </body>
        </html>
      ''';
      return Response.ok(html, headers: {'content-type': 'text/html'});
    });

    router.get('/download/<name>', (Request request, String name) {
      final decodedName = Uri.decodeComponent(name);
      final file = _selectedFiles.firstWhere(
        (f) => f.name == decodedName,
        orElse: () => _selectedFiles.first,
      );

      if (file.path != null) {
        final diskFile = File(file.path!);
        if (diskFile.existsSync()) {
          return Response.ok(
            diskFile.openRead(),
            headers: {
              'content-type': 'application/octet-stream',
              'content-disposition': 'attachment; filename="${file.name}"',
              'content-length': file.size.toString(),
            },
          );
        }
      } else if (file.bytes != null) {
        return Response.ok(
          file.bytes!,
          headers: {
            'content-type': 'application/octet-stream',
            'content-disposition': 'attachment; filename="${file.name}"',
          },
        );
      }
      return Response.notFound('File not found');
    });

    router.post('/upload', (Request request) async {
      final contentType = request.headers['content-type'] ?? '';
      if (!contentType.contains('multipart/form-data')) {
        return Response.badRequest(body: 'Expected multipart/form-data');
      }

      final bytes = await request.read().expand((b) => b).toList();
      final filename = 'received_${DateTime.now().millisecondsSinceEpoch}.bin';
      final downloadDir = Directory('/storage/emulated/0/Download');
      final targetPath = downloadDir.existsSync()
          ? '${downloadDir.path}/$filename'
          : '${Directory.systemTemp.path}/$filename';

      final file = File(targetPath);
      await file.writeAsBytes(bytes);

      setState(() => _receivedFiles.add(targetPath));

      return Response.ok('''
        <!DOCTYPE html>
        <html>
        <body style="background: #0B0F19; color: #10B981; font-family: sans-serif; text-align: center; padding: 40px;">
          <h2>File Transferred Successfully!</h2>
          <p style="color: #9CA3AF;">Saved to device storage.</p>
          <a href="/" style="color: #818CF8; text-decoration: none; font-weight: bold;">← Back to Transfer Portal</a>
        </body>
        </html>
      ''', headers: {'content-type': 'text/html'});
    });

    try {
      final server = await shelf_io.serve(router, InternetAddress.anyIPv4, _port);
      setState(() {
        _server = server;
        _isSharing = true;
      });
      _startBroadcasting();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start server: $e')),
        );
      }
    }
  }

  Future<void> _stopShareServer() async {
    _stopBroadcasting();
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    setState(() => _isSharing = false);
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _stopBroadcasting();
    _pruneTimer?.cancel();
    _udpSocket?.close();
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shareUrl = 'http://${_localIp ?? "127.0.0.1"}:$_port';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.bolt, color: Color(0xFF818CF8)),
            const SizedBox(width: 8),
            Text('ZShare (${_deviceName.split(" ").take(2).join(" ")})', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ],
        ),
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1F2937)),
              ),
              child: Row(
                children: [
                  Icon(
                    _isSharing ? Icons.wifi_tethering : Icons.wifi,
                    color: _isSharing ? Colors.greenAccent : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isSharing ? 'Sharing Active' : 'Ready on Local Network',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'IP: ${_localIp ?? "Detecting..."}',
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (_isSharing)
                    IconButton(
                      icon: const Icon(Icons.stop_circle, color: Colors.redAccent),
                      onPressed: _stopShareServer,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add),
              label: const Text('Choose Files to Share'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),

            // Quick Share Radar: Nearby Devices
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1F2937)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.radar, color: Color(0xFF818CF8), size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Nearby Devices (Quick Share)',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_nearbyPeers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: Text(
                          'Scanning for active ZShare devices on Wi-Fi...',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ),
                    )
                  else
                    ..._nearbyPeers.values.map((peer) {
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF6366F1).withOpacity(0.2),
                          child: const Icon(Icons.devices, color: Color(0xFF818CF8)),
                        ),
                        title: Text(peer.deviceName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: Text(
                          '${peer.ip} • ${peer.fileCount} file(s) available',
                          style: const TextStyle(color: Colors.grey, fontSize: 11),
                        ),
                        trailing: ElevatedButton(
                          onPressed: () => launchUrl(Uri.parse(peer.url), mode: LaunchMode.externalApplication),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1F2937),
                            foregroundColor: const Color(0xFF818CF8),
                          ),
                          child: const Text('Connect'),
                        ),
                      );
                    }),
                ],
              ),
            ),
            const SizedBox(height: 20),

            if (_isSharing) ...[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF6366F1).withOpacity(0.3)),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Direct Transfer URL & QR',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: QrImageView(
                        data: shareUrl,
                        version: QrVersions.auto,
                        size: 170,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SelectableText(
                      shareUrl,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xFF818CF8),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_receivedFiles.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Received Files:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ..._receivedFiles.map((p) => Text('• ${p.split('/').last}', style: const TextStyle(color: Colors.greenAccent, fontSize: 12))),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

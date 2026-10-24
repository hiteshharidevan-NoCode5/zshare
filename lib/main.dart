import 'dart:io';
import 'package:flutter/material.dart' hide Router;
import 'package:file_picker/file_picker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:qr_flutter/qr_flutter.dart';

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

class ZShareHome extends StatefulWidget {
  const ZShareHome({super.key});

  @override
  State<ZShareHome> createState() => _ZShareHomeState();
}

class _ZShareHomeState extends State<ZShareHome> {
  HttpServer? _server;
  String? _localIp;
  List<PlatformFile> _selectedFiles = [];
  final List<String> _receivedFiles = [];
  bool _isSharing = false;
  final int _port = 8888;

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
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

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _selectedFiles = result.files;
      });
      _startShareServer();
    }
  }

  Future<void> _startShareServer() async {
    await _stopShareServer();

    final router = shelf_router.Router();

    // Portal interface with both download list and direct upload
    router.get('/', (Request request) {
      final fileListHtml = _selectedFiles.isEmpty
          ? '<p style="color: #6B7280; font-size: 13px;">No files shared from host yet.</p>'
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
          <title>ZShare Transfer Portal</title>
          <style>
            body { background: #0B0F19; color: #F3F4F6; font-family: -apple-system, sans-serif; padding: 24px; text-align: center; }
            .card { background: #111827; border: 1px solid #1F2937; border-radius: 16px; padding: 20px; max-width: 500px; margin: 0 auto 20px auto; }
            .btn { background: #6366F1; color: white; border: none; padding: 10px 20px; border-radius: 8px; font-weight: bold; cursor: pointer; }
          </style>
        </head>
        <body>
          <h1 style="color: #818CF8; margin-bottom: 4px;">⚡ ZShare</h1>
          <p style="color: #9CA3AF; font-size: 13px; margin-bottom: 24px;">High-Speed Wi-Fi Transfer</p>

          <div class="card">
            <h3 style="margin-top: 0;">📤 Send File to Host</h3>
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

    // File download route
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

    // File upload route
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

      setState(() {
        _receivedFiles.add(targetPath);
      });

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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start server: $e')),
        );
      }
    }
  }

  Future<void> _stopShareServer() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    setState(() => _isSharing = false);
  }

  @override
  void dispose() {
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shareUrl = 'http://${_localIp ?? "127.0.0.1"}:$_port';

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bolt, color: Color(0xFF818CF8)),
            SizedBox(width: 8),
            Text('ZShare', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  Column(
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
            const SizedBox(height: 16),
            if (!_isSharing) ...[
              OutlinedButton.icon(
                onPressed: _startShareServer,
                icon: const Icon(Icons.arrow_downward, color: Color(0xFF818CF8)),
                label: const Text('Start Receive Mode Only', style: TextStyle(color: Color(0xFF818CF8))),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF6366F1)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
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
                      'Scan or Connect from Chromebook Browser',
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
                        size: 180,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      shareUrl,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xFF818CF8),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Open to send and receive files simultaneously',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
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

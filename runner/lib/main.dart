import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// underfoot iOS runner: executes the bundled prompt suite against the
/// OS-bundled Apple Foundation Models on this device and exports the capture.
///
/// The capture comes back over two paths so the desktop side can use
/// whichever works: (1) saved to the app's Documents directory (visible in
/// Finder/Files via UIFileSharingEnabled, pullable with `devicectl device
/// copy from`), and (2) printed to the console as base64 chunks between
/// UNDERFOOT-BEGIN / UNDERFOOT-END markers for `devicectl launch --console`.
void main() => runApp(const UnderfootRunnerApp());

class UnderfootRunnerApp extends StatelessWidget {
  const UnderfootRunnerApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: CaptureScreen(),
      );
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  static const _capture = MethodChannel('underfoot/capture');
  static const _progress = EventChannel('underfoot/progress');

  final List<String> _log = ['underfoot runner starting…'];
  String _status = 'running';

  @override
  void initState() {
    super.initState();
    _progress.receiveBroadcastStream().listen((event) {
      setState(() {
        _log.add('$event');
        if (_log.length > 200) _log.removeAt(0);
      });
    });
    _run();
  }

  Future<void> _run() async {
    try {
      final suiteBytes = await rootBundle.load('assets/core-v1.json');
      final suiteText = utf8.decode(suiteBytes.buffer
          .asUint8List(suiteBytes.offsetInBytes, suiteBytes.lengthInBytes));
      final captureJson = await _capture.invokeMethod<String>('run', suiteText);
      if (captureJson == null) {
        setState(() => _status = 'failed: engine returned nothing');
        return;
      }
      _emit(captureJson);
      setState(() => _status = 'done — capture saved to Documents');
    } catch (e) {
      // ignore: avoid_print
      print('UNDERFOOT-ERROR $e');
      setState(() => _status = 'failed: $e');
    }
  }

  /// Prints the capture as numbered base64 chunks; os_log truncates long
  /// lines, so chunks stay well under the limit.
  void _emit(String captureJson) {
    final encoded = base64Encode(utf8.encode(captureJson));
    const chunkSize = 600;
    final chunkCount = (encoded.length / chunkSize).ceil();
    // ignore: avoid_print
    print('UNDERFOOT-BEGIN chunks=$chunkCount bytes=${captureJson.length}');
    for (var i = 0; i < chunkCount; i++) {
      final end = (i + 1) * chunkSize;
      // ignore: avoid_print
      print(
          'DW$i:${encoded.substring(i * chunkSize, end > encoded.length ? encoded.length : end)}');
    }
    // ignore: avoid_print
    print('UNDERFOOT-END');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0d1117),
        appBar: AppBar(
          backgroundColor: const Color(0xFF161b22),
          title: Text('underfoot — $_status',
              style: const TextStyle(color: Colors.white, fontSize: 16)),
        ),
        body: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _log.length,
          itemBuilder: (context, i) => Text(
            _log[i],
            style: const TextStyle(
                color: Color(0xFF3fb950), fontFamily: 'Menlo', fontSize: 11),
          ),
        ),
      );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Живой сканер: наводите камеру — штрих-код считывается сам.
class ScannerPage extends StatefulWidget {
  static const manual = '__manual__';
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final MobileScannerController ctrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.itf,
      BarcodeFormat.qrCode,
    ],
  );
  bool done = false;
  bool torch = false;

  void _onDetect(BarcodeCapture cap) {
    if (done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(v.trim());
        return;
      }
    }
  }

  Future<void> _typeCode() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Цифры штрих-кода'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '8801234567890'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Готово')),
        ],
      ),
    );
    if (v != null && v.isNotEmpty && mounted) {
      done = true;
      Navigator.of(context).pop(v);
    }
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: MobileScanner(controller: ctrl, onDetect: _onDetect)),
          Center(
            child: Container(
              width: 290,
              height: 180,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(
                    onPressed: () {
                      ctrl.toggleTorch();
                      setState(() => torch = !torch);
                    },
                    icon: Icon(torch ? Icons.flash_off : Icons.flash_on),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Наведите камеру на штрих-код —\nон считается автоматически',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: _typeCode,
                            child: const Text('Ввести цифры'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: () {
                              done = true;
                              Navigator.pop(context, ScannerPage.manual);
                            },
                            child: const Text('Нет штрих-кода'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

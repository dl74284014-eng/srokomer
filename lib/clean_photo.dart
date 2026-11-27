import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:image/image.dart' as img;

/// «Как сканер»: находит товар на фото (ML Kit, на телефоне), убирает фон (белый),
/// кадрирует по товару и ставит его по центру. Результат — квадрат 1024×1024.
/// Если товар не найден или что-то пошло не так — null (остаётся обычное фото).
Future<List<int>?> cleanProductPhoto(String src) async {
  SubjectSegmenter? seg;
  try {
    seg = SubjectSegmenter(
      options: SubjectSegmenterOptions(
        enableForegroundBitmap: false,
        enableForegroundConfidenceMask: true,
        enableMultipleSubjects: SubjectResultOptions(enableConfidenceMask: false, enableSubjectBitmap: false),
      ),
    );
    final r = await seg.processImage(InputImage.fromFilePath(src)).timeout(const Duration(seconds: 15));
    final dynamic raw = r.foregroundConfidenceMask;
    if (raw is! List || raw.isEmpty) return null;
    final mask = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      mask[i] = (raw[i] as num).toDouble();
    }
    final bytes = await File(src).readAsBytes();
    return await Isolate.run(() => _compose(bytes, mask));
  } catch (_) {
    return null;
  } finally {
    try {
      await seg?.close();
    } catch (_) {}
  }
}

List<int>? _compose(Uint8List bytes, Float32List mask) {
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  final w = im.width, h = im.height;
  if (mask.length != w * h) return null;

  var x0 = w, y0 = h, x1 = -1, y1 = -1, cnt = 0;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (mask[row + x] > 0.5) {
        cnt++;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  // товар не найден, или «товар» — почти всё фото: оставляем как есть
  if (cnt < w * h * 0.03 || cnt > w * h * 0.97) return null;

  final bw = x1 - x0 + 1, bh = y1 - y0 + 1;
  final pad = (max(bw, bh) * 0.07).round();
  final side = max(bw, bh) + 2 * pad;
  final out = img.Image(width: side, height: side);
  img.fill(out, color: img.ColorRgb8(255, 255, 255));
  final ox = (side - bw) ~/ 2 - x0, oy = (side - bh) ~/ 2 - y0;
  for (var y = y0; y <= y1; y++) {
    final row = y * w;
    for (var x = x0; x <= x1; x++) {
      // мягкий край: уверенность 0.25…0.65 → плавный переход в белый
      final a = ((mask[row + x] - 0.25) / 0.4).clamp(0.0, 1.0);
      if (a <= 0) continue;
      final p = im.getPixel(x, y);
      final r = (p.r * a + 255 * (1 - a)).round();
      final g = (p.g * a + 255 * (1 - a)).round();
      final b = (p.b * a + 255 * (1 - a)).round();
      out.setPixelRgb(x + ox, y + oy, r, g, b);
    }
  }
  // ровно 1024 px — как все фото приложения (по этому размеру приложение узнаёт свои фото)
  final res = img.copyResize(out, width: 1024, height: 1024, interpolation: img.Interpolation.average);
  return img.encodeJpg(res, quality: 85);
}

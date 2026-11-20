import 'dart:convert';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;

// ================= Поиск товара по штрих-коду в интернете =================
class OnlineProduct {
  final String name;
  final String imageUrl;
  final String hint;
  OnlineProduct(this.name, this.imageUrl, this.hint);
}

Future<OnlineProduct?> lookupOnline(String code) async {
  if (!RegExp(r'^\d{8,14}$').hasMatch(code)) return null;
  try {
    final uri = Uri.parse(
        'https://world.openfoodfacts.org/api/v2/product/$code.json?fields=product_name,product_name_ko,product_name_en,generic_name,brands,quantity,image_front_url,image_url,categories_tags');
    final r = await http.get(uri, headers: {
      'User-Agent': 'Srokomer/1.0 (Android; personal use)'
    }).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map || j['product'] is! Map) return null;
    final p = Map<String, dynamic>.from(j['product'] as Map);
    String s(String k) => (p[k] ?? '').toString().trim();
    var name = s('product_name_ko');
    if (name.isEmpty) name = s('product_name');
    if (name.isEmpty) name = s('product_name_en');
    if (name.isEmpty) name = s('generic_name');
    if (name.isEmpty) return null;
    final brand = s('brands').split(',').first.trim();
    if (brand.isNotEmpty && !name.toLowerCase().contains(brand.toLowerCase())) {
      name = '$brand $name';
    }
    final q = s('quantity');
    if (q.isNotEmpty && !name.contains(q)) name = '$name $q';
    final img = s('image_front_url').isNotEmpty ? s('image_front_url') : s('image_url');
    final tags = (p['categories_tags'] is List) ? (p['categories_tags'] as List).join(' ') : '';
    return OnlineProduct(name, img, tags);
  } catch (_) {
    return null;
  }
}

Future<List<int>?> download(String url) async {
  try {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
    if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) return r.bodyBytes;
  } catch (_) {}
  return null;
}

// ================= Распознавание текста (на телефоне, без интернета) =================
class OcrLine {
  final String text;
  final double height;
  OcrLine(this.text, this.height);
}

Future<List<OcrLine>> ocrLines(String path) async {
  final rec = TextRecognizer(script: TextRecognitionScript.korean);
  try {
    final res = await rec.processImage(InputImage.fromFilePath(path));
    final out = <OcrLine>[];
    for (final b in res.blocks) {
      for (final l in b.lines) {
        final t = l.text.trim();
        if (t.isNotEmpty) out.add(OcrLine(t, l.boundingBox.height.toDouble()));
      }
    }
    return out;
  } finally {
    await rec.close();
  }
}

/// Варианты названия: самые крупные строки, без цифр-мусора.
List<String> nameCandidates(List<OcrLine> lines) {
  final junk = RegExp(r'^[\d\s.,:;/\-()%*+#]+$');
  final skipWords = ['소비기한', '유통기한', '제조일', '원재료', '영양', '보관', '바코드', '반품', '교환', '고객', '주소', 'kcal'];
  final c = lines.where((l) {
    final t = l.text;
    if (t.length < 2) return false;
    if (junk.hasMatch(t)) return false;
    for (final w in skipWords) {
      if (t.contains(w)) return false;
    }
    return true;
  }).toList()
    ..sort((a, b) => b.height.compareTo(a.height));
  final seen = <String>{};
  final out = <String>[];
  for (final l in c) {
    if (seen.add(l.text)) out.add(l.text);
    if (out.length >= 8) break;
  }
  return out;
}

class FoundDate {
  final String iso;
  final String raw;
  FoundDate(this.iso, this.raw);
}

/// Ищет срок годности: приоритет строкам рядом с 소비기한/유통기한/까지/EXP.
FoundDate? findExpiry(List<OcrLine> lines) {
  final keys = ['소비기한', '유통기한', '까지', 'exp', 'best before', 'bb'];
  final mfg = ['제조', 'mfg', 'prod'];
  final re = RegExp(r'(20\d{2}|\d{2})\s*[.\-/년]\s*(\d{1,2})\s*[.\-/월]\s*(\d{1,2})');
  final re8 = RegExp(r'(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)');
  final now = DateTime.now();
  final cands = <({DateTime d, int score, String raw})>[];

  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].text;
    final low = t.toLowerCase();
    final prev = i > 0 ? lines[i - 1].text.toLowerCase() : '';
    var score = 0;
    if (keys.any((k) => low.contains(k))) score += 3;
    if (keys.any((k) => prev.contains(k))) score += 2;
    if (mfg.any((k) => low.contains(k))) score -= 4;
    void add(int y, int m, int d, String raw) {
      if (y < 100) y += 2000;
      if (m < 1 || m > 12 || d < 1 || d > 31) return;
      final dt = DateTime(y, m, d);
      if (dt.month != m || dt.day != d) return;
      if (y < now.year - 2 || y > now.year + 10) return;
      cands.add((d: dt, score: score, raw: raw));
    }

    for (final m in re.allMatches(t)) {
      add(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), m.group(0)!);
    }
    for (final m in re8.allMatches(t)) {
      add(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), m.group(0)!);
    }
  }
  if (cands.isEmpty) return null;
  cands.sort((a, b) {
    final s = b.score.compareTo(a.score);
    return s != 0 ? s : b.d.compareTo(a.d); // при равенстве — более поздняя дата
  });
  final best = cands.first;
  final iso =
      '${best.d.year}-${best.d.month.toString().padLeft(2, '0')}-${best.d.day.toString().padLeft(2, '0')}';
  return FoundDate(iso, best.raw);
}

import 'dart:convert';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;

// ================= Поиск товара по штрих-коду =================
// Порядок: 식약처 (C005 → I2570) → Open Food Facts → поиск Kakao (Daum).
class LookupResult {
  String name;
  String maker;
  String type;
  String imageUrl;
  String source;
  bool guess; // true — название угадано по поиску, обязательно переспросить
  List<String> alternatives;
  LookupResult(this.name,
      {this.maker = '', this.type = '', this.imageUrl = '', this.source = '', this.guess = false, List<String>? alternatives})
      : alternatives = alternatives ?? [];
}

const _timeout = Duration(seconds: 10);

Future<LookupResult?> lookupBarcode(String code, {String mfdsKey = '', String kakaoKey = ''}) async {
  LookupResult? r;
  if (mfdsKey.isNotEmpty) {
    r = await _mfds(mfdsKey, 'C005', 'BAR_CD', code);
    r ??= await _mfds(mfdsKey, 'I2570', 'BRCD_NO', code);
  }
  r ??= await _off(code);
  if (r == null && kakaoKey.isNotEmpty) r = await _kakaoGuess(kakaoKey, code);
  if (r != null) r.imageUrl = ''; // фото из интернета не используем — только свои снимки
  return r;
}

String _s(Map m, String k) => (m[k] ?? '').toString().trim();

/// 식품의약품안전처 OpenAPI (foodsafetykorea.go.kr)
Future<LookupResult?> _mfds(String key, String svc, String param, String code) async {
  try {
    final uri = Uri.parse('http://openapi.foodsafetykorea.go.kr/api/$key/$svc/json/1/5/$param=$code');
    final r = await http.get(uri).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map || j[svc] is! Map) return null;
    final rows = (j[svc] as Map)['row'];
    if (rows is! List || rows.isEmpty) return null;
    final row = rows.first as Map;
    final name = svc == 'C005' ? _s(row, 'PRDLST_NM') : (_s(row, 'PRDT_NM').isNotEmpty ? _s(row, 'PRDT_NM') : _s(row, 'PRDLST_NM'));
    if (name.isEmpty) return null;
    final maker = svc == 'C005' ? _s(row, 'BSSH_NM') : _s(row, 'CMPNY_NM');
    final type = svc == 'C005'
        ? _s(row, 'PRDLST_DCNM')
        : [_s(row, 'HRNK_PRDLST_NM'), _s(row, 'PRDLST_NM')].where((e) => e.isNotEmpty).join(' ');
    return LookupResult(name, maker: maker, type: type, source: '식약처');
  } catch (_) {
    return null;
  }
}

/// Проверка ключа 식약처: null — работает, иначе текст ошибки.
Future<String?> testMfdsKey(String key) async {
  try {
    final r = await http
        .get(Uri.parse('http://openapi.foodsafetykorea.go.kr/api/$key/C005/json/1/1'))
        .timeout(_timeout);
    if (r.statusCode != 200) return 'HTTP ${r.statusCode}';
    final body = utf8.decode(r.bodyBytes);
    final j = jsonDecode(body);
    if (j is Map && j['C005'] is Map) {
      final res = (j['C005'] as Map)['RESULT'];
      final c = res is Map ? _s(res, 'CODE') : '';
      if (c == 'INFO-000' || c == 'INFO-200') return null;
      return res is Map ? '${_s(res, 'CODE')} ${_s(res, 'MSG')}' : body;
    }
    if (j is Map && j['RESULT'] is Map) return '${_s(j['RESULT'], 'CODE')} ${_s(j['RESULT'], 'MSG')}';
    return body.length > 200 ? body.substring(0, 200) : body;
  } catch (e) {
    return '$e';
  }
}

/// Open Food Facts (мировая база, корейских товаров немного)
Future<LookupResult?> _off(String code) async {
  if (!RegExp(r'^\d{8,14}$').hasMatch(code)) return null;
  try {
    final uri = Uri.parse(
        'https://world.openfoodfacts.org/api/v2/product/$code.json?fields=product_name,product_name_ko,product_name_en,generic_name,brands,quantity,image_front_url,image_url,categories_tags');
    final r = await http.get(uri, headers: {'User-Agent': 'Srokomer/1.1 (Android; personal use)'}).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map || j['product'] is! Map) return null;
    final p = j['product'] as Map;
    var name = _s(p, 'product_name_ko');
    if (name.isEmpty) name = _s(p, 'product_name');
    if (name.isEmpty) name = _s(p, 'product_name_en');
    if (name.isEmpty) name = _s(p, 'generic_name');
    if (name.isEmpty) return null;
    final brand = _s(p, 'brands').split(',').first.trim();
    if (brand.isNotEmpty && !name.toLowerCase().contains(brand.toLowerCase())) name = '$brand $name';
    final q = _s(p, 'quantity');
    if (q.isNotEmpty && !name.contains(q)) name = '$name $q';
    final img = _s(p, 'image_front_url').isNotEmpty ? _s(p, 'image_front_url') : _s(p, 'image_url');
    final tags = (p['categories_tags'] is List) ? (p['categories_tags'] as List).join(' ') : '';
    return LookupResult(name, imageUrl: img, type: tags, source: 'Open Food Facts');
  } catch (_) {
    return null;
  }
}

String _clean(String s) {
  s = s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  // убрать хвосты вида " : 네이버 쇼핑", " - 쿠팡!", " | 사이트"
  s = s.split(RegExp(r'\s[|:\-–]\s')).first;
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Поиск Kakao (Daum) по цифрам штрих-кода: заголовки страниц магазинов обычно содержат название.
Future<LookupResult?> _kakaoGuess(String key, String code) async {
  try {
    final uri = Uri.https('dapi.kakao.com', '/v2/search/web', {'query': code, 'size': '15'});
    final r = await http.get(uri, headers: {'Authorization': 'KakaoAK $key'}).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final docs = (j is Map && j['documents'] is List) ? j['documents'] as List : const [];
    final titles = <String>[];
    for (final d in docs) {
      if (d is! Map) continue;
      var tt = _clean(_s(d, 'title')).replaceAll(code, '').trim();
      tt = tt.replaceAll(RegExp(r'^[\s\-:|,]+|[\s\-:|,]+$'), '');
      if (tt.length < 2 || RegExp(r'^[\d\s]+$').hasMatch(tt)) continue;
      if (!titles.contains(tt)) titles.add(tt);
      if (titles.length >= 6) break;
    }
    if (titles.isEmpty) return null;
    return LookupResult(titles.first, source: 'Daum', guess: true, alternatives: titles);
  } catch (_) {
    return null;
  }
}

/// Картинка товара через поиск изображений Kakao (Daum).
Future<String?> kakaoImage(String key, String name) async {
  try {
    final uri = Uri.https('dapi.kakao.com', '/v2/search/image', {'query': name, 'size': '5'});
    final r = await http.get(uri, headers: {'Authorization': 'KakaoAK $key'}).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final docs = (j is Map && j['documents'] is List) ? j['documents'] as List : const [];
    for (final d in docs) {
      if (d is Map) {
        final u = _s(d, 'image_url');
        final th = _s(d, 'thumbnail_url');
        if (u.isNotEmpty || th.isNotEmpty) return '$u\n$th'; // основной + запасной URL
      }
    }
  } catch (_) {}
  return null;
}

/// Название без объёма/веса/количества — для поиска картинок.
String shortName(String name) => name
    .replaceAll(RegExp(r'\(?\d+([.,]\d+)?\s*(ml|mL|ML|l|L|g|G|kg|KG|Kg|개입|개|입|병|매|팩|봉|캔|CAN|can|box|BOX)\s*([x×*X]\s*\d+\s*(개입|개|입|병|매|팩|봉|캔|ea|EA)?)?\)?'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class WebImage {
  final String full, thumb;
  WebImage(this.full, this.thumb);
  String get both => '$full\n$thumb';
}

String lastImageError = '';

/// Несколько картинок товара из поиска Kakao (Daum): сначала по полному названию, затем по короткому.
Future<List<WebImage>> kakaoImages(String key, String name, {int size = 12}) async {
  lastImageError = '';
  final out = <WebImage>[];
  final queries = <String>{name.trim(), shortName(name)}..removeWhere((q) => q.length < 2);
  for (final q in queries) {
    try {
      final uri = Uri.https('dapi.kakao.com', '/v2/search/image', {'query': q, 'size': '$size'});
      final r = await http.get(uri, headers: {'Authorization': 'KakaoAK $key'}).timeout(_timeout);
      if (r.statusCode != 200) {
        lastImageError = 'Kakao HTTP ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
        continue;
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final docs = (j is Map && j['documents'] is List) ? j['documents'] as List : const [];
      for (final d in docs) {
        if (d is! Map) continue;
        final u = _s(d, 'image_url'), th = _s(d, 'thumbnail_url');
        if (u.isEmpty && th.isEmpty) continue;
        out.add(WebImage(u, th.isNotEmpty ? th : u));
      }
      if (out.length >= 4) break;
    } catch (e) {
      lastImageError = '$e';
    }
  }
  return out;
}

/// Проверка ключа Kakao: null — работает.
Future<String?> testKakaoKey(String key) async {
  try {
    final uri = Uri.https('dapi.kakao.com', '/v2/search/image', {'query': '우유', 'size': '1'});
    final r = await http.get(uri, headers: {'Authorization': 'KakaoAK $key'}).timeout(_timeout);
    if (r.statusCode == 200) return null;
    final b = utf8.decode(r.bodyBytes);
    return 'HTTP ${r.statusCode} ${b.length > 200 ? b.substring(0, 200) : b}';
  } catch (e) {
    return '$e';
  }
}

/// Скачивает картинку (поддерживает несколько URL через перевод строки — берёт первый рабочий).
Future<List<int>?> download(String urls) async {
  for (final url in urls.split('\n')) {
    if (url.trim().isEmpty) continue;
    try {
      final r = await http.get(Uri.parse(url.trim()), headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'
      }).timeout(const Duration(seconds: 12));
      final ct = r.headers['content-type'] ?? '';
      if (r.statusCode == 200 && r.bodyBytes.length > 500 && (ct.isEmpty || ct.startsWith('image'))) {
        return r.bodyBytes;
      }
    } catch (_) {}
  }
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

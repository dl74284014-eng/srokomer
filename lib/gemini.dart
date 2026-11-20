import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'store.dart';

/// Распознавание упаковки через Google Gemini (точнее встроенного ML Kit).
class GeminiResult {
  final List<String> names; // варианты названия, первый — самый вероятный
  final String category;
  final String expiry; // YYYY-MM-DD или ''
  final String rawDate;
  GeminiResult(this.names, this.category, this.expiry, this.rawDate);
}

// Быстрые модели без «размышлений» — ответ за 1–3 секунды
const _models = ['gemini-flash-lite-latest', 'gemini-2.5-flash-lite', 'gemini-flash-latest'];

String _prompt() {
  final cats = [for (final c in cats_) c].join(', ');
  final now = DateTime.now();
  final today =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return '''
You read product packaging photos from a Korean supermarket.
Return ONLY JSON:
{"names": ["exact product name as printed", "alternative 1", "alternative 2"],
 "category": "one key from: $cats",
 "expiry": "YYYY-MM-DD or empty",
 "expiry_raw": "date text exactly as printed or empty"}
Rules:
- Copy the product name EXACTLY as printed on the package, character by character, in the original language (usually Korean). Keep brand, special characters (®, ™, ·, %, -, +, /, &, parentheses) and size/volume (e.g. 200ml, 1L, 500g) if printed near the name.
- Do NOT translate. Do NOT invent text that is not visible. Do NOT include slogans, nutrition facts, ingredients or company addresses.
- "names": first the most likely full product name, then up to 2 alternatives (shorter or with/without brand).
- "expiry": the expiry / best-before date (소비기한, 유통기한, 까지, EXP, BEST BEFORE). NOT the manufacturing date (제조일, MFG). Korean dates are often YYYY.MM.DD or YY.MM.DD. Today is $today. Empty if not visible.
- If no product name is visible, return "names": [].
''';
}

final cats_ = cats.map((c) => c.k).toList();

/// null — ключа нет или не удалось (тогда используется ML Kit).
Future<GeminiResult?> geminiRead(String imagePath) async {
  final key = store.geminiKey;
  if (key.isEmpty) return null;
  final bytes = await File(imagePath).readAsBytes();
  final body = jsonEncode({
    'contents': [
      {
        'parts': [
          {'text': _prompt()},
          {
            'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}
          },
        ]
      }
    ],
    'generationConfig': {'temperature': 0, 'responseMimeType': 'application/json'},
  });
  for (final m in _models) {
    try {
      final r = await http
          .post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent'),
            headers: {'x-goog-api-key': key, 'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) continue; // модель недоступна — пробуем следующую
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final parts = j['candidates']?[0]?['content']?['parts'];
      if (parts is! List) return null;
      final text = parts.map((p) => (p is Map ? (p['text'] ?? '') : '').toString()).join();
      final mm = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (mm == null) return null;
      final o = jsonDecode(mm.group(0)!) as Map;
      final names = ((o['names'] as List?) ?? [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      final cat = (o['category'] ?? '').toString();
      var exp = (o['expiry'] ?? '').toString().trim();
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(exp) || parseIso(exp) == null) exp = '';
      return GeminiResult(names, catMap.containsKey(cat) ? cat : 'other', exp, (o['expiry_raw'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Проверка ключа: null — работает.
Future<String?> testGeminiKey(String key) async {
  try {
    final r = await http
        .get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1'),
            headers: {'x-goog-api-key': key})
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 200) return null;
    final b = utf8.decode(r.bodyBytes);
    return 'HTTP ${r.statusCode} ${b.length > 200 ? b.substring(0, 200) : b}';
  } catch (e) {
    return '$e';
  }
}

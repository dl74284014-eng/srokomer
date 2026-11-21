import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;


import 'models.dart';
import 'store.dart';

final _client = http.Client(); // одно соединение на всё время — без повторных рукопожатий

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
  final now = DateTime.now();
  final today =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return '''
Korean supermarket product photo. Return ONLY JSON:
{"names":["full name","shorter variant"],"expiry":"YYYY-MM-DD or empty","expiry_raw":"date as printed"}
"names"[0] = everything that would be on a price tag, copied EXACTLY as printed (original language, no translation, keep special characters ®·%-+/&()): brand + product name + flavor/variant + size and count, e.g. "농심 신라면 120g×5", "서울우유 1급A 우유 1000ml", "CJ 비비고 왕교자 1.05kg".
Size/weight/volume/count (ml, L, g, kg, 개, 개입, 입, 매, ×N) MUST be included if visible anywhere on the package.
"names"[1] = short name without size. No slogans, ingredients, nutrition, addresses. Invent nothing.
"expiry": 소비기한/유통기한/까지/EXP date, NOT 제조일/MFG. Dates look like YYYY.MM.DD or YY.MM.DD. Today $today.
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
    'generationConfig': {'temperature': 0, 'maxOutputTokens': 200, 'responseMimeType': 'application/json'},
  });
  for (final m in _models) {
    try {
      final r = await _client
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
      const cat = 'other';
      var exp = (o['expiry'] ?? '').toString().trim();
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(exp) || parseIso(exp) == null) exp = '';
      return GeminiResult(names, cat, exp, (o['expiry_raw'] ?? '').toString());
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

/// Заранее открыть соединение с Google, чтобы первое распознавание было быстрее.
Future<void> geminiWarmUp() async {
  final key = store.geminiKey;
  if (key.isEmpty) return;
  try {
    await _client
        .get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1'),
            headers: {'x-goog-api-key': key})
        .timeout(const Duration(seconds: 8));
  } catch (_) {}
}

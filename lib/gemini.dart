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

// Варианты (модель + настройки) от самого быстрого. Первый сработавший запоминается,
// чтобы в следующий раз не тратить время на неподходящие.
const _variants = <(String, Map<String, Object>?)>[
  ('gemini-flash-lite-latest', {'thinkingBudget': 0}),
  ('gemini-flash-lite-latest', {'thinkingLevel': 'minimal'}),
  ('gemini-2.5-flash-lite', {'thinkingBudget': 0}),
  ('gemini-flash-lite-latest', null),
  ('gemini-flash-latest', {'thinkingLevel': 'minimal'}),
  ('gemini-flash-latest', {'thinkingBudget': 0}),
  ('gemini-flash-latest', null),
];

/// Сколько длился последний ответ Gemini (мс) — показывается в окне распознавания.
int lastGeminiMs = 0;

const _catGuide = '''Categories (key: what belongs there):
milk: dairy — 우유, 가공유, 요거트/요구르트, 치즈, 버터, 생크림, 두유 (soy milk)
meat: 육류 — pork, beef, chicken, 햄, 소시지, 베이컨, 스팸
fish: 수산 — fish, seafood, 어묵, 맛살, 젓갈, frozen shrimp
veg: fresh fruits and vegetables, 버섯, 샐러드
kimchi: 김치, 반찬, 단무지, 장아찌, 나물
tofu: 두부, 계란/달걀, 메추리알
noodle: 라면, 컵라면, 국수, 우동, 냉면, 파스타
ready: 도시락, 김밥, 삼각김밥, 즉석식품/HMR, 샌드위치, 밀키트, 죽, 국/찌개 팩
frozen: 냉동식품, 아이스크림, 만두, 냉동피자
bread: 빵, 케이크, 베이커리, 떡
snack: 과자, 초콜릿, 사탕, 젤리, 견과, 쿠키
drink: 음료 — 탄산음료, 주스, 커피, 차, 생수, 이온/에너지 음료, 홍삼·건강 음료, 무알콜 음료
alcohol: 주류 — 소주, 맥주, 막걸리, 와인, 하이볼, 위스키, 사케/청주, 과실주, 양주 (any drink containing alcohol)
sauce: 소스, 장류(고추장/된장/간장), 양념, 조미료, 케첩, 마요네즈, 드레싱
grocery: 쌀, 즉석밥, 밀가루, 설탕, 소금, 식용유, 통조림, 김(조미김), 시리얼, 잼, 꿀
other: anything else (non-food, household, gift sets of mixed goods)''';

String _prompt() {
  final now = DateTime.now();
  final today =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return '''
Korean supermarket product photo. Return ONLY JSON:
{"names":["full name","shorter variant"],"category":"one key","expiry":"YYYY-MM-DD or empty","expiry_raw":"date as printed"}
"names"[0] = everything that would be on a price tag, copied EXACTLY as printed (original language, no translation, keep special characters ®·%-+/&()): brand + product name + flavor/variant + size and count, e.g. "농심 신라면 120g×5", "서울우유 1급A 우유 1000ml", "CJ 비비고 왕교자 1.05kg".
Size/weight/volume/count (ml, L, g, kg, 개, 개입, 입, 매, ×N) MUST be included if visible anywhere on the package.
"names"[1] = short name without size. No slogans, ingredients, nutrition, addresses. Invent nothing.
"expiry": 소비기한/유통기한/까지/EXP date, NOT 제조일/MFG. Dates look like YYYY.MM.DD or YY.MM.DD. Today $today.
"category": choose the single best key for what the product IS (look at the photo and the name).
$_catGuide
''';
}

final cats_ = cats.map((c) => c.k).toList();

bool _keyInQuery = false;
String _rejectedKey = ''; // ключ отклонён — до смены ключа не тратим время на Gemini // запомнить, если ключ принимается только в адресе запроса

Future<http.Response> _post(String model, String key, String body) async {
  Future<http.Response> send(bool inQuery) => _client
      .post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'
            '${inQuery ? '?key=${Uri.encodeQueryComponent(key)}' : ''}'),
        headers: {if (!inQuery) 'x-goog-api-key': key, 'Content-Type': 'application/json'},
        body: body,
      )
      .timeout(const Duration(seconds: 15));
  var r = await send(_keyInQuery);
  if (r.statusCode == 401 && !_keyInQuery) {
    final r2 = await send(true);
    if (r2.statusCode != 401) {
      _keyInQuery = true;
      r = r2;
    }
  }
  return r;
}

/// null — ключа нет или не удалось (тогда используется ML Kit).
Future<GeminiResult?> geminiRead(String imagePath) async {
  lastGeminiMs = 0;
  final key = store.geminiKey;
  if (key.isEmpty || key == _rejectedKey) return null; // сразу встроенное распознавание
  final sw = Stopwatch()..start();
  final b64 = base64Encode(await File(imagePath).readAsBytes());
  final start = int.tryParse(store.settings['gemVariant'] ?? '') ?? 0;
  for (var k = 0; k < _variants.length; k++) {
    final idx = (start + k) % _variants.length;
    final (model, thinking) = _variants[idx];
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': _prompt()},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': b64}
            },
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0,
        'maxOutputTokens': 180,
        'responseMimeType': 'application/json',
        if (thinking != null) 'thinkingConfig': thinking,
      },
    });
    try {
      final r = await _post(model, key, body);
      // 400/404 — эта модель или настройка не подходит: следующий вариант
      if (r.statusCode == 400 || r.statusCode == 404) continue;
      if (r.statusCode == 401 || r.statusCode == 403) {
        _rejectedKey = key;
        return null;
      }
      if (r.statusCode != 200) return null;
      if (idx != start) {
        store.settings['gemVariant'] = '$idx';
        store.save();
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final parts = j['candidates']?[0]?['content']?['parts'];
      if (parts is! List) return null;
      final text = parts.map((p) => (p is Map && p['thought'] != true ? (p['text'] ?? '') : '').toString()).join();
      final mm = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (mm == null) return null;
      final o = jsonDecode(mm.group(0)!) as Map;
      final names = ((o['names'] as List?) ?? [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      var exp = (o['expiry'] ?? '').toString().trim();
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(exp) || parseIso(exp) == null) exp = '';
      lastGeminiMs = sw.elapsedMilliseconds;
      final cat = (o['category'] ?? '').toString().trim();
      return GeminiResult(names, catMap.containsKey(cat) ? cat : 'other', exp, (o['expiry_raw'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Проверка ключа настоящим (маленьким) запросом распознавания — так же, как работает приложение.
/// null — работает.
Future<String?> testGeminiKey(String key) async {
  String? last;
  for (final (model, thinking) in _variants) {
    try {
      final r = await _post(model, key, jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': 'Reply with: ok'}
                  ]
                }
              ],
              'generationConfig': {'maxOutputTokens': 5, if (thinking != null) 'thinkingConfig': thinking},
            }));
      if (r.statusCode == 200) return null;
      final b = utf8.decode(r.bodyBytes);
      last = 'HTTP ${r.statusCode} ${b.length > 160 ? b.substring(0, 160) : b}';
      if (r.statusCode == 401 || r.statusCode == 403) return last; // ключ отклонён — дальше пробовать нет смысла
    } catch (e) {
      last = '$e';
    }
  }
  return last;
}

/// Заранее открыть соединение с Google (без запроса к списку моделей — новые ключи AQ. его не принимают).
Future<void> geminiWarmUp() async {
  try {
    await _client.head(Uri.parse('https://generativelanguage.googleapis.com/')).timeout(const Duration(seconds: 8));
  } catch (_) {}
}

/// Названия товаров с нескольких фото за один запрос (быстрее и не упирается в лимиты).
/// Возвращает список той же длины ('' — не прочитано), или null, если Gemini недоступен.
Future<List<String>?> geminiReadNames(List<String> paths) async {
  final key = store.geminiKey;
  if (key.isEmpty || key == _rejectedKey) return null;
  final parts = <Map<String, Object>>[
    {
      'text': 'You get ${paths.length} photos of products from a Korean supermarket, in order. '
          'For EACH photo return the product name exactly as printed on the package: brand + name + flavor/variant + '
          'size/count (ml, L, g, kg, 개입, ×N; for multi-packs/combos like "코카콜라 1.5L + 스프라이트 1.5L" include every part). '
          'Original language, no translation. If a photo has no readable product name, use "". '
          'Return ONLY JSON: {"names": ["...", "..."]} with exactly ${paths.length} entries in the same order.'
    },
  ];
  for (final p in paths) {
    parts.add({
      'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(await File(p).readAsBytes())}
    });
  }
  final start = int.tryParse(store.settings['gemVariant'] ?? '') ?? 0;
  for (var attempt = 0; attempt < 5; attempt++) {
    final (model, thinking) = _variants[start % _variants.length];
    final body = jsonEncode({
      'contents': [
        {'parts': parts}
      ],
      'generationConfig': {
        'temperature': 0,
        'maxOutputTokens': 120 * paths.length + 50,
        'responseMimeType': 'application/json',
        if (thinking != null) 'thinkingConfig': thinking,
      },
    });
    try {
      final r = await _post(model, key, body);
      if (r.statusCode == 429 || r.statusCode >= 500) {
        await Future.delayed(Duration(seconds: 10 + attempt * 10)); // лимит — подождать и повторить
        continue;
      }
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final ps = j['candidates']?[0]?['content']?['parts'];
      if (ps is! List) return null;
      final text = ps.map((p) => (p is Map && p['thought'] != true ? (p['text'] ?? '') : '').toString()).join();
      final mm = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (mm == null) return null;
      final names = ((jsonDecode(mm.group(0)!) as Map)['names'] as List?) ?? [];
      return List.generate(paths.length, (i) => i < names.length ? names[i].toString().trim() : '');
    } catch (_) {
      await Future.delayed(const Duration(seconds: 3));
    }
  }
  return null;
}


/// Категории для списка названий (без фото, один запрос на 40 товаров). null — Gemini недоступен.
Future<List<String>?> geminiCategorize(List<String> names) async {
  final key = store.geminiKey;
  if (key.isEmpty || key == _rejectedKey) return null;
  final list = [for (var i = 0; i < names.length; i++) '$i. ${names[i]}'].join('\n');
  final body = jsonEncode({
    'contents': [
      {
        'parts': [
          {
            'text': 'Korean supermarket products. For each product choose the single best category key.\n'
                '$_catGuide\n\nProducts:\n$list\n\n'
                'Return ONLY JSON: {"cats": ["key", ...]} with exactly ${names.length} keys in the same order.'
          }
        ]
      }
    ],
    'generationConfig': {'temperature': 0, 'maxOutputTokens': 20 * names.length + 50, 'responseMimeType': 'application/json'},
  });
  final start = int.tryParse(store.settings['gemVariant'] ?? '') ?? 0;
  for (var attempt = 0; attempt < 4; attempt++) {
    final (model, _) = _variants[start % _variants.length];
    try {
      final r = await _post(model, key, body);
      if (r.statusCode == 429 || r.statusCode >= 500) {
        await Future.delayed(Duration(seconds: 10 + attempt * 10));
        continue;
      }
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final ps = j['candidates']?[0]?['content']?['parts'];
      if (ps is! List) return null;
      final text = ps.map((p) => (p is Map && p['thought'] != true ? (p['text'] ?? '') : '').toString()).join();
      final mm = RegExp(r'\{[\s\S]*\}').firstMatch(text);
      if (mm == null) return null;
      final out = ((jsonDecode(mm.group(0)!) as Map)['cats'] as List?) ?? [];
      return List.generate(names.length, (i) {
        final k = i < out.length ? out[i].toString().trim() : '';
        return catMap.containsKey(k) ? k : 'other';
      });
    } catch (_) {
      await Future.delayed(const Duration(seconds: 3));
    }
  }
  return null;
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class Store extends ChangeNotifier {
  List<Item> items = [];
  Map<String, Product> products = {};
  Map<String, String> settings = {};

  // --- для синхронизации ---
  Map<String, int> tombstones = {}; // id удалённых товаров → время удаления
  Set<String> dirtyItems = {}; // изменены здесь, ещё не отправлены
  Set<String> dirtyProducts = {};
  VoidCallback? onLocalChange; // сюда подключается синхронизация

  late Directory dir;
  late Directory photoDir;

  File get _file => File('${dir.path}/srokomer.json');

  Future<void> load() async {
    dir = await getApplicationDocumentsDirectory();
    photoDir = Directory('${dir.path}/photos');
    if (!await photoDir.exists()) await photoDir.create(recursive: true);
    Map<String, dynamic>? j;
    for (final f in [_file, File('${_file.path}.bak')]) {
      try {
        if (await f.exists()) {
          j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          break;
        }
      } catch (e) {
        debugPrint('broken ${f.path}: $e'); // пробуем резервную копию
      }
    }
    if (j == null && await _file.exists()) {
      // файл не читается: сохраняем его копию, чтобы ничего не потерять навсегда
      try {
        await _file.copy('${_file.path}.broken-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
    }
    try {
      if (j != null) {
        items = ((j['items'] as List?) ?? [])
            .map((e) => Item.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        final p = (j['products'] as Map?) ?? {};
        products = p.map((k, v) =>
            MapEntry(k.toString(), Product.fromJson(Map<String, dynamic>.from(v as Map))));
        final st = (j['settings'] as Map?) ?? {};
        settings = st.map((k, v) => MapEntry(k.toString(), v.toString()));
        final tb = (j['tombstones'] as Map?) ?? {};
        tombstones = tb.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
        dirtyItems = ((j['dirtyItems'] as List?) ?? []).map((e) => e.toString()).toSet();
        dirtyProducts = ((j['dirtyProducts'] as List?) ?? []).map((e) => e.toString()).toSet();
      }
    } catch (e) {
      debugPrint('load error $e');
    }
    // Код синхронизации создаётся один раз на первом запуске
    if ((settings['syncSpace'] ?? '').isEmpty) {
      settings['syncSpace'] = newSpaceCode();
      markAllDirty();
      await save();
    }
  }

  void markAllDirty() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final it in items) {
      if (it.updatedAt == 0) it.updatedAt = now;
    }
    for (final p in products.values) {
      if (p.updatedAt == 0) p.updatedAt = now;
    }
    dirtyItems.addAll(items.map((e) => e.id));
    dirtyProducts.addAll(products.keys);
  }

  static String newSpaceCode() {
    const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    String part() => List.generate(4, (_) => abc[r.nextInt(abc.length)]).join();
    return '${part()}-${part()}-${part()}';
  }

  // Сохранения выполняются строго по очереди: раньше одновременная запись (синхронизация + правка)
  // могла испортить файл, и при следующем запуске терялись ссылки на фото.
  Future<void> _saving = Future.value();
  int _saveSeq = 0;

  Future<void> save() {
    _saving = _saving.then((_) => _doSave()).catchError((e) => debugPrint('save error $e'));
    return _saving;
  }

  Future<void> _doSave() async {
    final data = jsonEncode({
      'items': items.map((e) => e.toJson()).toList(),
      'products': products.map((k, v) => MapEntry(k, v.toJson())),
      'settings': settings,
      'tombstones': tombstones,
      'dirtyItems': dirtyItems.toList(),
      'dirtyProducts': dirtyProducts.toList(),
    });
    final tmp = File('${_file.path}.${++_saveSeq}.tmp');
    await tmp.writeAsString(data, flush: true);
    if (await _file.exists()) {
      // резервная копия последнего исправного файла + копия раз в день
      try {
        await _file.copy('${_file.path}.bak');
        final day = DateTime.now().toIso8601String().substring(0, 10);
        final daily = File('${_file.path}.$day.bak');
        if (!await daily.exists()) await _file.copy(daily.path);
      } catch (_) {}
    }
    await tmp.rename(_file.path);
  }

  /// Изменение, сделанное на этом телефоне.
  Future<void> upsertItem(Item it) async {
    it.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final i = items.indexWhere((x) => x.id == it.id);
    if (i >= 0) {
      final old = items[i];
      if (old.photo == it.photo && it.photoRemote.isEmpty) it.photoRemote = old.photoRemote;
      if (old.photo != it.photo) it.photoRemote = '';
      items[i] = it;
    } else {
      items.add(it);
    }
    dirtyItems.add(it.id);
    notifyListeners();
    await save();
    onLocalChange?.call();
  }

  Future<void> deleteItem(String id) async {
    items.removeWhere((x) => x.id == id);
    tombstones[id] = DateTime.now().millisecondsSinceEpoch;
    dirtyItems.add(id);
    notifyListeners();
    await save();
    onLocalChange?.call();
  }

  Future<void> putProduct(String code, Product p) async {
    if (code.isEmpty) return;
    p.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final old = products[code];
    if (old != null && old.photo == p.photo && p.photoRemote.isEmpty) p.photoRemote = old.photoRemote;
    products[code] = p;
    dirtyProducts.add(code);
    await save();
    onLocalChange?.call();
  }

  /// Данные пришли из облака — только перерисовать экран.
  void notify() => notifyListeners();



  static const _defaultGeminiKey = ''; // ключ Gemini не хранится в коде — вводится в Настройках на телефоне
  String get geminiKey {
    var k = settings['geminiKey'] ?? '';
    if (k.startsWith('AQ.Ab8RN6JO9RVact')) k = ''; // старый отклонённый ключ — заменён новым
    return (k.isNotEmpty ? k : _defaultGeminiKey).trim();
  }

  // Токен GitHub (только чтение этого репозитория) — для автообновления приложения
  static const _defaultGhToken = '';
  String get ghToken {
    final k = settings['ghToken'] ?? '';
    return (k.isNotEmpty ? k : _defaultGhToken).trim();
  }

  // Облако синхронизации (Supabase). Значения по умолчанию встраиваются в сборку.
  static const _defaultSupaUrl = 'https://xmcsewifdsgksywxrnmc.supabase.co';
  static const _defaultSupaKey = 'sb_publishable_ruycDQwapaCfIWnHBXOUwg_iByjJTdR';
  String get supaUrl {
    final v = settings['supaUrl'] ?? '';
    return (v.isNotEmpty ? v : _defaultSupaUrl).trim().replaceAll(RegExp(r'/+$'), '');
  }

  String get supaKey {
    final v = settings['supaKey'] ?? '';
    return (v.isNotEmpty ? v : _defaultSupaKey).trim();
  }

  String get syncSpace => settings['syncSpace'] ?? '';

  Future<void> setSetting(String k, String v) async {
    settings[k] = v;
    if (k == 'lang' || k == 'hand') notifyListeners();
    await save();
  }

  /// [itemId] попадает в имя файла: даже если данные испортятся, фото найдётся по товару.
  Future<String> savePhotoFile(String srcPath, {String? itemId}) async {
    final dst = '${photoDir.path}/${itemId != null ? '${itemId}__' : ''}${newId()}.jpg';
    await File(srcPath).copy(dst);
    return dst;
  }

  Future<String> savePhotoBytes(List<int> bytes, {String? name}) async {
    final dst = '${photoDir.path}/${name ?? '${newId()}.jpg'}';
    await File(dst).writeAsBytes(bytes);
    return dst;
  }
}

final store = Store();


/// Тот же товар: одинаковый штрих-код, а без штрих-кода — одинаковое название.
bool sameProduct(Item o, String barcode, String name) {
  final c = barcode.replaceAll(' ', '');
  if (c.isNotEmpty) return o.barcode == c;
  final n = name.trim().toLowerCase();
  return n.isNotEmpty && o.barcode.isEmpty && o.name.trim().toLowerCase() == n;
}

/// Все партии (разные сроки) этого товара, по возрастанию срока.
List<Item> batchesOf(String barcode, String name) {
  final l = store.items.where((o) => sameProduct(o, barcode, name)).toList();
  l.sort((a, b) {
    if (a.expiry.isEmpty) return 1;
    if (b.expiry.isEmpty) return -1;
    return a.expiry.compareTo(b.expiry);
  });
  return l;
}

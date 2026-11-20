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
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
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

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'items': items.map((e) => e.toJson()).toList(),
      'products': products.map((k, v) => MapEntry(k, v.toJson())),
      'settings': settings,
      'tombstones': tombstones,
      'dirtyItems': dirtyItems.toList(),
      'dirtyProducts': dirtyProducts.toList(),
    }));
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

  static const _defaultMfdsKey = '30bc43ac294d4eabbc4f';
  String get mfdsKey {
    final k = settings['mfdsKey'] ?? '';
    return k.isNotEmpty ? k : _defaultMfdsKey;
  }

  static const _defaultKakaoKey = '17761fbbe8398b95622e6de5869c03ed';
  String get kakaoKey {
    final k = settings['kakaoKey'] ?? '';
    return k.isNotEmpty ? k : _defaultKakaoKey;
  }

  static const _defaultGeminiKey = 'AQ.Ab8RN6JO9RVactXmOcY1qS2Zjfoj8FquD6lcrioYnwYyb489zw';
  String get geminiKey {
    final k = settings['geminiKey'] ?? '';
    return (k.isNotEmpty ? k : _defaultGeminiKey).trim();
  }

  // Облако синхронизации (Supabase). Значения по умолчанию встраиваются в сборку.
  static const _defaultSupaUrl = '';
  static const _defaultSupaKey = '';
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
    if (k == 'lang') notifyListeners();
    await save();
  }

  Future<String> savePhotoFile(String srcPath) async {
    final dst = '${photoDir.path}/${newId()}.jpg';
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class Store extends ChangeNotifier {
  List<Item> items = [];
  Map<String, Product> products = {};
  Map<String, String> settings = {};
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
      }
    } catch (e) {
      debugPrint('load error $e');
    }
  }

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'items': items.map((e) => e.toJson()).toList(),
      'products': products.map((k, v) => MapEntry(k, v.toJson())),
      'settings': settings,
    }));
    await tmp.rename(_file.path);
  }

  Future<void> upsertItem(Item it) async {
    final i = items.indexWhere((x) => x.id == it.id);
    if (i >= 0) {
      items[i] = it;
    } else {
      items.add(it);
    }
    notifyListeners();
    await _save();
  }

  Future<void> deleteItem(String id) async {
    items.removeWhere((x) => x.id == id);
    notifyListeners();
    await _save();
  }

  static const _defaultMfdsKey = '30bc43ac294d4eabbc4f';
  String get mfdsKey {
    final k = settings['mfdsKey'] ?? '';
    return k.isNotEmpty ? k : _defaultMfdsKey;
  }

  Future<void> setSetting(String k, String v) async {
    settings[k] = v;
    if (k == 'lang') notifyListeners();
    await _save();
  }

  Future<void> putProduct(String code, Product p) async {
    if (code.isEmpty) return;
    products[code] = p;
    await _save();
  }

  Future<String> savePhotoFile(String srcPath) async {
    final dst = '${photoDir.path}/${newId()}.jpg';
    await File(srcPath).copy(dst);
    return dst;
  }

  Future<String> savePhotoBytes(List<int> bytes) async {
    final dst = '${photoDir.path}/${newId()}.jpg';
    await File(dst).writeAsBytes(bytes);
    return dst;
  }
}

final store = Store();

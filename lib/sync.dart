import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'store.dart';

/// Синхронизация между телефонами через Supabase (REST).
/// Правило конфликтов: побеждает более позднее изменение (updatedAt).
class SyncService extends ChangeNotifier {
  bool running = false;
  String status = '';
  String? error;
  DateTime? lastOk;
  Timer? _debounce;
  Timer? _periodic;
  bool _again = false;

  bool get enabled => store.supaUrl.isNotEmpty && store.supaKey.isNotEmpty && store.syncSpace.isNotEmpty;

  void attach() {
    store.onLocalChange = () {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), syncNow);
    };
  }

  void startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(seconds: 20), (_) => syncNow());
  }

  void stopPeriodic() {
    _periodic?.cancel();
    _periodic = null;
  }

  Map<String, String> get _h {
    final k = store.supaKey;
    return {
      'apikey': k,
      if (k.startsWith('eyJ')) 'Authorization': 'Bearer $k',
      'Content-Type': 'application/json',
    };
  }

  Uri _rest(String table, [Map<String, String>? q]) {
    final base = Uri.parse(store.supaUrl);
    return base.replace(path: '/rest/v1/$table', queryParameters: q);
  }

  Uri _obj(String name) {
    final base = Uri.parse(store.supaUrl);
    return base.replace(path: '/storage/v1/object/photos/$name');
  }

  Future<void> syncNow() async {
    if (!enabled) return;
    if (running) {
      _again = true;
      return;
    }
    running = true;
    error = null;
    notifyListeners();
    try {
      await _push();
      await _pull();
      lastOk = DateTime.now();
    } catch (e) {
      error = '$e';
      debugPrint('syncer error $e');
    } finally {
      running = false;
      notifyListeners();
    }
    if (_again) {
      _again = false;
      unawaited(syncNow());
    }
  }

  // ---------------- отправка ----------------
  Future<void> _uploadPhoto(String localPath, String remoteName) async {
    final f = File(localPath);
    if (!await f.exists()) return;
    final h = Map<String, String>.from(_h)
      ..['Content-Type'] = 'image/jpeg'
      ..['x-upsert'] = 'true';
    final r = await http.post(_obj(remoteName), headers: h, body: await f.readAsBytes()).timeout(const Duration(seconds: 30));
    if (r.statusCode >= 300) throw 'photo ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
  }

  String _fileName(String path) => path.split('/').last;

  Future<void> _push() async {
    final space = store.syncSpace;
    if (store.dirtyItems.isNotEmpty) {
      final ids = store.dirtyItems.toList();
      final rows = <Map<String, dynamic>>[];
      for (final id in ids) {
        final idx = store.items.indexWhere((e) => e.id == id);
        final Item? it = idx >= 0 ? store.items[idx] : null;
        if (it != null) {
          if (it.photo.isNotEmpty && it.photoRemote.isEmpty && File(it.photo).existsSync()) {
            final rn = '$space/${_fileName(it.photo)}';
            await _uploadPhoto(it.photo, rn);
            it.photoRemote = rn;
          }
          final data = it.toJson()..remove('photo');
          rows.add({'space': space, 'id': id, 'data': data, 'updated_at': it.updatedAt, 'deleted': false});
        } else {
          final ts = store.tombstones[id] ?? DateTime.now().millisecondsSinceEpoch;
          rows.add({'space': space, 'id': id, 'data': {}, 'updated_at': ts, 'deleted': true});
        }
      }
      final r = await http
          .post(_rest('items', {'on_conflict': 'space,id'}),
              headers: {..._h, 'Prefer': 'resolution=merge-duplicates,return=minimal'}, body: jsonEncode(rows))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode >= 300) throw 'items ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
      store.dirtyItems.removeAll(ids);
      await store.save();
    }
    if (store.dirtyProducts.isNotEmpty) {
      final codes = store.dirtyProducts.toList();
      final rows = <Map<String, dynamic>>[];
      for (final c in codes) {
        final p = store.products[c];
        if (p == null) continue;
        if (p.photo.isNotEmpty && p.photoRemote.isEmpty && File(p.photo).existsSync()) {
          final rn = '$space/${_fileName(p.photo)}';
          await _uploadPhoto(p.photo, rn);
          p.photoRemote = rn;
        }
        final data = p.toJson()..remove('photo');
        rows.add({'space': space, 'code': c, 'data': data, 'updated_at': p.updatedAt});
      }
      if (rows.isNotEmpty) {
        final r = await http
            .post(_rest('products', {'on_conflict': 'space,code'}),
                headers: {..._h, 'Prefer': 'resolution=merge-duplicates,return=minimal'}, body: jsonEncode(rows))
            .timeout(const Duration(seconds: 30));
        if (r.statusCode >= 300) throw 'products ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
      }
      store.dirtyProducts.removeAll(codes);
      await store.save();
    }
  }

  // ---------------- получение ----------------
  Future<String> _localPhotoFor(String remote) async {
    if (remote.isEmpty) return '';
    final name = _fileName(remote);
    final path = '${store.photoDir.path}/$name';
    if (await File(path).exists()) return path;
    try {
      final r = await http.get(_obj(remote), headers: _h).timeout(const Duration(seconds: 30));
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
        return store.savePhotoBytes(r.bodyBytes, name: name);
      }
    } catch (_) {}
    return '';
  }

  Future<List<Map<String, dynamic>>> _fetch(String table, String sinceKey) async {
    final since = store.settings[sinceKey] ?? '';
    final q = <String, String>{
      'space': 'eq.${store.syncSpace}',
      'select': '*',
      'order': 'synced_at.asc',
      'limit': '1000',
    };
    if (since.isNotEmpty) q['synced_at'] = 'gte.$since';
    final r = await http.get(_rest(table, q), headers: _h).timeout(const Duration(seconds: 30));
    if (r.statusCode >= 300) throw '$table ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
    final list = jsonDecode(utf8.decode(r.bodyBytes));
    if (list is! List) return [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _pull() async {
    var changed = false;

    final rows = await _fetch('items', 'syncSinceItems');
    for (final row in rows) {
      final id = row['id'].toString();
      final ts = (row['updated_at'] as num).toInt();
      if (store.dirtyItems.contains(id)) continue; // здесь есть неотправленная правка
      final i = store.items.indexWhere((e) => e.id == id);
      if (row['deleted'] == true) {
        if (i >= 0 && store.items[i].updatedAt <= ts) {
          store.items.removeAt(i);
          store.tombstones[id] = ts;
          changed = true;
        }
        continue;
      }
      if (i >= 0 && store.items[i].updatedAt >= ts) continue;
      final remote = Item.fromJson(Map<String, dynamic>.from(row['data'] as Map));
      remote.id = id;
      remote.updatedAt = ts;
      if (i >= 0 && store.items[i].photoRemote == remote.photoRemote && store.items[i].photo.isNotEmpty) {
        remote.photo = store.items[i].photo;
      } else {
        remote.photo = await _localPhotoFor(remote.photoRemote);
      }
      if (i >= 0) {
        store.items[i] = remote;
      } else {
        store.items.add(remote);
      }
      changed = true;
    }
    if (rows.isNotEmpty) store.settings['syncSinceItems'] = rows.last['synced_at'].toString();

    final prows = await _fetch('products', 'syncSinceProducts');
    for (final row in prows) {
      final code = row['code'].toString();
      final ts = (row['updated_at'] as num).toInt();
      if (store.dirtyProducts.contains(code)) continue;
      final old = store.products[code];
      if (old != null && old.updatedAt >= ts) continue;
      final p = Product.fromJson(Map<String, dynamic>.from(row['data'] as Map));
      p.updatedAt = ts;
      if (old != null && old.photoRemote == p.photoRemote && old.photo.isNotEmpty) {
        p.photo = old.photo;
      } else {
        p.photo = await _localPhotoFor(p.photoRemote);
      }
      store.products[code] = p;
      changed = true;
    }
    if (prows.isNotEmpty) store.settings['syncSinceProducts'] = prows.last['synced_at'].toString();

    await store.save();
    if (changed) store.notify();
  }

  /// Подключиться к коду другого телефона: всё местное объединится с общим.
  Future<void> joinSpace(String code) async {
    code = code.trim().toUpperCase();
    if (code.isEmpty || code == store.syncSpace) return;
    store.settings['syncSpace'] = code;
    store.settings['syncSinceItems'] = '';
    store.settings['syncSinceProducts'] = '';
    store.markAllDirty();
    await store.save();
    await syncNow();
  }

  /// Проверка подключения: null — всё хорошо.
  Future<String?> test() async {
    if (store.supaUrl.isEmpty || store.supaKey.isEmpty) return 'URL / key?';
    try {
      final r = await http
          .get(_rest('items', {'select': 'id', 'limit': '1'}), headers: _h)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode < 300) return null;
      return 'HTTP ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
    } catch (e) {
      return '$e';
    }
  }
}

final syncer = SyncService();

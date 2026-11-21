import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'auth.dart';
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

  bool get enabled => auth.configured && auth.loggedIn;
  String _token = '';

  void attach() {
    store.onLocalChange = () {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), syncNow);
    };
  }

  void startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(seconds: 4), (_) => syncNow(quiet: true));
  }

  void stopPeriodic() {
    _periodic?.cancel();
    _periodic = null;
  }

  Map<String, String> get _h => {
        'apikey': store.supaKey,
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
      };

  Uri _rest(String table, [Map<String, String>? q]) {
    final base = Uri.parse(store.supaUrl);
    return base.replace(path: '/rest/v1/$table', queryParameters: q);
  }

  Uri _obj(String name) {
    final base = Uri.parse(store.supaUrl);
    return base.replace(path: '/storage/v1/object/photos/$name');
  }

  /// quiet — фоновая проверка каждые 4 секунды: без мигающего значка.
  Future<void> syncNow({bool quiet = false}) async {
    if (!enabled) return;
    if (running) {
      _again = true;
      return;
    }
    running = true;
    error = null;
    if (!quiet) notifyListeners();
    try {
      final tk = await auth.accessToken();
      if (tk == null) throw 'login';
      _token = tk;
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

  /// Ошибка с фото (не мешает сохранять товары). Пусто — всё хорошо.
  String photoWarning = '';
  final Set<String> _photoRetry = {};

  Future<bool> _tryUpload(String localPath, String remoteName) async {
    try {
      await _uploadPhoto(localPath, remoteName);
      photoWarning = '';
      return true;
    } catch (e) {
      photoWarning = '$e';
      return false;
    }
  }

  String _fileName(String path) => path.split('/').last;

  Future<void> _push() async {
    final space = auth.uid;
    if (store.dirtyItems.isNotEmpty) {
      final ids = store.dirtyItems.toList();
      final rows = <Map<String, dynamic>>[];
      for (final id in ids) {
        final idx = store.items.indexWhere((e) => e.id == id);
        final Item? it = idx >= 0 ? store.items[idx] : null;
        if (it != null) {
          if (it.photo.isNotEmpty && it.photoRemote.isEmpty && File(it.photo).existsSync()) {
            final rn = '$space/${_fileName(it.photo)}';
            if (await _tryUpload(it.photo, rn)) {
              it.photoRemote = rn;
            } else {
              _photoRetry.add(id); // товар сохраняем сейчас, фото дошлём позже
            }
          }
          final data = it.toJson()..remove('photo');
          rows.add({'owner': space, 'id': id, 'data': data, 'updated_at': it.updatedAt, 'deleted': false});
        } else {
          final ts = store.tombstones[id] ?? DateTime.now().millisecondsSinceEpoch;
          rows.add({'owner': space, 'id': id, 'data': {}, 'updated_at': ts, 'deleted': true});
        }
      }
      final r = await http
          .post(_rest('items', {'on_conflict': 'owner,id'}),
              headers: {..._h, 'Prefer': 'resolution=merge-duplicates,return=minimal'}, body: jsonEncode(rows))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode >= 300) throw 'items ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
      store.dirtyItems.removeAll(ids);
      store.dirtyItems.addAll(_photoRetry); // повторить отправку фото в следующий раз
      _photoRetry.clear();
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
          if (await _tryUpload(p.photo, rn)) p.photoRemote = rn;
        }
        final data = p.toJson()..remove('photo');
        rows.add({'owner': space, 'code': c, 'data': data, 'updated_at': p.updatedAt});
      }
      if (rows.isNotEmpty) {
        final r = await http
            .post(_rest('products', {'on_conflict': 'owner,code'}),
                headers: {..._h, 'Prefer': 'resolution=merge-duplicates,return=minimal'}, body: jsonEncode(rows))
            .timeout(const Duration(seconds: 30));
        if (r.statusCode >= 300) throw 'products ${r.statusCode}: ${utf8.decode(r.bodyBytes)}';
      }
      store.dirtyProducts.removeAll(codes);
      await store.save();
    }
  }

  // ---------------- получение ----------------
  final Set<String> _needPhotos = {};
  final Set<String> _needProductPhotos = {};
  bool _downloading = false;

  String _existingLocal(String remote) {
    if (remote.isEmpty) return '';
    final path = '${store.photoDir.path}/${_fileName(remote)}';
    return File(path).existsSync() ? path : '';
  }

  /// Фото докачиваются в фоне, товары уже видны.
  Future<void> _downloadPhotos() async {
    if (_downloading) return;
    _downloading = true;
    try {
      for (final id in _needPhotos.toList()) {
        final i = store.items.indexWhere((e) => e.id == id);
        if (i < 0) {
          _needPhotos.remove(id);
          continue;
        }
        final path = await _localPhotoFor(store.items[i].photoRemote);
        if (path.isNotEmpty) {
          final j = store.items.indexWhere((e) => e.id == id);
          if (j >= 0) store.items[j].photo = path;
          _needPhotos.remove(id);
          store.notify();
        }
      }
      for (final code in _needProductPhotos.toList()) {
        final p = store.products[code];
        if (p == null) {
          _needProductPhotos.remove(code);
          continue;
        }
        final path = await _localPhotoFor(p.photoRemote);
        if (path.isNotEmpty) {
          p.photo = path;
          _needProductPhotos.remove(code);
        }
      }
      await store.save();
    } finally {
      _downloading = false;
    }
  }

  /// Сколько товаров лежит в облаке (для проверки).
  Future<int?> cloudCount() async {
    try {
      final tk = await auth.accessToken();
      if (tk == null) return null;
      _token = tk;
      final r = await http.get(_rest('items', {'select': 'id', 'deleted': 'eq.false', 'limit': '1'}),
          headers: {..._h, 'Prefer': 'count=exact'}).timeout(const Duration(seconds: 15));
      final cr = r.headers['content-range'] ?? '';
      return int.tryParse(cr.split('/').last);
    } catch (_) {
      return null;
    }
  }
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
      'owner': 'eq.${auth.uid}',
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
        remote.photo = _existingLocal(remote.photoRemote);
        if (remote.photo.isEmpty && remote.photoRemote.isNotEmpty) _needPhotos.add(id);
      }
      if (i >= 0) {
        store.items[i] = remote;
      } else {
        store.items.add(remote);
      }
      changed = true;
    }
    var sinceChanged = false;
    if (rows.isNotEmpty && store.settings['syncSinceItems'] != rows.last['synced_at'].toString()) {
      store.settings['syncSinceItems'] = rows.last['synced_at'].toString();
      sinceChanged = true;
    }

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
        p.photo = _existingLocal(p.photoRemote);
        if (p.photo.isEmpty && p.photoRemote.isNotEmpty) _needProductPhotos.add(code);
      }
      store.products[code] = p;
      changed = true;
    }
    if (prows.isNotEmpty && store.settings['syncSinceProducts'] != prows.last['synced_at'].toString()) {
      store.settings['syncSinceProducts'] = prows.last['synced_at'].toString();
      sinceChanged = true;
    }

    if (changed || sinceChanged) await store.save();
    if (changed) store.notify();
    unawaited(_downloadPhotos());
  }

  /// После входа в аккаунт: всё, что есть на телефоне, объединяется с облаком.
  Future<void> afterLogin() async {
    store.settings['syncSinceItems'] = '';
    store.settings['syncSinceProducts'] = '';
    store.markAllDirty();
    // фото нужно загрузить в папку этого аккаунта
    for (final it in store.items) {
      it.photoRemote = '';
    }
    for (final p in store.products.values) {
      p.photoRemote = '';
    }
    await store.save();
    await syncNow();
  }

  /// Проверка подключения: null — всё хорошо.
  Future<String?> test() async {
    if (store.supaUrl.isEmpty || store.supaKey.isEmpty) return 'URL / key?';
    _token = (await auth.accessToken()) ?? store.supaKey;
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

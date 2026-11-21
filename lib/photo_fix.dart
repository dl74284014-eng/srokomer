import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'store.dart';
import 'sync.dart';

/// Размер картинки по заголовку файла (JPEG/PNG), без полной загрузки.
(int, int)? imageSize(File f) {
  try {
    final raf = f.openSync();
    final head = raf.readSync(64 * 1024);
    raf.closeSync();
    final b = Uint8List.fromList(head);
    // PNG
    if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return (w, h);
    }
    // JPEG: ищем маркер SOF
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return (w, h);
        }
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
          i += 2;
          continue;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        i += 2 + len;
      }
    }
  } catch (_) {}
  return null;
}

/// Фото, снятое в приложении: камера/галерея ужимает его ровно до 1024/1200/1400/2000 px
/// по длинной стороне. Картинки из интернета обычно другого размера.
bool isOwnPhoto(File f) {
  final sz = imageSize(f);
  if (sz == null) return false;
  final long = sz.$1 > sz.$2 ? sz.$1 : sz.$2;
  for (final m in const [1024, 1200, 1400, 2000]) {
    if ((long - m).abs() <= 2) return true;
  }
  return false;
}

bool _exists(String p) => p.isNotEmpty && File(p).existsSync();

String _base(String p) => p.split('/').last;

/// Восстановление фото. Порядок поиска пропавшего фото товара:
///  0) файл с id товара в имени; 1) ссылка на фото в облаке;
///  2) свои фото на телефоне по времени съёмки; 3) свои фото в облаке по времени загрузки.
/// [removeWeb] — заодно убрать картинки, найденные в интернете.
/// Возвращает (убрано из интернета, восстановлено).
Future<(int, int)> fixPhotos({bool removeWeb = false, bool cloud = true}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  var removed = 0, restored = 0;

  void setPhoto(Item it, String path, String remote) {
    it.photo = path;
    it.photoRemote = remote;
    it.updatedAt = now;
    store.dirtyItems.add(it.id);
    if (it.barcode.isNotEmpty) {
      final p = store.products[it.barcode];
      if (p != null && !_exists(p.photo)) {
        p.photo = path;
        p.photoRemote = remote;
        p.updatedAt = now;
        store.dirtyProducts.add(it.barcode);
      }
    }
    restored++;
  }

  // --- убрать картинки из интернета (только свои снимки остаются) ---
  if (removeWeb) {
    for (final it in store.items) {
      if (_exists(it.photo) && !isOwnPhoto(File(it.photo))) {
        it.photo = '';
        it.photoRemote = '';
        it.updatedAt = now;
        store.dirtyItems.add(it.id);
        removed++;
      }
    }
    store.products.forEach((code, p) {
      if (_exists(p.photo) && !isOwnPhoto(File(p.photo))) {
        p.photo = '';
        p.photoRemote = '';
        p.updatedAt = now;
        store.dirtyProducts.add(code);
      }
    });
  }

  List<Item> missing() => store.items.where((i) => !_exists(i.photo)).toList();
  Set<String> usedNames() => {
        for (final it in store.items)
          if (it.photo.isNotEmpty) _base(it.photo),
        for (final p in store.products.values)
          if (p.photo.isNotEmpty) _base(p.photo),
      };

  // --- 0) файл с id товара в имени ---
  final files = store.photoDir.listSync().whereType<File>().toList();
  for (final it in missing()) {
    final f = files.where((f) => _base(f.path).startsWith('${it.id}__')).toList();
    if (f.isNotEmpty) setPhoto(it, f.last.path, '');
  }

  // --- 1) у товара есть ссылка на фото в облаке ---
  if (cloud && syncer.enabled) {
    for (final it in missing()) {
      if (it.photoRemote.isEmpty) continue;
      final local = '${store.photoDir.path}/${_base(it.photoRemote)}';
      final path = File(local).existsSync() ? local : await syncer.fetchCloudPhoto(it.photoRemote);
      if (path.isNotEmpty && isOwnPhoto(File(path))) setPhoto(it, path, it.photoRemote);
    }
  }

  // --- 2) свои фото на телефоне, ни к чему не привязанные: по времени съёмки ---
  final used = usedNames();
  final free = <(File, int)>[];
  for (final e in store.photoDir.listSync().whereType<File>()) {
    if (used.contains(_base(e.path))) continue;
    if (!isOwnPhoto(e)) {
      if (removeWeb) {
        try {
          e.deleteSync(); // ненужная картинка из интернета
        } catch (_) {}
      }
      continue;
    }
    free.add((e, e.lastModifiedSync().millisecondsSinceEpoch));
  }
  (T, int)? nearest<T>(List<(T, int)> pool, int createdAt) {
    (T, int)? best;
    var bestD = 1 << 62;
    for (final f in pool) {
      final d = f.$2 - createdAt; // фото сохраняется после начала добавления товара
      if (d < -2 * 60 * 1000 || d > 60 * 60 * 1000) continue;
      if (d.abs() < bestD) {
        bestD = d.abs();
        best = f;
      }
    }
    return best;
  }

  for (final it in missing()..sort((a, b) => b.createdAt.compareTo(a.createdAt))) {
    final best = nearest(free, it.createdAt);
    if (best != null) {
      free.remove(best);
      setPhoto(it, best.$1.path, '');
    }
  }

  // --- 3) свои фото в облаке, ни к чему не привязанные: по времени загрузки ---
  if (cloud && syncer.enabled && missing().isNotEmpty) {
    try {
      final usedNow = usedNames();
      final usedRemote = {for (final it in store.items) it.photoRemote};
      final pool = (await syncer.listCloudPhotos())
          .where((o) => !usedRemote.contains(o.$1) && !usedNow.contains(_base(o.$1)))
          .toList();
      for (final it in missing()..sort((a, b) => b.createdAt.compareTo(a.createdAt))) {
        while (true) {
          final best = nearest(pool, it.createdAt);
          if (best == null) break;
          pool.remove(best);
          final path = await syncer.fetchCloudPhoto(best.$1);
          if (path.isEmpty) continue;
          if (!isOwnPhoto(File(path))) {
            try {
              File(path).deleteSync();
            } catch (_) {}
            continue; // это была картинка из интернета — ищем дальше
          }
          setPhoto(it, path, best.$1);
          break;
        }
      }
    } catch (_) {}
  }

  if (removed > 0 || restored > 0) {
    await store.save();
    store.notify();
    store.onLocalChange?.call();
  }
  return (removed, restored);
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'widgets.dart';
import 'l10n.dart';
import 'store.dart';

/// Номер сборки, вшивается при сборке на GitHub (--dart-define).
const buildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
const buildName = String.fromEnvironment('BUILD_NAME', defaultValue: 'dev');
const _repo = 'dl74284014-eng/srokomer';

class UpdateInfo {
  final int build;
  final String name;
  final int assetId;
  UpdateInfo(this.build, this.name, this.assetId);
}

Map<String, String> get _gh => {
      'Authorization': 'Bearer ${store.ghToken}',
      'X-GitHub-Api-Version': '2022-11-28',
    };

/// Есть ли версия новее установленной. null — нет (или нет доступа).
Future<UpdateInfo?> checkUpdate() async {
  if (store.ghToken.isEmpty) return null;
  try {
    final r = await http
        .get(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: {..._gh, 'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    final tag = (j['tag_name'] ?? '').toString().replaceFirst('v', '');
    final build = int.tryParse(tag.split('.').last) ?? 0;
    final assets = (j['assets'] as List?) ?? [];
    final apk = assets.cast<Map>().where((a) => a['name'] == 'srokomer.apk').toList();
    if (apk.isEmpty || build <= buildNumber) return null;
    return UpdateInfo(build, tag, (apk.first['id'] as num).toInt());
  } catch (_) {
    return null;
  }
}

/// Скачивает APK, сообщая прогресс 0..1. Возвращает путь к файлу.
Future<String?> downloadUpdate(UpdateInfo u, void Function(double) onProgress) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse('https://api.github.com/repos/$_repo/releases/assets/${u.assetId}'))
      ..followRedirects = false
      ..headers.addAll({..._gh, 'Accept': 'application/octet-stream'});
    var res = await client.send(req);
    if (res.statusCode >= 300 && res.statusCode < 400 && res.headers['location'] != null) {
      // GitHub отдаёт временную ссылку на файл — по ней качаем уже без токена
      res = await client.send(http.Request('GET', Uri.parse(res.headers['location']!)));
    }
    if (res.statusCode != 200) return null;
    final total = res.contentLength ?? 0;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/update.apk');
    final sink = f.openWrite();
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    return f.path;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Проверить и предложить обновление. [manual] — показать «у вас последняя версия», если новее нет.
Future<void> offerUpdate(BuildContext context, {bool manual = false}) async {
  final u = await checkUpdate();
  if (!context.mounted) return;
  if (u == null) {
    if (manual) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('upd_latest'))));
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('⬆️ ${t('upd_title')}'),
      content: Text(tf('upd_text', {'v': u.name})),
      actions: acts([
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('upd_later'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('upd_now'))),
      ]),
    ),
  );
  if (ok != true || !context.mounted) return;
  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tf('upd_loading', {'p': (p * 100).round()})),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: p > 0 ? p : null),
          ]),
        ),
      ),
    ),
  );
  final path = await downloadUpdate(u, (p) => progress.value = p);
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  if (path == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('upd_fail'))));
    return;
  }
  await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
}

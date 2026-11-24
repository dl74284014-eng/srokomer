import 'dart:io';

import 'package:flutter/material.dart';

import 'gemini.dart';
import 'lookup.dart';
import 'models.dart';
import 'photo_fix.dart';
import 'photo_review_page.dart';
import 'store.dart';
import 'l10n.dart';

MainAxisAlignment get dialogAlign =>
    hand == 'left' ? MainAxisAlignment.start : (hand == 'right' ? MainAxisAlignment.end : MainAxisAlignment.center);

class InfoNote extends StatelessWidget {
  final String text;
  const InfoNote(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: P.note,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: TextStyle(color: P.noteText, fontSize: 13.5)),
      );
}

/// Показывает «Обработка…» пока выполняется задача.
Future<T> withLoading<T>(BuildContext context, String text, Future<T> Function() fn) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ]),
      ),
    ),
  );
  try {
    return await fn();
  } finally {
    nav.pop();
  }
}

/// «Это оно?» — true = да, false = нет, null = закрыли.
Future<bool?> askThisOne(BuildContext context,
    {required String title, required String text, String sub = '', String imagePath = ''}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (imagePath.isNotEmpty && File(imagePath).existsSync())
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                height: 160,
                color: P.photoBg,
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            ),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(sub, style: TextStyle(color: P.muted)),
            ),
        ],
      ),
      actionsAlignment: dialogAlign,
      actions: hand == 'left'
          ? [
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('yes'))),
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('no'))),
            ]
          : [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('no'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('yes'))),
            ],
    ),
  );
}

/// Выбор строк (можно несколько — склеятся в одно название).
Future<String?> pickLines(BuildContext context, List<String> lines) {
  final sel = <int>{};
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t('mark_lines'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              Text(t('mark_lines_sub')),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < lines.length; i++)
                      CheckboxListTile(
                        value: sel.contains(i),
                        onChanged: (v) => set(() => v == true ? sel.add(i) : sel.remove(i)),
                        title: Text(lines[i], style: const TextStyle(fontSize: 17)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, ''),
                    child: Text(t('type_myself')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: sel.isEmpty
                        ? null
                        : () {
                            final l = sel.toList()..sort();
                            Navigator.pop(ctx, l.map((i) => lines[i]).join(' '));
                          },
                    child: Text(t('done')),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Выбор одного варианта из списка. null — ничего не подошло.
Future<String?> pickOne(BuildContext context, String title, List<String> options) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in options)
                    ListTile(
                      title: Text(o, style: const TextStyle(fontSize: 16)),
                      onTap: () => Navigator.pop(ctx, o),
                    ),
                ],
              ),
            ),
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text(t('none_of_these'))),
          ],
        ),
      ),
    ),
  );
}

/// «Это оно?» с живым обновлением: сначала быстрый результат с телефона,
/// затем, когда придёт ответ Gemini, текст уточняется прямо в окне.
Future<bool?> askLive(BuildContext context,
    {required String title,
    required ValueNotifier<String?> text,
    required ValueNotifier<bool> refining,
    String imagePath = ''}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: Listenable.merge([text, refining]),
      builder: (ctx, _) {
        final v = text.value;
        final busy = refining.value;
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (imagePath.isNotEmpty && File(imagePath).existsSync())
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 150,
                    color: P.photoBg,
                    child: Image.file(File(imagePath), fit: BoxFit.contain, cacheWidth: 600),
                  ),
                ),
              const SizedBox(height: 12),
              if (v != null)
                Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))
              else if (!busy)
                Text(t('no_text'), style: TextStyle(color: P.muted)),
              const SizedBox(height: 8),
              if (busy)
                Row(children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t('refining'), style: TextStyle(color: P.muted, fontSize: 13))),
                ])
              else if (v != null)
                Text('${t('refined')}${lastGeminiMs > 0 ? ' · ${(lastGeminiMs / 1000).toStringAsFixed(1)} s' : ''}',
                    style: const TextStyle(color: Color(0xFF2A8A57), fontSize: 13)),
            ],
          ),
          actionsAlignment: dialogAlign,
          actions: [
            if (hand == 'left')
              FilledButton(onPressed: v == null ? null : () => Navigator.pop(ctx, true), child: Text(t('yes'))),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(v == null ? t('type_myself') : t('no'))),
            if (hand != 'left')
              FilledButton(onPressed: v == null ? null : () => Navigator.pop(ctx, true), child: Text(t('yes'))),
          ],
        );
      },
    ),
  );
}


/// Проверить, что фото на своих местах (с окном прогресса).
/// Сначала через Gemini (точно, с учётом объёма); без Gemini — встроенным распознаванием.
Future<void> runRematch(BuildContext context) async {
  final prog = ValueNotifier<String>('…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 14),
          Expanded(child: ValueListenableBuilder<String>(valueListenable: prog, builder: (_, v, __) => Text(v))),
        ]),
      ),
    ),
  );
  final g = await verifyPhotosGemini((d, n) => prog.value = '${t('photo_checking')} $d / $n');
  (int, int) r;
  var doubts = <Doubt>[];
  if (g != null) {
    r = (g.$1, g.$2);
    doubts = g.$3;
  } else {
    r = await rematchPhotos(readPhotoText, (d, n) => prog.value = '${t('photo_checking')} $d / $n');
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6), content: Text(tf('photo_rematch_done', {'m': r.$1, 'n': r.$2}))));
  if (doubts.isNotEmpty) {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoReviewPage(doubts)));
  }
}


/// Выбор категории (сетка).
Future<String?> pickCategory(BuildContext context, String current) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('category'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Flexible(
            child: GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.05,
              children: [
                for (final c in cats)
                  Material(
                    color: c.k == current ? const Color(0xFF16794C).withValues(alpha: 0.18) : P.card,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.pop(ctx, c.k),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(c.e, style: const TextStyle(fontSize: 28)),
                          const SizedBox(height: 4),
                          Text(catName(c),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    ),
  );
}

/// «Категория: 🧃 Напитки — верно?» Да → эта; «Другая» → выбор из списка. null — закрыли.
Future<String?> askCategory(BuildContext context, String suggest) async {
  final c = catOf(suggest);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('cat_q')),
      content: Row(children: [
        Text(c.e, style: const TextStyle(fontSize: 34)),
        const SizedBox(width: 12),
        Expanded(child: Text(catName(c), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
      ]),
      actionsAlignment: dialogAlign,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cat_other'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('yes'))),
      ],
    ),
  );
  if (ok == true) return suggest;
  if (ok == false && context.mounted) return pickCategory(context, suggest);
  return null;
}


/// Gemini раскладывает все товары по категориям (по названиям, пачками по 40).
Future<void> runCategorizeAll(BuildContext context) async {
  final items = [...store.items];
  if (items.isEmpty) return;
  final prog = ValueNotifier<String>('…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 14),
          Expanded(child: ValueListenableBuilder<String>(valueListenable: prog, builder: (_, v, __) => Text(v))),
        ]),
      ),
    ),
  );
  var changed = 0;
  var failed = false;
  for (var k = 0; k < items.length; k += 40) {
    prog.value = '${t('cat_working')} $k / ${items.length}';
    final chunk = items.sublist(k, k + 40 < items.length ? k + 40 : items.length);
    final res = await geminiCategorize(chunk.map((e) => e.name).toList());
    if (res == null) {
      failed = true;
      break;
    }
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i].category != res[i]) {
        final n = Item.fromJson(chunk[i].toJson())..category = res[i];
        await store.upsertItem(n);
        changed++;
      }
    }
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(failed && changed == 0 ? t('cat_fail') : tf('cat_done', {'n': changed}))));
}


/// Алкоголь из «Напитков» (и «Другого») — в категорию «Алкоголь»: по словам в названии и, если есть ключ, через Gemini.
Future<void> moveAlcohol() async {
  final cand = store.items.where((i) => i.category == 'drink' || i.category == 'other').toList();
  if (cand.isEmpty) return;
  final toAlc = <String>{};
  for (final it in cand) {
    if (guessCategory('${it.name} ${it.nameRu}') == 'alcohol') toAlc.add(it.id);
  }
  if (store.geminiKey.isNotEmpty) {
    final rest = cand.where((i) => !toAlc.contains(i.id) && i.name.isNotEmpty).toList();
    for (var s = 0; s < rest.length; s += 40) {
      final part = rest.sublist(s, s + 40 > rest.length ? rest.length : s + 40);
      try {
        final r = await geminiCategorize([for (final i in part) i.name]);
        if (r == null) break;
        for (var k = 0; k < part.length && k < r.length; k++) {
          if (r[k] == 'alcohol') toAlc.add(part[k].id);
        }
      } catch (_) {
        break;
      }
    }
  }
  for (final it in cand) {
    if (!toAlc.contains(it.id)) continue;
    await store.upsertItem(Item.fromJson(it.toJson())..category = 'alcohol');
    final pr = store.products[it.barcode];
    if (it.barcode.isNotEmpty && pr != null && pr.category != 'alcohol') {
      await store.putProduct(it.barcode, Product.fromJson(pr.toJson())..category = 'alcohol');
    }
  }
}

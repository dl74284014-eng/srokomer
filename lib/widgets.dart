import 'dart:io';

import 'package:flutter/material.dart';

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
          color: const Color(0xFFE3F2EA),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: const TextStyle(color: Color(0xFF0F5C39), fontSize: 13.5)),
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
                color: const Color(0xFFF1EEE7),
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
            ),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(sub, style: TextStyle(color: Colors.grey.shade700)),
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
                    color: const Color(0xFFF1EEE7),
                    child: Image.file(File(imagePath), fit: BoxFit.contain, cacheWidth: 600),
                  ),
                ),
              const SizedBox(height: 12),
              if (v != null)
                Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))
              else if (!busy)
                Text(t('no_text'), style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              if (busy)
                Row(children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t('refining'), style: const TextStyle(color: Colors.black54, fontSize: 13))),
                ])
              else if (v != null)
                Text(t('refined'), style: const TextStyle(color: Color(0xFF2A8A57), fontSize: 13)),
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

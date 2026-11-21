import 'dart:io';

import 'package:flutter/material.dart';

import 'item_form.dart';
import 'l10n.dart';
import 'models.dart';
import 'store.dart';
import 'widgets.dart';

Future<void> openItemForm(BuildContext context, Item it,
    {bool isNew = true, String info = '', bool focusName = false, bool autoOcr = false, bool autoPhoto = false}) {
  return Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ItemFormPage(
          item: it, isNew: isNew, info: info, focusName: focusName, autoOcr: autoOcr, autoPhoto: autoPhoto),
    ),
  );
}

Widget itemThumb(Item it, {double size = 58}) {
  final hasPhoto = it.photo.isNotEmpty && File(it.photo).existsSync();
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Container(
      width: size,
      height: size,
      color: P.thumb,
      alignment: Alignment.center,
      child: hasPhoto
          ? Image.file(File(it.photo), width: size, height: size, fit: BoxFit.cover, cacheWidth: 200)
          : Text('📦', style: TextStyle(fontSize: size * 0.45)),
    ),
  );
}

/// Карточка товара: нажатие — открыть, долгое нажатие — меню действий.
class ItemTile extends StatelessWidget {
  final Item it;
  const ItemTile(this.it, {super.key});

  @override
  Widget build(BuildContext context) {
    final dl = daysLeft(it.expiry);
    final u = urgency(dl);
    final sub = [
      '${t('until')} ${fmtDate(it.expiry)}',
      if (it.qty > 1) '${it.qty} ${t('pcs')}',
      if (it.notes.isNotEmpty) '📝 ${it.notes}',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: P.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => openItemForm(context, Item.fromJson(it.toJson()), isNew: false),
          onLongPress: () => showItemActions(context, it),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              itemThumb(it),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    it.name.isEmpty ? t('no_name') : it.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  const SizedBox(height: 3),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: P.muted)),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 66),
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
                decoration: BoxDecoration(color: urgSoft(u), borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text(dl == null ? '?' : (dl < 0 ? '!' : '$dl'),
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: urgColor(u))),
                  Text(
                    dl == null
                        ? t('no_date')
                        : dl < 0
                            ? t('expired')
                            : dl == 0
                                ? t('today')
                                : daysWord(dl),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: urgColor(u)),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

Future<void> showItemActions(BuildContext context, Item it) async {
  final dl = daysLeft(it.expiry);
  final act = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget tile(String k, IconData ic, String label, {Color? color}) => ListTile(
            leading: Icon(ic, color: color),
            title: Text(label, style: TextStyle(fontSize: 16.5, color: color, fontWeight: FontWeight.w500)),
            onTap: () => Navigator.pop(ctx, k),
          );
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: itemThumb(it, size: 48),
            title: Text(it.name.isEmpty ? t('no_name') : it.name,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${t('until')} ${fmtDate(it.expiry)} · ${leftText(dl)}'),
          ),
          const Divider(height: 1),
          tile('edit', Icons.edit_outlined, t('act_edit')),
          tile('date', Icons.event_outlined, t('act_date')),
          tile('photo', Icons.image_search, t('photo_web')),
          if (it.qty > 1) tile('minus', Icons.remove_circle_outline, t('act_minus')),
          tile('delete', Icons.delete_outline, t('delete'), color: const Color(0xFFD6363B)),
          const SizedBox(height: 8),
        ]),
      );
    },
  );
  if (act == null || !context.mounted) return;

  switch (act) {
    case 'edit':
      await openItemForm(context, Item.fromJson(it.toJson()), isNew: false);
    case 'date':
      final d = await showDatePicker(
        context: context,
        initialDate: parseIso(it.expiry) ?? today(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2045),
        helpText: t('valid_until'),
      );
      if (d != null) {
        final n = Item.fromJson(it.toJson())..expiry = isoOf(d);
        await store.upsertItem(n);
      }
    case 'photo':
      final p = await pickWebPhoto(context, it.name);
      if (p != null) {
        final n = Item.fromJson(it.toJson())
          ..photo = p
          ..photoRemote = '';
        await store.upsertItem(n);
      }
    case 'minus':
      final n = Item.fromJson(it.toJson())..qty = it.qty - 1;
      await store.upsertItem(n);
    case 'delete':
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tf('delete_q', {'name': it.name})),
          content: Text(t('delete_sub')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD6363B)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('delete')),
            ),
          ],
        ),
      );
      if (ok == true) await store.deleteItem(it.id);
  }
}

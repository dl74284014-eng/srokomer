import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'package:image_picker/image_picker.dart';

import 'gemini.dart';
import 'item_tile.dart';
import 'lookup.dart';
import 'models.dart';
import 'store.dart';
import 'widgets.dart';

class ItemFormPage extends StatefulWidget {
  final Item item;
  final bool isNew;
  final String info;
  final bool focusName;
  final bool autoOcr;
  final bool autoPhoto; // сразу открыть камеру для главного фото (название возьмётся с него)
  final bool autoDate; // сразу открыть выбор срока (новая партия)
  const ItemFormPage({
    super.key,
    required this.item,
    this.isNew = true,
    this.info = '',
    this.focusName = false,
    this.autoOcr = false,
    this.autoPhoto = false,
    this.autoDate = false,
  });

  @override
  State<ItemFormPage> createState() => _ItemFormPageState();
}

class _ItemFormPageState extends State<ItemFormPage> {
  late final TextEditingController name, nameRu, code, notes, price;
  final FocusNode nameFocus = FocusNode();
  late String category, expiry, photo;
  late int qty;
  late bool mute;
  late bool ret;
  bool remember = true;
  bool catManual = false; // категорию выбрали вручную — больше не трогаем
  bool saving = false;
  final picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    name = TextEditingController(text: it.name);
    nameRu = TextEditingController(text: it.nameRu);
    code = TextEditingController(text: it.barcode);
    notes = TextEditingController(text: it.notes);
    price = TextEditingController(text: it.price > 0 ? '${it.price}' : '');
    ret = it.ret;
    category = it.category;
    expiry = it.expiry;
    photo = it.photo;
    qty = it.qty;
    mute = it.mute;
    if (category == 'other' && it.name.isNotEmpty) category = guessCategory(it.name);
    catManual = !widget.isNew;
    geminiWarmUp(); // заранее открыть соединение — первое распознавание быстрее
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.autoPhoto) {
        _changePhoto(true);
      } else if (widget.autoDate) {
        _pickDate();
      } else if (widget.autoOcr) {
        _ocrName();
      } else if (widget.focusName) {
        nameFocus.requestFocus();
        name.selection = TextSelection(baseOffset: 0, extentOffset: name.text.length);
      }
    });
  }

  @override
  void dispose() {
    name.dispose();
    nameRu.dispose();
    code.dispose();
    notes.dispose();
    nameFocus.dispose();
    super.dispose();
  }

  bool get _btnLeft => hand != 'right';

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 100),
        duration: const Duration(seconds: 3),
      ));

  Future<XFile?> _shoot({bool camera = true}) => picker.pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1024, // меньше фото — быстрее отправка и ответ Gemini, текст названия читается
        maxHeight: 1024,
        imageQuality: 78,
      );

  /// Главное фото товара: сохраняем его и сразу берём с него название и описание
  /// (заменяет старое после подтверждения «Это название?»).
  Future<void> _changePhoto(bool camera) async {
    final x = await _shoot(camera: camera);
    if (x == null || !mounted) return;
    final p = await store.savePhotoFile(x.path, itemId: widget.item.id);
    if (!mounted) return;
    setState(() => photo = p);
    await _ocrName(p);
  }

  // ---------- считать название ----------
  /// [givenPath] — уже снятое главное фото; без него открывается камера (кнопка «Считать»).
  Future<void> _ocrName([String? givenPath]) async {
    final String? path = givenPath ?? (await _shoot())?.path;
    if (path == null || !mounted) return;
    // Параллельно: мгновенное распознавание на телефоне + точное через Gemini.
    // Окно «Это название?» показывается сразу и уточняется, когда придёт ответ Gemini.
    final text = ValueNotifier<String?>(null);
    final refining = ValueNotifier<bool>(true);
    var alts = <String>[];
    var gExp = '';
    var mlDone = false, gDone = false;
    void finish() {
      if (mlDone && gDone) refining.value = false;
    }

    ocrLines(path).then((lines) {
      final c = nameCandidates(lines);
      alts = [...alts, ...c.where((e) => !alts.contains(e))];
      if (text.value == null && c.isNotEmpty) text.value = c.first;
    }).catchError((_) {}).whenComplete(() {
      mlDone = true;
      finish();
    });
    var gotGemini = false;
    String gCat = 'other';
    geminiRead(path).then((g) {
      if (g != null && g.names.isNotEmpty) {
        gotGemini = true;
        gCat = g.category;
        text.value = g.names.first;
        alts = [...g.names, ...alts.where((e) => !g.names.contains(e))];
        gExp = g.expiry;
      }
    }).catchError((_) {}).whenComplete(() {
      gDone = true;
      // Gemini ответил — дальше ждать телефонное распознавание незачем
      if (gotGemini) mlDone = true;
      finish();
    });

    String? chosen;
    final ans = await askLive(context, title: t('is_name_q'), text: text, refining: refining, imagePath: path);
    if (!mounted) return;
    if (ans == true) {
      chosen = text.value;
    } else if (ans == false) {
      final rest = alts.where((e) => e != text.value).toList();
      if (rest.isNotEmpty) chosen = await pickOne(context, t('pick_variant'), rest);
    }
    if (chosen != null && expiry.isEmpty && gExp.isNotEmpty) {
      setState(() => expiry = gExp);
      _snack('${t('valid_until')}: ${fmtDate(gExp)} ✓');
    }
    // Снятое фото оставляем у товара, даже если название не подошло (раньше оно терялось)
    final saved = photo.isEmpty ? await store.savePhotoFile(path, itemId: widget.item.id) : photo;
    if (!mounted) return;
    if (photo.isEmpty) setState(() => photo = saved);
    if (chosen == null || chosen.isEmpty) {
      nameFocus.requestFocus();
      return;
    }
    final String picked = chosen;
    setState(() {
      name.text = picked;
      photo = saved;
    });
    // Категория: ставим сразу (Gemini или словарь), без вопроса — поменять можно вручную
    if (!catManual && mounted) {
      final c = gCat != 'other' ? gCat : guessCategory(picked);
      if (c != 'other') setState(() => category = c);
    }
  }

  // ---------- считать срок годности ----------
  Future<void> _ocrDate() async {
    final x = await _shoot();
    if (x == null || !mounted) return;
    FoundDate? f;
    final g = await withLoading(context, t('finding_date'), () => geminiRead(x.path));
    if (!mounted) return;
    if (g != null && g.expiry.isNotEmpty) {
      f = FoundDate(g.expiry, g.rawDate.isNotEmpty ? g.rawDate : fmtDate(g.expiry));
    } else {
      final lines = await withLoading(context, t('finding_date'), () => ocrLines(x.path));
      if (!mounted) return;
      f = findExpiry(lines);
    }
    if (f == null) {
      _snack(t('no_date_found'));
      return;
    }
    final FoundDate found = f;
    final ok = await askThisOne(
      context,
      title: t('date_ok_q'),
      text: '${t('until')} ${fmtDate(f.iso)}',
      sub: '${t('on_pack')}: ${f.raw} · ${leftText(daysLeft(f.iso))}',
      imagePath: x.path,
    );
    if (ok == true) setState(() => expiry = found.iso);
  }

  Future<void> _pickDate() async {
    final init = parseIso(expiry) ?? today();
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2045),
      helpText: t('valid_until'),
    );
    if (d != null) setState(() => expiry = isoOf(d));
  }

  void _quick({int days = 0, int months = 0}) {
    final t = today();
    setState(() => expiry = isoOf(DateTime(t.year, t.month + months, t.day + days)));
  }

  Future<void> _save() async {
    if (name.text.trim().isEmpty) {
      _snack(t('enter_name'));
      nameFocus.requestFocus();
      return;
    }
    if (expiry.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('no_exp_title')),
          content: Text(t('no_exp_text')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('without_date'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('set_date'))),
          ],
        ),
      );
      if (ok != true) {
        _pickDate();
        return;
      }
    }
    // Партии: тот же товар с ТЕМ ЖЕ сроком — одна партия (количество складываем),
    // с другим сроком — отдельная партия.
    var id = widget.item.id;
    var createdAt = widget.item.createdAt;
    final code0 = code.text.replaceAll(' ', '');
    final others = batchesOf(code0, name.text).where((o) => o.id != id).toList();
    final twin = others.where((o) => o.expiry == expiry).firstOrNull;
    if (twin != null) {
      qty += twin.qty;
      if (photo.isEmpty) photo = twin.photo;
      if (notes.text.trim().isEmpty && twin.notes.isNotEmpty) notes.text = twin.notes;
      if (widget.isNew) {
        id = twin.id;
        createdAt = twin.createdAt;
      } else {
        await store.deleteItem(twin.id);
      }
      others.remove(twin);
      _snack(t('batch_merged'));
    }
    setState(() => saving = true);
    final it = Item(
      id: id,
      name: name.text.trim(),
      nameRu: nameRu.text.trim(),
      category: category,
      barcode: code.text.replaceAll(' ', ''),
      expiry: expiry,
      notes: notes.text.trim(),
      qty: qty,
      mute: mute,
      price: int.tryParse(price.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
      ret: ret,
      photo: photo,
      createdAt: createdAt,
    );
    await store.upsertItem(it);
    // Название, категория и фото — общие для всех партий товара
    for (final o in others) {
      final noPhoto = o.photo.isEmpty || !File(o.photo).existsSync();
      if (o.name == it.name && o.nameRu == it.nameRu && o.category == it.category && !(noPhoto && it.photo.isNotEmpty)) {
        continue;
      }
      final n = Item.fromJson(o.toJson())
        ..name = it.name
        ..nameRu = it.nameRu
        ..category = it.category;
      if (noPhoto && it.photo.isNotEmpty) {
        n.photo = it.photo;
        n.photoRemote = '';
      }
      await store.upsertItem(n);
    }
    if (remember && it.barcode.isNotEmpty) {
      await store.putProduct(it.barcode,
          Product(name: it.name, nameRu: it.nameRu, category: it.category, photo: it.photo, price: it.price));
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tf('delete_q', {'name': name.text})),
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
    if (ok == true) {
      await store.deleteItem(widget.item.id);
      if (mounted) Navigator.pop(context, true);
    }
  }

  Widget _batchesBox(List<Item> same) {
    Widget row(String date, int q, int? dl, {VoidCallback? onTap, bool current = false}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
            child: Row(children: [
              Icon(current ? Icons.radio_button_checked : Icons.inventory_2_outlined, size: 20, color: P.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${t('until')} ${fmtDate(date)}${q > 1 ? '  ×$q' : ''}${current ? '  (${t('this_batch')})' : ''}',
                    style: TextStyle(fontSize: 15, fontWeight: current ? FontWeight.w700 : FontWeight.w500)),
              ),
              Text(leftText(dl), style: TextStyle(fontSize: 13, color: urgColor(urgency(dl)), fontWeight: FontWeight.w600)),
              if (onTap != null) Icon(Icons.chevron_right, color: P.muted),
            ]),
          ),
        );
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(border: Border.all(color: P.dim), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t('batches_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        if (!widget.isNew) row(expiry, qty, daysLeft(expiry), current: true),
        for (final o in same)
          row(o.expiry, o.qty, daysLeft(o.expiry),
              onTap: () => openItemForm(context, Item.fromJson(o.toJson()), isNew: false)
                  .then((_) => mounted ? setState(() {}) : null)),
        if (!widget.isNew)
          TextButton.icon(
            onPressed: () => newBatch(context, widget.item).then((_) => mounted ? setState(() {}) : null),
            icon: const Icon(Icons.add),
            label: Text(t('batch_add')),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dl = daysLeft(expiry);
    final same = batchesOf(code.text, name.text).where((i) => i.id != widget.item.id).toList();
    const gap = SizedBox(height: 14);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? t('new_item') : t('item')),
        actions: [
          if (!widget.isNew)
            IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline), tooltip: t('delete')),
          IconButton(onPressed: saving ? null : _save, icon: const Icon(Icons.check), tooltip: t('save')),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: Column(children: [
        Expanded(
          child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (widget.info.isNotEmpty) InfoNote(widget.info),
          // фото
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 190,
              color: P.photoBg,
              child: photo.isNotEmpty && File(photo).existsSync()
                  ? Image.file(File(photo), fit: BoxFit.contain)
                  : const Center(child: Text('📦', style: TextStyle(fontSize: 56))),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _changePhoto(true),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(t('photo_cam')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _changePhoto(false),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(t('photo_gal')),
              ),
            ),
          ]),

          gap,
          // название
          Row(textDirection: _btnLeft ? TextDirection.rtl : TextDirection.ltr, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: name,
                focusNode: nameFocus,
                onChanged: (v) {
                  if (catManual) return;
                  final g = guessCategory(v);
                  if (g != category && g != 'other') setState(() => category = g);
                },
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('name'),
                  hintText: t('name_hint'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              child: FilledButton.tonalIcon(
                onPressed: _ocrName,
                icon: const Icon(Icons.document_scanner_outlined),
                label: Text(t('read')),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: nameRu,
            decoration: InputDecoration(
              labelText: t('translation'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          gap,
          // срок
          Text(t('exp_title'),
              style: TextStyle(color: P.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(textDirection: _btnLeft ? TextDirection.rtl : TextDirection.ltr, children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _pickDate,
                icon: const Icon(Icons.event),
                label: Text(expiry.isEmpty ? t('pick_date') : fmtDate(expiry),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 52,
              child: FilledButton.tonalIcon(
                onPressed: _ocrDate,
                icon: const Icon(Icons.document_scanner_outlined),
                label: Text(t('read')),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            ActionChip(label: Text(t('q_today')), onPressed: () => _quick()),
            ActionChip(label: Text(t('q_tomorrow')), onPressed: () => _quick(days: 1)),
            ActionChip(label: Text(t('q_3')), onPressed: () => _quick(days: 3)),
            ActionChip(label: Text(t('q_7')), onPressed: () => _quick(days: 7)),
            ActionChip(label: Text(t('q_14')), onPressed: () => _quick(days: 14)),
            ActionChip(label: Text(t('q_1m')), onPressed: () => _quick(months: 1)),
            ActionChip(label: Text(t('q_3m')), onPressed: () => _quick(months: 3)),
          ]),
          if (expiry.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(leftText(dl),
                  style: TextStyle(color: urgColor(urgency(dl)), fontWeight: FontWeight.w700)),
            ),
          gap,
          // категория
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () async {
              final c = await pickCategory(context, category);
              if (c != null) {
                setState(() {
                  category = c;
                  catManual = true;
                });
              }
            },
            child: InputDecorator(
              decoration: InputDecoration(labelText: t('category'), border: const OutlineInputBorder()),
              child: Row(children: [
                Text(catOf(category).e, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(child: Text(catName(catOf(category)), style: const TextStyle(fontSize: 16))),
                const Icon(Icons.arrow_drop_down),
              ]),
            ),
          ),
          gap,
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: P.dim),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    onPressed: () => setState(() => qty = qty > 1 ? qty - 1 : 1),
                    icon: const Icon(Icons.remove)),
                Text('$qty ${t('pcs')}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                IconButton(onPressed: () => setState(() => qty++), icon: const Icon(Icons.add)),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: code,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: t('barcode'), border: const OutlineInputBorder()),
              ),
            ),
          ]),
          if (same.isNotEmpty || !widget.isNew) _batchesBox(same),
          gap,
          TextField(
            controller: price,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t('price'),
              hintText: t('price_hint'),
              suffixText: '원',
              prefixIcon: const Icon(Icons.sell_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.assignment_return_outlined, color: ret ? const Color(0xFF7B4FD6) : null),
            title: Text(t('ret_mark')),
            subtitle: Text(t('ret_sub')),
            value: ret,
            onChanged: (v) => setState(() => ret = v),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: notes,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: t('notes'),
              hintText: t('notes_hint'),
              border: const OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(t('notif_item')),
            value: !mute,
            onChanged: (v) => setState(() => mute = !v),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? true),
            title: Text(t('remember')),
            subtitle: Text(t('remember_sub')),
          ),
        ],
          ),
        ),
        // Кнопка «Сохранить» всегда над клавиатурой
        Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          elevation: 6,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: saving ? null : _save,
                child: Text(saving ? t('saving') : t('save'), style: const TextStyle(fontSize: 17)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

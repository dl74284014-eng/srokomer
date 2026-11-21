import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'package:image_picker/image_picker.dart';

import 'gemini.dart';
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
  const ItemFormPage({
    super.key,
    required this.item,
    this.isNew = true,
    this.info = '',
    this.focusName = false,
    this.autoOcr = false,
    this.autoPhoto = false,
  });

  @override
  State<ItemFormPage> createState() => _ItemFormPageState();
}

class _ItemFormPageState extends State<ItemFormPage> {
  late final TextEditingController name, nameRu, code, notes;
  final FocusNode nameFocus = FocusNode();
  late String category, expiry, photo;
  late int qty;
  late bool mute;
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

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

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
    final p = await store.savePhotoFile(x.path);
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
    geminiRead(path).then((g) {
      if (g != null && g.names.isNotEmpty) {
        gotGemini = true;
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

    String gCat = 'other';
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
    if (chosen == null || chosen.isEmpty || !mounted) {
      nameFocus.requestFocus();
      return;
    }
    final String picked = chosen;
    final saved = photo.isEmpty ? await store.savePhotoFile(path) : photo;
    if (!mounted) return;
    setState(() {
      name.text = picked;
      if (!catManual) {
        final gc = gCat != 'other' ? gCat : guessCategory(picked);
        if (gc != 'other') category = gc;
      }
      photo = saved;
    });
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
    // Без дубликатов: если такой товар уже есть (тот же штрих-код или то же название) — обновляем его
    var id = widget.item.id;
    var createdAt = widget.item.createdAt;
    final code0 = code.text.replaceAll(' ', '');
    final name0 = name.text.trim().toLowerCase();
    for (final o in store.items) {
      if (o.id == id) continue;
      final same = (code0.isNotEmpty && o.barcode == code0) || (code0.isEmpty && o.barcode.isEmpty && o.name.trim().toLowerCase() == name0);
      if (same) {
        if (!widget.isNew) {
          // редактирование: убираем второй экземпляр
          await store.deleteItem(o.id);
        } else {
          id = o.id;
          createdAt = o.createdAt;
          if (photo.isEmpty) photo = o.photo;
          if (notes.text.trim().isEmpty && o.notes.isNotEmpty) notes.text = o.notes;
          _snack(t('updated_existing'));
        }
        break;
      }
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
      photo: photo,
      createdAt: createdAt,
    );
    await store.upsertItem(it);
    if (remember && it.barcode.isNotEmpty) {
      await store.putProduct(it.barcode,
          Product(name: it.name, nameRu: it.nameRu, category: it.category, photo: it.photo));
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

  @override
  Widget build(BuildContext context) {
    final dl = daysLeft(expiry);
    final same = code.text.isEmpty
        ? <Item>[]
        : store.items.where((i) => i.barcode == code.text && i.id != widget.item.id).toList();
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
              color: const Color(0xFFE9E5DC),
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
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: () async {
              final p = await pickWebPhoto(context, name.text);
              if (p != null && mounted) setState(() => photo = p);
            },
            icon: const Icon(Icons.image_search),
            label: Text(t('photo_web')),
          ),
          gap,
          // название
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(children: [
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
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
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
          if (same.isNotEmpty)
            InfoNote(t('same_code') +
                same.map((o) => '${t('until')} ${fmtDate(o.expiry)}${o.qty > 1 ? ' ×${o.qty}' : ''}').join(', ')),
          gap,
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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

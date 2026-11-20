import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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
  const ItemFormPage({
    super.key,
    required this.item,
    this.isNew = true,
    this.info = '',
    this.focusName = false,
    this.autoOcr = false,
  });

  @override
  State<ItemFormPage> createState() => _ItemFormPageState();
}

class _ItemFormPageState extends State<ItemFormPage> {
  late final TextEditingController name, nameRu, code, notes;
  final FocusNode nameFocus = FocusNode();
  late String category, expiry, photo;
  late int qty;
  bool remember = true;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.autoOcr) {
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
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 88,
      );

  Future<void> _changePhoto(bool camera) async {
    final x = await _shoot(camera: camera);
    if (x == null) return;
    final p = await store.savePhotoFile(x.path);
    setState(() => photo = p);
  }

  // ---------- считать название ----------
  Future<void> _ocrName() async {
    final x = await _shoot();
    if (x == null || !mounted) return;
    final lines = await withLoading(context, 'Читаю текст…', () => ocrLines(x.path));
    if (!mounted) return;
    final c = nameCandidates(lines);
    if (c.isEmpty) {
      _snack('Текст не найден — снимите ближе и ровнее');
      return;
    }
    String? chosen;
    final ans = await askThisOne(context, title: 'Это название?', text: c.first, imagePath: x.path);
    if (!mounted) return;
    if (ans == true) {
      chosen = c.first;
    } else if (ans == false) {
      chosen = await pickLines(context, c);
    }
    if (chosen == null || chosen.isEmpty || !mounted) {
      nameFocus.requestFocus();
      return;
    }
    final String picked = chosen;
    final saved = photo.isEmpty ? await store.savePhotoFile(x.path) : photo;
    if (!mounted) return;
    setState(() {
      name.text = picked;
      if (category == 'other') category = guessCategory(picked);
      photo = saved;
    });
  }

  // ---------- считать срок годности ----------
  Future<void> _ocrDate() async {
    final x = await _shoot();
    if (x == null || !mounted) return;
    final lines = await withLoading(context, 'Ищу срок годности…', () => ocrLines(x.path));
    if (!mounted) return;
    final f = findExpiry(lines);
    if (f == null) {
      _snack('Дату не нашёл — выберите вручную');
      return;
    }
    final ok = await askThisOne(
      context,
      title: 'Срок годности верный?',
      text: 'до ${fmtDate(f.iso)}',
      sub: 'на упаковке: ${f.raw} · ${leftText(daysLeft(f.iso))}',
      imagePath: x.path,
    );
    if (ok == true) setState(() => expiry = f.iso);
  }

  Future<void> _pickDate() async {
    final init = parseIso(expiry) ?? today();
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2045),
      helpText: 'Годен до',
    );
    if (d != null) setState(() => expiry = isoOf(d));
  }

  void _quick({int days = 0, int months = 0}) {
    final t = today();
    setState(() => expiry = isoOf(DateTime(t.year, t.month + months, t.day + days)));
  }

  Future<void> _save() async {
    if (name.text.trim().isEmpty) {
      _snack('Введите название');
      nameFocus.requestFocus();
      return;
    }
    if (expiry.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Срок годности не указан'),
          content: const Text('Сохранить без даты?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Без даты')),
            FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Указать дату')),
          ],
        ),
      );
      if (ok != true) {
        _pickDate();
        return;
      }
    }
    setState(() => saving = true);
    final it = Item(
      id: widget.item.id,
      name: name.text.trim(),
      nameRu: nameRu.text.trim(),
      category: category,
      barcode: code.text.replaceAll(' ', ''),
      expiry: expiry,
      notes: notes.text.trim(),
      qty: qty,
      photo: photo,
      createdAt: widget.item.createdAt,
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
        title: Text('Удалить «${name.text}»?'),
        content: const Text('Например, если товар продан или списан.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD6363B)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
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
    final c = catOf(category);
    final same = code.text.isEmpty
        ? <Item>[]
        : store.items.where((i) => i.barcode == code.text && i.id != widget.item.id).toList();
    const gap = SizedBox(height: 14);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Новый товар' : 'Товар'),
        actions: [
          if (!widget.isNew)
            IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline), tooltip: 'Удалить'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
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
                  : Center(child: Text(c.e, style: const TextStyle(fontSize: 56))),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _changePhoto(true),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Фото товара'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _changePhoto(false),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Из галереи'),
              ),
            ),
          ]),
          gap,
          // название
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: name,
                focusNode: nameFocus,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  hintText: 'например, 서울우유 1L',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              child: FilledButton.tonalIcon(
                onPressed: _ocrName,
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Считать'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: nameRu,
            decoration: const InputDecoration(
              labelText: 'По-русски (необязательно)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          gap,
          // срок
          Text('Срок годности — до какого числа',
              style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _pickDate,
                icon: const Icon(Icons.event),
                label: Text(expiry.isEmpty ? 'Выбрать дату' : fmtDate(expiry),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 52,
              child: FilledButton.tonalIcon(
                onPressed: _ocrDate,
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Считать'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            ActionChip(label: const Text('Сегодня'), onPressed: () => _quick()),
            ActionChip(label: const Text('Завтра'), onPressed: () => _quick(days: 1)),
            ActionChip(label: const Text('+3 дня'), onPressed: () => _quick(days: 3)),
            ActionChip(label: const Text('+7 дней'), onPressed: () => _quick(days: 7)),
            ActionChip(label: const Text('+14 дней'), onPressed: () => _quick(days: 14)),
            ActionChip(label: const Text('+1 мес'), onPressed: () => _quick(months: 1)),
            ActionChip(label: const Text('+3 мес'), onPressed: () => _quick(months: 3)),
          ]),
          if (expiry.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(leftText(dl),
                  style: TextStyle(color: urgColor(urgency(dl)), fontWeight: FontWeight.w700)),
            ),
          gap,
          // категория
          DropdownButtonFormField<String>(
            value: category,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Категория', border: OutlineInputBorder()),
            items: [
              for (final x in cats)
                DropdownMenuItem(value: x.k, child: Text('${x.e}  ${x.n} · ${x.ko}')),
            ],
            onChanged: (v) => setState(() => category = v ?? 'other'),
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
                Text('$qty шт.', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                IconButton(onPressed: () => setState(() => qty++), icon: const Icon(Icons.add)),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: code,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Штрих-код', border: OutlineInputBorder()),
              ),
            ),
          ]),
          if (same.isNotEmpty)
            InfoNote('В списке уже есть с этим штрих-кодом: ' +
                same.map((o) => 'до ${fmtDate(o.expiry)}${o.qty > 1 ? ' ×${o.qty}' : ''}').join(', ')),
          gap,
          TextField(
            controller: notes,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Заметки',
              hintText: 'полка, поставщик, скидка…',
              border: OutlineInputBorder(),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? true),
            title: const Text('Запомнить товар по штрих-коду'),
            subtitle: const Text('В следующий раз название и фото подставятся сами'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            onPressed: saving ? null : _save,
            child: Text(saving ? 'Сохраняю…' : 'Сохранить', style: const TextStyle(fontSize: 17)),
          ),
        ),
      ),
    );
  }
}

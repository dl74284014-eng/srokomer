import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'l10n.dart';
import 'models.dart';
import 'store.dart';

List<Item> _sortedItems() {
  final order = {for (var i = 0; i < cats.length; i++) cats[i].k: i};
  final l = [...store.items];
  l.sort((a, b) {
    final c = (order[catOf(a.category).k] ?? 99).compareTo(order[catOf(b.category).k] ?? 99);
    if (c != 0) return c;
    return (daysLeft(a.expiry) ?? 1 << 30).compareTo(daysLeft(b.expiry) ?? 1 << 30);
  });
  return l;
}

List<String> _headers() => [
      t('col_cat'),
      t('name'),
      t('translation').split('(').first.trim(),
      t('barcode'),
      t('pcs'),
      t('valid_until'),
      t('col_left'),
      t('notes'),
      t('col_added'),
    ];

List<String> _row(Item it) {
  final dl = daysLeft(it.expiry);
  final added = DateTime.fromMillisecondsSinceEpoch(it.createdAt);
  return [
    catName(catOf(it.category)),
    it.name,
    it.nameRu,
    it.barcode,
    '${it.qty}',
    fmtDate(it.expiry),
    dl == null ? '' : '$dl',
    it.notes,
    fmtDate(isoOf(added)),
  ];
}

String _stamp() {
  final n = DateTime.now();
  return '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}';
}

Future<File> buildXlsx() async {
  final ex = xl.Excel.createExcel();
  final sheetName = isKo ? '상품' : 'Товары';
  ex.rename('Sheet1', sheetName);
  final sh = ex[sheetName];
  final head = _headers();
  sh.appendRow([for (final h in head) xl.TextCellValue(h)]);
  for (var c = 0; c < head.length; c++) {
    sh.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).cellStyle =
        xl.CellStyle(bold: true);
  }
  for (final it in _sortedItems()) {
    final r = _row(it);
    final dl = daysLeft(it.expiry);
    sh.appendRow([
      for (var i = 0; i < r.length; i++)
        if (i == 4)
          xl.IntCellValue(it.qty)
        else if (i == 6 && dl != null)
          xl.IntCellValue(dl)
        else
          xl.TextCellValue(r[i]),
    ]);
  }
  const widths = [18.0, 36.0, 24.0, 16.0, 7.0, 13.0, 12.0, 30.0, 13.0];
  for (var i = 0; i < widths.length; i++) {
    sh.setColumnWidth(i, widths[i]);
  }
  final bytes = ex.save();
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/srokomer_${_stamp()}.xlsx');
  await f.writeAsBytes(bytes!);
  return f;
}

String _x(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _run(String text, {bool bold = false, int size = 20}) =>
    '<w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Malgun Gothic" w:cs="Arial"/>'
    '${bold ? '<w:b/>' : ''}<w:sz w:val="$size"/></w:rPr><w:t xml:space="preserve">${_x(text)}</w:t></w:r>';

String _cell(String text, {bool head = false, String fill = ''}) =>
    '<w:tc><w:tcPr>${fill.isNotEmpty ? '<w:shd w:val="clear" w:color="auto" w:fill="$fill"/>' : ''}</w:tcPr>'
    '<w:p><w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr>${_run(text, bold: head, size: 18)}</w:p></w:tc>';

Future<File> buildDocx() async {
  final head = _headers();
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>')
    ..write('<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>${_run(t('export_doc_title'), bold: true, size: 32)}</w:p>')
    ..write('<w:p><w:pPr><w:spacing w:after="200"/></w:pPr>${_run('${fmtDate(isoOf(DateTime.now()))} · ${store.items.length} ${t('pcs')}', size: 20)}</w:p>')
    ..write('<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/><w:tblBorders>');
  for (final side in ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) {
    b.write('<w:$side w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/>');
  }
  b.write('</w:tblBorders><w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar></w:tblPr>');
  b.write('<w:tr><w:trPr><w:tblHeader/></w:trPr>');
  for (final h in head) {
    b.write(_cell(h, head: true, fill: 'E3F2EA'));
  }
  b.write('</w:tr>');
  for (final it in _sortedItems()) {
    final u = urgency(daysLeft(it.expiry));
    final fill = u == Urg.red ? 'FDE8E8' : (u == Urg.orange ? 'FFF0E0' : '');
    b.write('<w:tr>');
    for (final v in _row(it)) {
      b.write(_cell(v, fill: fill));
    }
    b.write('</w:tr>');
  }
  b.write('</w:tbl><w:p/>');
  b.write('<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>'
      '<w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>');
  b.write('</w:body></w:document>');

  const types = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  final arc = Archive();
  void add(String name, String content) {
    final data = utf8.encode(content);
    arc.addFile(ArchiveFile(name, data.length, data));
  }

  add('[Content_Types].xml', types);
  add('_rels/.rels', rels);
  add('word/document.xml', b.toString());
  final bytes = ZipEncoder().encode(arc);
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/srokomer_${_stamp()}.docx');
  await f.writeAsBytes(bytes!);
  return f;
}

Future<void> showExportSheet(BuildContext context) async {
  if (store.items.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('export_empty'))));
    return;
  }
  final kind = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('export_title'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(t('export_sub'), style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0xFF1D6F42), child: Text('X', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            title: const Text('Excel (.xlsx)', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, 'xlsx'),
          ),
          ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0xFF2B579A), child: Text('W', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            title: const Text('Word (.docx)', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, 'docx'),
          ),
        ]),
      ),
    ),
  );
  if (kind == null) return;
  try {
    final f = kind == 'xlsx' ? await buildXlsx() : await buildDocx();
    final mime = kind == 'xlsx'
        ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    await Share.shareXFiles([XFile(f.path, mimeType: mime)], subject: t('export_doc_title'));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
}

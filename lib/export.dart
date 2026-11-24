import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'l10n.dart';
import 'models.dart';
import 'store.dart';

List<Item> _sortedItems() {
  final l = [...store.items];
  l.sort((a, b) => (daysLeft(a.expiry) ?? 1 << 30).compareTo(daysLeft(b.expiry) ?? 1 << 30));
  return l;
}

List<String> _headers() => [
      t('name'),
      t('translation').split('(').first.trim(),
      t('barcode'),
      t('pcs'),
      t('valid_until'),
      t('col_left'),
      t('notes'),
      t('col_added'),
      t('price'),
      t('ret_short'),
    ];

List<String> _row(Item it) {
  final dl = daysLeft(it.expiry);
  final added = DateTime.fromMillisecondsSinceEpoch(it.createdAt);
  return [
    it.name,
    it.nameRu,
    it.barcode,
    '${it.qty}',
    fmtDate(it.expiry),
    dl == null ? '' : '$dl',
    it.notes,
    fmtDate(isoOf(added)),
    it.price > 0 ? fmtPrice(it.price) : '',
    it.ret ? '✔' : '',
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
        if (i == 3)
          xl.IntCellValue(it.qty)
        else if (i == 5 && dl != null)
          xl.IntCellValue(dl)
        else if (i == 8 && it.price > 0)
          xl.IntCellValue(it.price)
        else
          xl.TextCellValue(r[i]),
    ]);
  }
  const widths = [36.0, 24.0, 16.0, 7.0, 13.0, 12.0, 30.0, 13.0, 11.0, 8.0];
  for (var i = 0; i < widths.length; i++) {
    sh.setColumnWidth(i, widths[i]);
  }
  final bytes = ex.save();
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/lmart_${_stamp()}.xlsx');
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
  final f = File('${dir.path}/lmart_${_stamp()}.docx');
  await f.writeAsBytes(bytes!);
  return f;
}

// ---------------- текст (сообщение / .txt) ----------------
String _dot(Item it) {
  switch (urgency(daysLeft(it.expiry))) {
    case Urg.red:
      return '🔴';
    case Urg.orange:
      return '🟠';
    case Urg.yellow:
      return '🟡';
    case Urg.green:
      return '🟢';
    case Urg.none:
      return '⚪';
  }
}

String buildText() {
  final b = StringBuffer()
    ..writeln('${t('export_doc_title')} · ${fmtDate(isoOf(DateTime.now()))}')
    ..writeln('${store.items.length} ${t('pcs')}')
    ..writeln();
  for (final it in _sortedItems()) {
    final q = it.qty > 1 ? ' ×${it.qty}' : '';
    b.writeln('${_dot(it)} ${it.name}$q${it.price > 0 ? ' · ${fmtPrice(it.price)}' : ''}${it.ret ? ' · ↩ ${t('ret_short')}' : ''}');
    b.writeln('    ${t('until')} ${fmtDate(it.expiry)} · ${leftText(daysLeft(it.expiry))}'
        '${it.notes.isNotEmpty ? ' · 📝 ${it.notes}' : ''}');
  }
  return b.toString();
}

Future<File> buildTxt() async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/lmart_${_stamp()}.txt');
  await f.writeAsString(buildText());
  return f;
}

// ---------------- PDF ----------------
Future<File> buildPdf() async {
  final font = pw.Font.ttf(await rootBundle.load('assets/fonts/NanumGothic-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/NanumGothic-Bold.ttf'));
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: bold));
  final head = _headers();
  final rows = _sortedItems().map(_row).toList();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(24),
    build: (ctx) => [
      pw.Text(t('export_doc_title'), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text('${fmtDate(isoOf(DateTime.now()))} · ${store.items.length} ${t('pcs')}',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
      pw.SizedBox(height: 10),
      pw.TableHelper.fromTextArray(
        headers: head,
        data: rows,
        headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE3F2EA)),
        cellStyle: const pw.TextStyle(fontSize: 9),
        cellAlignment: pw.Alignment.centerLeft,
        oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF7F7F7)),
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      ),
    ],
  ));
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/lmart_${_stamp()}.pdf');
  await f.writeAsBytes(await doc.save());
  return f;
}

Future<void> showExportSheet(BuildContext context) async {
  if (store.items.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('export_empty'))));
    return;
  }
  Widget opt(BuildContext ctx, String k, Color c, String letter, String title, {String sub = ''}) => ListTile(
        leading: CircleAvatar(
            backgroundColor: c,
            child: Text(letter, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))),
        title: Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600)),
        subtitle: sub.isEmpty ? null : Text(sub),
        onTap: () => Navigator.pop(ctx, k),
      );
  final kind = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('export_title'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(t('export_sub'), style: const TextStyle(color: Colors.black54)),
          Text('🇰🇷 ${t('export_ko_note')}', style: const TextStyle(color: Color(0xFF2A8A57), fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          opt(ctx, 'msg', const Color(0xFFFEE500), '💬', t('export_msg'), sub: t('export_msg_sub')),
          opt(ctx, 'pdf', const Color(0xFFD93025), 'PDF', 'PDF (.pdf)'),
          opt(ctx, 'xlsx', const Color(0xFF1D6F42), 'X', 'Excel (.xlsx)'),
          opt(ctx, 'docx', const Color(0xFF2B579A), 'W', 'Word (.docx)'),
          opt(ctx, 'txt', const Color(0xFF616161), 'TXT', t('export_txt')),
        ]),
      ),
    ),
  );
  if (kind == null) return;
  try {
    if (kind == 'msg') {
      final text = await inKorean(() async => buildText());
      await Share.share(text, subject: '유통기한 목록');
      return;
    }
    final File f;
    final String mime;
    switch (kind) {
      case 'xlsx':
        f = await inKorean(buildXlsx);
        mime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'docx':
        f = await inKorean(buildDocx);
        mime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'pdf':
        f = await inKorean(buildPdf);
        mime = 'application/pdf';
      default:
        f = await inKorean(buildTxt);
        mime = 'text/plain';
    }
    await Share.shareXFiles([XFile(f.path, mimeType: mime)], subject: '유통기한 목록');
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
}

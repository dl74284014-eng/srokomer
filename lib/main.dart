import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'item_form.dart';
import 'l10n.dart';
import 'settings_page.dart';
import 'lookup.dart';
import 'models.dart';
import 'scanner_page.dart';
import 'store.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const SrokomerApp());
}

const brand = Color(0xFF16794C);
const bg = Color(0xFFF4F1EA);

class SrokomerApp extends StatelessWidget {
  const SrokomerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
      title: 'Срокомер',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: brand,
        scaffoldBackgroundColor: bg,
        appBarTheme: const AppBarTheme(backgroundColor: bg, surfaceTintColor: Colors.transparent),
      ),
      locale: Locale(lang),
      supportedLocales: const [Locale('ru'), Locale('ko'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomePage(),
    ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

const sortKeys = ['soon', 'late', 'az', 'za', 'new'];
String sortName(String k) => t('sort_$k');

class _HomePageState extends State<HomePage> {
  String cat = 'all';
  Urg? urg;
  String sort = 'soon';
  String q = '';

  // ---------------- действия ----------------
  Future<void> _openForm(Item it,
      {bool isNew = true, String info = '', bool focusName = false, bool autoOcr = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ItemFormPage(
            item: it, isNew: isNew, info: info, focusName: focusName, autoOcr: autoOcr),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code == null || !mounted) return;
    if (code == ScannerPage.manual) {
      _openForm(Item(id: newId()), info: t('no_barcode_info'), autoOcr: true);
      return;
    }
    final known = store.products[code];
    if (known != null) {
      _openForm(
        Item(id: newId(), name: known.name, nameRu: known.nameRu, category: known.category, barcode: code, photo: known.photo),
        info: t('known'),
      );
      return;
    }
    final mfdsKey = store.mfdsKey;
    final kakaoKey = store.kakaoKey;
    final found = await withLoading(context, tf('searching', {'code': code}), () async {
      final r = await lookupBarcode(code, mfdsKey: mfdsKey, kakaoKey: kakaoKey);
      var photo = '';
      if (r != null && r.imageUrl.isNotEmpty) {
        final bytes = await download(r.imageUrl);
        if (bytes != null) photo = await store.savePhotoBytes(bytes);
      }
      return (r: r, photo: photo);
    });
    if (!mounted) return;
    final r = found.r;
    final noKeysHint = (mfdsKey.isEmpty || kakaoKey.isEmpty) ? '\n\n${t('keys_hint')}' : '';
    if (r == null) {
      _openForm(Item(id: newId(), barcode: code),
          info: tf('not_found', {'code': code}) + noKeysHint, autoOcr: true);
      return;
    }
    final sub = [
      if (r.maker.isNotEmpty) r.maker,
      if (r.type.isNotEmpty && !r.type.contains(':')) r.type,
      '${t('source')}: ${r.source}',
    ].join(' · ');
    final ok = await askThisOne(context,
        title: r.guess ? t('guess_q') : t('found_q'), text: r.name, sub: sub, imagePath: found.photo);
    if (ok == null || !mounted) return;
    var name = r.name;
    var confirmed = ok;
    if (!ok && r.alternatives.length > 1) {
      final pick = await pickOne(context, t('pick_variant'), r.alternatives.skip(1).toList());
      if (!mounted) return;
      if (pick != null) {
        name = pick;
        confirmed = true;
      }
    }
    _openForm(
      Item(
        id: newId(),
        name: name,
        category: guessCategory('$name ${r.type}'),
        barcode: code,
        photo: found.photo,
      ),
      focusName: !confirmed,
      info: confirmed ? '' : t('fix_name'),
    );
  }

  // ---------------- данные для списка ----------------
  List<Item> _filtered() {
    final qq = q.trim().toLowerCase();
    return store.items.where((it) {
      if (urg != null && urgency(daysLeft(it.expiry)) != urg) return false;
      if (qq.isEmpty) return true;
      return [it.name, it.nameRu, it.notes, it.barcode].any((v) => v.toLowerCase().contains(qq));
    }).toList();
  }

  int Function(Item, Item) _cmp() {
    const big = 1 << 30;
    switch (sort) {
      case 'late':
        return (a, b) => (daysLeft(b.expiry) ?? -big).compareTo(daysLeft(a.expiry) ?? -big);
      case 'az':
        return (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case 'za':
        return (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase());
      case 'new':
        return (a, b) => b.createdAt.compareTo(a.createdAt);
      default:
        return (a, b) => (daysLeft(a.expiry) ?? big).compareTo(daysLeft(b.expiry) ?? big);
    }
  }

  int? _minDays(List<Item> l) {
    int? m;
    for (final i in l) {
      final d = daysLeft(i.expiry);
      if (d != null && (m == null || d < m)) m = d;
    }
    return m;
  }

  String _groupText(List<Item> l) {
    final m = _minDays(l);
    final n = '${l.length} ${t('pcs')}';
    if (m == null) return '$n · ${t('no_dates')}';
    if (m < 0) return '$n · ${t('has_expired')}';
    if (m == 0) return '$n · ${t('nearest_today')}';
    return '$n · ${tf('nearest_in', {'n': m, 'd': daysWord(m)})}';
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('🛒 ', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(isKo ? '유통기한 체크' : 'Срокомер', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Text(isKo ? 'Срокомер' : '유통기한', style: const TextStyle(fontSize: 13, color: Colors.black54)),
        ]),
        actions: [
          IconButton(
            tooltip: t('settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) => _body(),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'add',
            backgroundColor: Colors.white,
            onPressed: () => _openForm(Item(id: newId())),
            tooltip: t('add_manual'),
            child: const Icon(Icons.add),
          ),
          const SizedBox(width: 14),
          FloatingActionButton.extended(
            heroTag: 'scan',
            backgroundColor: brand,
            foregroundColor: Colors.white,
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(t('scan'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final base = _filtered();
    final byCat = <String, List<Item>>{};
    for (final it in base) {
      byCat.putIfAbsent(catOf(it.category).k, () => []).add(it);
    }
    if (cat != 'all' && !byCat.containsKey(cat)) cat = 'all';
    final cmp = _cmp();

    final children = <Widget>[
      _stats(),
      const SizedBox(height: 10),
      _searchRow(),
      const SizedBox(height: 8),
      _chips(base.length, byCat),
    ];

    if (store.items.isEmpty) {
      children.add(_Empty('📦', t('empty_title'), t('empty_text')));
    } else if (base.isEmpty) {
      children.add(_Empty('🔍', t('nothing'), ''));
    } else if (cat != 'all') {
      final l = [...byCat[cat]!]..sort(cmp);
      final c = catOf(cat);
      children.add(_groupHeader(c, l));
      children.addAll(l.map(_tile));
    } else {
      final groups = cats.where((c) => byCat.containsKey(c.k)).toList();
      if (sort == 'soon') {
        groups.sort((a, b) => (_minDays(byCat[a.k]!) ?? 1 << 30).compareTo(_minDays(byCat[b.k]!) ?? 1 << 30));
      } else if (sort == 'late') {
        groups.sort((a, b) => (_minDays(byCat[b.k]!) ?? -(1 << 30)).compareTo(_minDays(byCat[a.k]!) ?? -(1 << 30)));
      } else if (sort == 'az' || sort == 'za') {
        groups.sort((a, b) => sort == 'az' ? catName(a).compareTo(catName(b)) : catName(b).compareTo(catName(a)));
      }
      for (final c in groups) {
        final l = [...byCat[c.k]!]..sort(cmp);
        children.add(_groupHeader(c, l));
        children.addAll(l.map(_tile));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 110),
      children: children,
    );
  }

  Widget _stats() {
    var red = 0, orange = 0, yellow = 0;
    for (final it in store.items) {
      final u = urgency(daysLeft(it.expiry));
      if (u == Urg.red) red++;
      if (u == Urg.orange) orange++;
      if (u == Urg.yellow) yellow++;
    }
    Widget cell(Urg? u, int n, String label, Color color) {
      final active = u != null && urg == u;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => urg = (u == null || urg == u) ? null : u),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: active ? Colors.black87 : Colors.transparent, width: 2),
              boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$n', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
              Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
            ]),
          ),
        ),
      );
    }

    return Row(children: [
      cell(Urg.red, red, t('expired'), urgColor(Urg.red)),
      cell(Urg.orange, orange, t('le3'), urgColor(Urg.orange)),
      cell(Urg.yellow, yellow, t('le7'), urgColor(Urg.yellow)),
      cell(null, store.items.length, t('total'), Colors.black87),
    ]);
  }

  Widget _searchRow() {
    return Row(children: [
      Expanded(
        child: TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: InputDecoration(
            hintText: t('search'),
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
      ),
      const SizedBox(width: 8),
      PopupMenuButton<String>(
        initialValue: sort,
        onSelected: (v) => setState(() => sort = v),
        itemBuilder: (_) => [
          for (final k in sortKeys) PopupMenuItem(value: k, child: Text(sortName(k))),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.sort, size: 20),
            const SizedBox(width: 4),
            Text(sortName(sort), style: const TextStyle(fontSize: 13)),
          ]),
        ),
      ),
    ]);
  }

  Widget _chips(int total, Map<String, List<Item>> byCat) {
    Widget chip(String key, String label, int n, Color? dot) {
      final on = cat == key;
      return Padding(
        padding: const EdgeInsets.only(right: 7),
        child: GestureDetector(
          onTap: () => setState(() => cat = key),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Colors.black87 : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? Colors.black87 : const Color(0xFFE4DFD4)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (dot != null) ...[
                Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                const SizedBox(width: 6),
              ],
              Text(label, style: TextStyle(color: on ? Colors.white : Colors.black87, fontSize: 13.5)),
              const SizedBox(width: 5),
              Text('$n',
                  style: TextStyle(
                      color: on ? Colors.white70 : Colors.black54, fontWeight: FontWeight.w700, fontSize: 13)),
            ]),
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip('all', t('all'), total, null),
          for (final c in cats)
            if (byCat.containsKey(c.k))
              chip(c.k, '${c.e} ${catName(c)}', byCat[c.k]!.length, urgColor(urgency(_minDays(byCat[c.k]!)))),
        ],
      ),
    );
  }

  Widget _groupHeader(Cat c, List<Item> l) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${c.e} ${catName(c)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(_groupText(l), style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
        ]),
      );

  Widget _tile(Item it) {
    final dl = daysLeft(it.expiry);
    final u = urgency(dl);
    final c = catOf(it.category);
    final hasPhoto = it.photo.isNotEmpty && File(it.photo).existsSync();
    final sub = [
      '${t('until')} ${fmtDate(it.expiry)}',
      if (it.nameRu.isNotEmpty) it.nameRu,
      if (it.notes.isNotEmpty) '📝 ${it.notes}',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openForm(Item.fromJson(it.toJson()), isNew: false),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 58,
                  height: 58,
                  color: const Color(0xFFEEEEEE),
                  alignment: Alignment.center,
                  child: hasPhoto
                      ? Image.file(File(it.photo), width: 58, height: 58, fit: BoxFit.cover, cacheWidth: 180)
                      : Text(c.e, style: const TextStyle(fontSize: 26)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    it.name.isEmpty ? t('no_name') : (it.qty > 1 ? '${it.name}  ×${it.qty}' : it.name),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 3),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 64),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                decoration: BoxDecoration(color: urgSoft(u), borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text(dl == null ? '?' : (dl < 0 ? '!' : '$dl'),
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: urgColor(u))),
                  Text(
                    dl == null
                        ? t('no_date')
                        : dl < 0
                            ? t('expired')
                            : dl == 0
                                ? t('today')
                                : daysWord(dl),
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: urgColor(u)),
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

class _Empty extends StatelessWidget {
  final String icon, title, text;
  const _Empty(this.icon, this.title, this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 20),
        child: Column(children: [
          Text(icon, style: const TextStyle(fontSize: 52)),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
          ],
        ]),
      );
}

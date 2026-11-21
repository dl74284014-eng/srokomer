import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'export.dart';
import 'item_tile.dart';
import 'l10n.dart';
import 'list_page.dart';
import 'lookup.dart';
import 'models.dart';
import 'notify.dart';
import 'scanner_page.dart';
import 'settings_page.dart';
import 'auth.dart';
import 'store.dart';
import 'sync.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  syncer.attach();
  runApp(const SrokomerApp());
  notifier.init();
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
        title: 'L할인마트 유통기한',
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_onStore);
    auth.addListener(_onStore); // смена языка и данных — перерисовать весь экран (шапку и кнопки тоже)
    syncer.syncNow();
    syncer.startPeriodic();
    if (notifier.on) notifier.requestPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_onStore);
    auth.removeListener(_onStore);
    syncer.stopPeriodic();
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      notifier.reschedule(); // пересчитать «осталось N дней»
      syncer.syncNow();
      syncer.startPeriodic();
    } else if (state == AppLifecycleState.paused) {
      syncer.stopPeriodic();
    }
  }
  Future<void> _scan() async {
    final code = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code == null || !mounted) return;
    if (code == ScannerPage.manual) {
      openItemForm(context, Item(id: newId()), info: t('no_barcode_info'), autoOcr: true);
      return;
    }
    // Товар уже в списке — открываем его, а не создаём дубликат
    final existing = store.items.where((i) => i.barcode == code).toList();
    if (existing.isNotEmpty) {
      openItemForm(context, Item.fromJson(existing.first.toJson()), isNew: false, info: t('already_in_list'));
      return;
    }
    final known = store.products[code];
    if (known != null) {
      openItemForm(context, 
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
      openItemForm(context, Item(id: newId(), barcode: code),
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
    openItemForm(context, 
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

  void _open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  int? _minDays(Iterable<Item> l) {
    int? m;
    for (final i in l) {
      final d = daysLeft(i.expiry);
      if (d != null && (m == null || d < m)) m = d;
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Image.asset('assets/icon.png', width: 36, height: 36),
          ),
          const SizedBox(width: 10),
          const Text('L할인마트 유통기한', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          ListenableBuilder(
            listenable: syncer,
            builder: (context, _) {
              if (!syncer.enabled) return const SizedBox.shrink();
              final icon = syncer.running
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Icon(syncer.error == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      color: syncer.error == null ? const Color(0xFF2A8A57) : const Color(0xFFD6363B));
              return IconButton(tooltip: t('sync_now'), icon: icon, onPressed: syncer.syncNow);
            },
          ),
          IconButton(
            tooltip: t('export'),
            icon: const Icon(Icons.ios_share),
            onPressed: () => showExportSheet(context),
          ),
          IconButton(
            tooltip: t('settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(const SettingsPage()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: syncer.syncNow,
        child: ListenableBuilder(listenable: store, builder: (context, _) => _body()),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: brand,
                  minimumSize: const Size.fromHeight(60),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                ),
                onPressed: _scan,
                icon: const Icon(Icons.qr_code_scanner, size: 28),
                label: Text(t('scan_big'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 60,
              height: 60,
              child: IconButton.filledTonal(
                tooltip: t('add_manual'),
                style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                onPressed: () => openItemForm(context, Item(id: newId())),
                icon: const Icon(Icons.add, size: 30),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _body() {
    final items = store.items;
    var red = 0, orange = 0, yellow = 0;
    for (final it in items) {
      final u = urgency(daysLeft(it.expiry));
      if (u == Urg.red) red++;
      if (u == Urg.orange) orange++;
      if (u == Urg.yellow) yellow++;
    }
    final soon = items.where((i) {
      final d = daysLeft(i.expiry);
      return d != null && d <= 3;
    }).toList()
      ..sort((a, b) => daysLeft(a.expiry)!.compareTo(daysLeft(b.expiry)!));

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
      children: [
        if (auth.configured && !auth.loggedIn)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: const Color(0xFFFFF0E0),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _open(const SettingsPage()),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    const Text('☁️', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(t('acc_banner'), style: const TextStyle(fontSize: 14))),
                    const Icon(Icons.chevron_right),
                  ]),
                ),
              ),
            ),
          ),
        // ---- светофор сроков ----
        Row(children: [
          _stat(red, t('expired'), Urg.red, () => _open(ListPage(urg: Urg.red, title: t('expired_list')))),
          _stat(red + orange, t('le3'), Urg.orange, () => _open(ListPage(urg: Urg.orange, title: t('soon_list')))),
          _stat(red + orange + yellow, t('le7'), Urg.yellow, () => _open(ListPage(urg: Urg.yellow, title: t('week_list')))),
        ]),
        const SizedBox(height: 12),
        // ---- поиск ----
        GestureDetector(
          onTap: () => _open(ListPage(title: t('all_items'), focusSearch: true)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              const Icon(Icons.search, color: Colors.black54),
              const SizedBox(width: 10),
              Expanded(child: Text(t('search'), style: const TextStyle(color: Colors.black54, fontSize: 15))),
            ]),
          ),
        ),
        const SizedBox(height: 18),
        // ---- плашки: категории и все товары ----
        _bigButton('📋', t('all_items'), '${items.length} ${t('pcs')}', () => _open(ListPage(title: t('all_items')))),
        const SizedBox(height: 20),
        // ---- скоро заканчивается ----
        Text(t('soon_title'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        if (items.isEmpty)
          _note('📦  ${t('empty_text')}')
        else if (soon.isEmpty)
          _note('✅  ${t('all_good')}')
        else ...[
          ...soon.take(8).map((it) => ItemTile(it, key: ValueKey(it.id))),
          if (soon.length > 8)
            TextButton(
              onPressed: () => _open(ListPage(urg: Urg.orange, title: t('soon_list'))),
              child: Text('${t('all_items')} (${soon.length}) →'),
            ),
          Text(t('hold_hint'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.black45, fontSize: 12.5)),
        ],
      ],
    );
  }

  Widget _note(String text) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: const TextStyle(fontSize: 15, height: 1.4)),
      );

  Widget _stat(int n, String label, Urg u, VoidCallback onTap) {
    final active = n > 0;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: active ? urgSoft(u) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$n',
                    style: TextStyle(
                        fontSize: 28, fontWeight: FontWeight.w800, color: active ? urgColor(u) : Colors.black26)),
                Text(label, style: const TextStyle(fontSize: 13, color: Colors.black87)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bigButton(String emoji, String title, String sub, VoidCallback onTap) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(children: [
              Text(emoji, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 14),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              Text(sub, style: const TextStyle(color: Colors.black54, fontSize: 14)),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: Colors.black45),
            ]),
          ),
        ),
      );
}

/// Экран со всеми категориями (открывается с главного экрана).
class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  void _open(BuildContext context, Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  int? _minDays(Iterable<Item> l) {
    int? m;
    for (final i in l) {
      final d = daysLeft(i.expiry);
      if (d != null && (m == null || d < m)) m = d;
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('categories'))),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final items = store.items;
          return GridView.count(
            padding: const EdgeInsets.all(14),
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.92,
            children: [
              for (final c in cats)
                _catTile(c.e, catName(c), items.where((i) => catOf(i.category).k == c.k).toList(),
                    () => _open(context, ListPage(cat: c.k, title: '${c.e} ${catName(c)}'))),
            ],
          );
        },
      ),
    );
  }

  Widget _catTile(String emoji, String name, List<Item> l, VoidCallback onTap) {
    final m = _minDays(l);
    final u = urgency(m);
    final empty = l.isEmpty;
    final badge = empty
        ? ''
        : m == null
            ? '—'
            : m < 0
                ? '!'
                : m == 0
                    ? t('today')
                    : tf('short_days', {'n': m});
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Opacity(
          opacity: empty ? 0.45 : 1,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(emoji, style: const TextStyle(fontSize: 30)),
              const SizedBox(height: 4),
              Text(name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.15)),
              const SizedBox(height: 4),
              if (!empty)
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('${l.length}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: urgSoft(u), borderRadius: BorderRadius.circular(8)),
                    child: Text(badge,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: urgColor(u))),
                  ),
                ])
              else
                const Text('0', style: TextStyle(fontSize: 13, color: Colors.black45)),
            ]),
          ),
        ),
      ),
    );
  }
}

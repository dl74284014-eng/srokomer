import 'package:flutter/material.dart';

import 'item_tile.dart';
import 'l10n.dart';
import 'models.dart';
import 'store.dart';

/// Список товаров: одна категория, все товары или фильтр по сроку.
class ListPage extends StatefulWidget {
  final String? cat; // ключ категории
  final Urg? urg; // фильтр по сроку
  final String title;
  final bool focusSearch;
  const ListPage({super.key, this.cat, this.urg, required this.title, this.focusSearch = false});

  @override
  State<ListPage> createState() => _ListPageState();
}

const sortKeys = ['soon', 'late', 'az', 'za', 'new'];

class _ListPageState extends State<ListPage> {
  String q = '';
  late String sort = store.settings['sort'] ?? 'soon';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          PopupMenuButton<String>(
            tooltip: t('sort'),
            icon: const Icon(Icons.sort),
            initialValue: sort,
            onSelected: (v) {
              setState(() => sort = v);
              store.setSetting('sort', v);
            },
            itemBuilder: (_) => [
              for (final k in sortKeys)
                PopupMenuItem(value: k, child: Text(t('sort_$k'))),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final qq = q.trim().toLowerCase();
          final items = store.items.where((it) {
            if (widget.cat != null && catOf(it.category).k != widget.cat) return false;
            if (widget.urg != null) {
              final u = urgency(daysLeft(it.expiry));
              // «неделя» включает и более срочные, «≤3» включает просроченные
              if (widget.urg == Urg.red && u != Urg.red) return false;
              if (widget.urg == Urg.orange && !(u == Urg.red || u == Urg.orange)) return false;
              if (widget.urg == Urg.yellow && !(u == Urg.red || u == Urg.orange || u == Urg.yellow)) return false;
            }
            if (qq.isEmpty) return true;
            return [it.name, it.nameRu, it.notes, it.barcode].any((v) => v.toLowerCase().contains(qq));
          }).toList()
            ..sort(_cmp());

          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
            children: [
              TextField(
                autofocus: widget.focusSearch,
                onChanged: (v) => setState(() => q = v),
                decoration: InputDecoration(
                  hintText: t('search'),
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
                child: Text('${t('sort')}: ${t('sort_$sort')} · ${items.length} ${t('pcs')}',
                    style: const TextStyle(color: Colors.black54, fontSize: 13)),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 60),
                  child: Center(
                    child: Text(q.isEmpty ? t('empty_cat') : t('nothing'),
                        style: const TextStyle(color: Colors.black54, fontSize: 16)),
                  ),
                ),
              ...items.map((it) => ItemTile(it, key: ValueKey(it.id))),
              if (items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(t('hold_hint'),
                      textAlign: TextAlign.center, style: const TextStyle(color: Colors.black45, fontSize: 12.5)),
                ),
            ],
          );
        },
      ),
    );
  }
}

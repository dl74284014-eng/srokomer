import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'models.dart';
import 'photo_fix.dart';
import 'store.dart';

/// Сомнительные фото: название на фото не совпадает с названием товара.
/// Для каждого — «Фото верное» или «Убрать фото».
class PhotoReviewPage extends StatefulWidget {
  final List<Doubt> doubts;
  const PhotoReviewPage(this.doubts, {super.key});
  @override
  State<PhotoReviewPage> createState() => _PhotoReviewPageState();
}

class _PhotoReviewPageState extends State<PhotoReviewPage> {
  late final List<Doubt> list = [...widget.doubts];

  Future<void> _ok(Doubt d) async {
    await markPhotoOk(d.item.id);
    setState(() => list.remove(d));
  }

  Future<void> _remove(Doubt d) async {
    final n = Item.fromJson(d.item.toJson())
      ..photo = ''
      ..photoRemote = '';
    await store.upsertItem(n);
    await markPhotoOk(d.item.id);
    setState(() => list.remove(d));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${t('review_title')} (${list.length})')),
      body: list.isEmpty
          ? Center(child: Text('✅ ${t('review_done')}', style: const TextStyle(fontSize: 17)))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(t('review_help'), style: TextStyle(color: P.muted)),
                const SizedBox(height: 10),
                for (final d in list)
                  Card(
                    elevation: 0,
                    color: P.card,
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(File(d.item.photo),
                                width: 110, height: 110, fit: BoxFit.cover, cacheWidth: 330,
                                errorBuilder: (_, __, ___) => const SizedBox(width: 110, height: 110)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t('review_item'), style: TextStyle(color: P.muted, fontSize: 12)),
                              Text(d.item.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                              const SizedBox(height: 8),
                              Text(t('review_on_photo'), style: TextStyle(color: P.muted, fontSize: 12)),
                              Text(d.photoName, style: const TextStyle(fontSize: 15)),
                            ]),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _remove(d),
                              icon: const Icon(Icons.hide_image_outlined),
                              label: Text(t('act_nophoto')),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _ok(d),
                              icon: const Icon(Icons.check),
                              label: Text(t('review_ok')),
                            ),
                          ),
                        ]),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}

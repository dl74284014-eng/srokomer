import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'lookup.dart';
import 'store.dart';
import 'sync.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController mfds =
      TextEditingController(text: store.mfdsKey);
  late final TextEditingController kakao =
      TextEditingController(text: store.kakaoKey);
  late final TextEditingController supaUrl = TextEditingController(text: store.supaUrl);
  late final TextEditingController supaKey = TextEditingController(text: store.supaKey);
  final TextEditingController joinCode = TextEditingController();
  String? mfdsStatus, kakaoStatus, syncTest;
  bool showServer = false;
  bool busyM = false, busyK = false;

  @override
  void dispose() {
    mfds.dispose();
    kakao.dispose();
    supaUrl.dispose();
    supaKey.dispose();
    joinCode.dispose();
    super.dispose();
  }

  Future<void> _checkMfds() async {
    final k = mfds.text.trim();
    await store.setSetting('mfdsKey', k);
    if (k.isEmpty) return;
    setState(() => busyM = true);
    final err = await testMfdsKey(k);
    if (!mounted) return;
    setState(() {
      busyM = false;
      mfdsStatus = err == null ? t('key_ok') : '❌ $err';
    });
  }

  Future<void> _checkKakao() async {
    final k = kakao.text.trim();
    await store.setSetting('kakaoKey', k);
    if (k.isEmpty) return;
    setState(() => busyK = true);
    final err = await testKakaoKey(k);
    if (!mounted) return;
    setState(() {
      busyK = false;
      kakaoStatus = err == null ? t('key_ok') : '❌ $err';
    });
  }

  Widget _keyBlock({
    required String title,
    required String help,
    required TextEditingController ctrl,
    required bool busy,
    required String? status,
    required VoidCallback onCheck,
    required String settingKey,
  }) {
    return Card(
      elevation: 0,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Text(help, style: const TextStyle(color: Colors.black54, height: 1.4)),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            onChanged: (v) => store.setSetting(settingKey, v.trim()),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.tonal(
              onPressed: busy ? null : onCheck,
              child: Text(busy ? t('checking') : t('check')),
            ),
            const SizedBox(width: 10),
            if (status != null)
              Expanded(
                child: Text(status,
                    style: TextStyle(
                        color: status.startsWith('❌') ? const Color(0xFFD6363B) : const Color(0xFF2A8A57),
                        fontWeight: FontWeight.w600)),
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _syncBlock() {
    return ListenableBuilder(
      listenable: syncer,
      builder: (context, _) {
        String st;
        Color col = Colors.black54;
        if (!syncer.enabled) {
          st = t('sync_off');
          col = const Color(0xFFE5740B);
        } else if (syncer.running) {
          st = '⟳ …';
        } else if (syncer.error != null) {
          st = '❌ ${syncer.error}';
          col = const Color(0xFFD6363B);
        } else if (syncer.lastOk != null) {
          final d = syncer.lastOk!;
          st = '✓ ${t('sync_ok')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
          col = const Color(0xFF2A8A57);
        } else {
          st = '';
        }
        return Card(
          elevation: 0,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t('sync_title'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 6),
              Text(t('sync_text'), style: const TextStyle(color: Colors.black54, height: 1.4)),
              const SizedBox(height: 14),
              Text(t('sync_code'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                    decoration: BoxDecoration(color: const Color(0xFFE3F2EA), borderRadius: BorderRadius.circular(10)),
                    child: SelectableText(store.syncSpace,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: store.syncSpace));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('copied'))));
                  },
                  child: Text(t('copy')),
                ),
              ]),
              const SizedBox(height: 4),
              Text(t('sync_code_help'), style: const TextStyle(color: Colors.black54, fontSize: 13)),
              const SizedBox(height: 14),
              Text(t('sync_join'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: joinCode,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(hintText: 'XXXX-XXXX-XXXX', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final c = joinCode.text.trim();
                    if (c.length < 6) return;
                    await syncer.joinSpace(c);
                    joinCode.clear();
                    if (!mounted) return;
                    setState(() {});
                    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text(t('sync_joined'))));
                  },
                  child: Text(t('sync_join_btn')),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                FilledButton.tonalIcon(
                  onPressed: syncer.running || !syncer.enabled ? null : syncer.syncNow,
                  icon: const Icon(Icons.sync),
                  label: Text(t('sync_now')),
                ),
              ]),
              if (st.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(st, style: TextStyle(color: col, fontWeight: FontWeight.w600)),
                ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => setState(() => showServer = !showServer),
                child: Text('${t('sync_server')} ${showServer ? '▲' : '▼'}'),
              ),
              if (showServer) ...[
                TextField(
                  controller: supaUrl,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Project URL', border: OutlineInputBorder(), isDense: true),
                  onChanged: (v) => store.setSetting('supaUrl', v.trim()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: supaKey,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'anon / publishable key', border: OutlineInputBorder(), isDense: true),
                  onChanged: (v) => store.setSetting('supaKey', v.trim()),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton.tonal(
                    onPressed: () async {
                      final e = await syncer.test();
                      if (!mounted) return;
                      setState(() => syncTest = e == null ? t('key_ok') : '❌ $e');
                      if (e == null) syncer.syncNow();
                    },
                    child: Text(t('check')),
                  ),
                  const SizedBox(width: 10),
                  if (syncTest != null) Expanded(child: Text(syncTest!)),
                ]),
              ],
            ]),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t('language'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ru', label: Text('Русский')),
              ButtonSegment(value: 'ko', label: Text('한국어')),
            ],
            selected: {lang},
            onSelectionChanged: (v) async {
              await store.setSetting('lang', v.first);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 20),
          _syncBlock(),
          const SizedBox(height: 24),
          Text(t('db_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Text(t('db_text'), style: const TextStyle(color: Colors.black54, height: 1.4)),
          const SizedBox(height: 10),
          _keyBlock(
            title: t('mfds_key'),
            help: t('mfds_help'),
            ctrl: mfds,
            busy: busyM,
            status: mfdsStatus,
            onCheck: _checkMfds,
            settingKey: 'mfdsKey',
          ),
          const SizedBox(height: 10),
          _keyBlock(
            title: t('kakao_key'),
            help: t('kakao_help'),
            ctrl: kakao,
            busy: busyK,
            status: kakaoStatus,
            onCheck: _checkKakao,
            settingKey: 'kakaoKey',
          ),
          const SizedBox(height: 20),
          Text(t('about_data'), style: const TextStyle(color: Colors.black45)),
        ],
      ),
    );
  }
}

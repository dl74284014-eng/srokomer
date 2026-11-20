import 'package:flutter/material.dart';

import 'l10n.dart';
import 'lookup.dart';
import 'store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController mfds =
      TextEditingController(text: store.mfdsKey);
  late final TextEditingController kakao =
      TextEditingController(text: store.settings['kakaoKey'] ?? '');
  String? mfdsStatus, kakaoStatus;
  bool busyM = false, busyK = false;

  @override
  void dispose() {
    mfds.dispose();
    kakao.dispose();
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

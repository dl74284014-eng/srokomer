import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'gemini.dart';
import 'lookup.dart';
import 'models.dart';
import 'notify.dart';
import 'auth.dart';
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
  late final TextEditingController gem = TextEditingController(text: store.geminiKey);
  String? gemStatus;
  bool busyG = false;
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
    gem.dispose();
    supaKey.dispose();
    joinCode.dispose();
    email.dispose();
    pass.dispose();
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

  Future<void> _checkGemini() async {
    final k = gem.text.trim();
    await store.setSetting('geminiKey', k);
    if (k.isEmpty) return;
    setState(() => busyG = true);
    final err = await testGeminiKey(k);
    if (!mounted) return;
    setState(() {
      busyG = false;
      gemStatus = err == null ? t('key_ok') : '❌ $err';
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

  final TextEditingController email = TextEditingController();
  final TextEditingController pass = TextEditingController();
  bool authBusy = false;
  String? authMsg;

  Future<void> _doAuth(bool register) async {
    final e = email.text.trim(), p = pass.text;
    if (!e.contains('@') || p.length < 6) {
      setState(() => authMsg = '❌ ${t('auth_bad_input')}');
      return;
    }
    setState(() {
      authBusy = true;
      authMsg = null;
    });
    final err = register ? await auth.signUp(e, p) : await auth.signIn(e, p);
    if (!mounted) return;
    setState(() {
      authBusy = false;
      authMsg = err == null ? null : (err == 'confirm' ? t('auth_confirm') : '❌ $err');
    });
    if (err == null) {
      pass.clear();
      syncer.afterLogin();
    }
  }

  Widget _syncBlock() {
    return ListenableBuilder(
      listenable: Listenable.merge([syncer, auth]),
      builder: (context, _) {
        final card = (List<Widget> children) => Card(
              elevation: 0,
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
              ),
            );
        final head = [
          Text('☁️ ${t('acc_title')}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 6),
          Text(t('acc_text'), style: const TextStyle(color: Colors.black54, height: 1.4)),
          const SizedBox(height: 12),
        ];
        final server = <Widget>[
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
          ],
        ];

        if (!auth.configured) {
          return card([...head, Text(t('sync_off'), style: const TextStyle(color: Color(0xFFE5740B))), ...server]);
        }

        if (!auth.loggedIn) {
          return card([
            ...head,
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(labelText: t('acc_email'), border: const OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pass,
              obscureText: true,
              decoration: InputDecoration(labelText: t('acc_pass'), border: const OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed: authBusy ? null : () => _doAuth(false),
                  child: Text(t('acc_login')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: authBusy ? null : () => _doAuth(true),
                  child: Text(t('acc_register')),
                ),
              ),
            ]),
            TextButton(
              onPressed: authBusy
                  ? null
                  : () async {
                      final e = email.text.trim();
                      if (!e.contains('@')) {
                        setState(() => authMsg = '❌ ${t('auth_bad_input')}');
                        return;
                      }
                      final err = await auth.resetPassword(e);
                      if (!mounted) return;
                      setState(() => authMsg = err == null ? t('acc_reset_sent') : '❌ $err');
                    },
              child: Text(t('acc_forgot')),
            ),
            if (authBusy) const LinearProgressIndicator(),
            if (authMsg != null) Text(authMsg!, style: TextStyle(color: authMsg!.startsWith('❌') ? const Color(0xFFD6363B) : const Color(0xFF2A8A57))),
            ...server,
          ]);
        }

        String st;
        Color col = Colors.black54;
        if (syncer.running) {
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
        return card([
          ...head,
          Row(children: [
            const CircleAvatar(child: Icon(Icons.person)),
            const SizedBox(width: 10),
            Expanded(child: Text(auth.email, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
          ]),
          const SizedBox(height: 10),
          Text(t('acc_other_phones'), style: const TextStyle(color: Colors.black54, fontSize: 13)),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton.tonalIcon(
              onPressed: syncer.running ? null : syncer.syncNow,
              icon: const Icon(Icons.sync),
              label: Text(t('sync_now')),
            ),
            const Spacer(),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(t('acc_logout_q')),
                    content: Text(t('acc_logout_sub')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('acc_logout'))),
                    ],
                  ),
                );
                if (ok == true) await auth.signOut();
              },
              child: Text(t('acc_logout')),
            ),
          ]),
          if (st.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(st, style: TextStyle(color: col, fontWeight: FontWeight.w600)),
            ),
          ...server,
        ]);
      },
    );
  }

  Future<void> _set(String k, String v) async {
    await store.setSetting(k, v);
    setState(() {});
    notifier.reschedule();
  }

  Widget _notifBlock() {
    final on = notifier.on;
    final days = notifier.days;
    const dayOptions = [0, 1, 2, 3, 5, 7, 14, 30];
    final h = notifier.hour.toString().padLeft(2, '0');
    final m = notifier.minute.toString().padLeft(2, '0');
    return Card(
      elevation: 0,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('🔔 ${t('notif_title')}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('notif_on')),
            value: on,
            onChanged: (v) async {
              if (v) await notifier.requestPermission();
              await _set('notifOn', v ? '1' : '0');
            },
          ),
          if (on) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('notif_time')),
              trailing: OutlinedButton(
                onPressed: () async {
                  final tm = await showTimePicker(
                      context: context, initialTime: TimeOfDay(hour: notifier.hour, minute: notifier.minute));
                  if (tm == null) return;
                  await store.setSetting('notifHour', '${tm.hour}');
                  await _set('notifMin', '${tm.minute}');
                },
                child: Text('$h:$m', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 6),
            Text(t('notif_days'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(t('notif_days_help'), style: const TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final d in dayOptions)
                FilterChip(
                  label: Text(d == 0 ? t('notif_day0') : tf('short_days', {'n': d})),
                  selected: days.contains(d),
                  onSelected: (sel) {
                    final n = {...days};
                    sel ? n.add(d) : n.remove(d);
                    _set('notifDays', (n.toList()..sort()).join(','));
                  },
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('notif_expired')),
              value: notifier.expiredReminder,
              onChanged: (v) => _set('notifExpired', v ? '1' : '0'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.tonalIcon(
                onPressed: () => notifier.showTest(),
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text(t('notif_test')),
              ),
            ]),
          ],
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
          const SizedBox(height: 20),
          Text(t('hand_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'left', label: Text(t('hand_left'))),
              ButtonSegment(value: 'center', label: Text(t('hand_center'))),
              ButtonSegment(value: 'right', label: Text(t('hand_right'))),
            ],
            selected: {hand},
            onSelectionChanged: (v) async {
              await store.setSetting('hand', v.first);
              store.notify();
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 20),
          _syncBlock(),
          const SizedBox(height: 12),
          _notifBlock(),
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
          const SizedBox(height: 10),
          _keyBlock(
            title: t('gemini_key'),
            help: t('gemini_help'),
            ctrl: gem,
            busy: busyG,
            status: gemStatus,
            onCheck: _checkGemini,
            settingKey: 'geminiKey',
          ),
          const SizedBox(height: 20),
          Text(t('about_data'), style: const TextStyle(color: Colors.black45)),
        ],
      ),
    );
  }
}

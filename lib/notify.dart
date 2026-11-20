import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'l10n.dart';
import 'models.dart';
import 'store.dart';

/// Напоминания о сроках годности.
/// Каждый день, когда есть что сообщить, приходит одно уведомление со списком товаров.
class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Timer? _debounce;

  // ---------- настройки ----------
  bool get on => (store.settings['notifOn'] ?? '1') == '1';
  int get hour => int.tryParse(store.settings['notifHour'] ?? '') ?? 9;
  int get minute => int.tryParse(store.settings['notifMin'] ?? '') ?? 0;
  Set<int> get days => (store.settings['notifDays'] ?? '1,3')
      .split(',')
      .map((e) => int.tryParse(e.trim()))
      .whereType<int>()
      .toSet();
  bool get expiredReminder => (store.settings['notifExpired'] ?? '1') == '1';

  /// Пусто — все категории.
  Set<String> get cats =>
      (store.settings['notifCats'] ?? '').split(',').where((e) => e.isNotEmpty).toSet();

  Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      );
      _ready = true;
      store.addListener(_onStoreChange);
      await reschedule();
    } catch (e) {
      debugPrint('notify init $e');
    }
  }

  Future<bool> requestPermission() async {
    final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await a?.requestNotificationsPermission() ?? true;
  }

  void _onStoreChange() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), reschedule);
  }

  NotificationDetails _details(String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          'expiry',
          isKo ? '유통기한 알림' : 'Сроки годности',
          channelDescription: isKo ? '유통기한 임박 알림' : 'Напоминания об окончании срока годности',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  String _when(int d) {
    if (isKo) {
      if (d < 0) return '${-d}일 지남';
      if (d == 0) return '오늘까지';
      if (d == 1) return '내일까지';
      return '$d일 남음';
    }
    if (d < 0) return 'просрочено';
    if (d == 0) return 'сегодня последний день';
    if (d == 1) return 'до завтра';
    return 'через $d ${daysWord(d)}';
  }

  bool _wanted(Item it) {
    if (it.mute || it.expiry.isEmpty) return false;
    final c = cats;
    return c.isEmpty || c.contains(catOf(it.category).k);
  }

  Future<void> reschedule() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
      if (!on) return;
      final now = DateTime.now();
      final todayD = DateTime(now.year, now.month, now.day);
      // день → список строк «товар — когда»
      final perDay = <DateTime, List<(int, String)>>{};
      final ds = days;
      for (final it in store.items.where(_wanted)) {
        final exp = parseIso(it.expiry);
        if (exp == null) continue;
        for (final d in ds) {
          final day = DateTime(exp.year, exp.month, exp.day - d);
          if (day.isBefore(todayD)) continue;
          (perDay[day] ??= []).add((d, it.name));
        }
      }
      // просроченные — в ближайшее уведомление
      if (expiredReminder) {
        final first = DateTime(now.year, now.month, now.day, hour, minute).isAfter(now)
            ? todayD
            : todayD.add(const Duration(days: 1));
        for (final it in store.items.where(_wanted)) {
          final dl = daysLeft(it.expiry);
          if (dl != null && dl < 0) (perDay[first] ??= []).add((dl, it.name));
        }
      }
      final keys = perDay.keys.toList()..sort();
      var id = 1;
      for (final day in keys.take(60)) {
        final at = DateTime(day.year, day.month, day.day, hour, minute);
        if (!at.isAfter(now)) continue;
        final list = perDay[day]!..sort((a, b) => a.$1.compareTo(b.$1));
        final title = isKo
            ? '⏰ 유통기한 임박: ${list.length}개'
            : '⏰ Срок годности: ${list.length} ${plural(list.length, 'товар', 'товара', 'товаров')}';
        // e.$1 — сколько дней останется до окончания в день уведомления
        final body = list.take(12).map((e) => '• ${e.$2} — ${_when(e.$1)}').join('\n') +
            (list.length > 12 ? '\n… +${list.length - 12}' : '');
        await _plugin.zonedSchedule(
          id++,
          title,
          body,
          tz.TZDateTime.from(at, tz.UTC),
          _details(body),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    } catch (e) {
      debugPrint('reschedule $e');
    }
  }

  Future<void> showTest() async {
    await requestPermission();
    final soon = store.items.where(_wanted).where((i) {
      final d = daysLeft(i.expiry);
      return d != null && d <= (days.isEmpty ? 3 : days.reduce((a, b) => a > b ? a : b));
    }).toList()
      ..sort((a, b) => (daysLeft(a.expiry) ?? 0).compareTo(daysLeft(b.expiry) ?? 0));
    final body = soon.isEmpty
        ? (isKo ? '알림이 이렇게 표시됩니다 ✓' : 'Так будут выглядеть уведомления ✓')
        : soon.take(12).map((i) => '• ${i.name} — ${_when(daysLeft(i.expiry)!)}').join('\n');
    await _plugin.show(0, isKo ? '⏰ 유통기한 알림 (테스트)' : '⏰ Срок годности (проверка)', body, _details(body));
  }
}

final notifier = Notifier();

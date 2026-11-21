import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'store.dart';

/// Аккаунт (почта + пароль) в Supabase. Токены хранятся в настройках телефона.
class AuthService extends ChangeNotifier {
  String get uid => store.settings['authUid'] ?? '';
  String get email => store.settings['authEmail'] ?? '';
  bool get loggedIn => uid.isNotEmpty && (store.settings['authRefresh'] ?? '').isNotEmpty;
  bool get configured => store.supaUrl.isNotEmpty && store.supaKey.isNotEmpty;

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse(store.supaUrl).replace(path: path, queryParameters: q);

  Map<String, String> get _h => {'apikey': store.supaKey, 'Content-Type': 'application/json'};

  Future<void> _saveSession(Map j) async {
    final user = (j['user'] as Map?) ?? {};
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + ((j['expires_in'] as num?)?.toInt() ?? 3600);
    store.settings['authAccess'] = (j['access_token'] ?? '').toString();
    store.settings['authRefresh'] = (j['refresh_token'] ?? '').toString();
    store.settings['authExp'] = '$exp';
    if (user['id'] != null) store.settings['authUid'] = user['id'].toString();
    if (user['email'] != null) store.settings['authEmail'] = user['email'].toString();
    await store.save();
    notifyListeners();
  }

  String _err(http.Response r) {
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        return (j['msg'] ?? j['error_description'] ?? j['message'] ?? j['error'] ?? r.statusCode).toString();
      }
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }

  /// null — успех, иначе текст ошибки. 'confirm' — нужно подтвердить почту.
  Future<String?> signUp(String email, String password) async {
    try {
      final r = await http
          .post(_u('/auth/v1/signup'), headers: _h, body: jsonEncode({'email': email, 'password': password}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 300) return _err(r);
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      if (j['access_token'] == null) {
        // подтверждение почты включено — пробуем войти (если уже подтверждено)
        final e = await signIn(email, password);
        return e == null ? null : 'confirm';
      }
      await _saveSession(j);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> signIn(String email, String password) async {
    try {
      final r = await http
          .post(_u('/auth/v1/token', {'grant_type': 'password'}),
              headers: _h, body: jsonEncode({'email': email, 'password': password}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 300) return _err(r);
      await _saveSession(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> resetPassword(String email) async {
    try {
      final r = await http
          .post(_u('/auth/v1/recover'), headers: _h, body: jsonEncode({'email': email}))
          .timeout(const Duration(seconds: 20));
      return r.statusCode < 300 ? null : _err(r);
    } catch (e) {
      return '$e';
    }
  }

  Future<void> signOut() async {
    for (final k in ['authAccess', 'authRefresh', 'authExp', 'authUid', 'authEmail']) {
      store.settings.remove(k);
    }
    store.settings['syncSinceItems'] = '';
    store.settings['syncSinceProducts'] = '';
    await store.save();
    notifyListeners();
  }

  /// Действующий токен доступа (обновляется сам, когда истекает).
  Future<String?> accessToken() async {
    if (!loggedIn) return null;
    final exp = int.tryParse(store.settings['authExp'] ?? '') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (exp - now > 120 && (store.settings['authAccess'] ?? '').isNotEmpty) {
      return store.settings['authAccess'];
    }
    try {
      final r = await http
          .post(_u('/auth/v1/token', {'grant_type': 'refresh_token'}),
              headers: _h, body: jsonEncode({'refresh_token': store.settings['authRefresh']}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 300) {
        if (r.statusCode == 400 || r.statusCode == 401) await signOut(); // сессия больше недействительна
        return null;
      }
      await _saveSession(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
      return store.settings['authAccess'];
    } catch (e) {
      debugPrint('refresh $e');
      return null;
    }
  }
}

final auth = AuthService();

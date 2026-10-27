import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// An anonymous Supabase user: no sign-up screen, but a real user id and a real token (so every row is the user's own).
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
    'a': accessToken,
    'r': refreshToken,
    'u': userId,
    'e': expiresAt.millisecondsSinceEpoch,
  };

  factory AuthSession.fromJson(Map<String, Object?> j) => AuthSession(
    accessToken: j['a'] as String,
    refreshToken: j['r'] as String,
    userId: j['u'] as String,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
  );
}

abstract class AuthStore {
  Future<AuthSession?> load();
  Future<void> save(AuthSession session);
}

class MemoryAuthStore implements AuthStore {
  AuthSession? value;

  @override
  Future<AuthSession?> load() async => value;

  @override
  Future<void> save(AuthSession session) async => value = session;
}

class PrefsAuthStore implements AuthStore {
  static const _key = 'life.auth';

  @override
  Future<AuthSession?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      return AuthSession.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(AuthSession session) async =>
      (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(session.toJson()),
      );
}

class AnonymousAuth {
  AnonymousAuth({
    required this.baseUrl,
    required this.apiKey,
    required this.client,
    required this.store,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 20),
  }) : _now = now ?? DateTime.now;

  final String baseUrl;
  final String apiKey;
  final http.Client client;
  final AuthStore store;
  final Duration timeout;
  final DateTime Function() _now;

  AuthSession? _session;
  Future<AuthSession>? _inflight;

  /// A token that is good for at least a minute. Calls made at the same time share one refresh.
  Future<AuthSession> ensure({bool forceRefresh = false}) {
    if (!forceRefresh && _inflight != null) return _inflight!;
    final f = _ensure(forceRefresh);
    _inflight = f;
    return f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    });
  }

  Future<AuthSession> _ensure(bool forceRefresh) async {
    _session ??= await store.load();
    final s = _session;
    if (s != null &&
        !forceRefresh &&
        s.expiresAt.isAfter(_now().add(const Duration(seconds: 60))))
      return s;
    if (s != null) {
      final refreshed = await _request(
        '/auth/v1/token?grant_type=refresh_token',
        {'refresh_token': s.refreshToken},
        allowFailure: true,
      );
      if (refreshed != null) return _keep(refreshed);
    }
    final created = await _request('/auth/v1/signup', const {});
    return _keep(created!);
  }

  Future<AuthSession> _keep(AuthSession s) async {
    _session = s;
    await store.save(s);
    return s;
  }

  Future<AuthSession?> _request(
    String path,
    Map<String, Object?> body, {
    bool allowFailure = false,
  }) async {
    http.Response res;
    try {
      res = await client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {'apikey': apiKey, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw AgentException('timeout');
    } catch (_) {
      throw AgentException('network');
    }
    Map<String, Object?>? json;
    try {
      json = Map<String, Object?>.from(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map,
      );
    } catch (_) {
      json = null;
    }
    final token = json?['access_token'];
    if (res.statusCode == 200 &&
        token is String &&
        json?['refresh_token'] is String &&
        json?['user'] is Map) {
      final expiresIn = (json?['expires_in'] as num?)?.toInt() ?? 3600;
      return AuthSession(
        accessToken: token,
        refreshToken: json!['refresh_token'] as String,
        userId: (json['user'] as Map)['id'] as String,
        expiresAt: _now().add(Duration(seconds: expiresIn)),
      );
    }
    if (allowFailure && res.statusCode >= 400 && res.statusCode < 500)
      return null; // the refresh token is no longer valid: start fresh
    throw AgentException(
      json?['error_code'] is String
          ? json!['error_code'] as String
          : 'auth_failed',
      status: res.statusCode,
    );
  }
}

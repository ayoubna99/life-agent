import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'models.dart';

/// The phone's side of docs/API.md. Every call carries the anonymous user's token; a 401 refreshes it once and retries.
class AgentApi {
  AgentApi({
    required this.baseUrl,
    required this.apiKey,
    required this.client,
    required this.auth,
    this.timeout = const Duration(seconds: 120),
  });

  final String baseUrl;
  final String apiKey;
  final http.Client client;
  final AnonymousAuth auth;
  final Duration timeout;

  Future<String> get userId async => (await auth.ensure()).userId;

  Future<ChatAnswer> chat({
    required String mode,
    required String today,
    required String date,
    String? conversationId,
    String locale = 'en',
    Map<String, Object?>? input,
    Map<String, List<String>>? report,
  }) async {
    final json = await _agent({
      'action': 'chat',
      'mode': mode,
      'today': today,
      'date': date,
      'locale': locale,
      'conversation_id': ?conversationId,
      'report': ?report,
      'input': input,
    });
    return ChatAnswer.fromJson(json);
  }

  Future<void> uploadUsage(List<UsageRow> rows) async {
    // The server takes at most 200 rows per request.
    for (var i = 0; i < rows.length; i += 200) {
      await _agent({
        'action': 'usage',
        'days': [for (final r in rows.skip(i).take(200)) r.toJson()],
      });
    }
  }

  /// The evening reminder's words, or null when tomorrow is already planned. [test] writes it anyway.
  Future<String?> evening({
    required String today,
    required String tomorrow,
    required String now,
    List<String> done = const [],
    List<String> missed = const [],
    bool test = false,
  }) async {
    final json = await _agent({
      'action': 'evening',
      'today': today,
      'tomorrow': tomorrow,
      'now': now,
      'done': done,
      'missed': missed,
      if (test) 'test': true,
    });
    return json['planned'] == true ? null : json['text'] as String?;
  }

  /// Lify's voice: [text] spoken by Orpheus on Baseten, as a WAV file. Null when the server has no voice set up
  /// (the phone's own voice is used then).
  Future<Uint8List?> speak(String text) async {
    try {
      final json = await _agent({'action': 'speak', 'text': text});
      final audio = json['audio'];
      return audio is String ? base64Decode(audio) : null;
    } on AgentException catch (e) {
      if (e.code == 'tts_not_configured') return null;
      rethrow;
    }
  }

  /// When the phone went quiet on the last nights (phone use, not sleep).
  Future<void> uploadNights(List<PhoneNight> nights) async {
    if (nights.isEmpty) return;
    await _agent({
      'action': 'usage',
      'nights': [for (final n in nights.take(14)) n.toJson()],
    });
  }

  Future<SavedPlan?> plan(String date) async {
    final json = await _agent({'action': 'plan', 'date': date});
    final plan = json['plan'];
    return plan == null
        ? null
        : SavedPlan.fromJson(Map<String, Object?>.from(plan as Map));
  }

  /// The newest strategy and the versions before it (newest first).
  Future<({Strategy? current, List<Strategy> history})> strategy() async {
    final json = await _agent({'action': 'strategy'});
    final history = [
      for (final s in (json['history'] as List? ?? const []))
        Strategy.fromJson(Map<String, Object?>.from(s as Map)),
    ];
    return (current: history.isEmpty ? null : history.first, history: history);
  }

  /// The experiment totals over the last [days] days.
  Future<ExperimentResults> experiments({
    required String today,
    int days = 14,
  }) async {
    final json = await _agent({
      'action': 'experiments',
      'today': today,
      'days': days,
    });
    return ExperimentResults.fromJson(
      Map<String, Object?>.from(json['results'] as Map),
    );
  }

  Future<Profile> profile({Profile? set}) async {
    final json = await _agent({
      'action': 'profile',
      if (set != null) 'set': set.toJson(),
    });
    return Profile.fromJson(Map<String, Object?>.from(json['profile'] as Map));
  }

  Future<NudgeAnswer> nudge({
    required String today,
    required String now,
    required String app,
    required int usedMinutes,
    required int limitMinutes,
    required String reason,
    String locale = 'en',
    List<String> done = const [],
    String style = 'task',
  }) async {
    final json = await _agent({
      'action': 'nudge',
      'today': today,
      'now': now,
      'app': app,
      'used_minutes': usedMinutes,
      'limit_minutes': limitMinutes,
      'reason': reason,
      'locale': locale,
      'done': done,
      'style': style,
    });
    return NudgeAnswer(
      text: json['text'] as String,
      task: json['task'] as String?,
    );
  }

  /// Uploads a PDF, a photo or a text file and asks the server to read it. Returns the document id for the next chat message.
  Future<AttachResult> attach({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    final path = await _upload(bytes, fileName, contentType);
    final json = await _agent({
      'action': 'attach',
      'path': path,
      'name': fileName,
    });
    return AttachResult.fromJson(json);
  }

  /// Uploads a WAV recording (mono, 16-bit, 16 or 24 kHz) and returns what was said.
  Future<String> transcribe({
    required Uint8List wav,
    List<String> languages = const [],
    List<String> keywords = const [],
  }) async {
    final path = await _upload(wav, 'voice.wav', 'audio/wav');
    final json = await _agent({
      'action': 'transcribe',
      'path': path,
      if (languages.isNotEmpty) 'languages': languages,
      if (keywords.isNotEmpty) 'keywords': keywords,
    });
    return json['text'] as String;
  }

  static String safeName(String name) {
    final clean = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return clean.length > 80 ? clean.substring(clean.length - 80) : clean;
  }

  Future<String> _upload(
    Uint8List bytes,
    String fileName,
    String contentType,
  ) async {
    final path =
        '${await userId}/${DateTime.now().millisecondsSinceEpoch}-${safeName(fileName)}';
    final res = await _send(
      (s) => client.post(
        Uri.parse('$baseUrl/storage/v1/object/uploads/$path'),
        headers: {
          'apikey': apiKey,
          'Authorization': 'Bearer ${s.accessToken}',
          'Content-Type': contentType,
          'x-upsert': 'true',
        },
        body: bytes,
      ),
    );
    if (res.statusCode >= 300)
      throw AgentException('upload_failed', status: res.statusCode);
    return path;
  }

  Future<Map<String, Object?>> _agent(Map<String, Object?> body) async {
    final res = await _send(
      (s) => client.post(
        Uri.parse('$baseUrl/functions/v1/agent'),
        headers: {
          'apikey': apiKey,
          'Authorization': 'Bearer ${s.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ),
    );
    Map<String, Object?> json;
    try {
      json = Map<String, Object?>.from(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map,
      );
    } catch (_) {
      throw AgentException('bad_response', status: res.statusCode);
    }
    if (res.statusCode == 200) return json;
    final error = json['error'];
    final code = error is Map && error['code'] is String
        ? error['code'] as String
        : 'http_${res.statusCode}';
    throw AgentException(code, status: res.statusCode);
  }

  /// Sends with the current token; one 401 means "refresh and try again".
  Future<http.Response> _send(
    Future<http.Response> Function(AuthSession) request,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final session = await auth.ensure(forceRefresh: attempt == 1);
      http.Response res;
      try {
        res = await request(session).timeout(timeout);
      } on TimeoutException {
        throw AgentException('timeout');
      } on AgentException {
        rethrow;
      } catch (_) {
        throw AgentException('network');
      }
      if (res.statusCode == 401 && attempt == 0) continue;
      return res;
    }
    throw AgentException('auth_failed', status: 401);
  }
}

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_agent/agent/agent_api.dart';
import 'package:life_agent/agent/auth.dart';

const base = 'https://proj.supabase.co';
const key = 'sb_publishable_test';
const userId = '00000000-0000-0000-0000-00000000000a';

class Req {
  Req(this.method, this.url, this.headers, this.bodyBytes);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  String get path => url.path + (url.hasQuery ? '?${url.query}' : '');
  Map<String, Object?> get json =>
      Map<String, Object?>.from(jsonDecode(utf8.decode(bodyBytes)) as Map);
  String? get action =>
      headers['content-type']?.contains('json') == true &&
          url.path.endsWith('/agent')
      ? json['action'] as String?
      : null;
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> tokenBody({
  String access = 'access-1',
  String refresh = 'refresh-1',
  String id = userId,
  int expiresIn = 3600,
}) => {
  'access_token': access,
  'refresh_token': refresh,
  'expires_in': expiresIn,
  'user': {'id': id},
};

/// A fake Supabase: every request is recorded, `handler` answers (default: sign-in works, everything else is a 500).
class FakeServer {
  FakeServer(this.handler);

  final http.Response Function(Req) handler;
  final List<Req> requests = [];

  late final MockClient client = MockClient((r) async {
    final req = Req(r.method, r.url, r.headers, r.bodyBytes);
    requests.add(req);
    return handler(req);
  });

  List<Req> get agentCalls => [
    for (final r in requests)
      if (r.url.path.endsWith('/functions/v1/agent')) r,
  ];
}

AnonymousAuth newAuth(
  http.Client client, {
  DateTime Function()? now,
  MemoryAuthStore? store,
}) => AnonymousAuth(
  baseUrl: base,
  apiKey: key,
  client: client,
  store: store ?? MemoryAuthStore(),
  now: now,
);

AgentApi newApi(FakeServer server, {Duration? timeout}) => AgentApi(
  baseUrl: base,
  apiKey: key,
  client: server.client,
  auth: newAuth(server.client),
  timeout: timeout ?? const Duration(seconds: 5),
);

http.Response ok(Req r, {Map<String, Object?> Function(Req)? agent}) {
  if (r.url.path == '/auth/v1/signup') return jsonResponse(tokenBody());
  if (r.url.path.startsWith('/storage/v1/'))
    return jsonResponse({'Key': 'uploads/x'});
  return jsonResponse(agent!(r));
}

Map<String, Object?> text(
  String t, {
  String id = 'c0000000-0000-0000-0000-000000000001',
  bool planSaved = false,
  List<Map<String, Object?>> artifacts = const [],
}) => {
  'type': 'text',
  'conversation_id': id,
  'text': t,
  'plan_saved': planSaved,
  'artifacts': artifacts,
};

Map<String, Object?> calls(
  List<(String, Map<String, Object?>)> list, {
  String id = 'c0000000-0000-0000-0000-000000000001',
}) => {
  'type': 'tool_calls',
  'conversation_id': id,
  'calls': [
    for (var i = 0; i < list.length; i++)
      {'id': 'call_${i + 1}', 'name': list[i].$1, 'args': list[i].$2},
  ],
  'plan_saved': false,
  'artifacts': <Object?>[],
};

/// An API whose server is any async function (to make it slow, for example).
AgentApi newApiWith(
  Future<http.Response> Function(http.BaseRequest) handler,
  Duration timeout,
) {
  final client = MockClient((r) => handler(r));
  return AgentApi(
    baseUrl: base,
    apiKey: key,
    client: client,
    auth: newAuth(client),
    timeout: timeout,
  );
}

String safe(String name) => AgentApi.safeName(name);

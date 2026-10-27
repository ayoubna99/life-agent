import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:life_agent/agent/auth.dart';
import 'package:life_agent/agent/models.dart';

import 'helpers.dart';

void main() {
  test('the first call signs in anonymously with the publishable key, and the token is reused', () async {
    final server = FakeServer((r) => jsonResponse(tokenBody()));
    final auth = newAuth(server.client);
    final a = await auth.ensure();
    final b = await auth.ensure();
    expect(a.accessToken, 'access-1');
    expect(a.userId, userId);
    expect(b.accessToken, 'access-1');
    expect(server.requests, hasLength(1));
    expect(server.requests.single.path, '/auth/v1/signup');
    expect(server.requests.single.headers['apikey'], key);
    expect(server.requests.single.json, isEmpty);
  });

  test(
    'a stored session survives an app restart without any network call',
    () async {
      final store = MemoryAuthStore();
      final first = FakeServer((r) => jsonResponse(tokenBody()));
      await newAuth(first.client, store: store).ensure();
      final second = FakeServer((r) => throw StateError('no network expected'));
      final s = await newAuth(second.client, store: store).ensure();
      expect(s.userId, userId);
      expect(second.requests, isEmpty);
    },
  );

  test('a token about to expire is refreshed with the refresh token and the same user stays', () async {
    var clock = DateTime(2026, 10, 27, 9);
    final server = FakeServer(
      (r) => r.path.contains('refresh_token')
          ? jsonResponse(tokenBody(access: 'access-2', refresh: 'refresh-2'))
          : jsonResponse(tokenBody(expiresIn: 3600)),
    );
    final auth = newAuth(server.client, now: () => clock);
    await auth.ensure();
    clock = clock.add(
      const Duration(minutes: 59, seconds: 30),
    ); // less than a minute left
    final s = await auth.ensure();
    expect(s.accessToken, 'access-2');
    expect(
      server.requests.last.path,
      '/auth/v1/token?grant_type=refresh_token',
    );
    expect(server.requests.last.json, {'refresh_token': 'refresh-1'});
  });

  test(
    'if the refresh token is no longer valid a new anonymous user is created',
    () async {
      var clock = DateTime(2026, 10, 27, 9);
      var signups = 0;
      final server = FakeServer((r) {
        if (r.path.contains('refresh_token'))
          return jsonResponse({'error_code': 'refresh_token_not_found'}, 400);
        signups++;
        return jsonResponse(
          tokenBody(id: 'user-$signups', access: 'access-$signups'),
        );
      });
      final auth = newAuth(server.client, now: () => clock);
      await auth.ensure();
      clock = clock.add(const Duration(days: 2));
      final s = await auth.ensure();
      expect(s.userId, 'user-2');
      expect(signups, 2);
    },
  );

  test('calls made at the same time share one sign-in', () async {
    final server = FakeServer((r) => jsonResponse(tokenBody()));
    final auth = newAuth(server.client);
    final all = await Future.wait([
      auth.ensure(),
      auth.ensure(),
      auth.ensure(),
    ]);
    expect(all.map((s) => s.accessToken).toSet(), {'access-1'});
    expect(server.requests, hasLength(1));
  });

  test('sign-in problems come back as codes the screen can explain', () async {
    final off = FakeServer(
      (r) => jsonResponse({
        'error_code': 'anonymous_provider_disabled',
        'msg': 'x',
      }, 422),
    );
    await expectLater(
      newAuth(off.client).ensure(),
      throwsA(
        isA<AgentException>().having(
          (e) => e.code,
          'code',
          'anonymous_provider_disabled',
        ),
      ),
    );

    final html = FakeServer((r) => http.Response('<html>oops</html>', 502));
    await expectLater(
      newAuth(html.client).ensure(),
      throwsA(
        isA<AgentException>().having((e) => e.code, 'code', 'auth_failed'),
      ),
    );

    final down = FakeServer((r) => throw http.ClientException('no route'));
    await expectLater(
      newAuth(down.client).ensure(),
      throwsA(isA<AgentException>().having((e) => e.offline, 'offline', true)),
    );
  });
}

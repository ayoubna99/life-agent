import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:life_agent/agent/models.dart';

import 'helpers.dart';

void main() {
  test(
    'a chat message carries the token, the key and exactly the documented body',
    () async {
      final server = FakeServer(
        (r) => ok(r, agent: (_) => text('What do you want to do tomorrow?')),
      );
      final api = newApi(server);
      final a = await api.chat(
        mode: 'planning',
        today: '2026-10-27',
        date: '2026-10-28',
        input: {'type': 'user', 'text': 'Plan my day'},
      );
      expect(a.text, 'What do you want to do tomorrow?');
      expect(a.wantsTools, isFalse);
      final call = server.agentCalls.single;
      expect(call.headers['authorization'], 'Bearer access-1');
      expect(call.headers['apikey'], key);
      expect(call.json, {
        'action': 'chat',
        'mode': 'planning',
        'today': '2026-10-27',
        'date': '2026-10-28',
        'locale': 'en',
        'input': {'type': 'user', 'text': 'Plan my day'},
      });
    },
  );

  test('tool calls and artifacts are read from the answer', () {
    final a = ChatAnswer.fromJson(
      calls([
        ('set_app_limit', {'app': 'Instagram', 'minutes_per_day': 30}),
      ]),
    );
    expect(a.wantsTools, isTrue);
    expect(a.calls.single.name, 'set_app_limit');
    expect(a.calls.single.args['minutes_per_day'], 30);
    final t = ChatAnswer.fromJson(
      text(
        'Done',
        planSaved: true,
        artifacts: [
          {'type': 'pdf', 'title': 'German sheet', 'url': 'https://x/a.pdf'},
        ],
      ),
    );
    expect(t.planSaved, isTrue);
    expect(t.artifacts.single.type, 'pdf');
    expect(
      () => ChatAnswer.fromJson({'type': 'weird'}),
      throwsA(isA<AgentException>()),
    );
  });

  test(
    'one 401 refreshes the token and the same request is sent again',
    () async {
      var agentCalls = 0;
      final server = FakeServer((r) {
        if (r.path == '/auth/v1/signup') return jsonResponse(tokenBody());
        if (r.path.contains('refresh_token'))
          return jsonResponse(
            tokenBody(access: 'access-2', refresh: 'refresh-2'),
          );
        return ++agentCalls == 1
            ? jsonResponse({'code': 401}, 401)
            : jsonResponse(text('hi'));
      });
      final a = await newApi(server).chat(
        mode: 'planning',
        today: '2026-10-27',
        date: '2026-10-28',
        input: {'type': 'user', 'text': 'hi'},
      );
      expect(a.text, 'hi');
      expect(server.agentCalls.map((c) => c.headers['authorization']), [
        'Bearer access-1',
        'Bearer access-2',
      ]);
    },
  );

  test('a second 401 is reported, not retried forever', () async {
    final server = FakeServer(
      (r) => r.path.startsWith('/auth/')
          ? jsonResponse(tokenBody())
          : jsonResponse({
              'error': {'code': 'not_signed_in'},
            }, 401),
    );
    await expectLater(
      newApi(server).chat(
        mode: 'planning',
        today: '2026-10-27',
        date: '2026-10-28',
        input: {'type': 'user', 'text': 'hi'},
      ),
      throwsA(
        isA<AgentException>().having((e) => e.code, 'code', 'not_signed_in'),
      ),
    );
    expect(server.agentCalls, hasLength(2));
  });

  test(
    'every server problem becomes a code and a flag the screen can use',
    () async {
      Future<AgentException> failure(http.Response Function() answer) async {
        final server = FakeServer(
          (r) => r.path == '/auth/v1/signup'
              ? jsonResponse(tokenBody())
              : answer(),
        );
        try {
          await newApi(server).plan('2026-10-28');
        } on AgentException catch (e) {
          return e;
        }
        throw TestFailure('the call should have failed');
      }

      expect(
        (await failure(
          () => jsonResponse({
            'error': {'code': 'daily_limit_reached'},
          }, 429),
        )).dailyLimit,
        isTrue,
      );
      expect(
        (await failure(
          () => jsonResponse({
            'error': {'code': 'demo_at_capacity'},
          }, 429),
        )).capacity,
        isTrue,
      );
      expect(
        (await failure(
          () => jsonResponse({
            'error': {'code': 'agent_timeout'},
          }, 504),
        )).timedOut,
        isTrue,
      );
      expect(
        (await failure(
          () => jsonResponse({
            'error': {'code': 'store_error'},
          }, 502),
        )).code,
        'store_error',
      );
      expect(
        (await failure(() => jsonResponse({'weird': true}, 500))).code,
        'http_500',
      );
      expect(
        (await failure(() => http.Response('<html>gateway</html>', 502))).code,
        'bad_response',
      );
      expect(
        (await failure(() => throw http.ClientException('offline'))).offline,
        isTrue,
      );
    },
  );

  test('a slow answer times out instead of hanging the screen', () async {
    final api = newApiWith(
      (r) async => r.url.path.startsWith('/auth/')
          ? jsonResponse(tokenBody())
          : Completer<http.Response>().future,
      const Duration(milliseconds: 50),
    );
    await expectLater(
      api.plan('2026-10-28'),
      throwsA(
        isA<AgentException>().having((e) => e.timedOut, 'timedOut', true),
      ),
    );
  });

  test('usage goes up in batches of 200, and plan/profile/nudge use the documented fields', () async {
    final server = FakeServer(
      (r) => ok(
        r,
        agent: (req) {
          switch (req.action) {
            case 'usage':
              return {'saved': 1};
            case 'plan':
              return {
                'plan': {
                  'date': '2026-10-28',
                  'status': 'ready',
                  'data': {
                    'wake': '07:00',
                    'tasks': [
                      {
                        'title': 'Study German',
                        'minutes': 40,
                        'start_time': '19:00',
                        'links': ['https://x/a.pdf'],
                      },
                    ],
                    'limits': [
                      {'app': 'TikTok', 'minutes_per_day': 30},
                    ],
                  },
                },
              };
            case 'profile':
              return {
                'profile': {
                  'wake': '07:00',
                  'sleep': '23:30',
                  'apps': ['TikTok'],
                },
              };
            case 'nudge':
              return {'text': 'Start your German now.', 'task': 'Study German'};
          }
          throw StateError('unexpected ${req.action}');
        },
      ),
    );
    final api = newApi(server);
    await api.uploadUsage([
      for (var i = 0; i < 450; i++)
        UsageRow(day: '2026-10-27', app: 'App$i', minutes: 5),
    ]);
    expect(
      [for (final c in server.agentCalls) (c.json['days'] as List).length],
      [200, 200, 50],
    );

    final plan = (await api.plan('2026-10-28'))!;
    expect(plan.tasks.single.title, 'Study German');
    expect(plan.tasks.single.startTime, '19:00');
    expect(plan.limits.single.minutesPerDay, 30);
    expect(plan.wake, '07:00');

    final profile = await api.profile(
      set: const Profile(wake: '07:00', sleep: '23:30', apps: ['TikTok']),
    );
    expect(profile.sleep, '23:30');
    expect(server.agentCalls.last.json, {
      'action': 'profile',
      'set': {
        'wake': '07:00',
        'sleep': '23:30',
        'apps': ['TikTok'],
      },
    });

    final n = await api.nudge(
      today: '2026-10-28',
      now: '17:40',
      app: 'TikTok',
      usedMinutes: 25,
      limitMinutes: 30,
      reason: 'approaching',
      done: ['Gym'],
    );
    expect(n.text, 'Start your German now.');
    expect(n.task, 'Study German');
    expect(server.agentCalls.last.json['used_minutes'], 25);
    expect(server.agentCalls.last.json['done'], ['Gym']);
  });

  test('a missing plan is null', () async {
    final server = FakeServer((r) => ok(r, agent: (_) => {'plan': null}));
    expect(await newApi(server).plan('2026-10-28'), isNull);
  });

  test('a file is uploaded to the user\'s own folder, then the server is asked to read it', () async {
    final server = FakeServer(
      (r) => ok(
        r,
        agent: (_) => {
          'document_id': 'd0000000-0000-0000-0000-000000000001',
          'name': 'My timetable.jpg',
          'kind': 'image',
          'read_by': 'vision',
          'pages': 1,
        },
      ),
    );
    final r = await newApi(server).attach(
      bytes: Uint8List.fromList([1, 2, 3]),
      fileName: 'My timetable.jpg',
      contentType: 'image/jpeg',
    );
    expect(r.kind, 'image');
    expect(r.readBy, 'vision');
    final upload = server.requests.firstWhere(
      (q) => q.path.startsWith('/storage/'),
    );
    expect(upload.method, 'POST');
    expect(
      upload.path,
      matches(
        RegExp('^/storage/v1/object/uploads/$userId/\\d+-My_timetable\\.jpg\$'),
      ),
    );
    expect(upload.headers['content-type'], 'image/jpeg');
    expect(upload.headers['authorization'], 'Bearer access-1');
    expect(upload.bodyBytes, [1, 2, 3]);
    final ask = server.agentCalls.single.json;
    expect(ask['action'], 'attach');
    expect(ask['name'], 'My timetable.jpg');
    expect((ask['path'] as String).startsWith('$userId/'), isTrue);
  });

  test('a failed upload says so and never asks the server to read a file that is not there', () async {
    final server = FakeServer(
      (r) => r.path.startsWith('/storage/')
          ? jsonResponse({'message': 'too big'}, 413)
          : ok(r, agent: (_) => {}),
    );
    await expectLater(
      newApi(server).attach(
        bytes: Uint8List(3),
        fileName: 'a.pdf',
        contentType: 'application/pdf',
      ),
      throwsA(
        isA<AgentException>().having((e) => e.code, 'code', 'upload_failed'),
      ),
    );
    expect(server.agentCalls, isEmpty);
  });

  test(
    'a recording is uploaded as WAV and the transcript comes back',
    () async {
      final server = FakeServer(
        (r) => ok(
          r,
          agent: (_) => {'text': 'Study German at six', 'duration_ms': 3000},
        ),
      );
      final text = await newApi(server).transcribe(
        wav: Uint8List(10),
        languages: ['English'],
        keywords: ['TikTok'],
      );
      expect(text, 'Study German at six');
      expect(
        server.requests
            .firstWhere((q) => q.path.startsWith('/storage/'))
            .headers['content-type'],
        'audio/wav',
      );
      final ask = server.agentCalls.single.json;
      expect(ask['languages'], ['English']);
      expect(ask['keywords'], ['TikTok']);
    },
  );

  test('file names are made safe for the storage path', () {
    expect(safe('Lecture #3 (final).pdf'), 'Lecture_3_final_.pdf');
    expect(safe('../../etc/passwd'), '.._.._etc_passwd');
    expect(safe('x' * 200).length, 80);
    expect(jsonEncode(safe('é à.pdf')), isNot(contains('é')));
  });
}

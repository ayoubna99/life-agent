import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/agent_session.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/device/device_tools.dart';

import 'helpers.dart';

class FakeTools implements DeviceTools {
  FakeTools([this.handler]);

  final Future<Map<String, Object?>> Function(String, Map<String, Object?>)?
  handler;
  final List<String> ran = [];

  @override
  Future<Map<String, Object?>> run(
    String name,
    Map<String, Object?> args,
  ) async {
    ran.add(name);
    return handler != null ? handler!(name, args) : {'ok': true};
  }
}

AgentSession sessionFor(
  FakeServer server,
  DeviceTools tools, {
  String mode = 'execute',
  void Function(ToolCall)? onToolStart,
}) => AgentSession(
  api: newApi(server),
  tools: tools,
  mode: mode,
  today: '2026-10-28',
  date: '2026-10-28',
  onToolStart: onToolStart,
);

void main() {
  test('a plain answer: one request, the text comes back, the conversation id is remembered for the next message', () async {
    var n = 0;
    final server = FakeServer(
      (r) => ok(
        r,
        agent: (_) => text(++n == 1 ? 'What do you want to do?' : 'And sleep?'),
      ),
    );
    final s = sessionFor(server, FakeTools(), mode: 'planning');
    final first = await s.send('Plan tomorrow');
    expect(first.text, 'What do you want to do?');
    expect(s.conversationId, 'c0000000-0000-0000-0000-000000000001');
    await s.send('Study and gym');
    expect(server.agentCalls[0].json.containsKey('conversation_id'), isFalse);
    expect(
      server.agentCalls[1].json['conversation_id'],
      'c0000000-0000-0000-0000-000000000001',
    );
    expect(server.agentCalls[1].json['input'], {
      'type': 'user',
      'text': 'Study and gym',
    });
  });

  test('attachments go with the message', () async {
    final server = FakeServer((r) => ok(r, agent: (_) => text('Read it.')));
    await sessionFor(
      server,
      FakeTools(),
      mode: 'planning',
    ).send('Use this', attachments: ['d1', 'd2']);
    expect((server.agentCalls.single.json['input'] as Map)['attachments'], [
      'd1',
      'd2',
    ]);
  });

  test('the morning run: the phone runs every tool the agent asks for and sends back all results, then the agent finishes', () async {
    final replies = [
      calls([
        ('create_task', {'title': 'Study German', 'minutes': 40}),
        ('set_app_limit', {'app': 'TikTok', 'minutes_per_day': 30}),
      ]),
      text('Your day is set up: 1 task, 1 limit.', planSaved: false),
    ];
    var i = 0;
    final server = FakeServer((r) => ok(r, agent: (_) => replies[i++]));
    final tools = FakeTools(
      (name, args) async => name == 'create_task'
          ? {'ok': true, 'task_id': 't1'}
          : {'ok': true, 'enforced': true},
    );
    final started = <String>[];
    final reply = await sessionFor(
      server,
      tools,
      onToolStart: (c) => started.add(c.name),
    ).send('Apply today');
    expect(reply.text, 'Your day is set up: 1 task, 1 limit.');
    expect(tools.ran, ['create_task', 'set_app_limit']);
    expect(started, ['create_task', 'set_app_limit']);
    expect(reply.toolsRun.map((t) => t.ok), [true, true]);
    final results = (server.agentCalls[1].json['input'] as Map);
    expect(results['type'], 'tool_results');
    final list = (results['results'] as List).cast<Map>();
    expect(list.map((r) => r['tool_call_id']), ['call_1', 'call_2']);
    expect(jsonDecode(list[0]['content'] as String), {
      'ok': true,
      'task_id': 't1',
    });
    expect(
      server.agentCalls[1].json['conversation_id'],
      'c0000000-0000-0000-0000-000000000001',
    );
  });

  test('a tool that crashes is reported to the agent as a failure, so it can tell the user', () async {
    final replies = [
      calls([
        ('schedule_alarm', {'time': '18:00', 'message': 'Study'}),
      ]),
      text('I could not set the reminder.'),
    ];
    var i = 0;
    final server = FakeServer((r) => ok(r, agent: (_) => replies[i++]));
    final tools = FakeTools(
      (n, a) async => throw StateError('boom: secret detail'),
    );
    final reply = await sessionFor(server, tools).send('Apply today');
    expect(reply.toolsRun.single.ok, isFalse);
    final content =
        ((server.agentCalls[1].json['input'] as Map)['results'] as List)
                .single['content']
            as String;
    expect(jsonDecode(content)['ok'], false);
    expect(content, isNot(contains('secret detail')));
  });

  test('plan_saved and artifacts are collected across the rounds', () async {
    final replies = [
      calls([
        ('create_task', {'title': 'x', 'minutes': 5}),
      ]),
      text(
        'Ready',
        planSaved: true,
        artifacts: [
          {'type': 'pdf', 'title': 'German sheet', 'url': 'https://x/a.pdf'},
        ],
      ),
    ];
    var i = 0;
    final server = FakeServer((r) => ok(r, agent: (_) => replies[i++]));
    final reply = await sessionFor(server, FakeTools()).send('go');
    expect(reply.planSaved, isTrue);
    expect(reply.artifacts.single.title, 'German sheet');
  });

  test('an agent that never stops asking for tools is cut off', () async {
    final server = FakeServer(
      (r) => ok(
        r,
        agent: (_) => calls([
          ('create_task', {'title': 'x', 'minutes': 5}),
        ]),
      ),
    );
    await expectLater(
      sessionFor(server, FakeTools()).send('go'),
      throwsA(
        isA<AgentException>().having(
          (e) => e.code,
          'code',
          'too_many_tool_rounds',
        ),
      ),
    );
    expect(server.agentCalls.length, AgentSession.maxToolRounds + 1);
  });

  test(
    'a server error in the middle of the loop reaches the screen as it is',
    () async {
      var i = 0;
      final server = FakeServer((r) {
        if (r.path.startsWith('/auth/')) return jsonResponse(tokenBody());
        return i++ == 0
            ? jsonResponse(
                calls([
                  ('create_task', {'title': 'x', 'minutes': 5}),
                ]),
              )
            : jsonResponse({
                'error': {'code': 'demo_at_capacity'},
              }, 429);
      });
      await expectLater(
        sessionFor(server, FakeTools()).send('go'),
        throwsA(
          isA<AgentException>().having((e) => e.capacity, 'capacity', true),
        ),
      );
    },
  );
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/agent_session.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/chat/chat_controller.dart';
import 'package:life_agent/chat/messages.dart';
import 'package:life_agent/platform/native.dart';
import 'package:life_agent/platform/services.dart';

import 'fakes.dart';
import 'helpers.dart';
import 'session_test.dart' show FakeTools;

class Rig {
  Rig(this.server, {String mode = 'planning', bool withUsage = true}) {
    final api = newApi(server);
    session = AgentSession(
      api: api,
      tools: FakeTools(),
      mode: mode,
      today: '2026-10-27',
      date: '2026-10-28',
    );
    controller = ChatController(
      session: session,
      api: api,
      picks: picks,
      voice: voice,
      speaker: speaker,
      usage: withUsage
          ? UsageSync(native: native, upload: api.uploadUsage)
          : null,
      keywords: const ['TikTok'],
      maxRecording: const Duration(seconds: 120),
    );
  }

  final FakeServer server;
  final picks = FakePicks();
  final voice = FakeVoice();
  final speaker = FakeSpeaker();
  final native = FakeNative();
  late final AgentSession session;
  late final ChatController controller;
}

FakeServer answering(
  List<Map<String, Object?>> replies, {
  Map<String, Object?> Function(Req)? other,
}) {
  var i = 0;
  return FakeServer(
    (r) => ok(
      r,
      agent: (req) => req.action == 'chat' ? replies[i++] : other!(req),
    ),
  );
}

void main() {
  test('a message goes out, the answer comes back, and the screen shows "thinking" in between', () async {
    final rig = Rig(
      answering([
        text('What do you want to do tomorrow?'),
      ], other: (_) => {'saved': 1}),
    );
    final seen = <String?>[];
    rig.controller.addListener(() => seen.add(rig.controller.status));
    await rig.controller.send('Plan my day');
    expect(rig.controller.messages.map((m) => (m.who, m.text)), [
      (Who.user, 'Plan my day'),
      (Who.agent, 'What do you want to do tomorrow?'),
    ]);
    expect(seen, contains('Thinking…'));
    expect(rig.controller.busy, isFalse);
    expect(rig.controller.status, isNull);
  });

  test('real screen time is sent once before the first message, not before every one', () async {
    final rig = Rig(
      answering([text('a'), text('b')], other: (_) => {'saved': 1}),
    );
    await rig.controller.send('one');
    await rig.controller.send('two');
    final usageCalls = rig.server.agentCalls
        .where((c) => c.json['action'] == 'usage')
        .toList();
    expect(usageCalls, hasLength(1));
    expect((usageCalls.single.json['days'] as List).single, {
      'day': '2026-10-27',
      'app': 'TikTok',
      'minutes': 70,
    });
  });

  test('without Usage access the chat still works and the person is told what to turn on', () async {
    final rig = Rig(answering([text('ok')]));
    rig.native.usageAccess = false;
    await rig.controller.send('hi');
    expect(
      rig.server.agentCalls.where((c) => c.json['action'] == 'usage'),
      isEmpty,
    );
    final note = rig.controller.messages.firstWhere((m) => m.who == Who.note);
    expect(note.text, contains('Usage access'));
    expect(rig.controller.messages.last.text, 'ok');
  });

  test('the morning run does not read screen time at all', () async {
    final rig = Rig(answering([text('done')]), mode: 'execute');
    await rig.controller.send('Apply today');
    expect(
      rig.server.agentCalls.where((c) => c.json['action'] == 'usage'),
      isEmpty,
    );
  });

  test('errors become plain sentences in the chat, and the chat keeps working afterwards', () async {
    var n = 0;
    final server = FakeServer((r) {
      if (r.path.startsWith('/auth/')) return jsonResponse(tokenBody());
      if (r.action == 'usage') return jsonResponse({'saved': 1});
      return ++n == 1
          ? jsonResponse({
              'error': {'code': 'demo_at_capacity'},
            }, 429)
          : jsonResponse(text('back again'));
    });
    final rig = Rig(server);
    await rig.controller.send('hi');
    final err = rig.controller.messages.last;
    expect(err.who, Who.note);
    expect(err.error, isTrue);
    expect(err.text, contains('demo is full'));
    expect(err.text, isNot(contains('demo_at_capacity')));
    await rig.controller.send('hi again');
    expect(rig.controller.messages.last.text, 'back again');
  });

  test(
    'an empty message is not sent, and a second message while busy is ignored',
    () async {
      final rig = Rig(answering([text('a')], other: (_) => {'saved': 1}));
      await rig.controller.send('   ');
      expect(rig.controller.messages, isEmpty);
      final first = rig.controller.send('one');
      await rig.controller.send('two');
      await first;
      expect(
        rig.controller.messages.where((m) => m.who == Who.user),
        hasLength(1),
      );
    },
  );

  test(
    'a photo is read by the server and goes with the next message',
    () async {
      final server = answering(
        [text('I see your timetable.')],
        other: (req) {
          if (req.action == 'attach')
            return {
              'document_id': 'd0000000-0000-0000-0000-000000000001',
              'name': 'timetable.jpg',
              'kind': 'image',
              'read_by': 'vision',
            };
          return {'saved': 1};
        },
      );
      final rig = Rig(server);
      rig.picks.photo = PickedFile(
        name: 'timetable.jpg',
        bytes: Uint8List.fromList([9, 9]),
        contentType: 'image/jpeg',
      );
      await rig.controller.attachPhoto(camera: false);
      expect(rig.controller.attachments.single.kind, 'image');
      await rig.controller.send('Plan around this');
      expect(rig.controller.attachments, isEmpty);
      expect(rig.controller.messages.first.text, contains('timetable.jpg'));
      final chat = rig.server.agentCalls
          .firstWhere((c) => c.json['action'] == 'chat')
          .json;
      expect((chat['input'] as Map)['attachments'], [
        'd0000000-0000-0000-0000-000000000001',
      ]);
    },
  );

  test(
    'a file alone can be sent, and backing out of the picker does nothing',
    () async {
      final server = answering(
        [text('Read it.')],
        other: (req) => req.action == 'attach'
            ? {
                'document_id': 'd0000000-0000-0000-0000-000000000002',
                'name': 'a.pdf',
                'kind': 'pdf',
                'read_by': 'text',
              }
            : {'saved': 1},
      );
      final rig = Rig(server);
      await rig.controller.attachDocument();
      expect(rig.controller.attachments, isEmpty);
      rig.picks.document = PickedFile(
        name: 'a.pdf',
        bytes: Uint8List(4),
        contentType: 'application/pdf',
      );
      await rig.controller.attachDocument();
      await rig.controller.send('');
      expect(
        ((rig.server.agentCalls
                .firstWhere((c) => c.json['action'] == 'chat')
                .json['input'])
            as Map)['text'],
        'Please use the attached file.',
      );
    },
  );

  test(
    'a file the server cannot read is explained, and nothing stays attached',
    () async {
      final server = FakeServer((r) {
        if (r.path.startsWith('/auth/')) return jsonResponse(tokenBody());
        if (r.path.startsWith('/storage/')) return jsonResponse({});
        return jsonResponse({
          'error': {'code': 'no_text_in_document'},
        }, 422);
      });
      final rig = Rig(server);
      rig.picks.document = PickedFile(
        name: 'scan.pdf',
        bytes: Uint8List(4),
        contentType: 'application/pdf',
      );
      await rig.controller.attachDocument();
      expect(rig.controller.attachments, isEmpty);
      expect(
        rig.controller.messages.last.text,
        contains('could not read any text'),
      );
    },
  );

  test('voice: tap to listen, tap to send; the words become a message and the answer is read aloud', () async {
    final server = answering(
      [text('Sure, what time?')],
      other: (req) => req.action == 'transcribe'
          ? {'text': 'Study German tomorrow', 'duration_ms': 2000}
          : {'saved': 1},
    );
    final rig = Rig(server);
    await rig.controller.toggleVoice();
    expect(rig.controller.recording, isTrue);
    expect(rig.voice.started, isTrue);
    expect(rig.controller.status, contains('Listening'));
    await rig.controller.toggleVoice();
    expect(rig.controller.recording, isFalse);
    expect(rig.controller.messages.map((m) => m.text), [
      'Study German tomorrow',
      'Sure, what time?',
    ]);
    expect(rig.speaker.spoken, ['Sure, what time?']);
    final t = rig.server.agentCalls
        .firstWhere((c) => c.json['action'] == 'transcribe')
        .json;
    expect(t['keywords'], ['TikTok']);
    expect(t['languages'], ['English']);
  });

  test('typed messages are not read aloud', () async {
    final rig = Rig(
      answering([text('typed answer')], other: (_) => {'saved': 1}),
    );
    await rig.controller.send('hello');
    expect(rig.speaker.spoken, isEmpty);
  });

  test('voice problems: no microphone permission, silence, and a failed transcript are each explained', () async {
    final denied = Rig(answering([]));
    denied.voice.allowed = false;
    await denied.controller.toggleVoice();
    expect(denied.controller.recording, isFalse);
    expect(denied.controller.messages.last.text, contains('microphone'));

    final silent = Rig(answering([]));
    silent.voice.recording = null;
    await silent.controller.toggleVoice();
    await silent.controller.toggleVoice();
    expect(silent.controller.messages.last.text, contains('did not hear'));

    final noSpeech = Rig(
      FakeServer(
        (r) => r.path.startsWith('/auth/')
            ? jsonResponse(tokenBody())
            : r.path.startsWith('/storage/')
            ? jsonResponse({})
            : jsonResponse({
                'error': {'code': 'no_speech'},
              }, 422),
      ),
    );
    await noSpeech.controller.toggleVoice();
    await noSpeech.controller.toggleVoice();
    expect(noSpeech.controller.messages.last.text, contains('did not hear'));
    expect(noSpeech.controller.busy, isFalse);
  });

  test('a recording that runs too long stops by itself', () async {
    final api = newApi(
      answering(
        [text('ok')],
        other: (r) => r.action == 'transcribe'
            ? {'text': 'hello there', 'duration_ms': 1}
            : {'saved': 1},
      ),
    );
    final controller = ChatController(
      session: AgentSession(
        api: api,
        tools: FakeTools(),
        mode: 'planning',
        today: '2026-10-27',
        date: '2026-10-28',
      ),
      api: api,
      picks: FakePicks(),
      voice: FakeVoice(),
      speaker: FakeSpeaker(),
      maxRecording: const Duration(milliseconds: 20),
    );
    await controller.toggleVoice();
    expect(controller.recording, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(controller.recording, isFalse);
    expect(controller.messages.first.text, 'hello there');
  });

  test('every error code has words for a person', () {
    for (final code in [
      'demo_at_capacity',
      'daily_limit_reached',
      'network',
      'timeout',
      'upload_failed',
      'image_too_large',
      'pdf_unreadable',
      'no_speech',
      'bad_audio_not_mono',
      'too_many_tool_rounds',
      'store_error',
    ]) {
      final text = describeError(AgentException(code));
      expect(text, isNotEmpty);
      expect(text, isNot(equals(code)));
    }
    expect(describeError(StateError('x')), contains('Something went wrong'));
  });
}

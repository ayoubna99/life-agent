import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/agent_session.dart';
import 'package:life_agent/chat/chat_controller.dart';
import 'package:life_agent/chat/chat_page.dart';

import 'fakes.dart';
import 'helpers.dart';
import 'session_test.dart' show FakeTools;

Future<(ChatController, FakeOpener, FakeServer)> open(
  WidgetTester t,
  List<Map<String, Object?>> replies, {
  String? first,
  String mode = 'planning',
}) async {
  var i = 0;
  final server = FakeServer(
    (r) => ok(
      r,
      agent: (req) => req.action == 'chat' ? replies[i++] : {'saved': 1},
    ),
  );
  final api = newApi(server);
  final opener = FakeOpener();
  final controller = ChatController(
    session: AgentSession(
      api: api,
      tools: FakeTools(),
      mode: mode,
      today: '2026-10-27',
      date: '2026-10-28',
    ),
    api: api,
    picks: FakePicks(),
    voice: FakeVoice(),
    speaker: FakeSpeaker(),
  );
  await t.pumpWidget(
    MaterialApp(
      home: ChatPage(
        title: 'Plan tomorrow',
        controller: controller,
        opener: opener,
        firstMessage: first,
      ),
    ),
  );
  return (controller, opener, server);
}

void main() {
  testWidgets('typing a message shows it, then the agent\'s answer', (t) async {
    final (c, _, _) = await open(t, [
      text('What do you want to get done tomorrow?'),
    ]);
    await t.enterText(find.byKey(const Key('input')), 'Plan my day');
    await t.tap(find.byKey(const Key('send')));
    await t.pumpAndSettle();
    expect(find.text('Plan my day'), findsOneWidget);
    expect(find.text('What do you want to get done tomorrow?'), findsOneWidget);
    expect(find.byKey(const Key('status')), findsNothing);
    expect(c.busy, isFalse);
  });

  testWidgets(
    'while the agent works the screen says so and the send button is off',
    (t) async {
      final gate = Completer<void>();
      final api = newApiWith((r) async {
        if (r.url.path.startsWith('/auth/')) return jsonResponse(tokenBody());
        await gate.future;
        return jsonResponse(text('ok'));
      }, const Duration(seconds: 5));
      final c = ChatController(
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
      );
      await t.pumpWidget(
        MaterialApp(
          home: ChatPage(title: 'x', controller: c, opener: FakeOpener()),
        ),
      );
      final sending = c.send('hi');
      await t.pump();
      expect(find.text('Thinking…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        t.widget<IconButton>(find.byKey(const Key('send'))).onPressed,
        isNull,
      );
      gate.complete();
      await sending;
      await t.pumpAndSettle();
      expect(find.text('Thinking…'), findsNothing);
      expect(find.text('ok'), findsOneWidget);
    },
  );

  testWidgets('a saved plan shows the green banner', (t) async {
    await open(t, [text('Your plan is ready.', planSaved: true)]);
    expect(find.byKey(const Key('plan-saved')), findsNothing);
    await t.enterText(find.byKey(const Key('input')), 'Yes, save it');
    await t.tap(find.byKey(const Key('send')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('plan-saved')), findsOneWidget);
    expect(find.text('Your plan is saved.'), findsOneWidget);
  });

  testWidgets('a PDF the agent made appears as a card that opens the link', (
    t,
  ) async {
    final (_, opener, _) = await open(t, [
      text(
        'Here is your German sheet.',
        artifacts: [
          {
            'type': 'pdf',
            'title': 'German for beginners',
            'url': 'https://proj.supabase.co/storage/v1/object/sign/materials/u/a.pdf?token=t',
          },
        ],
      ),
    ]);
    await t.enterText(find.byKey(const Key('input')), 'make a pdf');
    await t.tap(find.byKey(const Key('send')));
    await t.pumpAndSettle();
    expect(find.text('German for beginners'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    await t.tap(find.byKey(const Key('artifact-German for beginners')));
    await t.pump();
    expect(opener.opened.single, contains('/materials/u/a.pdf'));
  });

  testWidgets('the morning run starts by itself when the screen opens', (
    t,
  ) async {
    final (c, _, server) = await open(
      t,
      [text('Your day is set up.')],
      first: 'Apply today',
      mode: 'execute',
    );
    await t.pumpAndSettle();
    expect(c.messages.first.text, 'Apply today');
    expect(find.text('Your day is set up.'), findsOneWidget);
    expect(server.agentCalls.single.json['mode'], 'execute');
  });

  testWidgets('an error shows as a red note, not a crash', (t) async {
    final server = FakeServer(
      (r) => r.path.startsWith('/auth/')
          ? jsonResponse(tokenBody())
          : jsonResponse({
              'error': {'code': 'daily_limit_reached'},
            }, 429),
    );
    final api = newApi(server);
    final c = ChatController(
      session: AgentSession(
        api: api,
        tools: FakeTools(),
        mode: 'execute',
        today: '2026-10-27',
        date: '2026-10-27',
      ),
      api: api,
      picks: FakePicks(),
      voice: FakeVoice(),
      speaker: FakeSpeaker(),
    );
    await t.pumpWidget(
      MaterialApp(
        home: ChatPage(title: 'x', controller: c, opener: FakeOpener()),
      ),
    );
    await t.enterText(find.byKey(const Key('input')), 'hi');
    await t.tap(find.byKey(const Key('send')));
    await t.pumpAndSettle();
    expect(find.textContaining('used all of today'), findsOneWidget);
  });

  testWidgets('the attach button offers a photo, the camera and a document', (
    t,
  ) async {
    await open(t, []);
    await t.tap(find.byKey(const Key('attach')));
    await t.pumpAndSettle();
    expect(find.text('Photo from gallery'), findsOneWidget);
    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('PDF or text file'), findsOneWidget);
  });

  testWidgets(
    'the microphone button listens, and the field is locked while it does',
    (t) async {
      final (c, _, _) = await open(t, [text('ok')]);
      await t.tap(find.byKey(const Key('mic')));
      await t.pump();
      expect(c.recording, isTrue);
      expect(find.text('Listening… tap again to send'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byKey(const Key('input'))).enabled,
        isFalse,
      );
      expect(
        t.widget<IconButton>(find.byKey(const Key('send'))).onPressed,
        isNull,
      );
      c.dispose(); // stops the recording timer
    },
  );
}

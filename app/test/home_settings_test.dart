import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/app_services.dart';
import 'package:life_agent/chat/chat_page.dart';
import 'package:life_agent/device/stores.dart';
import 'package:life_agent/platform/voice_settings.dart';
import 'package:life_agent/ui/home_page.dart';
import 'package:life_agent/ui/settings_page.dart';

import 'fakes.dart';
import 'helpers.dart';

class Env {
  Env({
    Map<String, Object?>? profile,
    Map<String, Object?>? plan,
    this.todayPlan,
    this.hour = 20,
    this.offline = false,
  }) {
    var chats = 0;
    server = FakeServer((r) {
      if (r.path.startsWith('/auth/')) return jsonResponse(tokenBody());
      if (offline) throw Exception('offline');
      switch (r.action) {
        case 'profile':
          if (r.json['set'] != null)
            saved = r.json['set'] as Map<String, Object?>;
          return jsonResponse({
            'profile': profile ?? {'apps': <String>[]},
          });
        case 'plan':
          return jsonResponse({
            'plan': r.json['date'] == '2026-10-27' ? todayPlan : plan,
          });
        case 'usage':
          return jsonResponse({'saved': 1});
        case 'chat':
          chats++;
          return jsonResponse(text('Reply $chats'));
      }
      return jsonResponse({});
    });
    services = AppServices(
      api: newApi(server),
      tasks: tasks,
      limits: MemoryLimitStore(),
      native: native,
      picks: FakePicks(),
      voice: FakeVoice(),
      speaker: speaker,
      opener: opener,
      voiceSettings: voiceSettings,
      baseUrl: base,
      apiKey: key,
      now: () => DateTime(2026, 10, 27, hour, 15),
    );
  }

  final int hour;
  final bool offline;
  final Map<String, Object?>? todayPlan;
  late final FakeServer server;
  late final AppServices services;
  final tasks = MemoryTaskStore();
  final native = FakeNative();
  final opener = FakeOpener();
  final speaker = FakeSpeaker();
  final voiceSettings = MemoryVoiceSettingsStore();
  Map<String, Object?>? saved;
}

Map<String, Object?> plan(int tasks) => {
  'date': '2026-10-28',
  'status': 'ready',
  'data': {
    'tasks': [
      for (var i = 1; i <= tasks; i++) {'title': 'Task $i', 'minutes': 30},
    ],
    'limits': <Object?>[],
  },
};

void main() {
  testWidgets(
    'first launch asks for the settings, and the banner goes away once they are saved on the server',
    (t) async {
      final env = Env();
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('setup')), findsOneWidget);
      expect(find.byKey(const Key('empty')), findsOneWidget);

      final known = Env(
        profile: {
          'wake': '07:00',
          'sleep': '23:30',
          'apps': ['TikTok'],
        },
      );
      await t.pumpWidget(
        MaterialApp(
          home: HomePage(key: UniqueKey(), services: known.services),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('setup')), findsNothing);
    },
  );

  testWidgets(
    'today\'s tasks are listed, can be opened for the steps, and ticked off',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '1',
          date: '2026-10-27',
          title: 'Study German',
          minutes: 40,
          startTime: '19:00',
          firstStep: 'Open the sheet',
          instructions: ['Read page 1'],
          links: ['https://x/a.pdf'],
        ),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('task-Study German')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('task-Study German')),
          matching: find.text('19:00 · 40 min'),
        ),
        findsOneWidget,
      );
      await t.ensureVisible(find.byKey(const Key('task-Study German')));
      await t.pump();
      await t.tap(find.byKey(const Key('task-Study German')));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('task-Study German')),
          matching: find.text('First step: Open the sheet'),
        ),
        findsOneWidget,
      );
      expect(find.text('• Read page 1'), findsOneWidget);
      await t.ensureVisible(find.text('Open material'));
      await t.pump();
      await t.tap(find.text('Open material'));
      expect(env.opener.opened.single, 'https://x/a.pdf');
      await t.ensureVisible(find.byKey(const Key('check-Study German')));
      await t.pump();
      await t.tap(find.byKey(const Key('check-Study German')));
      await t.pumpAndSettle();
      expect((await env.tasks.forDate('2026-10-27')).single.done, isTrue);
    },
  );

  testWidgets(
    'when tomorrow is planned the home says rest, and shows none of tomorrow\'s tasks',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
        plan: plan(2),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tomorrow')), findsOneWidget);
      expect(find.text('Tomorrow is planned. Rest now.'), findsOneWidget);
      expect(find.text('Your tasks show up in the morning.'), findsOneWidget);
      expect(
        find.textContaining('Task 1'),
        findsNothing,
        reason: 'nothing to read before sleep',
      );
      expect(find.textContaining('2 tasks'), findsNothing);
    },
  );

  testWidgets(
    'in the morning a ready plan offers to start the day, and the card goes once the tasks are set up',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
        todayPlan: {...plan(1), 'date': '2026-10-27'},
        hour: 8,
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('today-ready')), findsOneWidget);
      await env.tasks.upsert(
        const LocalTask(
          id: '1',
          date: '2026-10-27',
          title: 'Task 1',
          minutes: 30,
        ),
      );
      await t.pumpWidget(
        MaterialApp(
          home: HomePage(key: UniqueKey(), services: env.services),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('today-ready')), findsNothing);
    },
  );

  testWidgets(
    'the next task is shown on top, with its first step, and can be marked done',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
        hour: 9,
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '1',
          date: '2026-10-27',
          title: 'Gym',
          minutes: 60,
          startTime: '17:00',
        ),
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '2',
          date: '2026-10-27',
          title: 'Study German',
          minutes: 40,
          startTime: '10:00',
          firstStep: 'Open the sheet',
        ),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('next')),
          matching: find.text('Study German'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('First step: Open the sheet'), findsWidgets);
      await t.tap(find.byKey(const Key('next-done')));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('next')),
          matching: find.text('Gym'),
        ),
        findsOneWidget,
        reason: 'the next one moves up',
      );
    },
  );

  testWidgets(
    '"Next task (test)" schedules a reminder for the next task in 10 seconds and says to leave the app',
    (t) async {
      t.view.physicalSize = const Size(900, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
        hour: 9,
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '1',
          date: '2026-10-27',
          title: 'Study German',
          minutes: 40,
          startTime: '10:00',
          firstStep: 'Open the sheet',
        ),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('test-next')));
      await t.pump();
      await t.tap(find.byKey(const Key('test-next')));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 200));
      expect(env.native.alarms, hasLength(1));
      final (id, at, message) = env.native.alarms.single;
      expect(id, 'test-next');
      expect(
        message,
        'Next task: Study German (40 min). First step: Open the sheet',
      );
      final seconds = (at - DateTime.now().millisecondsSinceEpoch) / 1000;
      expect(seconds, inInclusiveRange(7, 11));
      expect(
        env.native.alarmCards.single,
        isFalse,
        reason: 'a notification, to test leaving the app',
      );
      expect(find.textContaining('Leave the app now'), findsOneWidget);
    },
  );

  testWidgets(
    '"Next task (test)" without tasks still tests the reminder, and without the alarms permission says what to turn on',
    (t) async {
      t.view.physicalSize = const Size(900, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('test-next')));
      await t.pump();
      await t.tap(find.byKey(const Key('test-next')));
      await t.pump();
      expect(env.native.alarms.single.$3, startsWith('Test reminder'));
    },
  );

  testWidgets(
    '"Next task (test)" without the alarms permission says what to turn on and schedules nothing',
    (t) async {
      t.view.physicalSize = const Size(900, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final off = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      off.native.exactAlarms = false;
      await t.pumpWidget(
        MaterialApp(
          home: HomePage(key: UniqueKey(), services: off.services),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('test-next')));
      await t.pump();
      await t.tap(find.byKey(const Key('test-next')));
      await t.pump();
      expect(find.textContaining('Alarms and reminders'), findsOneWidget);
      expect(off.native.alarms, isEmpty);
    },
  );

  testWidgets('"Nudge card (test)" asks for the card on top of other apps', (
    t,
  ) async {
    t.view.physicalSize = const Size(900, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final env = Env(
      profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
    );
    await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('test-card')));
    await t.pump();
    await t.tap(find.byKey(const Key('test-card')));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(env.native.alarmCards.single, isTrue);
    expect(env.native.alarms.single.$1, 'test-card');
  });

  test(
    'the good-morning reminder is set for tomorrow at the wake-up time, 07:00 when none is set',
    () async {
      final env = Env();
      expect(
        await env.services.scheduleMorning(const Profile(wake: '06:30')),
        isTrue,
      );
      expect(await env.services.scheduleMorning(const Profile()), isTrue);
      final first = DateTime.fromMillisecondsSinceEpoch(
        env.native.alarms[0].$2,
      );
      final second = DateTime.fromMillisecondsSinceEpoch(
        env.native.alarms[1].$2,
      );
      expect(
        [first.year, first.month, first.day, first.hour, first.minute],
        [2026, 10, 28, 6, 30],
      );
      expect([second.hour, second.minute], [7, 0]);
      expect(env.native.alarms[0].$1, 'morning-2026-10-28');
      expect(env.native.alarms[0].$3, contains('tap to start your day'));
    },
  );

  testWidgets('without Usage access a banner offers to turn it on', (t) async {
    t.view.physicalSize = const Size(900, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final env = Env(
      profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
    );
    env.native.usageAccess = false;
    await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
    await t.pumpAndSettle();
    await t.tap(
      find.descendant(
        of: find.byKey(const Key('usage-banner')),
        matching: find.text('Allow'),
      ),
    );
    expect(env.native.usageSettingsOpened, 1);
  });

  testWidgets(
    'offline the phone\'s own list is still shown, with a short note',
    (t) async {
      final env = Env(offline: true);
      await env.tasks.upsert(
        const LocalTask(id: '1', date: '2026-10-27', title: 'Gym', minutes: 60),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('task-Gym')), findsOneWidget);
      expect(find.textContaining('Offline'), findsOneWidget);
    },
  );

  testWidgets(
    '"Start my day" opens the chat and the morning run begins by itself',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
        hour: 8,
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('start')));
      await t.pump();
      await t.tap(find.byKey(const Key('start')));
      await t.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.text('Reply 1'), findsOneWidget);
      final chat = env.server.agentCalls
          .firstWhere((c) => c.json['action'] == 'chat')
          .json;
      expect(chat['mode'], 'execute');
      expect(chat['today'], '2026-10-27');
      expect(chat['date'], '2026-10-27');
    },
  );

  testWidgets(
    '"Plan tomorrow" plans the next day and reads the real screen time first',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('plan')));
      await t.pump();
      await t.tap(find.byKey(const Key('plan')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('input')), 'Plan my day');
      await t.tap(find.byKey(const Key('send')));
      await t.pumpAndSettle();
      final actions = [for (final c in env.server.agentCalls) c.json['action']];
      expect(actions.indexOf('usage'), lessThan(actions.indexOf('chat')));
      final chat = env.server.agentCalls
          .firstWhere((c) => c.json['action'] == 'chat')
          .json;
      expect(chat['mode'], 'planning');
      expect(chat['date'], '2026-10-28');
    },
  );

  testWidgets(
    '"Review my day" tells the agent which tasks were done and which were missed',
    (t) async {
      t.view.physicalSize = const Size(900, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '1',
          date: '2026-10-27',
          title: 'Study German',
          minutes: 40,
          done: true,
        ),
      );
      await env.tasks.upsert(
        const LocalTask(id: '2', date: '2026-10-27', title: 'Gym', minutes: 60),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('review')));
      await t.pump();
      await t.tap(find.byKey(const Key('review')));
      await t.pumpAndSettle();
      final chat = env.server.agentCalls
          .firstWhere((c) => c.json['action'] == 'chat')
          .json;
      expect(chat['mode'], 'review');
      expect(chat['date'], '2026-10-28');
      expect(chat['report'], {
        'done': ['Study German'],
        'missed': ['Gym'],
      });
    },
  );

  testWidgets(
    'opening the app tells the background watcher where the agent is and which apps are limited',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      await env.services.limits.set('TikTok', 30);
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(env.native.nudgeConfig?.baseUrl, base);
      expect(env.native.limits, {'TikTok': 30});
    },
  );

  testWidgets(
    'settings: wake, sleep, apps and focus are saved to the server in one call',
    (t) async {
      final env = Env(profile: {'apps': <String>[]});
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(services: env.services, profile: const Profile()),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('apps')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('app-TikTok')));
      await t.tap(find.byKey(const Key('app-Instagram')));
      await t.tap(find.byKey(const Key('apps-done')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('focus')), 'my thesis');
      await t.ensureVisible(find.byKey(const Key('save')));
      await t.pump();
      await t.tap(find.byKey(const Key('save')));
      await t.pumpAndSettle();
      expect(env.saved, {
        'apps': ['TikTok', 'Instagram'],
        'focus': 'my thesis',
      });
    },
  );

  testWidgets(
    'settings: existing values show, and a failed save says so without closing the screen',
    (t) async {
      final env = Env(offline: true);
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            services: env.services,
            profile: const Profile(
              wake: '06:30',
              sleep: '22:45',
              apps: ['TikTok'],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('06:30'), findsOneWidget);
      expect(find.text('22:45'), findsOneWidget);
      expect(find.text('TikTok'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('save')));
      await t.pump();
      await t.tap(find.byKey(const Key('save')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('error')), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);
    },
  );

  testWidgets(
    'settings: permissions show their state, and "Allow" goes to the right place',
    (t) async {
      final env = Env(profile: {'apps': <String>[]});
      env.native.usageAccess = false;
      env.native.notifications = false;
      env.native.exactAlarms = true;
      t.view.physicalSize = const Size(
        900,
        3200,
      ); // a tall screen, so the lazy list builds every row
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      env.native.overlay = false;
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(services: env.services, profile: const Profile()),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('perm-usage')));
      await t.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('perm-alarms')),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
      await t.tap(
        find.descendant(
          of: find.byKey(const Key('perm-usage')),
          matching: find.text('Allow'),
        ),
      );
      expect(env.native.usageSettingsOpened, 1);
      await t.tap(
        find.descendant(
          of: find.byKey(const Key('perm-overlay')),
          matching: find.text('Allow'),
        ),
      );
      expect(env.native.overlaySettingsOpened, 1);
      await t.tap(
        find.descendant(
          of: find.byKey(const Key('perm-notifications')),
          matching: find.text('Allow'),
        ),
      );
      await t.pumpAndSettle();
      expect(env.native.notifications, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('perm-notifications')),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'settings: the voice can be switched off, chosen from the phone\'s voices, and heard',
    (t) async {
      final env = Env(profile: {'apps': <String>[]});
      t.view.physicalSize = const Size(900, 3600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(services: env.services, profile: const Profile()),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Automatic'), findsOneWidget);

      await t.tap(find.byKey(const Key('voice-enabled')));
      await t.pumpAndSettle();
      expect(env.voiceSettings.value.enabled, isFalse);

      await t.tap(find.byKey(const Key('voice')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('voice-fr-fr-x-vlf-local')),
        findsNothing,
        reason: 'only the phone\'s language is offered',
      );
      await t.tap(find.byKey(const Key('voice-en-us-x-iom-local')));
      await t.pumpAndSettle();
      expect(env.voiceSettings.value.voiceName, 'en-us-x-iom-local');
      expect(env.voiceSettings.value.locale, 'en-US');
      expect(
        env.speaker.spoken.last,
        contains('how I sound'),
        reason: 'the new voice is heard right away',
      );

      await t.tap(find.byKey(const Key('voice')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('voice-auto')));
      await t.pumpAndSettle();
      expect(env.voiceSettings.value.voiceName, isNull);

      await t.ensureVisible(find.byKey(const Key('voice-sample')));

      await t.pump();
      await t.tap(find.byKey(const Key('voice-sample')));
      expect(
        env.speaker.spoken.length,
        3,
        reason: 'one sample per chosen voice plus the button',
      );
    },
  );
}

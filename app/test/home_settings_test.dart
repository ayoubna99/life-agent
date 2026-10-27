import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/app_services.dart';
import 'package:life_agent/chat/chat_page.dart';
import 'package:life_agent/device/stores.dart';
import 'package:life_agent/ui/home_page.dart';
import 'package:life_agent/ui/settings_page.dart';

import 'fakes.dart';
import 'helpers.dart';

class Env {
  Env({
    Map<String, Object?>? profile,
    Map<String, Object?>? plan,
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
          return jsonResponse({'plan': plan});
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
      speaker: FakeSpeaker(),
      opener: opener,
      baseUrl: base,
      apiKey: key,
      now: () => DateTime(2026, 10, 27, hour, 15),
    );
  }

  final int hour;
  final bool offline;
  late final FakeServer server;
  late final AppServices services;
  final tasks = MemoryTaskStore();
  final native = FakeNative();
  final opener = FakeOpener();
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
      expect(find.text('Study German'), findsOneWidget);
      expect(find.text('19:00 · 40 min'), findsOneWidget);
      await t.tap(find.byKey(const Key('task-Study German')));
      await t.pumpAndSettle();
      expect(find.text('First step: Open the sheet'), findsOneWidget);
      expect(find.text('• Read page 1'), findsOneWidget);
      await t.tap(find.text('Open material'));
      expect(env.opener.opened.single, 'https://x/a.pdf');
      await t.tap(find.byKey(const Key('check-Study German')));
      await t.pumpAndSettle();
      expect((await env.tasks.forDate('2026-10-27')).single.done, isTrue);
    },
  );

  testWidgets('tomorrow\'s saved plan is shown', (t) async {
    final env = Env(
      profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      plan: plan(2),
    );
    await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
    await t.pumpAndSettle();
    expect(find.text('Tomorrow is planned: 2 tasks'), findsOneWidget);
    expect(find.text('Task 1 · Task 2'), findsOneWidget);
  });

  testWidgets('without Usage access a banner offers to turn it on', (t) async {
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
      expect(find.text('Gym'), findsOneWidget);
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
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/device/plan_applier.dart';
import 'package:life_agent/device/stores.dart';
import 'package:life_agent/ui/learning.dart';

import 'device_runner_test.dart' show FakeAlarms;
import 'fakes.dart';
import 'home_settings_test.dart' show Env;
import 'package:life_agent/ui/home_page.dart';

final _shift = {
  'day': '2026-10-28',
  'status': 'final',
  'model': 'open',
  'shift': {
    'theories': [
      {
        'id': 'gym',
        'statement': 'Blunt lines about tomorrow\'s gym work after 22:00',
        'angle': 'gym_blunt',
        'confidence': 0.72,
        'status': 'kept',
        'evidence': 'left 4 of 6',
      },
      {
        'id': 'q',
        'statement': 'Questions do not work',
        'confidence': 0.8,
        'status': 'rejected',
        'evidence': 'stayed 5 of 5',
      },
    ],
    'angles': [
      {
        'id': 'gym_blunt',
        'name': 'Blunt, tomorrow\'s gym',
        'style': 'goal',
        'bands': ['night'],
        'apps': <String>[],
        'lines': [
          {'id': 'gym_blunt_1', 'text': 'Gym at 6. TikTok will still be here.'},
        ],
      },
    ],
    'notes': 'Gym works late at night.',
    'thinking': 'Gym lines got 4 of 6 after 22:00.',
    'critic': {'cut': 3, 'reasons': <String>[]},
  },
};

void main() {
  test(
    'a night shift from the server: theories, ideas with their results, the raw shift for the watcher',
    () {
      final s = NightShift.fromJson(
        _shift,
        stats: [
          {'angle': 'gym_blunt', 'tried': 6, 'left': 4},
        ],
      )!;
      expect(s.theories.first.status, 'kept');
      expect(s.angles.single.left, 4);
      expect(s.lineCount, 1);
      expect(s.cut, 3);
      expect(s.raw!['day'], '2026-10-28');
      expect(NightShift.fromJson(null), isNull);
    },
  );

  testWidgets(
    'home card shows the live theories (not the rejected ones), the page shows everything',
    (t) async {
      final s = NightShift.fromJson(_shift)!;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NightShiftCard(shift: s)),
        ),
      );
      expect(find.textContaining('tomorrow\'s gym work'), findsOneWidget);
      expect(find.text('Questions do not work'), findsNothing);
      expect(find.textContaining('the critic cut 3'), findsOneWidget);

      await t.pumpWidget(MaterialApp(home: NightShiftPage(shift: s)));
      expect(find.text('Questions do not work'), findsOneWidget);
      expect(
        find.text('"Gym at 6. TikTok will still be here."'),
        findsOneWidget,
      );
      await t.scrollUntilVisible(find.byKey(const Key('night-thinking')), 200);
      await t.tap(find.byKey(const Key('night-thinking')));
      await t.pumpAndSettle();
      expect(find.text('Gym lines got 4 of 6 after 22:00.'), findsOneWidget);
    },
  );

  group('a plan goes on the phone the moment it is saved', () {
    SavedPlan plan(List<Map<String, Object?>> tasks) => SavedPlan.fromJson({
      'date': '2026-10-28',
      'status': 'ready',
      'data': {'tasks': tasks, 'limits': <Object?>[]},
    });

    test(
      'tonight: tasks, in-app alarms at the start, phone alarms 10 minutes before, calendar reminders; once',
      () async {
        final alarms = FakeAlarms();
        final tasks = MemoryTaskStore();
        final native = FakeNative()
          ..calendar = const [
            CalendarEntry(title: 'Lecture', start: '10:00', end: '12:00'),
          ];
        final applier = PlanApplier(
          tasks: tasks,
          alarms: alarms,
          log: MemoryAlarmLog(),
          native: native,
        );
        final p = plan([
          {
            'title': 'Gym',
            'minutes': 60,
            'start_time': '07:00',
            'alarm': 'phone',
          },
          {
            'title': 'Read chapter 2',
            'minutes': 45,
            'start_time': '14:00',
            'alarm': 'in_app',
            'notes': 'Pages 30 to 52',
          },
          {
            'title': 'Late call',
            'minutes': 20,
            'start_time': '23:30',
            'alarm': 'phone',
          },
        ]);
        final now = DateTime(2026, 10, 27, 22, 0);
        expect(await applier.apply(p, now: now), 4);
        expect(alarms.phone, [(6, 50, 'Gym')]);
        // 23:30 tomorrow is more than a day away: the Clock app would ring tonight, so Life rings instead
        expect(alarms.set.map((a) => a.$2), [
          'Read chapter 2',
          'Get ready: Late call',
          'In 10 minutes: Lecture',
        ]);
        expect(alarms.set.first.$1, DateTime(2026, 10, 28, 14, 0));
        final saved = await tasks.forDate('2026-10-28');
        expect(saved.map((t) => t.title), [
          'Gym',
          'Read chapter 2',
          'Late call',
        ]);
        expect(saved[1].notes, 'Pages 30 to 52');
        expect(await applier.applied(p), isTrue);
        expect(
          await applier.apply(p, now: now),
          0,
          reason: 'the same plan again changes nothing',
        );
        expect(alarms.phone.length, 1);
      },
    );
  });

  testWidgets(
    'in the evening without a bank for tomorrow, home runs the night shift (study, then critic)',
    (t) async {
      final env = Env(hour: 21);
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      final shifts = [
        for (final r in env.server.agentCalls)
          if (r.action == 'nightshift') r.json,
      ];
      expect(
        shifts.map((j) => j['step']),
        containsAllInOrder(['get', 'study', 'critic']),
      );
      expect(
        shifts.firstWhere((j) => j['step'] == 'study')['day'],
        '2026-10-28',
      );
    },
  );

  testWidgets('"Pull me out" opens what matters next', (t) async {
    final env = Env(hour: 10);
    await env.tasks.upsert(
      const LocalTask(
        id: 'a',
        date: '2026-10-27',
        title: 'Thesis chapter 2',
        minutes: 60,
        startTime: '11:00',
      ),
    );
    env.native.launchAction = 'pull';
    await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('task-title')), findsOneWidget);
    expect(find.text('Thesis chapter 2'), findsWidgets);
  });
}

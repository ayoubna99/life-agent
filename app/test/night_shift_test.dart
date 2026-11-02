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
        'evidence': 'Left 4/6 with it vs 1/6 without (at night)',
        'model_said': {'status': 'kept', 'confidence': 0.7},
      },
      {
        'id': 'q',
        'statement': 'Questions do not work',
        'confidence': 0.8,
        'status': 'rejected',
        'evidence': 'Left 0/5 with it vs 4/6 without (all moments)',
        'model_said': {'status': 'kept', 'confidence': 0.9},
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
        beliefs: {
          'why': ['A concrete next step tends to beat general advice.'],
        },
      )!;
      expect(s.assumptions.single, startsWith('A concrete next step'));
      expect(s.theories[1].overruled, isTrue);
      expect(s.theories[0].overruled, isFalse);
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

      // a tall screen, so the whole page is laid out at once
      t.view.physicalSize = const Size(1080, 9000);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: NightShiftPage(shift: s)));
      await t.pumpAndSettle();
      expect(find.text('Questions do not work'), findsOneWidget);
      // the model said "kept", code said "rejected": the page shows the data won
      expect(find.byKey(const Key('theory-overruled')), findsOneWidget);
      expect(
        find.text(
          'Checked on your data: Left 0/5 with it vs 4/6 without (all moments)',
        ),
        findsOneWidget,
      );
      expect(
        find.text('"Gym at 6. TikTok will still be here."'),
        findsOneWidget,
      );
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

  testWidgets(
    'your path: from the typical day down to today, the days hit, and the trade',
    (t) async {
      final p = TaperView.fromJson({
        'app': 'TikTok',
        'baseline': 180,
        'goal': 30,
        'target': 130,
        'path': [
          {'day': '2026-11-01', 'target': 155},
          {'day': '2026-11-04', 'target': 130},
        ],
        'recent': [
          {'day': '2026-11-04', 'met': true},
        ],
        'trade': '25 minutes back: two pages of your thesis at 22:15.',
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TaperCard(tapers: [p])),
        ),
      );
      expect(
        find.text('3 h → 2 h 35 → today 2 h 10 · goal 30 min'),
        findsOneWidget,
      );
      expect(find.text('Hit 1 of the last 1 day'), findsOneWidget);
      expect(
        find.text('25 minutes back: two pages of your thesis at 22:15.'),
        findsOneWidget,
      );
    },
  );

  test(
    'theories carry last night\'s verdict, and the shift says what it read and what the critic cut',
    () {
      final s = NightShift.fromJson({
        'day': '2026-11-02',
        'status': 'final',
        'updated_at': '2026-11-01T22:49:28Z',
        'shift': {
          'theories': [
            {
              'statement': 'a',
              'status': 'kept',
              'confidence': 0.93,
              'evidence': '',
              'before': {'status': 'testing', 'confidence': 0.54},
            },
            {
              'statement': 'b',
              'status': 'testing',
              'confidence': 0.5,
              'evidence': '',
              'before': null,
            },
          ],
          'angles': <Object?>[],
          'read': {'nudges': 39, 'nights': 7},
          'critic': {
            'cut': 1,
            'reasons': ['generic'],
            'lines': [
              {'text': 'Take a break.', 'why': 'generic'},
            ],
          },
        },
      })!;
      expect(s.theories[0].beforeConfidence, 0.54);
      expect(s.theories[0].isNew, isFalse);
      expect(s.theories[1].isNew, isTrue);
      expect(s.readNudges, 39);
      expect(s.cutLines.single.$1, 'Take a break.');
      expect(s.writtenAt, isNotNull);
    },
  );

  testWidgets(
    '"Pull me out" opens the task the nudge was about, never a short break',
    (t) async {
      final env = Env(hour: 10);
      for (final task in const [
        LocalTask(
          id: 'b',
          date: '2026-10-27',
          title: 'Offline reset: tea, stretch, tidy',
          minutes: 10,
          startTime: '10:30',
        ),
        LocalTask(
          id: 'c',
          date: '2026-10-27',
          title: 'Apply to 3 internships',
          minutes: 90,
          startTime: '14:00',
        ),
        LocalTask(
          id: 'd',
          date: '2026-10-27',
          title: 'Gym',
          minutes: 60,
          startTime: '18:00',
        ),
      ]) {
        await env.tasks.upsert(task);
      }
      env.native.launchAction = 'pull|Gym';
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const Key('task-title'))).data, 'Gym');
      await t.pageBack();
      await t.pumpAndSettle();

      // no task named: the next one worth leaving an app for, skipping the 10 minute break
      env.native.launchAction = 'pull';
      await t.pumpWidget(
        MaterialApp(
          home: HomePage(key: UniqueKey(), services: env.services),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('task-title')), findsOneWidget);
      expect(find.text('Apply to 3 internships'), findsWidgets);
    },
  );

  testWidgets(
    'the page shows lines as they will appear: the real task and app filled in',
    (t) async {
      final s = NightShift.fromJson({
        'day': '2026-10-28',
        'status': 'final',
        'shift': {
          'theories': <Object?>[],
          'angles': [
            {
              'id': 'next',
              'name': 'Blunt, the next task',
              'lines': [
                {'id': 'n1', 'text': '{task} first. {app} can wait.'},
              ],
            },
          ],
        },
      })!;
      await t.pumpWidget(
        MaterialApp(
          home: NightShiftPage(shift: s, task: 'Gym', app: 'TikTok'),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('"Gym first. TikTok can wait."'), findsOneWidget);
      expect(find.textContaining('{task}'), findsNothing);
    },
  );

  testWidgets(
    'the lab shows moments, the control group, and a quick return to a feed as a failure',
    (t) async {
      final r = ExperimentResults.fromJson({
        'events': 3,
        'days': 1,
        'arms': <Object?>[],
        'control': {
          'nudged': {'tried': 10, 'stayed_off': 6},
          'without': {'tried': 4, 'stayed_off': 1},
          'lift': 0.35,
          'prob_better': 0.9,
        },
        'log': [
          for (final e in [
            {
              'angle': 'moment_lost_intent',
              'left': true,
              'message':
                  'You picked up your phone for WhatsApp 14 minutes ago.',
            },
            {'angle': 'moment_exit_point', 'left': false, 'holdout': true},
            {'angle': 'gym_blunt', 'left': true, 'back_to_feed': true},
          ])
            {
              'day': '2026-11-02',
              'time': '22:00',
              'app': 'TikTok',
              'arm': 'goal',
              'label': 'nudges with your own goal',
              'explore': false,
              'minutes_after': 3,
              ...e,
            },
        ],
      });
      expect(r.control!.withoutTried, 4);
      t.view.physicalSize = const Size(1080, 9000);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: LabNotebookPage(results: r)));
      await t.pumpAndSettle();
      expect(find.text('Moment: lost intent'), findsOneWidget);
      expect(find.byKey(const Key('lab-control')), findsOneWidget);
      expect(find.text('Held back on purpose (control group)'), findsOneWidget);
      expect(
        find.textContaining('went back to a feed within 10 minutes'),
        findsOneWidget,
      );
    },
  );

  test(
    'taking an app off "apps that pull me away" also drops an old limit a plan set for it',
    () async {
      final env = Env();
      await env.services.limits.set('Chrome', 25);
      await env.services.limits.set('TikTok', 60);
      await env.services.syncWatcher(distracting: ['TikTok']);
      expect(env.native.limits, {'TikTok': 60});
    },
  );
}

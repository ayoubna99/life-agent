import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/device/device_runner.dart';
import 'package:life_agent/device/rules.dart';
import 'package:life_agent/device/stores.dart';
import 'package:life_agent/platform/experiment_settings.dart';
import 'package:life_agent/ui/home_page.dart';
import 'package:life_agent/ui/learning.dart';
import 'package:life_agent/ui/settings_page.dart';

import 'helpers.dart';
import 'home_settings_test.dart' show Env;
import 'session_test.dart' show FakeTools, sessionFor;

Map<String, Object?> strategy(
  int v,
  String date,
  int maxTasks,
  List<String> changes,
) => {
  'version': v,
  'for_date': date,
  'limits': [
    {'app': 'Instagram', 'minutes': maxTasks == 3 ? 20 : 30},
  ],
  'plan_style': {'max_tasks': maxTasks, 'buffer_pct': 30},
  'risk_windows': ['21:00-23:00'],
  'rules': ['Max $maxTasks tasks'],
  'changes': changes,
  'evidence': changes.isEmpty ? <String>[] : ['Finished 3 of 5 tasks twice'],
};

Map<String, Object?> results({String? best = 'task'}) => {
  'events': 20,
  'days': 2,
  'demo_events': 0,
  'best': best,
  'arms': [
    {
      'arm': 'task',
      'label': 'nudges with your next task',
      'tried': 9,
      'left': 7,
      'prob_best': 0.87,
    },
    {
      'arm': 'cost',
      'label': 'nudges with what the time costs',
      'tried': 8,
      'left': 3,
      'prob_best': 0.05,
    },
    {
      'arm': 'goal',
      'label': 'nudges with your own goal',
      'tried': 3,
      'left': 1,
      'prob_best': 0.08,
    },
  ],
  'by_app': [
    {'app': 'Instagram', 'hits': 18, 'left': 11},
  ],
  'policy': {
    'events': 20,
    'life_rate': 0.64,
    'best_fixed': {'arm': 'cost', 'estimate': 0.41},
    'random': 0.38,
    'lift': 0.23,
    'lift_interval': [0.05, 0.38],
  },
  'contexts': [
    {'app': 'Instagram', 'band': 'night', 'hits': 12, 'leading': 'task'},
    {'app': 'Instagram', 'band': 'afternoon', 'hits': 3, 'leading': null},
  ],
  'log': [
    {
      'day': '2026-10-29',
      'time': '21:14',
      'app': 'Instagram',
      'band': 'night',
      'arm': 'goal',
      'label': 'nudges with your own goal',
      'explore': true,
      'propensity': 0.12,
      'message': 'Ayoub, the thesis chapter you wanted is one hour of focus.',
      'left': false,
      'minutes_after': 9.0,
      'demo': false,
    },
    {
      'day': '2026-10-29',
      'time': '20:40',
      'app': 'Instagram',
      'band': 'evening',
      'arm': 'task',
      'label': 'nudges with your next task',
      'explore': false,
      'propensity': 0.81,
      'message': 'German at 21:00, 40 min. Open the vocabulary sheet.',
      'left': true,
      'minutes_after': 0.3,
      'demo': false,
    },
  ],
};

void main() {
  test(
    'the experiment card sentence comes from the numbers and always shows the sample sizes',
    () {
      final r = ExperimentResults.fromJson(results());
      expect(
        r.headline,
        'Tested 3 nudge styles on Instagram. Nudges with your next task work best: '
        'you left 7 of 9 times vs 3 of 8 for nudges with what the time costs. Sending more of them.',
      );
      final open = ExperimentResults.fromJson(results(best: null));
      expect(open.headline, contains('Not enough to pick a winner yet'));
      expect(open.headline, contains('nudges with what the time costs 3 of 8'));
    },
  );

  test(
    'a strategy update in a reply is parsed, also from a tool round',
    () async {
      var n = 0;
      final server = FakeServer(
        (r) => ok(
          r,
          agent: (_) => ++n == 1
              ? {
                  ...calls([
                    ('get_calendar', {'date': '2026-10-28'}),
                  ]),
                  'strategy_update': {
                    'version': 3,
                    'changes': ['Cut Instagram limit 30 to 20'],
                  },
                }
              : text('Done.'),
        ),
      );
      final reply = await sessionFor(
        server,
        FakeTools(),
        mode: 'review',
      ).send('Review my day.');
      expect(reply.strategyUpdate?.version, 3);
      expect(reply.strategyUpdate?.changes, ['Cut Instagram limit 30 to 20']);
    },
  );

  group('get_calendar', () {
    DeviceToolRunner runner(List<CalendarEntry>? events) => DeviceToolRunner(
      tasks: MemoryTaskStore(),
      limits: MemoryLimitStore(),
      alarms: _NoAlarms(),
      enforcer: _NoLimits(),
      calendar: (_) async => events,
    );

    test('returns the events of the day', () async {
      final r = await runner(const [
        CalendarEntry(title: 'Lecture', start: '10:00', end: '12:00'),
        CalendarEntry(
          title: 'Holiday',
          start: '00:00',
          end: '23:59',
          allDay: true,
        ),
      ]).run('get_calendar', {'date': '2026-10-28'});
      expect(r['ok'], isTrue);
      expect(r['access'], isTrue);
      expect(r['events'], [
        {'title': 'Lecture', 'start': '10:00', 'end': '12:00'},
        {'title': 'Holiday', 'start': '00:00', 'end': '23:59', 'all_day': true},
      ]);
    });

    test('says when access is off, and checks the date', () async {
      final off = await runner(
        null,
      ).run('get_calendar', {'date': '2026-10-28'});
      expect(off['access'], isFalse);
      expect(off['note'], contains('Plan without it'));
      final bad = await runner(
        const [],
      ).run('get_calendar', {'date': 'tomorrow'});
      expect(bad['ok'], isFalse);
    });
  });

  group('session reminders', () {
    test(
      '"whenever I am 30 minutes on an app, remind me to do 10 push-ups" is saved and sent to the watcher',
      () async {
        final env = Env();
        final tools = env.services.tools;
        var r = await tools.run('set_session_rule', {
          'app': 'any',
          'minutes': 30,
          'ask': 'do 10 push-ups',
        });
        expect(r['ok'], isTrue);
        expect(env.native.rules!.single.ask, 'do 10 push-ups');
        r = await tools.run('set_session_rule', {
          'app': 'any',
          'minutes': 20,
          'ask': 'stretch',
        });
        expect(
          (await env.services.rules.all()).single.minutes,
          20,
          reason: 'replaces',
        );
        r = await tools.run('set_session_rule', {
          'app': 'Snapchat',
          'minutes': 15,
          'ask': 'drink water',
        });
        expect(r['enforced'], isFalse);
        expect(r['warning'], contains('not found'));
        r = await tools.run('remove_session_rule', {'app': 'any'});
        expect(r['ok'], isTrue);
        expect(env.native.rules!.map((x) => x.app), ['Snapchat']);
        r = await tools.run('remove_session_rule', {'app': 'TikTok'});
        expect(r['ok'], isFalse);
        r = await tools.run('set_session_rule', {
          'app': 'any',
          'minutes': 2,
          'ask': 'x',
        });
        expect(r['ok'], isFalse);
      },
    );

    testWidgets('settings list the reminders, and one can be removed', (
      t,
    ) async {
      t.view.physicalSize = const Size(1080, 5200);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      final env = Env(profile: {'apps': <String>[]});
      await env.services.rules.set(
        const SessionRule(app: 'any', minutes: 30, ask: 'do 10 push-ups'),
      );
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(services: env.services, profile: const Profile()),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Do 10 push-ups'), findsOneWidget);
      expect(find.text('After 30 min in a row on any app'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('rule-remove-any')));
      await t.pump();
      await t.tap(find.byKey(const Key('rule-remove-any')));
      await t.pumpAndSettle();
      expect(await env.services.rules.all(), isEmpty);
      expect(env.native.rules, isEmpty);
    });
  });

  testWidgets(
    'home: experiments are offered, and turning them on tells the watcher and shows the results',
    (t) async {
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      final env = Env(
        profile: {
          'wake': '07:00',
          'sleep': '23:30',
          'apps': ['Instagram'],
        },
        experimentResults: results(),
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('experiment-offer')), findsOneWidget);
      await t.tap(find.byKey(const Key('experiment-enable')));
      await t.pumpAndSettle();
      expect(env.native.experiments, (enabled: true, demo: false));
      expect(find.byKey(const Key('experiment-results')), findsOneWidget);
      expect(find.textContaining('you left 7 of 9 times'), findsOneWidget);
      expect(find.text('left 3 of 8 · 5% likely best'), findsOneWidget);
      expect(find.text('Early signal'), findsOneWidget);
      expect(find.textContaining('one person'), findsOneWidget);
      expect(
        find.textContaining('Life\'s choices: you left 64% of the time'),
        findsOneWidget,
      );
      expect(
        find.textContaining('+23 points (90% range +5 to +38)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Instagram · night: nudges with your next task lead (12 hits)',
        ),
        findsOneWidget,
      );

      await t.ensureVisible(find.byKey(const Key('open-lab')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('open-lab')));
      await t.pumpAndSettle();
      expect(find.byType(LabNotebookPage), findsOneWidget);
      expect(find.textContaining('contextual Thompson'), findsOneWidget);
      expect(
        find.text(
          '"Ayoub, the thesis chapter you wanted is one hour of focus."',
        ),
        findsOneWidget,
      );
      expect(find.text('Testing: picked with a 12% chance'), findsOneWidget);
      expect(
        find.text(
          'You stayed 9 more min. This style gets picked less here; trying others.',
        ),
        findsOneWidget,
      );
      expect(find.text('Current best here (81% chance)'), findsOneWidget);
      expect(
        find.text('You left the app. This style gets picked more here.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'home: the newest strategy shows what changed, and its page compares day 1 with now',
    (t) async {
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
        strategies: [
          strategy(3, '2026-10-30', 3, [
            'Cut Instagram limit 30 to 20',
            'Reduced plan from 5 tasks to 3',
          ]),
          strategy(1, '2026-10-28', 5, []),
        ],
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.text('Strategy v3'), findsOneWidget);
      expect(find.text('Cut Instagram limit 30 to 20'), findsOneWidget);
      await t.tap(find.byKey(const Key('strategy-card')));
      await t.pumpAndSettle();
      expect(find.byType(StrategyPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('then')),
          matching: find.text('Max 5 tasks'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('now')),
          matching: find.text('Max 3 tasks'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('version-1')), findsOneWidget);
    },
  );

  testWidgets('chat: a strategy update shows as a card under the reply', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StrategyUpdateCard(
            update: StrategyUpdate(
              version: 2,
              changes: ['Reduced plan from 5 tasks to 3'],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Strategy updated · v2'), findsOneWidget);
    expect(find.text('Reduced plan from 5 tasks to 3'), findsOneWidget);
  });

  testWidgets(
    'settings: the experiments and demo mode go to the watcher, demo mode gives the distracting apps a stand-in limit, and calendar access is asked',
    (t) async {
      t.view.physicalSize = const Size(1080, 5200);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      final env = Env(profile: {'apps': <String>[]});
      env.native.calendarAccess = false;
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            services: env.services,
            profile: const Profile(apps: ['TikTok']),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('exp-enabled')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('exp-enabled')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('exp-demo')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('exp-demo')));
      await t.pumpAndSettle();
      expect(env.native.experiments, (enabled: true, demo: true));
      expect(env.native.limits, {'TikTok': 30});
      expect(
        await env.services.experimentSettings.load(),
        isA<ExperimentSettings>().having((e) => e.demo, 'demo', isTrue),
      );
      await t.scrollUntilVisible(
        find.byKey(const Key('perm-calendar')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byKey(const Key('perm-calendar')),
          matching: find.text('Allow'),
        ),
      );
      await t.pumpAndSettle();
      expect(env.native.calendarRequests, 1);
    },
  );
}

class _NoAlarms implements AlarmScheduler {
  @override
  Future<bool> schedule({
    required String id,
    required DateTime at,
    required String message,
    bool card = false,
    String? title,
    String? open,
  }) async => true;

  final List<(int, int, String)> phone = [];

  @override
  Future<bool> phoneAlarm({
    required int hour,
    required int minute,
    required String message,
  }) async {
    phone.add((hour, minute, message));
    return true;
  }

  @override
  Future<void> cancel(String id) async {}
}

class _NoLimits implements LimitEnforcer {
  @override
  Future<List<String>> apply(Map<String, int> limits) async => const [];
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/chat/chat_page.dart';
import 'package:life_agent/onboarding/onboarding_page.dart';
import 'package:life_agent/onboarding/onboarding_store.dart';
import 'package:life_agent/ui/home_page.dart';
import 'package:life_agent/ui/last_night.dart';
import 'package:life_agent/ui/settings_page.dart';

import 'home_settings_test.dart' show Env;

void main() {
  test('the day ends at 05:00: at 01:30 it is still the evening before', () {
    expect(isoDate(logicalDay(DateTime(2026, 10, 29, 1, 30))), '2026-10-28');
    expect(isoDate(logicalDay(DateTime(2026, 10, 29, 4, 59))), '2026-10-28');
    expect(isoDate(logicalDay(DateTime(2026, 10, 29, 5, 0))), '2026-10-29');
    final late = Env(hour: 1);
    expect(late.services.today, '2026-10-26');
    expect(
      late.services.tomorrow,
      '2026-10-27',
      reason: 'planning at 01:15 plans the day that is about to start',
    );
  });

  test('last night, next to the chosen sleep time (phone use, not sleep)', () {
    const night = PhoneNight(night: '2026-10-28', down: '03:12');
    expect(
      lastNightLine(night, '23:00'),
      'Last night your phone went quiet at 03:12. Don\'t worry, we\'ll fix this together.',
    );
    expect(
      lastNightLine(const PhoneNight(night: 'x', down: '22:40'), '23:00'),
      contains('Right on time'),
    );
    expect(
      lastNightLine(const PhoneNight(night: 'x', down: '23:20'), '23:00'),
      'Last night your phone went quiet at 23:20, close to 23:00.',
    );
  });

  testWidgets(
    'onboarding: Lify shows when the phone went quiet last night next to the sleep time, and sets the evening reminder',
    (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.75;
      addTearDown(t.view.reset);
      final env = Env(profile: {'apps': <String>[]});
      (env.services.onboarding as MemoryOnboardingStore).isDone = false;
      await t.pumpWidget(
        MaterialApp(
          home: OnboardingGate(
            services: env.services,
            child: const Scaffold(body: Text('home')),
          ),
        ),
      );
      await t.pumpAndSettle();
      Future<void> next() async {
        await t.tap(find.byKey(const Key('ob-next')));
        await t.pumpAndSettle();
      }

      await next();
      await t.enterText(find.byKey(const Key('ob-name')), 'Jake');
      await t.pumpAndSettle();
      await next();
      await next();
      await next();
      expect(
        find.text(
          'Last night your phone went quiet at 03:12. Don\'t worry, we\'ll fix this together.',
        ),
        findsOneWidget,
      );
      await next();
      expect(env.native.eveningSleep, '23:00');
    },
  );

  testWidgets(
    'the evening reminder opens the app straight on "Plan tomorrow"',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:00', 'apps': <String>[]},
      );
      env.native.launchAction = 'plan';
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.text('Plan tomorrow'), findsWidgets);
      expect(env.native.eveningSleep, '23:00');
      expect(env.native.launchAction, isNull, reason: 'taken once');
    },
  );

  testWidgets(
    'planning uploads last nights\' phone-down times with the screen time',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:00', 'apps': <String>[]},
      );
      final c = await env.services.planningChat(const Profile());
      await c.send('Plan tomorrow');
      final usage = [
        for (final r in env.server.agentCalls)
          if (r.json['action'] == 'usage') r.json,
      ];
      expect(usage.any((u) => u['nights'] != null), isTrue);
      expect(
        (usage.firstWhere((u) => u['nights'] != null)['nights'] as List).single,
        {'night': '2026-10-26', 'down': '03:12', 'up': '10:40'},
      );
      c.dispose();
    },
  );

  testWidgets(
    'Settings > Check Lify says what is wrong in plain words: here, the watcher had no session for a nudge',
    (t) async {
      t.view.physicalSize = const Size(1080, 7000);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      final env = Env(profile: {'apps': <String>[]});
      env.native.status = {
        ...env.native.status,
        'running': false,
        'limits': <String>[],
        'lastProblem': 'no_session',
        'lastProblemAt': 0,
      };
      await t.pumpWidget(
        MaterialApp(
          home: SettingsPage(services: env.services, profile: const Profile()),
        ),
      );
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.byKey(const Key('check-run')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const Key('check-run')));
      await t.pumpAndSettle();
      expect(find.text('Lify answers'), findsOneWidget);
      expect(find.textContaining('no app to watch'), findsOneWidget);
      expect(find.textContaining('could not use your session'), findsOneWidget);
      expect(find.byKey(const Key('check-start-over')), findsNothing);
    },
  );
}

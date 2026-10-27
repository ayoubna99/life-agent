import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/onboarding/onboarding_page.dart';
import 'package:life_agent/onboarding/onboarding_store.dart';

import 'home_settings_test.dart' show Env;

void main() {
  group('reality check', () {
    test('averages the full days, leaves today out, and ranks the apps', () {
      final r = RealityCheck.from(const [
        UsageRow(day: '2026-10-25', app: 'TikTok', minutes: 120),
        UsageRow(day: '2026-10-25', app: 'YouTube', minutes: 60),
        UsageRow(day: '2026-10-26', app: 'TikTok', minutes: 80),
        UsageRow(day: '2026-10-26', app: 'Instagram', minutes: 40),
        UsageRow(day: '2026-10-27', app: 'TikTok', minutes: 500),
      ], today: '2026-10-27');
      expect(r.days, 2);
      expect(r.minutesPerDay, 150);
      expect(r.topApps, [('TikTok', 100), ('YouTube', 30), ('Instagram', 20)]);
      expect(r.daysPerYear.round(), 38);
      expect(r.shareOfWakingDay, closeTo(150 / 960, 0.001));
    });

    test('with only today it uses today, and with nothing it is empty', () {
      final r = RealityCheck.from(const [
        UsageRow(day: '2026-10-27', app: 'TikTok', minutes: 70),
      ], today: '2026-10-27');
      expect(r.minutesPerDay, 70);
      expect(RealityCheck.from(const [], today: '2026-10-27').empty, isTrue);
    });

    test('formats hours and minutes', () {
      expect(hoursAndMinutes(45), '45m');
      expect(hoursAndMinutes(120), '2h');
      expect(hoursAndMinutes(135), '2h 15m');
    });
  });

  Future<Env> open(WidgetTester t, {bool usage = true}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    final env = Env(profile: {'apps': <String>[]});
    env.native.usageAccess = usage;
    env.native.usage = const [
      UsageRow(day: '2026-10-26', app: 'TikTok', minutes: 150),
      UsageRow(day: '2026-10-26', app: 'YouTube', minutes: 60),
      UsageRow(day: '2026-10-26', app: 'Maps', minutes: 10),
      UsageRow(day: '2026-10-26', app: 'Notes', minutes: 5),
    ];
    final store = env.services.onboarding as MemoryOnboardingStore;
    store.isDone = false;
    await t.pumpWidget(
      MaterialApp(
        home: OnboardingGate(
          services: env.services,
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await t.pumpAndSettle();
    return env;
  }

  Future<void> next(WidgetTester t) async {
    await t.tap(find.byKey(const Key('ob-next')));
    await t.pumpAndSettle();
  }

  testWidgets(
    'the slides walk from hello to Lify, then save the name, times and apps and open the home',
    (t) async {
      final env = await open(t);
      expect(find.byKey(const Key('ob-logo')), findsOneWidget);
      expect(find.text('Ready to get your life back?'), findsOneWidget);
      await next(t);

      // the name is required
      await next(t);
      expect(find.byKey(const Key('ob-name')), findsOneWidget);
      await t.enterText(find.byKey(const Key('ob-name')), '  Mo ');
      await t.pumpAndSettle();
      expect(find.text('Hi Mo. Good to have you here.'), findsOneWidget);
      await next(t);

      // permissions show what is on
      expect(
        find.descendant(
          of: find.byKey(const Key('ob-perm-usage')),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      await next(t);

      // the real numbers, and the three biggest apps chosen
      expect(find.text('3h 45m'), findsOneWidget);
      expect(find.textContaining('57 full days a year'), findsOneWidget);
      await t.tap(find.byKey(const Key('ob-app-Maps')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('ob-app-Notes')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('ob-app-Notes')));
      await t.pumpAndSettle();
      await next(t);

      // Lify says hello by name, out loud too
      expect(find.byKey(const Key('ob-lify')), findsOneWidget);
      expect(find.text('Hi Mo, I\'m Lify.'), findsWidgets);
      expect(env.speaker.spoken.single, contains('Lify'));
      await next(t);

      expect(find.text('home'), findsOneWidget);
      expect(env.saved, {
        'wake': '07:00',
        'sleep': '23:00',
        'apps': ['TikTok', 'YouTube', 'Notes'],
        'name': 'Mo',
      });
      final store = env.services.onboarding as MemoryOnboardingStore;
      expect(store.isDone, isTrue);
      expect(store.firstName, 'Mo');
    },
  );

  testWidgets('without usage access the reality check asks for it', (t) async {
    final env = await open(t, usage: false);
    await next(t);
    await t.enterText(find.byKey(const Key('ob-name')), 'Mo');
    await t.pumpAndSettle();
    await next(t);
    expect(find.text('Skip for now'), findsOneWidget);
    await next(t);
    await t.tap(find.byKey(const Key('ob-reality-allow')));
    expect(env.native.usageSettingsOpened, 1);
  });

  testWidgets(
    'offline, the slides still finish and keep the name on the phone',
    (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.75;
      addTearDown(t.view.reset);
      final env = Env(offline: true);
      final store = env.services.onboarding as MemoryOnboardingStore;
      store.isDone = false;
      await t.pumpWidget(
        MaterialApp(
          home: OnboardingGate(
            services: env.services,
            child: const Scaffold(body: Text('home')),
          ),
        ),
      );
      await t.pumpAndSettle();
      await next(t);
      await t.enterText(find.byKey(const Key('ob-name')), 'Mo');
      await t.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await next(t);
      }
      expect(find.text('home'), findsOneWidget);
      expect(store.firstName, 'Mo');
    },
  );

  testWidgets('once done, the app opens straight on the home', (t) async {
    final env = Env();
    await t.pumpWidget(
      MaterialApp(
        home: OnboardingGate(
          services: env.services,
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.byKey(const Key('onboarding')), findsNothing);
  });
}

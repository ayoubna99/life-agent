// Renders the main screens to PNG (with the real fonts) for review. Not part of the normal test run:
//   flutter test screens/screens_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/chat/chat_page.dart';
import 'package:life_agent/device/stores.dart';
import 'package:life_agent/onboarding/onboarding_page.dart';
import 'package:life_agent/onboarding/onboarding_store.dart';
import 'package:life_agent/ui/home_page.dart';
import 'package:life_agent/ui/motion.dart';
import 'package:life_agent/ui/settings_page.dart';
import 'package:life_agent/ui/theme.dart';

import 'package:life_agent/platform/experiment_settings.dart';
import 'package:life_agent/ui/learning.dart';

import '../test/home_settings_test.dart' show Env, plan;
import '../test/learning_test.dart' show results, strategy;

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

Future<void> _images(WidgetTester t) async {
  await t.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e);
    }
  });
  await t.pump();
}

void main() {
  setUpAll(() async {
    Ambient.enabled = false;
    await _font('Jakarta', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'])
        'assets/fonts/PlusJakartaSans-$w.ttf',
    ]);
    await _font('Fraunces', [
      for (final w in ['Medium', 'SemiBold', 'Bold'])
        'assets/fonts/Fraunces-$w.ttf',
    ]);
    final sdk = Platform.environment['FLUTTER_ROOT']!;
    await _font('MaterialIcons', [
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]);
  });

  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 2.7;
    addTearDown(t.view.reset);
  }

  Widget app(Widget home, {Brightness b = Brightness.light}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: lifeTheme(Brightness.light),
    darkTheme: lifeTheme(Brightness.dark),
    themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
    home: home,
  );

  Future<void> shot(WidgetTester t, String name) async {
    await _images(t);
    await t.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('out/$name.png'),
    );
  }

  testWidgets('onboarding', (t) async {
    phone(t);
    final env = Env(profile: {'apps': <String>[]});
    env.native.notifications = false;
    env.native.overlay = false;
    env.native.usage = const [
      UsageRow(day: '2026-10-25', app: 'TikTok', minutes: 140),
      UsageRow(day: '2026-10-25', app: 'Instagram', minutes: 75),
      UsageRow(day: '2026-10-25', app: 'YouTube', minutes: 50),
      UsageRow(day: '2026-10-26', app: 'TikTok', minutes: 120),
      UsageRow(day: '2026-10-26', app: 'Instagram', minutes: 65),
      UsageRow(day: '2026-10-26', app: 'WhatsApp', minutes: 30),
      UsageRow(day: '2026-10-26', app: 'Chrome', minutes: 22),
    ];
    (env.services.onboarding as MemoryOnboardingStore).isDone = false;
    await t.pumpWidget(
      app(OnboardingGate(services: env.services, child: const SizedBox())),
    );
    await t.pumpAndSettle();
    await shot(t, '1_welcome');
    Future<void> next() async {
      await t.tap(find.byKey(const Key('ob-next')));
      await t.pumpAndSettle();
    }

    await next();
    await t.enterText(find.byKey(const Key('ob-name')), 'Mohamed');
    await shot(t, '2_name');
    await next();
    await shot(t, '3_permissions');
    await next();
    await shot(t, '4_reality');
    await next();
    await shot(t, '5_lify');
  });

  Future<Env> home(
    WidgetTester t, {
    int hour = 20,
    bool tomorrow = true,
    bool tasks = true,
  }) async {
    final env = Env(
      profile: {
        'wake': '07:00',
        'sleep': '23:30',
        'apps': <String>[],
        'name': 'Mohamed',
      },
      plan: tomorrow ? plan(2) : null,
      hour: hour,
    );
    if (tasks) {
      await env.tasks.upsert(
        const LocalTask(
          id: '1',
          date: '2026-10-27',
          title: 'Gym',
          minutes: 60,
          startTime: '08:00',
          done: true,
        ),
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '2',
          date: '2026-10-27',
          title: 'Study German',
          minutes: 40,
          startTime: '10:00',
          firstStep: 'Open the vocabulary sheet',
        ),
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '3',
          date: '2026-10-27',
          title: 'Call grandma',
          minutes: 20,
          startTime: '18:30',
        ),
      );
      await env.tasks.upsert(
        const LocalTask(
          id: '4',
          date: '2026-10-27',
          title: 'Read 20 pages',
          minutes: 30,
        ),
      );
    }
    return env;
  }

  testWidgets('home morning', (t) async {
    phone(t);
    final env = await home(t, hour: 9, tomorrow: false);
    await t.pumpWidget(app(HomePage(services: env.services)));
    await t.pumpAndSettle();
    await shot(t, '6_home_top');
    await t.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await t.pump();
    await shot(t, '6b_home_scroll120');
    await t.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await shot(t, '7_home_scrolled');
  });

  testWidgets('home evening dark', (t) async {
    phone(t);
    final env = await home(t, hour: 21);
    await t.pumpWidget(
      app(HomePage(services: env.services), b: Brightness.dark),
    );
    await t.pumpAndSettle();
    await t.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await shot(t, '8_home_evening_dark');
  });

  testWidgets('home ready', (t) async {
    phone(t);
    final env = Env(
      profile: {
        'wake': '07:00',
        'sleep': '23:30',
        'apps': <String>[],
        'name': 'Mohamed',
      },
      todayPlan: {...plan(1), 'date': '2026-10-27'},
      hour: 7,
    );
    await t.pumpWidget(app(HomePage(services: env.services)));
    await t.pumpAndSettle();
    await shot(t, '9_home_ready');
  });

  testWidgets('chat', (t) async {
    phone(t);
    final env = await home(t);
    final c = await env.services.planningChat(const Profile());
    await t.pumpWidget(
      app(ChatPage(title: 'Plan tomorrow', controller: c, opener: env.opener)),
    );
    await t.pumpAndSettle();
    await shot(t, '10_chat_empty');
    await t.enterText(
      find.byKey(const Key('input')),
      'Gym at 8, then German for 40 minutes',
    );
    await t.tap(find.byKey(const Key('send')));
    await t.pumpAndSettle();
    await shot(t, '11_chat');
  });

  testWidgets('settings', (t) async {
    phone(t);
    final env = await home(t);
    await t.pumpWidget(
      app(
        SettingsPage(
          services: env.services,
          profile: const Profile(
            wake: '07:00',
            sleep: '23:30',
            apps: ['TikTok', 'Instagram'],
            name: 'Mohamed',
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await shot(t, '12_settings');
  });

  testWidgets('learning', (t) async {
    phone(t);
    final history = [
      strategy(3, '2026-10-30', 3, [
        'Cut Instagram limit 30 to 20',
        'Reduced plan from 5 tasks to 3',
      ]),
      strategy(2, '2026-10-29', 4, [
        'Moved study to 09:00-12:00 (3 of 3 done there)',
      ]),
      strategy(1, '2026-10-28', 5, []),
    ];
    final env = Env(
      profile: {
        'wake': '07:00',
        'sleep': '23:30',
        'apps': <String>['Instagram'],
        'name': 'Mohamed',
      },
      strategies: history,
      experimentResults: results(),
      hour: 21,
    );
    await env.services.experimentSettings.save(
      const ExperimentSettings(enabled: true),
    );
    await t.pumpWidget(app(HomePage(services: env.services)));
    await t.pumpAndSettle();
    await t.drag(find.byType(CustomScrollView), const Offset(0, -1150));
    await shot(t, '13_learning');
    await t.pumpWidget(
      app(
        StrategyPage(history: [for (final h in history) Strategy.fromJson(h)]),
      ),
    );
    await t.pumpAndSettle();
    await shot(t, '14_strategy_page');
    await t.pumpWidget(
      app(
        const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: StrategyUpdateCard(
                update: StrategyUpdate(
                  version: 3,
                  changes: [
                    'Cut Instagram limit 30 to 20',
                    'Reduced plan from 5 tasks to 3',
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await shot(t, '15_strategy_updated');
    await t.pumpWidget(app(LabNotebookPage(results: ExperimentResults.fromJson(results()))));
    await t.pumpAndSettle();
    await shot(t, '16_lab_notebook');
  });
}

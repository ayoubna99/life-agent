import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/device/stores.dart';
import 'package:life_agent/ui/home_page.dart';
import 'package:life_agent/ui/task_page.dart';

import 'home_settings_test.dart' show Env;

const pdf =
    'https://proj.supabase.co/storage/v1/object/sign/materials/u/2026-10-27-chapter-3.pdf?token=abc';
const book = 'https://www.gutenberg.org/ebooks/1342';

const reading = LocalTask(
  id: 'r1',
  date: '2026-10-27',
  title: 'Read Pride and Prejudice',
  minutes: 45,
  startTime: '21:00',
  firstStep: 'Open chapter 3',
  instructions: ['Read chapters 3 and 4', 'Note one quote you like'],
  links: [book, pdf],
  notes: 'You wanted the free edition; chapters 3-4 tonight, 5-6 tomorrow.',
);

void main() {
  test(
    'links are sorted into PDFs, pictures and web pages by their address',
    () {
      expect(linkKind(pdf), LinkKind.pdf);
      expect(linkKind('https://x.co/a/card.webp?token=1'), LinkKind.image);
      expect(linkKind(book), LinkKind.web);
    },
  );

  testWidgets(
    'the task screen has everything decided in the chat: first step, notes, steps, the book and the study sheet',
    (t) async {
      t.view.physicalSize = const Size(1080, 3000);
      t.view.devicePixelRatio = 2.7;
      addTearDown(t.view.reset);
      final env = Env();
      await env.tasks.upsert(reading);
      var done = false;
      await t.pumpWidget(
        MaterialApp(
          home: TaskPage(
            task: reading,
            opener: env.opener,
            ringing: true,
            onDone: () async => done = true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('IT\'S TIME'), findsOneWidget);
      expect(find.text('Open chapter 3'), findsOneWidget);
      expect(find.textContaining('free edition'), findsOneWidget);
      expect(find.text('Note one quote you like'), findsOneWidget);
      expect(find.text('Study sheet (PDF)'), findsOneWidget);
      expect(find.text('gutenberg.org'), findsOneWidget);
      await t.tap(find.byKey(const Key('task-link-$book')));
      expect(env.opener.opened.single, book);
      await t.tap(find.byKey(const Key('task-done')));
      await t.pumpAndSettle();
      expect(done, isTrue);
    },
  );

  testWidgets(
    'an in-app alarm opens the app on that task\'s screen and stops the alarm sound',
    (t) async {
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:30', 'apps': <String>[]},
      );
      await env.tasks.upsert(reading);
      env.native.launchAction = 'task:r1';
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      expect(find.byType(TaskPage), findsOneWidget);
      expect(find.text('Read Pride and Prejudice'), findsWidgets);
      expect(env.native.alarmSoundStops, 1);
      await t.tap(find.byKey(const Key('task-done')));
      await t.pumpAndSettle();
      expect((await env.tasks.forDate('2026-10-27')).single.done, isTrue);
    },
  );

  test(
    'the agent picks the alarm: a real phone alarm for the gym, an in-app alarm that opens the reading task',
    () async {
      final env = Env(hour: 8);
      final tools = env.services.tools;
      await tools.run('create_task', {
        'title': 'Read Pride and Prejudice',
        'minutes': 45,
        'start_time': '21:00',
        'links': [pdf],
        'notes': 'Chapters 3-4',
      });
      final saved = (await env.tasks.forDate('2026-10-27')).single;
      expect(saved.notes, 'Chapters 3-4');
      expect(saved.links.single, pdf);

      var r = await tools.run('schedule_alarm', {
        'time': '17:45',
        'message': 'Gym in 15 minutes',
        'kind': 'phone',
      });
      expect(r['kind'], 'phone');
      expect(env.native.phoneAlarms.single, (17, 45, 'Gym in 15 minutes'));

      r = await tools.run('schedule_alarm', {
        'time': '21:00',
        'message': 'Time to read',
        'kind': 'in_app',
        'task_title': 'Read Pride and Prejudice',
      });
      expect(r['opens_task'], isTrue);
      expect(env.native.alarmOpens.last, 'task:${saved.id}');
      expect(env.native.alarmCards.last, isTrue);

      r = await tools.run('schedule_alarm', {
        'time': '21:00',
        'message': 'x',
        'kind': 'siren',
      });
      expect(r['ok'], isFalse);
    },
  );

  testWidgets(
    '"Evening reminder (test)": Lify writes it, it comes in 30 seconds, and tapping it opens planning',
    (t) async {
      t.view.physicalSize = const Size(900, 3400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final env = Env(
        profile: {'wake': '07:00', 'sleep': '23:00', 'apps': <String>[]},
      );
      await t.pumpWidget(MaterialApp(home: HomePage(services: env.services)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('test-evening')));
      await t.pump();
      await t.tap(find.byKey(const Key('test-evening')));
      await t.pumpAndSettle();
      final (id, at, message) = env.native.alarms.single;
      expect(id, 'test-evening');
      expect(message, 'Hey Mo, let\'s make our plans for tomorrow.');
      expect(env.native.alarmOpens.single, 'plan');
      expect(
        (at - DateTime.now().millisecondsSinceEpoch) / 1000,
        inInclusiveRange(27, 31),
      );
      expect(find.textContaining('In 30 seconds'), findsOneWidget);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/models.dart';
import 'package:life_agent/device/device_runner.dart';
import 'package:life_agent/device/stores.dart';

class FakeAlarms implements AlarmScheduler {
  final List<(DateTime, String)> set = [];
  bool allow = true;
  final List<String> cancelled = [];
  final List<String> scheduled = [];

  @override
  Future<bool> schedule({
    required String id,
    required DateTime at,
    required String message,
    bool card = false,
    String? title,
    String? open,
  }) async {
    if (allow) {
      set.add((at, message));
      scheduled.add(id);
    }
    return allow;
  }

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
  Future<void> cancel(String id) async => cancelled.add(id);
}

class FakeEnforcer implements LimitEnforcer {
  List<String> notFound = [];
  Map<String, int>? last;

  @override
  Future<List<String>> apply(Map<String, int> limits) async {
    last = limits;
    return notFound;
  }
}

void main() {
  final now = DateTime(2026, 10, 28, 8, 30);
  late MemoryTaskStore tasks;
  late MemoryLimitStore limits;
  late FakeAlarms alarms;
  late FakeEnforcer enforcer;
  late DeviceToolRunner run;
  var n = 0;

  setUp(() {
    tasks = MemoryTaskStore();
    limits = MemoryLimitStore();
    alarms = FakeAlarms();
    enforcer = FakeEnforcer();
    n = 0;
    run = DeviceToolRunner(
      tasks: tasks,
      limits: limits,
      alarms: alarms,
      enforcer: enforcer,
      now: () => now,
      newId: () => 't${++n}',
    );
  });

  test(
    'create_task puts the task on today\'s list with everything the agent gave',
    () async {
      final r = await run.run('create_task', {
        'title': 'Study German',
        'minutes': 40,
        'first_step': 'Open the sheet',
        'instructions': ['Read page 1', 'Do the exercises'],
        'links': ['https://x/a.pdf'],
        'start_time': '19:00',
      });
      expect(r, {'ok': true, 'task_id': 't1'});
      final saved = (await tasks.forDate('2026-10-28')).single;
      expect(saved.title, 'Study German');
      expect(saved.minutes, 40);
      expect(saved.instructions, hasLength(2));
      expect(saved.links.single, 'https://x/a.pdf');
      expect(saved.startTime, '19:00');
      expect(saved.done, isFalse);
    },
  );

  test(
    'running the morning plan twice never duplicates a task, and a ticked task stays ticked',
    () async {
      await run.run('create_task', {'title': 'Gym', 'minutes': 60});
      final first = (await tasks.forDate('2026-10-28')).single;
      await tasks.setDone(first.id, true);
      await run.run('create_task', {'title': 'gym', 'minutes': 45});
      final all = await tasks.forDate('2026-10-28');
      expect(all, hasLength(1));
      expect(all.single.minutes, 45);
      expect(all.single.done, isTrue);
    },
  );

  test(
    'bad task arguments are answered in words, and nothing is saved',
    () async {
      Future<String> err(Map<String, Object?> a) async =>
          (await run.run('create_task', a))['error'] as String;
      expect(await err({'minutes': 20}), contains('title'));
      expect(await err({'title': 'x', 'minutes': 2}), contains('5 to 480'));
      expect(await err({'title': 'x', 'minutes': 20.5}), contains('minutes'));
      expect(
        await err({'title': 'x', 'minutes': 20, 'start_time': '7pm'}),
        contains('HH:MM'),
      );
      expect(
        await err({'title': 'x', 'minutes': 20, 'links': 'https://x'}),
        contains('links'),
      );
      expect(
        await err({
          'title': 'x',
          'minutes': 20,
          'instructions': List.filled(9, 'a'),
        }),
        contains('instructions'),
      );
      expect(await tasks.forDate('2026-10-28'), isEmpty);
    },
  );

  test(
    'set_app_limit saves the limit and hands the whole list to the watcher',
    () async {
      await run.run('set_app_limit', {
        'app': 'Instagram',
        'minutes_per_day': 30,
      });
      final r = await run.run('set_app_limit', {
        'app': 'TikTok',
        'minutes_per_day': 20,
      });
      expect(r, {'ok': true, 'enforced': true});
      expect(enforcer.last, {'Instagram': 30, 'TikTok': 20});
      expect(await limits.all(), {'Instagram': 30, 'TikTok': 20});
    },
  );

  test(
    'a limit for an app that is not on this phone is saved but honestly reported as not enforced',
    () async {
      enforcer.notFound = ['tiktok'];
      final r = await run.run('set_app_limit', {
        'app': 'TikTok',
        'minutes_per_day': 20,
      });
      expect(r['ok'], true);
      expect(r['enforced'], false);
      expect(r['warning'], contains('not found on this phone'));
    },
  );

  test('set_app_limit refuses nonsense', () async {
    expect(
      (await run.run('set_app_limit', {
        'app': '',
        'minutes_per_day': 20,
      }))['ok'],
      false,
    );
    expect(
      (await run.run('set_app_limit', {
        'app': 'X',
        'minutes_per_day': 1,
      }))['error'],
      contains('5 to 720'),
    );
    expect(await limits.all(), isEmpty);
  });

  test('schedule_alarm sets a reminder at that time today', () async {
    final r = await run.run('schedule_alarm', {
      'time': '18:55',
      'message': 'Study German in 5 minutes',
    });
    expect(r['ok'], true);
    expect(alarms.set.single.$1, DateTime(2026, 10, 28, 18, 55));
    expect(alarms.set.single.$2, 'Study German in 5 minutes');
  });

  test(
    'a time that already passed, a bad time and a refusing phone are all reported, never faked',
    () async {
      expect(
        (await run.run('schedule_alarm', {
          'time': '07:00',
          'message': 'x',
        }))['error'],
        contains('already passed'),
      );
      expect(
        (await run.run('schedule_alarm', {
          'time': '25:00',
          'message': 'x',
        }))['error'],
        contains('HH:MM'),
      );
      expect(
        (await run.run('schedule_alarm', {
          'time': '18:00',
          'message': '',
        }))['error'],
        contains('message'),
      );
      alarms.allow = false;
      expect(
        (await run.run('schedule_alarm', {
          'time': '18:00',
          'message': 'x',
        }))['error'],
        contains('permission'),
      );
      expect(alarms.set, isEmpty);
    },
  );

  test('an unknown tool is refused', () async {
    expect((await run.run('delete_everything', {}))['ok'], false);
  });

  test('dates and times are formatted the way the API wants them', () {
    expect(isoDate(DateTime(2026, 1, 5)), '2026-01-05');
    expect(hhmm(DateTime(2026, 1, 5, 7, 3)), '07:03');
  });

  group('a new plan replaces the old one for today', () {
    test(
      'tasks, limits and reminders the new plan no longer has are removed; the ones it still has are kept',
      () async {
        await run.run('create_task', {'title': 'Gym', 'minutes': 60});
        await run.run('create_task', {'title': 'Study', 'minutes': 40});
        await run.run('set_app_limit', {
          'app': 'TikTok',
          'minutes_per_day': 30,
        });
        await run.run('set_app_limit', {
          'app': 'Instagram',
          'minutes_per_day': 20,
        });
        await run.run('schedule_alarm', {
          'time': '18:00',
          'message': 'Gym soon',
        });
        await run.run('schedule_alarm', {
          'time': '19:00',
          'message': 'Study soon',
        });

        // the next morning run applies a changed plan: Study stays, Read is new, Gym and Instagram are gone
        await run.beginRun();
        await run.run('create_task', {'title': 'study', 'minutes': 45});
        await run.run('create_task', {'title': 'Read', 'minutes': 30});
        await run.run('set_app_limit', {
          'app': 'TikTok',
          'minutes_per_day': 25,
        });
        await run.run('schedule_alarm', {
          'time': '19:00',
          'message': 'Study soon',
        });
        await run.endRun();

        expect((await tasks.forDate('2026-10-28')).map((t) => t.title), [
          'study',
          'Read',
        ]);
        expect(await limits.all(), {'TikTok': 25});
        expect(enforcer.last, {'TikTok': 25}, reason: 'the watcher is told');
        expect(
          alarms.cancelled,
          hasLength(1),
          reason: 'only the 18:00 reminder is cancelled',
        );
        expect(alarms.cancelled.single, contains('18:00'));
      },
    );

    test(
      'a task that was ticked off stays even if the new plan does not have it',
      () async {
        await run.run('create_task', {'title': 'Gym', 'minutes': 60});
        await tasks.setDone(
          (await tasks.forDate('2026-10-28')).single.id,
          true,
        );
        await run.beginRun();
        await run.run('create_task', {'title': 'Read', 'minutes': 30});
        await run.endRun();
        expect(
          (await tasks.forDate(
            '2026-10-28',
          )).map((t) => '${t.title}:${t.done}'),
          ['Gym:true', 'Read:false'],
        );
      },
    );

    test('nothing is removed unless a run was started and finished', () async {
      await run.run('create_task', {'title': 'Gym', 'minutes': 60});
      await run.endRun(); // no beginRun: a no-op
      await run
          .beginRun(); // started but never finished (an error in the middle)
      await run.run('create_task', {'title': 'Read', 'minutes': 30});
      expect((await tasks.forDate('2026-10-28')).map((t) => t.title), [
        'Gym',
        'Read',
      ]);
    });

    test('other days are never touched', () async {
      await tasks.upsert(
        const LocalTask(
          id: 'y',
          date: '2026-10-27',
          title: 'Yesterday',
          minutes: 10,
        ),
      );
      await run.beginRun();
      await run.run('create_task', {'title': 'Read', 'minutes': 30});
      await run.endRun();
      expect((await tasks.forDate('2026-10-27')).single.title, 'Yesterday');
    });
  });
}

import 'dart:ui' show PlatformDispatcher;

import 'package:http/http.dart' as http;

import 'agent/agent_api.dart';
import 'agent/agent_session.dart';
import 'agent/auth.dart';
import 'agent/models.dart';
import 'chat/chat_controller.dart';
import 'config.dart';
import 'device/device_runner.dart';
import 'device/next_task.dart';
import 'device/rules.dart';
import 'device/stores.dart';
import 'onboarding/onboarding_store.dart';
import 'platform/native.dart';
import 'platform/cloud_speaker.dart';
import 'platform/services.dart';
import 'platform/experiment_settings.dart';
import 'platform/voice_settings.dart';

/// Everything the screens need, in one place, so a test can swap any piece for a fake.
class AppServices {
  AppServices({
    required this.api,
    required this.tasks,
    required this.limits,
    required this.native,
    required this.picks,
    required this.voice,
    required this.speaker,
    required this.opener,
    required this.voiceSettings,
    this.languageCode = 'en',
    AlarmLog? alarmLog,
    OnboardingStore? onboarding,
    ExperimentSettingsStore? experimentSettings,
    RuleStore? rules,
    this.baseUrl = AppConfig.supabaseUrl,
    this.apiKey = AppConfig.supabaseKey,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       alarmLog = alarmLog ?? MemoryAlarmLog(),
       onboarding = onboarding ?? MemoryOnboardingStore(isDone: true),
       experimentSettings =
           experimentSettings ?? MemoryExperimentSettingsStore(),
       rules = rules ?? MemoryRuleStore();

  factory AppServices.real() {
    final client = http.Client();
    final voiceSettings = PrefsVoiceSettingsStore();
    final languageCode = PlatformDispatcher.instance.locale.languageCode;
    final auth = AnonymousAuth(
      baseUrl: AppConfig.supabaseUrl,
      apiKey: AppConfig.supabaseKey,
      client: client,
      store: PrefsAuthStore(),
    );
    final api = AgentApi(
      baseUrl: AppConfig.supabaseUrl,
      apiKey: AppConfig.supabaseKey,
      client: client,
      auth: auth,
    );
    final native = MethodChannelNative();
    return AppServices(
      api: api,
      tasks: PrefsTaskStore(),
      limits: PrefsLimitStore(),
      native: native,
      picks: DevicePicks(),
      voice: DeviceVoice(),
      // Lify's natural voice (Orpheus on Baseten), the phone's voice as the fallback
      speaker: CloudSpeaker(
        synth: api.speak,
        play: native.playAudio,
        stopPlaying: native.stopAudio,
        settings: voiceSettings,
        fallback: DeviceSpeaker(
          settings: voiceSettings,
          languageCode: languageCode,
        ),
      ),
      opener: DeviceLinks(),
      voiceSettings: voiceSettings,
      languageCode: languageCode,
      alarmLog: PrefsAlarmLog(),
      onboarding: PrefsOnboardingStore(),
      experimentSettings: PrefsExperimentSettingsStore(),
      rules: PrefsRuleStore(),
    );
  }

  final AgentApi api;
  final TaskStore tasks;
  final LimitStore limits;
  final Native native;
  final FilePicks picks;
  final VoiceRecorder voice;
  final Speaker speaker;
  final LinkOpener opener;
  final VoiceSettingsStore voiceSettings;
  final String languageCode;
  final AlarmLog alarmLog;
  final OnboardingStore onboarding;
  final ExperimentSettingsStore experimentSettings;

  /// The user's own reminders ("whenever I am 30 minutes on an app, remind me to do 10 push-ups").
  final RuleStore rules;
  final String baseUrl;
  final String apiKey;
  final DateTime Function() now;

  /// The user's day (it ends at 05:00): planning at 01:00 plans the day that is about to start.
  String get today => isoDate(logicalDay(now()));
  String get tomorrow {
    final d = logicalDay(now());
    return isoDate(DateTime(d.year, d.month, d.day + 1));
  }

  late final AlarmScheduler alarmScheduler = NativeAlarmScheduler(native);

  late final DeviceToolRunner tools = DeviceToolRunner(
    tasks: tasks,
    limits: limits,
    alarms: alarmScheduler,
    enforcer: NativeLimitEnforcer(native),
    alarmLog: alarmLog,
    rules: rules,
    applyRules: (all) async {
      try {
        return await native.applyRules(all);
      } catch (_) {
        return [
          for (final r in all) r.app,
        ]; // the watcher could not be told: report every app as not watched
      }
    },
    calendar: (date) async {
      try {
        return await native.calendarEvents(date);
      } catch (_) {
        return null; // the phone could not read it: the agent plans without it
      }
    },
    now: now,
  );

  late final UsageSync usageSync = UsageSync(
    native: native,
    upload: api.uploadUsage,
    uploadNights: api.uploadNights,
  );

  DateTime? _nightsSentAt;

  /// Sends the phone-down times of the last nights to the server whenever the app is opened (at most every 20
  /// minutes), so Lify knows about last night in any chat. Before, they were only sent when a planning chat started.
  Future<void> syncNights() async {
    final last = _nightsSentAt;
    if (last != null && DateTime.now().difference(last).inMinutes < 20) return;
    _nightsSentAt = DateTime.now();
    try {
      if (!await native.hasUsageAccess()) return;
      final nights = await native.phoneNights();
      if (nights.isNotEmpty) await api.uploadNights(nights);
    } catch (_) {
      _nightsSentAt = null; // try again next time
    }
  }

  /// The evening chat: plan tomorrow.
  Future<ChatController> planningChat(Profile profile) async => _chat(
    AgentSession(
      api: api,
      tools: tools,
      mode: 'planning',
      today: today,
      date: tomorrow,
    ),
    profile,
  );

  /// The morning run: the agent applies today's plan on this phone.
  Future<ChatController> executeChat(Profile profile) async => _chat(
    AgentSession(
      api: api,
      tools: tools,
      mode: 'execute',
      today: today,
      date: today,
    ),
    profile,
  );

  /// The evening review: compares today's plan with what happened, then adapts tomorrow's.
  Future<ChatController> reviewChat(Profile profile) async {
    final todays = await tasks.forDate(today);
    final report = {
      'done': [
        for (final t in todays)
          if (t.done) t.title,
      ],
      'missed': [
        for (final t in todays)
          if (!t.done) t.title,
      ],
    };
    return _chat(
      AgentSession(
        api: api,
        tools: tools,
        mode: 'review',
        today: today,
        date: tomorrow,
        report: report,
      ),
      profile,
    );
  }

  ChatController _chat(AgentSession session, Profile profile) => ChatController(
    session: session,
    api: api,
    picks: picks,
    voice: voice,
    speaker: speaker,
    voiceSettings: voiceSettings,
    usage: session.mode == 'execute' ? null : usageSync,
    keywords: profile.apps,
    // Once tomorrow is planned, a reminder wakes the person at their wake-up time (no tasks are shown before then).
    onPlanSaved: session.mode == 'execute'
        ? null
        : () => scheduleMorning(profile),
  );

  /// The good-morning reminder: tomorrow at the wake-up time (07:00 if none is set). Tapping it opens the app.
  Future<bool> scheduleMorning(Profile profile) {
    final wake = profile.wake ?? '07:00';
    final n = now();
    final at = DateTime(
      n.year,
      n.month,
      n.day + 1,
      int.parse(wake.substring(0, 2)),
      int.parse(wake.substring(3)),
    );
    return alarmScheduler.schedule(
      id: 'morning-${isoDate(at)}',
      at: at,
      message: 'Good morning. Your plan is ready: tap to start your day.',
    );
  }

  /// "Task alarm (test)": in 10 seconds the next task's in-app alarm rings and its screen opens (leave the app to see it).
  Future<String> testNextTask() async {
    final task = nextTask(await tasks.forDate(today), now());
    if (task == null) {
      return 'There is no task left today. Plan one, then try again.';
    }
    final ok = await alarmScheduler.schedule(
      id: 'test-next',
      at: DateTime.now().add(const Duration(seconds: 10)),
      message: 'It\'s time: ${task.title}',
      card: true,
      title: task.title,
      open: 'task:${task.id}',
    );
    return ok
        ? 'In 10 seconds the alarm for "${task.title}" rings and its screen opens. Leave the app now to test.'
        : 'The phone did not allow reminders. Turn on "Alarms and reminders" in Settings.';
  }

  /// "Evening reminder (test)": in 30 seconds, the evening reminder Lify writes for you ("let's make our plans for
  /// tomorrow"), even if tomorrow is already planned. Tapping it opens "Plan tomorrow".
  Future<String> testEvening() async {
    String? text;
    Object? problem;
    try {
      final todays = await tasks.forDate(today);
      text = await api.evening(
        today: today,
        tomorrow: tomorrow,
        now: hhmm(now()),
        done: [
          for (final t in todays)
            if (t.done) t.title,
        ],
        missed: [
          for (final t in todays)
            if (!t.done) t.title,
        ],
        test: true,
      );
    } catch (e) {
      problem = e;
    }
    if (text == null) {
      return 'Lify could not write the reminder (${problem == null ? 'no text' : _code(problem)}), so none was made. Settings > Check Lify shows why.';
    }
    final ok = await alarmScheduler.schedule(
      id: 'test-evening',
      at: DateTime.now().add(const Duration(seconds: 30)),
      message: text,
      title: 'Lify',
      open: 'plan',
    );
    return ok
        ? 'In 30 seconds Lify\'s evening notification arrives (tap it to plan tomorrow). Lock the phone or open another app.'
        : 'The phone did not allow reminders. Turn on "Alarms and reminders" in Settings.';
  }

  /// "Nudge card (test)": a real nudge written by Lify for the app you use most (as if you were 45 minutes into it),
  /// shown as the card on top of other apps in 10 seconds. If Lify cannot be reached, nothing is shown: there are no
  /// fixed messages.
  Future<String> testNudgeCard({List<String> distracting = const []}) async {
    final app = distracting.isNotEmpty
        ? distracting.first
        : ((await limits.all()).keys.firstOrNull ?? 'Instagram');
    final n = now();
    String text;
    try {
      final todays = await tasks.forDate(today);
      text = (await api.nudge(
        today: today,
        now: hhmm(n),
        app: app,
        usedMinutes: 45,
        limitMinutes: 30,
        reason: 'over',
        done: [
          for (final t in todays)
            if (t.done) t.title,
        ],
      )).text;
    } catch (e) {
      return 'Lify could not write the card (${_code(e)}), so none was made. Settings > Check Lify shows why.';
    }
    final ok = await alarmScheduler.schedule(
      id: 'test-card',
      at: DateTime.now().add(const Duration(seconds: 10)),
      message: text,
      card: true,
      title: '45 min on $app',
    );
    return ok
        ? 'In 10 seconds Lify\'s card appears. Open another app now to test.'
        : 'The phone did not allow reminders. Turn on "Alarms and reminders" in Settings.';
  }

  static String _code(Object e) =>
      e is AgentException ? e.code : e.runtimeType.toString();

  /// Settings > Check Lify: whether the server answers for this user, and what the background watcher is doing.
  Future<LifyCheck> check() async {
    String? user;
    String server;
    try {
      user = await api.userId;
      await api.profile();
      server = 'ok';
    } catch (e) {
      server = _code(e);
    }
    Map<String, Object?> watcher;
    try {
      watcher = await native.watcherStatus();
    } catch (e) {
      watcher = {'error': e.runtimeType.toString()};
    }
    return LifyCheck(user: user, server: server, watcher: watcher);
  }

  /// Re-tells the background watcher about saved limits, the agent address and the experiments (it must keep working
  /// when the app is closed). In demo mode with no limit yet, the distracting apps get a stand-in 30 minute limit on the
  /// watcher only, so the experiments can run during a demo.
  Future<void> syncWatcher({
    List<String> distracting = const [],
    String? sleep,
  }) async {
    try {
      // the evening reminder rings one hour before the sleep time (none until a sleep time is set)
      if (sleep != null) await native.configureEvening(sleep: sleep);
      await native.configureNudges(
        baseUrl: baseUrl,
        apiKey: apiKey,
        locale: 'en',
      );
      final settings = await experimentSettings.load();
      await native.configureExperiments(
        enabled: settings.enabled,
        demo: settings.enabled && settings.demo,
      );
      await native.applyRules(await rules.all());
      // No limits saved yet: the apps the user said pull them away are watched with 30 minutes a day, so nudges
      // work from day one (before, the watcher stayed off until "Start my day" set limits or demo mode was on).
      final saved = await limits.all();
      if (saved.isNotEmpty) {
        await native.applyLimits(saved);
      } else if (distracting.isNotEmpty) {
        await native.applyLimits({for (final a in distracting) a: 30});
      }
    } catch (_) {
      // The watcher is best effort; the screens still work.
    }
  }
}

/// What Settings > Check Lify shows.
class LifyCheck {
  const LifyCheck({
    required this.user,
    required this.server,
    required this.watcher,
  });

  final String? user;
  final String server; // "ok" or an error code
  final Map<String, Object?> watcher;
}

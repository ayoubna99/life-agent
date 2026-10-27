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
import 'device/stores.dart';
import 'onboarding/onboarding_store.dart';
import 'platform/native.dart';
import 'platform/services.dart';
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
    this.baseUrl = AppConfig.supabaseUrl,
    this.apiKey = AppConfig.supabaseKey,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       alarmLog = alarmLog ?? MemoryAlarmLog(),
       onboarding = onboarding ?? MemoryOnboardingStore(isDone: true);

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
    return AppServices(
      api: AgentApi(
        baseUrl: AppConfig.supabaseUrl,
        apiKey: AppConfig.supabaseKey,
        client: client,
        auth: auth,
      ),
      tasks: PrefsTaskStore(),
      limits: PrefsLimitStore(),
      native: MethodChannelNative(),
      picks: DevicePicks(),
      voice: DeviceVoice(),
      speaker: DeviceSpeaker(
        settings: voiceSettings,
        languageCode: languageCode,
      ),
      opener: DeviceLinks(),
      voiceSettings: voiceSettings,
      languageCode: languageCode,
      alarmLog: PrefsAlarmLog(),
      onboarding: PrefsOnboardingStore(),
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
  final String baseUrl;
  final String apiKey;
  final DateTime Function() now;

  String get today => isoDate(now());
  String get tomorrow {
    final n = now();
    return isoDate(DateTime(n.year, n.month, n.day + 1));
  }

  late final AlarmScheduler alarmScheduler = NativeAlarmScheduler(native);

  late final DeviceToolRunner tools = DeviceToolRunner(
    tasks: tasks,
    limits: limits,
    alarms: alarmScheduler,
    enforcer: NativeLimitEnforcer(native),
    alarmLog: alarmLog,
    now: now,
  );

  late final UsageSync usageSync = UsageSync(
    native: native,
    upload: api.uploadUsage,
  );

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

  /// "Next task (test)": a reminder for the next task in 10 seconds, so leaving the app shows whether alarms and notifications work.
  Future<String> testNextTask() async {
    final task = nextTask(await tasks.forDate(today), now());
    final message = task == null
        ? 'Test reminder: this is how your reminders look.'
        : 'Next task: ${task.title} (${task.minutes} min)${task.firstStep != null ? '. First step: ${task.firstStep}' : ''}';
    final ok = await alarmScheduler.schedule(
      id: 'test-next',
      at: DateTime.now().add(const Duration(seconds: 10)),
      message: message,
    );
    return ok
        ? 'In 10 seconds you get: "$message". Leave the app now to test.'
        : 'The phone did not allow reminders. Turn on "Alarms and reminders" in Settings.';
  }

  /// "Nudge card (test)": the card that appears on top of other apps when a limit is near, in 10 seconds.
  Future<String> testNudgeCard() async {
    final ok = await alarmScheduler.schedule(
      id: 'test-card',
      at: DateTime.now().add(const Duration(seconds: 10)),
      message:
          'Test nudge: this is how I appear on top of other apps when a limit is near.',
      card: true,
    );
    return ok
        ? 'In 10 seconds the card appears. Open another app now to test.'
        : 'The phone did not allow reminders. Turn on "Alarms and reminders" in Settings.';
  }

  /// Re-tells the background watcher about saved limits and the agent address (it must keep working when the app is closed).
  Future<void> syncWatcher() async {
    try {
      await native.configureNudges(
        baseUrl: baseUrl,
        apiKey: apiKey,
        locale: 'en',
      );
      await native.applyLimits(await limits.all());
    } catch (_) {
      // The watcher is best effort; the screens still work.
    }
  }
}

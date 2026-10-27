import 'dart:ui' show PlatformDispatcher;

import 'package:http/http.dart' as http;

import 'agent/agent_api.dart';
import 'agent/agent_session.dart';
import 'agent/auth.dart';
import 'agent/models.dart';
import 'chat/chat_controller.dart';
import 'config.dart';
import 'device/device_runner.dart';
import 'device/stores.dart';
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
    this.baseUrl = AppConfig.supabaseUrl,
    this.apiKey = AppConfig.supabaseKey,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       alarmLog = alarmLog ?? MemoryAlarmLog();

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
  final String baseUrl;
  final String apiKey;
  final DateTime Function() now;

  String get today => isoDate(now());
  String get tomorrow {
    final n = now();
    return isoDate(DateTime(n.year, n.month, n.day + 1));
  }

  late final DeviceToolRunner tools = DeviceToolRunner(
    tasks: tasks,
    limits: limits,
    alarms: NativeAlarmScheduler(native),
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
    usage: session.mode == 'execute' ? null : usageSync,
    keywords: profile.apps,
  );

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

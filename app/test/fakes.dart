import 'dart:typed_data';

import 'package:life_agent/agent/models.dart';
import 'package:life_agent/device/rules.dart';
import 'package:life_agent/platform/native.dart';
import 'package:life_agent/platform/services.dart';
import 'package:life_agent/platform/voice_settings.dart';

class FakePicks implements FilePicks {
  PickedFile? document;
  PickedFile? photo;

  @override
  Future<PickedFile?> pickDocument() async => document;

  @override
  Future<PickedFile?> pickPhoto({required bool camera}) async => photo;
}

class FakeVoice implements VoiceRecorder {
  bool allowed = true;
  Uint8List? recording = Uint8List.fromList([1, 2, 3]);
  bool started = false;

  @override
  Future<bool> hasPermission() async => allowed;

  @override
  Future<void> start() async => started = true;

  @override
  Future<Uint8List?> stop() async => recording;
}

class FakeSpeaker implements Speaker {
  final List<String> spoken = [];
  List<SpeechVoice> installed = const [
    SpeechVoice(name: 'en-us-x-tpd-network', locale: 'en-US'),
    SpeechVoice(name: 'en-us-x-iom-local', locale: 'en-US'),
    SpeechVoice(name: 'fr-fr-x-vlf-local', locale: 'fr-FR'),
  ];

  @override
  Future<List<SpeechVoice>> voices() async => installed;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}

class FakeOpener implements LinkOpener {
  final List<String> opened = [];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

class FakeNative implements Native {
  bool usageAccess = true;
  List<UsageRow> usage = const [
    UsageRow(day: '2026-10-27', app: 'TikTok', minutes: 70),
  ];
  List<String> apps = ['Instagram', 'TikTok', 'YouTube'];
  bool exactAlarms = true;
  bool notifications = true;
  List<String> notFound = [];
  Map<String, int>? limits;
  final List<(String, int, String)> alarms = [];
  final List<bool> alarmCards = [];
  int usageSettingsOpened = 0;
  ({String baseUrl, String apiKey, String locale})? nudgeConfig;

  @override
  Future<bool> hasUsageAccess() async => usageAccess;

  @override
  Future<void> openUsageAccessSettings() async => usageSettingsOpened++;

  @override
  Future<List<UsageRow>> usageSummary({int days = 7}) async => usage;

  @override
  Future<List<String>> installedApps() async => apps;

  @override
  Future<bool> canScheduleExactAlarms() async => exactAlarms;

  @override
  Future<void> openExactAlarmSettings() async {}

  @override
  Future<bool> scheduleAlarm({
    required String id,
    required int atMillis,
    required String message,
    bool card = false,
    String? title,
    String? open,
  }) async {
    if (!exactAlarms) return false;
    alarms.add((id, atMillis, message));
    alarmCards.add(card);
    alarmTitles.add(title);
    alarmOpens.add(open);
    return true;
  }

  final List<String?> alarmOpens = [];
  final List<(int, int, String)> phoneAlarms = [];
  int alarmSoundStops = 0;

  @override
  Future<bool> setPhoneAlarm({
    required int hour,
    required int minute,
    required String message,
  }) async {
    phoneAlarms.add((hour, minute, message));
    return true;
  }

  @override
  Future<void> stopAlarmSound() async => alarmSoundStops++;

  final List<String?> alarmTitles = [];
  List<SessionRule>? rules;

  @override
  Future<List<String>> applyRules(List<SessionRule> rules) async {
    this.rules = rules;
    return [
      for (final r in rules)
        if (!r.anyApp && !apps.contains(r.app)) r.app,
    ];
  }

  final List<String> cancelled = [];

  @override
  Future<void> cancelAlarm(String id) async => cancelled.add(id);

  @override
  Future<List<String>> applyLimits(Map<String, int> limits) async {
    this.limits = limits;
    return notFound;
  }

  @override
  Future<void> configureNudges({
    required String baseUrl,
    required String apiKey,
    required String locale,
  }) async => nudgeConfig = (baseUrl: baseUrl, apiKey: apiKey, locale: locale);

  @override
  Future<bool> notificationsAllowed() async => notifications;

  @override
  Future<void> requestNotifications() async => notifications = true;

  bool overlay = true;
  int overlaySettingsOpened = 0;

  @override
  Future<bool> canDrawOverlay() async => overlay;

  @override
  Future<void> openOverlaySettings() async => overlaySettingsOpened++;

  bool? nudgesAsNotifications;

  @override
  Future<void> setNudgesAsNotifications({required bool on}) async =>
      nudgesAsNotifications = on;

  Map<String, Object?>? bank;

  @override
  Future<void> setNudgeBank(Map<String, Object?> shift) async => bank = shift;

  final played = <Uint8List>[];

  @override
  Future<void> playAudio(Uint8List wav) async => played.add(wav);

  @override
  Future<void> stopAudio() async {}

  int batterySettingsOpened = 0;
  int popupSettingsOpened = 0;

  @override
  Future<void> openBatterySettings() async => batterySettingsOpened++;

  @override
  Future<void> openPopupSettings() async => popupSettingsOpened++;

  ({bool enabled, bool demo})? experiments;

  @override
  Future<void> configureExperiments({
    required bool enabled,
    required bool demo,
  }) async => experiments = (enabled: enabled, demo: demo);

  bool calendarAccess = true;
  int calendarRequests = 0;
  List<CalendarEntry> calendar = const [
    CalendarEntry(title: 'Lecture', start: '10:00', end: '12:00'),
  ];

  List<PhoneNight> nights = const [
    PhoneNight(night: '2026-10-26', down: '03:12', up: '10:40'),
  ];
  String? eveningSleep;
  String? launchAction;

  @override
  Future<List<PhoneNight>> phoneNights({int nights = 7}) async => this.nights;

  @override
  Future<void> configureEvening({required String sleep}) async =>
      eveningSleep = sleep;

  Map<String, Object?> status = {
    'running': true,
    'limits': ['TikTok 30 min'],
    'rules': 0,
    'experiments': true,
    'demo': true,
    'usageAccess': true,
    'overlay': true,
    'lastProblem': null,
    'lastProblemAt': 0,
    'lastNudgeAt': 0,
    'unsentResults': 0,
    'eveningSleep': '23:00',
  };

  @override
  Future<Map<String, Object?>> watcherStatus() async => status;

  @override
  Future<String?> takeLaunchAction() async {
    final a = launchAction;
    launchAction = null;
    return a;
  }

  @override
  Future<bool> hasCalendarAccess() async => calendarAccess;

  @override
  Future<void> requestCalendar() async {
    calendarRequests++;
    calendarAccess = true;
  }

  @override
  Future<List<CalendarEntry>?> calendarEvents(String date) async =>
      calendarAccess ? calendar : null;
}

import 'dart:typed_data';

import 'package:life_agent/agent/models.dart';
import 'package:life_agent/platform/native.dart';
import 'package:life_agent/platform/services.dart';

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
  }) async {
    if (!exactAlarms) return false;
    alarms.add((id, atMillis, message));
    return true;
  }

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
}

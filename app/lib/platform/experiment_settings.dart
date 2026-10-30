import 'package:shared_preferences/shared_preferences.dart';

/// "Let Life test what works for you" (opt-in) and demo mode (compressed thresholds for a live demo).
class ExperimentSettings {
  const ExperimentSettings({this.enabled = false, this.demo = false});

  final bool enabled;
  final bool demo;

  ExperimentSettings copyWith({bool? enabled, bool? demo}) =>
      ExperimentSettings(
        enabled: enabled ?? this.enabled,
        demo: demo ?? this.demo,
      );
}

abstract class ExperimentSettingsStore {
  Future<ExperimentSettings> load();
  Future<void> save(ExperimentSettings settings);
}

class MemoryExperimentSettingsStore implements ExperimentSettingsStore {
  MemoryExperimentSettingsStore([this.value = const ExperimentSettings()]);

  ExperimentSettings value;

  @override
  Future<ExperimentSettings> load() async => value;

  @override
  Future<void> save(ExperimentSettings settings) async => value = settings;
}

class PrefsExperimentSettingsStore implements ExperimentSettingsStore {
  static const _enabled = 'experiments.enabled';
  static const _demo = 'experiments.demo';

  @override
  Future<ExperimentSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return ExperimentSettings(
      enabled: p.getBool(_enabled) ?? false,
      demo: p.getBool(_demo) ?? false,
    );
  }

  @override
  Future<void> save(ExperimentSettings settings) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_enabled, settings.enabled);
    await p.setBool(_demo, settings.demo);
  }
}

import 'package:shared_preferences/shared_preferences.dart';

/// One of the voices the phone can speak with.
class SpeechVoice {
  const SpeechVoice({required this.name, required this.locale});

  final String name;
  final String locale; // e.g. en-US

  @override
  bool operator ==(Object other) =>
      other is SpeechVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

class VoiceSettings {
  const VoiceSettings({
    this.enabled = true,
    this.voiceName,
    this.locale,
    this.rate = 0.5,
    this.natural = false,
  });

  /// Lify's own voice (Orpheus, a natural voice served from Baseten) instead of the phone's. Falls back to the phone.
  final bool natural;

  /// Read the agent's answers aloud after the person spoke to it.
  final bool enabled;
  final String? voiceName;
  final String? locale;

  /// Android speech rate, 0.0 to 1.0 (0.5 is normal).
  final double rate;

  VoiceSettings copyWith({
    bool? enabled,
    String? voiceName,
    String? locale,
    double? rate,
    bool? natural,
    bool clearVoice = false,
  }) => VoiceSettings(
    enabled: enabled ?? this.enabled,
    voiceName: clearVoice ? null : (voiceName ?? this.voiceName),
    locale: clearVoice ? null : (locale ?? this.locale),
    rate: rate ?? this.rate,
    natural: natural ?? this.natural,
  );
}

abstract class VoiceSettingsStore {
  Future<VoiceSettings> load();
  Future<void> save(VoiceSettings settings);
}

class MemoryVoiceSettingsStore implements VoiceSettingsStore {
  VoiceSettings value = const VoiceSettings();

  @override
  Future<VoiceSettings> load() async => value;

  @override
  Future<void> save(VoiceSettings settings) async => value = settings;
}

class PrefsVoiceSettingsStore implements VoiceSettingsStore {
  @override
  Future<VoiceSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return VoiceSettings(
      enabled: p.getBool('life.voice.enabled') ?? true,
      voiceName: p.getString('life.voice.name'),
      locale: p.getString('life.voice.locale'),
      rate: (p.getDouble('life.voice.rate') ?? 0.5).clamp(0.2, 1.0),
      natural: p.getBool('life.voice.natural') ?? false,
    );
  }

  @override
  Future<void> save(VoiceSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('life.voice.enabled', s.enabled);
    await p.setDouble('life.voice.rate', s.rate);
    await p.setBool('life.voice.natural', s.natural);
    if (s.voiceName == null) {
      await p.remove('life.voice.name');
      await p.remove('life.voice.locale');
    } else {
      await p.setString('life.voice.name', s.voiceName!);
      await p.setString('life.voice.locale', s.locale ?? '');
    }
  }
}

/// How "Lify" is said: like "Life" with an "ee" at the end (LIFE-ee). Speech engines read the written name as "Liffy",
/// so the voice gets this spelling; the screen keeps "Lify".
const lifySpoken = 'Lifey';

String withSpokenName(String text) =>
    text.replaceAll(RegExp(r'\bLify\b', caseSensitive: false), lifySpoken);

/// Google's English voices that sound most like a person, best first.
const _natural = [
  'en-us-x-sfg-network',
  'en-us-x-tpf-network',
  'en-us-x-iog-network',
  'en-gb-x-gba-network',
];

/// The voices that speak the person's language, best first.
List<SpeechVoice> voicesFor(List<SpeechVoice> all, String languageCode) {
  final lang = languageCode.toLowerCase();
  final mine = [
    for (final v in all)
      if (v.locale.toLowerCase().replaceAll('_', '-').startsWith('$lang-') ||
          v.locale.toLowerCase() == lang)
        v,
  ];
  int rank(SpeechVoice v) {
    final n = v.name.toLowerCase();
    // Google's most natural English voices (warm, close to a real person), when installed
    for (final (i, best) in _natural.indexed) {
      if (n.startsWith(best)) return -_natural.length + i;
    }
    if (n.contains('network') ||
        n.contains('neural') ||
        n.contains('premium') ||
        n.contains('enhanced'))
      return 0; // the better-sounding ones
    if (n.contains('local')) return 1;
    return 2;
  }

  final sorted = [...mine]
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
  return sorted;
}

/// The voice used when the person has not chosen one: the best-sounding one in their language, or null for the phone's default.
SpeechVoice? pickDefaultVoice(List<SpeechVoice> all, String languageCode) {
  final list = voicesFor(all, languageCode);
  return list.isEmpty ? null : list.first;
}

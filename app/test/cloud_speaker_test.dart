import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/platform/cloud_speaker.dart';
import 'package:life_agent/platform/services.dart';
import 'package:life_agent/platform/voice_settings.dart';

class _Phone implements Speaker {
  final said = <String>[];
  @override
  Future<void> speak(String text) async => said.add(text);
  @override
  Future<void> stop() async {}
  @override
  Future<List<SpeechVoice>> voices() async => const [];
}

void main() {
  final wav = Uint8List.fromList([1, 2, 3]);

  CloudSpeaker make(
    Future<Uint8List?> Function(String) synth,
    List<Uint8List> played,
    _Phone phone, {
    bool natural = true,
  }) => CloudSpeaker(
    synth: synth,
    play: (w) async => played.add(w),
    stopPlaying: () async {},
    fallback: phone,
    settings: MemoryVoiceSettingsStore()
      ..value = VoiceSettings(natural: natural),
  );

  test('Lify speaks with the natural voice when the server has one', () async {
    final played = <Uint8List>[];
    final phone = _Phone();
    await make((_) async => wav, played, phone).speak('Hey Jake');
    expect(played, [wav]);
    expect(phone.said, isEmpty);
  });

  test(
    'not set up, failing, or switched off: the phone voice says it',
    () async {
      final played = <Uint8List>[];
      final phone = _Phone();
      var asked = 0;
      final notSetUp = make(
        (_) async {
          asked++;
          return null;
        },
        played,
        phone,
      );
      await notSetUp.speak('one');
      await notSetUp.speak('two');
      expect(asked, 1, reason: 'no voice on the server: not asked again');
      await make(
        (_) async => throw Exception('down'),
        played,
        phone,
      ).speak('three');
      await make((_) async => wav, played, phone, natural: false).speak('four');
      expect(phone.said, ['one', 'two', 'three', 'four']);
      expect(played, isEmpty);
    },
  );
}

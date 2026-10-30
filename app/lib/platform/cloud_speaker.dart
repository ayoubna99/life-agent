import 'dart:typed_data';

import 'services.dart';
import 'voice_settings.dart';

/// Lify speaks with a natural voice (Orpheus on Baseten, through the agent). If that is off, not set up on the
/// server, or fails, the phone's own voice says it instead: Lify is never silent because of the voice service.
class CloudSpeaker implements Speaker {
  CloudSpeaker({
    required this.synth,
    required this.play,
    required this.stopPlaying,
    required this.fallback,
    required this.settings,
  });

  /// The WAV for a text; null when the server has no voice set up.
  final Future<Uint8List?> Function(String text) synth;
  final Future<void> Function(Uint8List wav) play;
  final Future<void> Function() stopPlaying;
  final Speaker fallback;
  final VoiceSettingsStore settings;

  bool _notSetUp = false;
  int _turn = 0;

  @override
  Future<void> speak(String text) async {
    final turn = ++_turn;
    final s = await settings.load();
    if (s.natural && !_notSetUp) {
      try {
        final wav = await synth(text);
        if (turn != _turn) return; // stopped, or something newer to say
        if (wav != null) {
          await play(wav);
          return;
        }
        _notSetUp = true; // no voice on the server: don't ask again this run
      } catch (_) {
        // the phone's voice below
      }
    }
    if (turn == _turn) await fallback.speak(text);
  }

  @override
  Future<void> stop() async {
    _turn++;
    try {
      await stopPlaying();
    } catch (_) {}
    await fallback.stop();
  }

  @override
  Future<List<SpeechVoice>> voices() => fallback.voices();
}

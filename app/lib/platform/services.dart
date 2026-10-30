import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import 'voice_settings.dart';

/// A file the user chose to send to the agent.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.bytes,
    required this.contentType,
  });

  final String name;
  final Uint8List bytes;
  final String contentType;
}

abstract class FilePicks {
  /// A PDF or a text file, or null if the user backed out.
  Future<PickedFile?> pickDocument();

  /// A photo from the gallery or the camera, already shrunk (about 1600 px, JPEG quality 80: a few hundred KB).
  Future<PickedFile?> pickPhoto({required bool camera});
}

abstract class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start();

  /// Stops and returns a WAV file (mono, 16-bit, 24 kHz), or null if nothing was recorded.
  Future<Uint8List?> stop();
}

abstract class Speaker {
  Future<void> speak(String text);
  Future<void> stop();

  /// The voices installed on this phone.
  Future<List<SpeechVoice>> voices();
}

abstract class LinkOpener {
  Future<bool> open(String url);
}

class DevicePicks implements FilePicks {
  @override
  Future<PickedFile?> pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'md'],
      withData: true,
    );
    final f = result?.files.single;
    if (f == null || f.bytes == null) return null;
    final lower = f.name.toLowerCase();
    return PickedFile(
      name: f.name,
      bytes: f.bytes!,
      contentType: lower.endsWith('.pdf') ? 'application/pdf' : 'text/plain',
    );
  }

  @override
  Future<PickedFile?> pickPhoto({required bool camera}) async {
    final shot = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
    );
    if (shot == null) return null;
    return PickedFile(
      name: shot.name.isEmpty ? 'photo.jpg' : shot.name,
      bytes: await shot.readAsBytes(),
      contentType: 'image/jpeg',
    );
  }
}

class DeviceVoice implements VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  String? _path;

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<void> start() async {
    _path =
        '${Directory.systemTemp.path}/life-voice-${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 24000,
        numChannels: 1,
      ),
      path: _path!,
    );
  }

  @override
  Future<Uint8List?> stop() async {
    final path = await _rec.stop() ?? _path;
    _path = null;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();
    return bytes;
  }
}

class DeviceSpeaker implements Speaker {
  DeviceSpeaker({required this.settings, this.languageCode = 'en'});

  final VoiceSettingsStore settings;
  final String languageCode;
  final FlutterTts _tts = FlutterTts();
  Future<void>? _engine;

  /// Google's speech engine has the natural "network" voices; Samsung and other phones default to their own, flatter
  /// engine. Use Google's when it is installed (it is on almost every Android phone).
  Future<void> _useBestEngine() => _engine ??= () async {
    try {
      final engines = await _tts.getEngines as List<dynamic>?;
      if (engines?.contains('com.google.android.tts') ?? false) {
        await _tts.setEngine('com.google.android.tts');
      }
    } catch (_) {
      // the phone's default engine
    }
  }();

  @override
  Future<List<SpeechVoice>> voices() async {
    await _useBestEngine();
    try {
      final raw = await _tts.getVoices as List<dynamic>?;
      return [
        for (final v in raw ?? const [])
          if (v is Map && v['name'] != null)
            SpeechVoice(
              name: v['name'].toString(),
              locale: (v['locale'] ?? '').toString(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> speak(String text) async {
    final s = await settings.load();
    try {
      final chosen = s.voiceName != null
          ? SpeechVoice(name: s.voiceName!, locale: s.locale ?? '')
          : pickDefaultVoice(await voices(), languageCode);
      if (chosen != null)
        await _tts.setVoice({'name': chosen.name, 'locale': chosen.locale});
      await _tts.setSpeechRate(s.rate);
      await _tts.setPitch(1.05);
    } catch (_) {
      // the phone's default voice still works
    }
    await _tts.speak(withSpokenName(text));
  }

  @override
  Future<void> stop() async => _tts.stop();
}

class DeviceLinks implements LinkOpener {
  @override
  Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

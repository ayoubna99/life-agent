import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_api.dart';
import '../agent/agent_session.dart';
import '../agent/models.dart';
import '../platform/native.dart';
import '../platform/services.dart';
import 'messages.dart';
import 'text_clean.dart';
import '../platform/voice_settings.dart';

/// The state behind a chat screen: what was said, what the agent is doing right now, files and voice.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.session,
    required this.api,
    required this.picks,
    required this.voice,
    required this.speaker,
    this.voiceSettings,
    this.usage,
    this.keywords = const [],
    this.languages = const ['English'],
    this.maxRecording = const Duration(seconds: 120),
  });

  final AgentSession session;
  final AgentApi api;
  final FilePicks picks;
  final VoiceRecorder voice;
  final Speaker speaker;
  final VoiceSettingsStore? voiceSettings;
  final UsageSync? usage;
  final List<String> keywords;
  final List<String> languages;
  final Duration maxRecording;

  final List<ChatMessage> messages = [];
  final List<AttachResult> attachments = [];
  bool busy = false;
  bool recording = false;
  bool planSaved = false;
  String? status;
  bool _usageSynced = false;
  bool _spokenInput = false;
  Timer? _limit;

  void _set({bool? busy, String? status, bool clearStatus = false}) {
    if (busy != null) this.busy = busy;
    this.status = clearStatus ? null : (status ?? this.status);
    notifyListeners();
  }

  void _note(String text, {bool error = false}) =>
      messages.add(ChatMessage(Who.note, text, error: error));

  /// Sends what the user typed (or said) with any files attached so far.
  Future<void> send(String text) async {
    final clean = text.trim();
    if (busy || (clean.isEmpty && attachments.isEmpty)) return;
    final body = clean.isEmpty ? 'Please use the attached file.' : clean;
    final ids = [for (final a in attachments) a.documentId];
    messages.add(
      ChatMessage(
        Who.user,
        attachments.isEmpty
            ? body
            : '$body\n📎 ${attachments.map((a) => a.name).join(', ')}',
      ),
    );
    attachments.clear();
    _set(busy: true, clearStatus: true);
    try {
      await _syncUsageOnce();
      final reply = await _ask(body, ids);
      final shown = plainText(reply.text);
      messages.add(ChatMessage(Who.agent, shown, artifacts: reply.artifacts));
      planSaved = planSaved || reply.planSaved;
      if (_spokenInput) await _speakShort(shown);
    } catch (e) {
      _note(describeError(e), error: true);
    } finally {
      _spokenInput = false;
      _set(busy: false, clearStatus: true);
    }
  }

  /// Read aloud only after the person talked, in their chosen voice, and only a short clean version (never the links or the whole plan).
  Future<void> _speakShort(String text) async {
    final voice = await voiceSettings?.load();
    if (voice != null && !voice.enabled) return;
    final short = speakable(text);
    if (short.isNotEmpty) unawaited(speaker.speak(short));
  }

  Future<AgentReply> _ask(String body, List<String> ids) {
    return session.send(body, attachments: ids);
  }

  /// Planning and review use the real screen time. We send it once per chat; if Usage access is off we say so.
  Future<void> _syncUsageOnce() async {
    final u = usage;
    if (u == null || _usageSynced || session.mode == 'execute') return;
    _usageSynced = true;
    _set(status: 'Reading your screen time…');
    final r = await u.run();
    if (r.needsPermission) {
      _note(
        'I cannot see your screen time yet. Turn on "Usage access" for Life in Settings and I will plan with your real numbers.',
      );
    }
    _set(clearStatus: true);
  }

  Future<void> attachDocument() => _attach(picks.pickDocument);
  Future<void> attachPhoto({required bool camera}) =>
      _attach(() => picks.pickPhoto(camera: camera));

  Future<void> _attach(Future<PickedFile?> Function() pick) async {
    if (busy) return;
    try {
      final file = await pick();
      if (file == null) return;
      _set(busy: true, status: 'Reading ${file.name}…');
      final result = await api.attach(
        bytes: file.bytes,
        fileName: file.name,
        contentType: file.contentType,
      );
      attachments.add(result);
    } catch (e) {
      _note(describeError(e), error: true);
    } finally {
      _set(busy: false, clearStatus: true);
    }
  }

  void removeAttachment(AttachResult a) {
    attachments.remove(a);
    notifyListeners();
  }

  /// Tap once to start talking, tap again to send. The words are typed into the chat for the agent.
  Future<void> toggleVoice() async {
    if (busy && !recording) return;
    if (!recording) {
      if (!await voice.hasPermission()) {
        _note(
          'I need the microphone to listen. Allow it in your phone settings.',
          error: true,
        );
        notifyListeners();
        return;
      }
      try {
        await voice.start();
      } catch (_) {
        _note('The microphone could not start.', error: true);
        notifyListeners();
        return;
      }
      recording = true;
      _limit = Timer(maxRecording, () => unawaited(toggleVoice()));
      _set(status: 'Listening… tap again to send');
      return;
    }
    _limit?.cancel();
    recording = false;
    _set(busy: true, status: 'Listening…');
    String? said;
    try {
      final wav = await voice.stop();
      if (wav == null || wav.isEmpty) throw AgentException('no_speech');
      said = await api.transcribe(
        wav: wav,
        languages: languages,
        keywords: keywords,
      );
    } catch (e) {
      _note(describeError(e), error: true);
    }
    _set(busy: false, clearStatus: true);
    if (said != null && said.trim().isNotEmpty) {
      _spokenInput = true;
      await send(said);
    }
  }

  @override
  void dispose() {
    _limit?.cancel();
    unawaited(speaker.stop());
    super.dispose();
  }
}

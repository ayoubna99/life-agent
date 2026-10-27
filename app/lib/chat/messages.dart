import '../agent/models.dart';

enum Who { user, agent, note }

class ChatMessage {
  const ChatMessage(
    this.who,
    this.text, {
    this.artifacts = const [],
    this.error = false,
  });

  final Who who;
  final String text;
  final List<Artifact> artifacts;
  final bool error;
}

/// Words for the person, never a raw code.
String describeError(Object e) {
  if (e is! AgentException) return 'Something went wrong. Please try again.';
  if (e.capacity)
    return 'The demo is full for today. Please try again tomorrow.';
  if (e.dailyLimit)
    return 'You have used all of today\'s agent requests. Come back tomorrow.';
  if (e.offline) return 'No connection. Check your internet and try again.';
  if (e.timedOut) return 'The agent took too long. Please try again.';
  switch (e.code) {
    case 'anonymous_provider_disabled':
    case 'auth_failed':
      return 'Could not start your session. Please try again in a moment.';
    case 'upload_failed':
      return 'The file could not be sent. It may be too big.';
    case 'image_too_large':
      return 'That photo is too big. Try a smaller one.';
    case 'image_unreadable':
    case 'no_text_in_document':
      return 'I could not read any text in that file.';
    case 'pdf_unreadable':
    case 'unsupported_file':
      return 'I cannot read that kind of file. Send a PDF, a photo or a text file.';
    case 'no_speech':
      return 'I did not hear anything. Try again a little closer to the microphone.';
    case 'too_many_tool_rounds':
      return 'The agent got stuck. Please try again.';
  }
  if (e.code.startsWith('bad_audio'))
    return 'That recording could not be used. Try again.';
  return 'The agent had a problem (${e.code}). Please try again.';
}

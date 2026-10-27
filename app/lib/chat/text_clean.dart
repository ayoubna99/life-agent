// What the person reads and hears. The server already cleans replies; this is the phone's own safety net
// (older messages, a model that slips), and it makes the short version that is read aloud.

final _storedFile = RegExp(
  r'https?://[^\s)\]]*/storage/v1/object/sign/[^\s)\]]*',
  caseSensitive: false,
);
final _anyUrl = RegExp(r'https?://[^\s)\]]+', caseSensitive: false);

/// Plain text for a chat bubble: no markdown marks and no links to our own private files (they show as cards).
String plainText(String text) {
  var out = text
      .replaceAll(_storedFile, '')
      .replaceAllMapped(RegExp(r'(\*\*|__)(.+?)\1'), (m) => m[2]!)
      .replaceAllMapped(
        RegExp(
          r'(^|[\s(])\*([^*\s][^*\n]*?)\*(?=[\s).,;:!?]|$)',
          multiLine: true,
        ),
        (m) => '${m[1]}${m[2]}',
      )
      .replaceAll(RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+', multiLine: true), '')
      .replaceAll(RegExp(r'^[ \t]*[*+][ \t]+', multiLine: true), '- ')
      .replaceAll('`', '')
      .replaceAll(RegExp(r'[ \t]+$', multiLine: true), '')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (out.isEmpty) out = text.trim();
  return out;
}

/// The short, clean version that is read aloud: no links, no list marks, no emoji, and only the first few sentences,
/// because a spoken list of everything on screen is too long to listen to.
String speakable(String text, {int maxChars = 240}) {
  var out = plainText(text)
      .replaceAll(_anyUrl, '')
      .replaceAll(RegExp(r'^[ \t]*[-•]\s+', multiLine: true), '')
      .replaceAll(
        RegExp(
          r'[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{FE0F}]',
          unicode: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s*\n\s*'), '. ')
      .replaceAllMapped(RegExp(r'([.!?:])\s*\.'), (m) => m[1]!)
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  if (out.length <= maxChars) return out;
  final cut = out.substring(0, maxChars);
  final end = [
    cut.lastIndexOf('. '),
    cut.lastIndexOf('! '),
    cut.lastIndexOf('? '),
  ].reduce((a, b) => a > b ? a : b);
  if (end > 60) return cut.substring(0, end + 1);
  final space = cut.lastIndexOf(' ');
  return '${(space > 0 ? cut.substring(0, space) : cut).replaceAll(RegExp(r'[,;:\s]+$'), '')}…';
}

/// The apps that pull most people away. Used to pre-choose "Apps that pull me away" (the person can change it), so the
/// watcher has something to watch from the first minute, even on a new phone with no screen-time history.
const commonFeeds = [
  'TikTok', 'Instagram', 'YouTube', 'Facebook', 'Snapchat', 'X', 'Twitter', 'Reddit', 'Twitch', 'Threads', 'Pinterest',
];

bool isCommonFeed(String app) => commonFeeds.any((f) => f.toLowerCase() == app.trim().toLowerCase());

/// The pre-chosen list: the feeds they use most, then other feeds installed on the phone (at most [max]). With no feed
/// at all: their three most used apps, as before.
List<String> defaultDistracting({
  List<String> topUsed = const [],
  List<String> installed = const [],
  int max = 5,
}) {
  final out = <String>[];
  void add(String a) {
    if (out.length < max && !out.any((o) => o.toLowerCase() == a.toLowerCase())) out.add(a);
  }

  for (final a in topUsed) {
    if (isCommonFeed(a)) add(a);
  }
  for (final a in installed) {
    if (isCommonFeed(a)) add(a);
  }
  if (out.isEmpty) topUsed.take(3).forEach(add);
  return out;
}

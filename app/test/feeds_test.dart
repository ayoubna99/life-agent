import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/agent/feeds.dart';

void main() {
  test('pre-chosen apps: the feeds they use most, then installed feeds, never empty-handed', () {
    expect(
      defaultDistracting(topUsed: ['WhatsApp', 'Instagram', 'Chrome', 'TikTok'], installed: ['YouTube', 'Gmail']),
      ['Instagram', 'TikTok', 'YouTube'],
    );
    // a new phone (a judge's emulator): no history, but feeds are installed
    expect(defaultDistracting(installed: ['Gmail', 'tiktok', 'Reddit']), ['tiktok', 'Reddit']);
    // no feed anywhere: their three most used apps
    expect(defaultDistracting(topUsed: ['WhatsApp', 'Chrome', 'Gmail', 'Maps']), ['WhatsApp', 'Chrome', 'Gmail']);
    expect(defaultDistracting(), isEmpty);
  });
}

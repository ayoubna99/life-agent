import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/chat/text_clean.dart';
import 'package:life_agent/platform/voice_settings.dart';

const stored =
    'https://vldudnzlnkxqjnhwepqq.supabase.co/storage/v1/object/sign/materials/aa8ac5b9/2026-10-28-algorithms-1-big-o-basics-5821ae1f.pdf?token=eyJraWQiOiI2ZWM2NDc4OS01MDAzLTRkZmYtOTVlNi1jYjUxMzI0NWRkZGIiLCJhbGciOiJIUzUxMiJ9.eyJ1cmwi';

void main() {
  test(
    'what the screenshot showed: markdown marks and the long file links are gone, the words stay',
    () {
      final shown = plainText(
        'All done — here is what I made:\n\n**1. Big-O PDF:**\n$stored\n\nCovers O(1) to O(n!) + self-test.\n\n**3. Your usage:**\n- TikTok: ~177 min/day',
      );
      expect(shown, isNot(contains('**')));
      expect(shown, isNot(contains('supabase.co')));
      expect(shown, isNot(contains('token=')));
      expect(shown, contains('1. Big-O PDF:'));
      expect(shown, contains('Covers O(1) to O(n!) + self-test.'));
      expect(shown, contains('- TikTok: ~177 min/day'));
    },
  );

  test(
    'plain text is kept as it is, including a lone asterisk and other links',
    () {
      expect(plainText('2 * 3 = 6'), '2 * 3 = 6');
      expect(
        plainText('Read https://www.gutenberg.org/ebooks/6133 tonight'),
        'Read https://www.gutenberg.org/ebooks/6133 tonight',
      );
      expect(plainText('## Plan\n* Gym\n+ Study'), 'Plan\n- Gym\n- Study');
      expect(
        plainText(stored),
        stored,
        reason: 'never turn an answer into nothing',
      );
    },
  );

  test(
    'the spoken version has no links, no list marks, no emoji, and is short',
    () {
      final spoken = speakable(
        'Your plan is ready! 🎉\n\n- 10:00 Review Big-O (60 min)\n- 16:00 Birthday card for Mike (15 min)\n\nRead more at https://www.gutenberg.org/ebooks/6133 tonight.',
      );
      expect(spoken, isNot(contains('http')));
      expect(spoken, isNot(contains('🎉')));
      expect(spoken, isNot(contains('- ')));
      expect(spoken, contains('Your plan is ready!'));
      expect(spoken, contains('10:00 Review Big-O (60 min)'));
    },
  );

  test('a long answer is cut at a sentence, never in the middle of a word', () {
    final long = List.generate(
      30,
      (i) => 'Sentence number $i is here.',
    ).join(' ');
    final spoken = speakable(long, maxChars: 120);
    expect(spoken.length, lessThanOrEqualTo(120));
    expect(spoken.endsWith('.'), isTrue);
    expect(speakable('word ' * 100, maxChars: 50).endsWith('…'), isTrue);
    expect(speakable('Short one.'), 'Short one.');
  });

  test(
    'the voice picker puts natural voices first and only offers the phone\'s language',
    () {
      const all = [
        SpeechVoice(name: 'en-us-x-iom-local', locale: 'en-US'),
        SpeechVoice(name: 'en-us-x-tpd-network', locale: 'en-US'),
        SpeechVoice(name: 'fr-fr-x-vlf-local', locale: 'fr-FR'),
        SpeechVoice(name: 'en-gb-x-gbb-network', locale: 'en_GB'),
        SpeechVoice(name: 'xx', locale: 'en'),
      ];
      final en = voicesFor(all, 'en');
      expect(en.map((v) => v.name), [
        'en-gb-x-gbb-network',
        'en-us-x-tpd-network',
        'en-us-x-iom-local',
        'xx',
      ]);
      expect(pickDefaultVoice(all, 'en')!.name, 'en-gb-x-gbb-network');
      expect(voicesFor(all, 'fr').single.name, 'fr-fr-x-vlf-local');
      expect(pickDefaultVoice(all, 'de'), isNull);
      // Google's most natural voice wins when the phone has it
      expect(
        pickDefaultVoice([
          ...all,
          const SpeechVoice(name: 'en-us-x-sfg-network', locale: 'en-US'),
        ], 'en')!.name,
        'en-us-x-sfg-network',
      );
    },
  );

  test('the voice says Lify as LIFE-ee, the screen still says Lify', () {
    expect(withSpokenName('Hi, I am Lify. LIFY!'), 'Hi, I am Lifey. Lifey!');
    expect(withSpokenName('Lifestyle and Life'), 'Lifestyle and Life');
  });
}

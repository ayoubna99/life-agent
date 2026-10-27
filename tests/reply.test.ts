import assert from 'node:assert/strict';
import { test } from 'node:test';

import { cleanReply, stripReasoning } from '../supabase/functions/_shared/reply.ts';

test('reasoning in tags is removed, whether it is closed, cut at the start, or never closed', () => {
  assert.equal(stripReasoning('<think>hmm\nlet me see</think>Your plan is ready.'), 'Your plan is ready.');
  assert.equal(stripReasoning('Hello <thinking>x</thinking>there <Reasoning>y</Reasoning>friend'), 'Hello there friend');
  assert.equal(stripReasoning('I should call save_plan first.</think>Done.'), 'Done.');
  assert.equal(stripReasoning('Done. <think>and now I wonder'), 'Done.');
  assert.equal(stripReasoning('Nothing to strip.'), 'Nothing to strip.');
});

test('markdown becomes plain text and bullets stay readable', () => {
  assert.equal(cleanReply('**Plan for tomorrow**\n\n## Morning\n* 08:00 Study\n+ 09:00 Gym\n`code`'), 'Plan for tomorrow\n\nMorning\n- 08:00 Study\n- 09:00 Gym\ncode');
  assert.equal(cleanReply('This is *important* and __bold__.'), 'This is important and bold.');
  assert.equal(cleanReply('2 * 3 = 6 and 4*5'), '2 * 3 = 6 and 4*5', 'a lone asterisk is not markdown');
});

test('links to our private files are removed, other links are kept', () => {
  const stored = 'https://abc.supabase.co/storage/v1/object/sign/materials/u/a.pdf?token=eyJ.long.token';
  assert.equal(cleanReply(`Here it is: ${stored} enjoy`), 'Here it is: enjoy');
  assert.equal(cleanReply(`(${stored})`), '()'.length ? '()' : '');
  assert.equal(cleanReply('Read https://www.gutenberg.org/ebooks/6133 tonight'), 'Read https://www.gutenberg.org/ebooks/6133 tonight');
});

test('an answer that is only a link or only reasoning is not turned into nothing', () => {
  const stored = 'https://abc.supabase.co/storage/v1/object/sign/materials/u/a.pdf?token=t';
  assert.equal(cleanReply(stored), stored);
  assert.equal(cleanReply('<think>only thoughts</think>'), '');
});

test('blank lines are tidied after removals', () => {
  assert.equal(cleanReply('A\n\n\n\n\nB   \n\n'), 'A\n\nB');
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { ExperimentEvent } from '../supabase/functions/_shared/experiments.ts';
import { handle } from '../supabase/functions/_shared/http.ts';
import { lineProblem, readJson, usedLines, validateShift } from '../supabase/functions/_shared/nightshift.ts';
import { jwt, MemoryStore, SUPABASE_URL } from './helpers.ts';

const ENV: Record<string, string> = {
  MUSE_BASE_URL: 'https://api.meta.ai/v1', MUSE_API_KEY: 'sk-secret-key', MUSE_MODEL: 'muse-spark-1.1', SUPABASE_URL,
  OPEN_API_KEY: 'bt-key', MODEL_ROUTE: 'chat', // the night shift runs on the open model whatever the route says
};

function http(body: unknown, store: MemoryStore, answer: (url: string, init: RequestInit) => Response) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return answer(url, init);
  }) as unknown as typeof fetch;
  const req = new Request('https://x/functions/v1/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}`, apikey: 'k' }, body: JSON.stringify(body) });
  return { res: handle(req, { get: (n) => ENV[n], fetchImpl, storeFor: () => store }), calls };
}
const reply = (content: string, reasoning?: string) =>
  new Response(JSON.stringify({ choices: [{ message: { role: 'assistant', content, ...(reasoning ? { reasoning_content: reasoning } : {}) } }] }), { status: 200 });

const ev = (i: number, angle: string, left: boolean, message: string): ExperimentEvent => ({
  id: `e${i}`, day: '2026-10-29', time: '22:1' + (i % 10), app: 'TikTok', arm: 'goal', explore: false, reason: 'over', left,
  seconds_after: left ? 12 : 600, window_seconds: 900, demo: false, propensity: 0.5, context: 'night', message, angle, line_id: `${angle}_1_${i}`,
});

const STUDY = {
  theories: [
    { id: 'gym_at_night', statement: 'He leaves when tomorrow\'s gym is mentioned at night', when: { bands: ['night'] }, test: { angle: 'gym_blunt' }, confidence: 0.72, status: 'kept', evidence: 'left 2 of 2' },
    { id: 'questions', statement: 'Questions do not work on him', when: {}, test: { tone: 'question' }, confidence: 1.7, status: 'weird', evidence: 'stayed 1 of 1' },
    { id: 'vibes', statement: 'He likes good vibes', test: { mood: 'happy' } }, // nothing code can test: dropped
  ],
  angles: [
    {
      id: 'gym_blunt', name: 'Blunt, tomorrow\'s gym, at night', style: 'goal', bands: ['night', 'dawn'], apps: ['TikTok'],
      lines: [
        'Gym at 6. TikTok will still be here.',
        'Tomorrow-you wants that 6 AM gym. Close it.',
        'Ayoub, you are at 140 minutes past your limit.', // the old meter: refused
        'Gym at 6. TikTok will still be here!', // the same line again: refused
        'Gym at 6. TikTok will still be here.', // and again
      ],
    },
    { id: 'empty', name: 'Nothing usable', style: 'feelings', lines: ['Take a 10 min break.'] },
    { id: 'thesis_dare', name: 'A dare about the thesis', style: 'task', bands: [], lines: ['One page of the thesis. I dare you.', 'Drink water and rest, you deserve it.'] },
  ],
  notes: 'Gym lines work late at night.',
};

test('bank lines: short, no meters, no numbers about minutes, no repeats, no health words', () => {
  const used = new Set(['gym at 6 tiktok will still be here']);
  assert.equal(lineProblem('One page of the thesis. I dare you.', used), null);
  assert.equal(lineProblem('Gym at 6. TikTok will still be here.', used), 'already used');
  assert.match(lineProblem('That is 2 hours gone.', used)!, /numbers/);
  assert.match(lineProblem('You\'re at your limit again', used)!, /meter/);
  assert.match(lineProblem('This is a very long line that just keeps going and going well past the point of reading', used)!, /long|words/);
  assert.equal(lineProblem('Ayoub, you know this one.', used, 'Ayoub'), 'the old template opening');
  assert.equal(lineProblem('Is this addiction talking?', used), 'health language');
  assert.deepEqual(readJson('Sure!\n```json\n{"a":1}\n```'), { a: 1 });
});

test('code checks what the model proposed: ids, bands, styles, bad lines out, empty angles dropped', () => {
  const s = validateShift(STUDY, '2026-10-30', new Set(), 'Ayoub');
  assert.deepEqual(s.angles.map((a) => a.id), ['gym_blunt', 'thesis_dare']);
  const gym = s.angles[0];
  assert.deepEqual(gym.lines.map((l) => l.text), ['Gym at 6. TikTok will still be here.', 'Tomorrow-you wants that 6 AM gym. Close it.']);
  assert.deepEqual(gym.lines.map((l) => l.id), ['gym_blunt_20261030_1', 'gym_blunt_20261030_2']);
  assert.deepEqual(gym.bands, ['night']);
  assert.deepEqual(s.angles[1].bands, ['morning', 'afternoon', 'evening', 'night'], 'no band given: any time');
  assert.equal(s.theories.length, 2, 'a theory code cannot test is dropped');
  assert.equal(s.theories[1].status, 'testing', 'no data yet: the model saying "kept" or 170% changes nothing');
  assert.ok(Math.abs(s.theories[1].confidence - 0.5) < 0.05, 'no data: a coin flip');
  assert.deepEqual(s.theories[1].model_said, { status: 'weird', confidence: 1 });
  assert.throws(() => validateShift({ angles: [{ id: 'x', lines: ['You are at your limit.'] }] }, '2026-10-30', new Set()));
});

test('the night shift: the study reads the whole history and thinks harder, the critic cuts, the phone gets the bank', async () => {
  const store = new MemoryStore();
  store.profile = { apps: ['TikTok'], name: 'Ayoub', focus: 'thesis' };
  store.experiments = [ev(1, 'gym_blunt', true, 'Gym at 6. Phone down.'), ev(2, 'gym_blunt', true, 'Your 6 AM self is watching.'), ev(3, 'questions', false, 'Is this video worth it?')];
  store.nights = [{ night: '2026-10-28', down: '03:30', up: '08:02' }];

  const study = http({ action: 'nightshift', step: 'study', day: '2026-10-30' }, store, () => reply(JSON.stringify(STUDY), 'Gym lines got 2 of 2 at night; questions 0 of 1. Keep gym, test a thesis dare.'));
  const r = await study.res;
  assert.equal(r.status, 200);
  const draft = (await r.json()).shift;
  assert.equal(draft.status, 'draft');
  assert.equal(draft.shift.thinking, 'Gym lines got 2 of 2 at night; questions 0 of 1. Keep gym, test a thesis dare.');
  // the open model, thinking harder than for a nudge, with everything in one prompt
  assert.equal(study.calls[0].url, 'https://inference.baseten.co/v1/chat/completions');
  const sent = JSON.parse(study.calls[0].init.body as string);
  assert.equal(sent.reasoning_effort, 'medium');
  const prompt = sent.messages[1].content as string;
  assert.match(prompt, /"Your 6 AM self is watching\." -> LEFT after 12s/);
  assert.match(prompt, /gym_blunt: 2\/2 left/);
  assert.match(prompt, /2026-10-28: 03:30 \/ 08:02/);
  assert.equal(store.quota, 1);

  // run again within 6 hours: nothing new is spent
  const again = await (await http({ action: 'nightshift', step: 'study', day: '2026-10-30' }, store, () => { throw new Error('no call'); }).res).json();
  assert.equal(again.skipped, 'recent');

  const critic = http({ action: 'nightshift', step: 'critic', day: '2026-10-30' }, store, () =>
    reply(JSON.stringify({ cut: [{ id: 'gym_blunt_20261030_2', why: 'sounds like a poster' }] })));
  const final = (await (await critic.res).json()).shift;
  assert.equal(final.status, 'final');
  assert.equal(JSON.parse(critic.calls[0].init.body as string).reasoning_effort, 'low');
  assert.deepEqual(final.shift.critic, { cut: 1, reasons: ['sounds like a poster'] });
  assert.deepEqual(final.shift.angles.flatMap((a: { lines: { text: string }[] }) => a.lines.map((l) => l.text)), [
    'Gym at 6. TikTok will still be here.',
    'One page of the thesis. I dare you.',
    'Drink water and rest, you deserve it.',
  ]);

  const got = await (await http({ action: 'nightshift' }, store, () => { throw new Error('no call'); }).res).json();
  assert.equal(got.shift.day, '2026-10-30');
  assert.deepEqual(got.angles.find((a: { angle: string }) => a.angle === 'gym_blunt'), { angle: 'gym_blunt', tried: 2, left: 2, pulled: 0, lines: 2 });
});

test('the critic never empties the bank, and when it is down the draft is used as it is', async () => {
  const store = new MemoryStore();
  await store.saveNightShift({ day: '2026-10-30', status: 'draft', model: 'open', shift: validateShift(STUDY, '2026-10-30', new Set()) });
  const all = ['gym_blunt_20261030_1', 'gym_blunt_20261030_2', 'thesis_dare_20261030_1'].map((id) => ({ id, why: 'meh' }));
  const strict = await (await http({ action: 'nightshift', step: 'critic', day: '2026-10-30' }, store, () => reply(JSON.stringify({ cut: all }))).res).json();
  assert.equal(strict.shift.shift.critic.cut, 0);
  assert.equal(strict.shift.shift.angles.length, 2);

  await store.saveNightShift({ day: '2026-10-31', status: 'draft', model: 'open', shift: validateShift(STUDY, '2026-10-31', new Set()) });
  const down = await (await http({ action: 'nightshift', step: 'critic', day: '2026-10-31' }, store, () => new Response('busy', { status: 503 })).res).json();
  assert.equal(down.shift.status, 'final');
  assert.match(down.shift.shift.critic.reasons[0], /could not be reached/);
});

test('a line already sent is never written again', () => {
  const used = usedLines([ev(1, 'gym_blunt', true, 'Gym at 6. TikTok will still be here.')], null);
  const s = validateShift(STUDY, '2026-10-30', used);
  assert.equal(s.angles[0].lines[0].text, 'Tomorrow-you wants that 6 AM gym. Close it.');
});

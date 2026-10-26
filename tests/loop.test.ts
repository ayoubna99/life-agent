import assert from 'node:assert/strict';
import { test } from 'node:test';

import { BadRequest, LIMITS, NotFound, parseChatRequest, QuotaExceeded, runChat } from '../supabase/functions/_shared/loop.ts';
import type { ChatRequest } from '../supabase/functions/_shared/loop.ts';
import { MuseError } from '../supabase/functions/_shared/muse.ts';
import { callsReply, cfg, fakeNet, MemoryStore, SUPABASE_URL, textReply, USER } from './helpers.ts';
import type { FakeNet } from './helpers.ts';

const base = (over: Partial<ChatRequest> = {}): ChatRequest => ({
  mode: 'planning',
  today: '2026-10-26',
  date: '2026-10-27',
  input: { type: 'user', text: 'Help me plan tomorrow' },
  ...over,
});

function setup(replies: unknown[], others: Record<string, number | 'network'> = {}, dailyLimit = 80) {
  const store = new MemoryStore();
  const net = fakeNet(replies, others);
  const run = (req: ChatRequest) =>
    runChat(req, { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit, fetchImpl: net.fetchImpl, randomId: () => 'abcdef1234567890' });
  return { store, net, run };
}

const last = (net: FakeNet) => net.museRequests[net.museRequests.length - 1];
const names = (net: FakeNet) => last(net).tools.map((t) => t.function.name);

test('a new conversation: the question goes to the model, the answer comes back, both are stored', async () => {
  const { store, net, run } = setup([textReply('What do you want to get done tomorrow?')]);
  const r = await run(base());
  assert.equal(r.type, 'text');
  assert.equal(r.type === 'text' && r.text, 'What do you want to get done tomorrow?');
  assert.equal(r.plan_saved, false);
  assert.equal(store.quota, 1);
  const saved = store.messages.get(r.conversation_id)!;
  assert.deepEqual(saved.map((m) => m.role), ['user', 'assistant']);
  assert.equal(store.conversations.get(r.conversation_id)!.kind, 'planning');
  assert.equal(last(net).model, 'muse-test');
});

test('the system prompt carries the mode and the app context, and each mode gets only its own tools', async () => {
  const planning = setup([textReply('ok')]);
  await planning.run(base({ locale: 'fr' }));
  const sys = last(planning.net).messages[0];
  assert.equal(sys.role, 'system');
  assert.match(sys.content!, /Mode: planning/);
  assert.match(sys.content!, /today: 2026-10-26/);
  assert.match(sys.content!, /plan_date: 2026-10-27/);
  assert.match(sys.content!, /user_language: fr/);
  assert.deepEqual(names(planning.net), ['get_usage', 'save_plan', 'create_material']);

  const execute = setup([textReply('ok')]);
  await execute.run(base({ mode: 'execute' }));
  assert.match(last(execute.net).messages[0].content!, /Mode: execute/);
  assert.deepEqual(names(execute.net), ['get_plan', 'create_task', 'set_app_limit', 'schedule_alarm']);

  const review = setup([textReply('ok')]);
  await review.run(base({ mode: 'review', report: { done: ['Study'], missed: ['Gym'] } }));
  const content = last(review.net).messages[0].content!;
  assert.match(content, /Mode: review/);
  assert.match(content, /review_date: 2026-10-26/);
  assert.match(content, /tasks_missed: \["Gym"\]/);
  assert.deepEqual(names(review.net), ['get_usage', 'get_plan', 'save_plan', 'create_material']);
});

test('the conversation is remembered: the second request sends only the new message and the model sees all of it', async () => {
  const { net, run } = setup([textReply('What are your tasks?'), textReply('And your sleep time?')]);
  const first = await run(base());
  await run(base({ conversation_id: first.conversation_id, input: { type: 'user', text: 'Study and gym' } }));
  const roles = last(net).messages.map((m) => m.role);
  assert.deepEqual(roles, ['system', 'user', 'assistant', 'user']);
  assert.equal(last(net).messages[3].content, 'Study and gym');
});

test('a server tool runs on the server and the model gets its real answer', async () => {
  const { store, net, run } = setup([callsReply(['get_usage', { app: 'instagram', days: 3 }]), textReply('You spend about 70 minutes a day on Instagram.')]);
  store.usage = [
    { day: '2026-10-26', app: 'Instagram', minutes: 80 },
    { day: '2026-10-25', app: 'Instagram', minutes: 60 },
    { day: '2026-10-20', app: 'Instagram', minutes: 500 }, // too old for days=3
    { day: '2026-10-26', app: 'TikTok', minutes: 5 },
  ];
  const r = await run(base());
  assert.equal(r.type, 'text');
  assert.equal(net.museRequests.length, 2);
  const toolMessage = last(net).messages.find((m) => m.role === 'tool')!;
  const result = JSON.parse(toolMessage.content!);
  assert.deepEqual(result, { app: 'instagram', days: [{ day: '2026-10-26', minutes: 80 }, { day: '2026-10-25', minutes: 60 }], average_minutes: 70 });
  assert.deepEqual(store.messages.get(r.conversation_id)!.map((m) => m.role), ['user', 'assistant', 'tool', 'assistant']);
});

test('save_plan stores the plan for the day the APP named, not the day the model wrote', async () => {
  const { store, run } = setup([
    callsReply(['save_plan', { date: '1999-01-01', tasks: [{ title: 'Study algorithms', minutes: 40, start_time: '18:00' }], limits: [{ app: 'Instagram', minutes_per_day: 30 }] }]),
    textReply('Your plan is ready.'),
  ]);
  const r = await run(base({ input: { type: 'user', text: 'Yes, confirmed' } }));
  assert.equal(r.plan_saved, true);
  assert.equal(store.plans.size, 1);
  const plan = store.plans.get('2026-10-27')!;
  assert.equal(plan.data.tasks[0].title, 'Study algorithms');
  assert.equal(plan.data.limits[0].app, 'Instagram');
});

test('a plan the validator refuses goes back to the model, which fixes it and tries again', async () => {
  const { store, net, run } = setup([
    callsReply(['save_plan', { tasks: [{ title: 'Study', minutes: 3 }] }]),
    callsReply(['save_plan', { tasks: [{ title: 'Study', minutes: 30 }] }]),
    textReply('Saved.'),
  ]);
  const r = await run(base());
  assert.equal(r.plan_saved, true);
  assert.equal(store.plans.get('2026-10-27')!.data.tasks[0].minutes, 30);
  const firstAnswer = JSON.parse(net.museRequests[1].messages.find((m) => m.role === 'tool')!.content!);
  assert.match(firstAnswer.error, /minutes/);
});

test('save_plan drops dead links, keeps live and our own, and says which it dropped', async () => {
  const own = `${SUPABASE_URL}/storage/v1/object/sign/materials/${USER}/sheet.md?token=t`;
  const { store, net, run } = setup(
    [
      callsReply(['save_plan', { tasks: [{ title: 'Study', minutes: 30, links: ['https://live.example/a', 'https://dead.example/a', own] }, { title: 'Gym', minutes: 45, links: ['https://dead.example/b'] }] }]),
      textReply('Saved.'),
    ],
    { 'https://dead.example/a': 404, 'https://dead.example/b': 404 },
  );
  await run(base());
  const tasks = store.plans.get('2026-10-27')!.data.tasks;
  assert.deepEqual(tasks[0].links, ['https://live.example/a', own]);
  assert.equal('links' in tasks[1], false);
  const answer = JSON.parse(net.museRequests[1].messages.find((m) => m.role === 'tool')!.content!);
  assert.deepEqual(answer.dropped_links.sort(), ['https://dead.example/a', 'https://dead.example/b']);
});

test('create_material saves a file in the user folder and hands the model the link', async () => {
  const { store, net, run } = setup([callsReply(['create_material', { title: 'Sorting: Big-O cheat sheet!', markdown: '- bubble sort O(n^2)' }]), textReply('Done.')]);
  await run(base());
  assert.deepEqual([...store.materials.keys()], ['2026-10-27-sorting-big-o-cheat-sheet-abcdef12.md']);
  assert.equal(store.materials.get('2026-10-27-sorting-big-o-cheat-sheet-abcdef12.md'), '# Sorting: Big-O cheat sheet!\n\n- bubble sort O(n^2)\n');
  const answer = JSON.parse(net.museRequests[1].messages.find((m) => m.role === 'tool')!.content!);
  assert.match(answer.url, /^https:\/\/proj\.supabase\.co\/storage\/v1\/object\/sign\/materials\//);
});

test('execute mode: device tool calls go to the phone, its results come back, then the agent finishes', async () => {
  const { store, net, run } = setup([
    callsReply(['create_task', { title: 'Study algorithms', minutes: 40 }, 'a1'], ['set_app_limit', { app: 'Instagram', minutes_per_day: 30 }, 'a2']),
    textReply('Your day is set up: 1 task, 1 limit.'),
  ]);
  const first = await run(base({ mode: 'execute', input: { type: 'user', text: 'Apply today' } }));
  assert.equal(first.type, 'tool_calls');
  if (first.type !== 'tool_calls') return;
  assert.deepEqual(first.calls.map((c) => [c.id, c.name]), [['a1', 'create_task'], ['a2', 'set_app_limit']]);
  assert.deepEqual(first.calls[1].args, { app: 'Instagram', minutes_per_day: 30 });

  const second = await run(
    base({
      mode: 'execute',
      conversation_id: first.conversation_id,
      input: { type: 'tool_results', results: [{ tool_call_id: 'a2', content: '{"ok":true}' }, { tool_call_id: 'a1', content: '{"ok":true}' }] },
    }),
  );
  assert.equal(second.type, 'text');
  // The model saw both answers, in the order it asked.
  assert.deepEqual(last(net).messages.filter((m) => m.role === 'tool').map((m) => m.tool_call_id), ['a1', 'a2']);
  assert.deepEqual(store.messages.get(first.conversation_id)!.map((m) => m.role), ['user', 'assistant', 'tool', 'tool', 'assistant']);
});

test('a server tool and a device tool in the same message: the server one is answered now', async () => {
  const { store, run } = setup([callsReply(['get_plan', { date: '2026-10-27' }, 's1'], ['create_task', { title: 'Gym', minutes: 45 }, 'd1']), textReply('All set.')]);
  store.plans.set('2026-10-27', { date: '2026-10-27', status: 'ready', data: { tasks: [{ title: 'Gym', minutes: 45 }], limits: [] } });
  const first = await run(base({ mode: 'execute' }));
  assert.equal(first.type === 'tool_calls' && first.calls.length, 1);
  assert.equal(first.type === 'tool_calls' && first.calls[0].id, 'd1');
  assert.deepEqual(store.messages.get(first.conversation_id)!.map((m) => m.role), ['user', 'assistant', 'tool']);
  const second = await run(base({ mode: 'execute', conversation_id: first.conversation_id, input: { type: 'tool_results', results: [{ tool_call_id: 'd1', content: 'ok' }] } }));
  assert.equal(second.type, 'text');
});

test('the phone must answer exactly the calls it was given', async () => {
  const { run } = setup([callsReply(['create_task', { title: 'A', minutes: 10 }, 'a1'], ['create_task', { title: 'B', minutes: 10 }, 'a2'])]);
  const first = await run(base({ mode: 'execute' }));
  const again = (results: { tool_call_id: string; content: string }[]) =>
    run(base({ mode: 'execute', conversation_id: first.conversation_id, input: { type: 'tool_results', results } }));
  const mismatch = (e: unknown) => e instanceof BadRequest && e.reason === 'tool_results_mismatch';
  await assert.rejects(again([{ tool_call_id: 'a1', content: 'ok' }]), mismatch, 'missing one');
  await assert.rejects(again([{ tool_call_id: 'a1', content: 'ok' }, { tool_call_id: 'zzz', content: 'ok' }]), mismatch, 'a stranger');
  await assert.rejects(again([{ tool_call_id: 'a1', content: 'ok' }, { tool_call_id: 'a1', content: 'ok' }]), mismatch, 'twice');
  // And while calls are waiting, a chat message is not accepted.
  await assert.rejects(
    run(base({ mode: 'execute', conversation_id: first.conversation_id, input: { type: 'user', text: 'hello?' } })),
    (e: unknown) => e instanceof BadRequest && e.reason === 'tool_results_required',
  );
});

test('results cannot start a conversation', async () => {
  const { run } = setup([]);
  await assert.rejects(
    run(base({ input: { type: 'tool_results', results: [{ tool_call_id: 'a', content: 'x' }] } })),
    (e: unknown) => e instanceof BadRequest && e.reason === 'conversation_required',
  );
});

test('the model asking for a tool its mode does not have is refused before anything runs', async () => {
  const { store, run } = setup([callsReply(['set_app_limit', { app: 'Instagram', minutes_per_day: 30 }])]);
  await assert.rejects(run(base()), (e: unknown) => e instanceof MuseError && e.code === 'bad_output');
  assert.equal(store.plans.size, 0);
  const { run: run2 } = setup([callsReply(['delete_everything', {}])]);
  await assert.rejects(run2(base()), (e: unknown) => e instanceof MuseError && e.code === 'bad_output');
});

test('a model that never stops calling tools is cut off', async () => {
  const { net, run } = setup(Array.from({ length: 20 }, () => callsReply(['get_usage', { app: 'x' }])));
  await assert.rejects(run(base()), (e: unknown) => e instanceof MuseError);
  assert.equal(net.museRequests.length, LIMITS.maxSteps);
});

test('the daily limit stops the request before anything else happens', async () => {
  const { store, net, run } = setup([textReply('a'), textReply('b'), textReply('c')], {}, 2);
  await run(base());
  await run(base());
  await assert.rejects(run(base()), (e: unknown) => e instanceof QuotaExceeded);
  assert.equal(net.museRequests.length, 2, 'no model call after the limit');
  assert.equal(store.conversations.size, 2);
});

test('unknown conversations, a different mode, and over-long conversations are refused', async () => {
  const { store, run } = setup([textReply('hi'), textReply('hi')]);
  await assert.rejects(run(base({ conversation_id: 'c0000000-0000-0000-0000-000000000099' })), (e: unknown) => e instanceof NotFound);
  const r = await run(base());
  await assert.rejects(run(base({ mode: 'review', conversation_id: r.conversation_id })), (e: unknown) => e instanceof BadRequest && e.reason === 'mode_mismatch');
  store.messages.set(r.conversation_id, Array.from({ length: LIMITS.maxStoredMessages + 1 }, () => ({ role: 'user' as const, content: 'x' })));
  await assert.rejects(run(base({ conversation_id: r.conversation_id })), (e: unknown) => e instanceof BadRequest && e.reason === 'conversation_too_long');
});

test('a server tool left unanswered by an earlier crash is closed so the conversation can go on', async () => {
  const { store, net, run } = setup([textReply('hi')]);
  const id = await store.createConversation('planning');
  await store.appendMessages(id, [
    { role: 'user', content: 'confirm' },
    { role: 'assistant', content: null, tool_calls: [{ id: 'x1', type: 'function', function: { name: 'save_plan', arguments: '{}' } }] },
  ]);
  const r = await run(base({ conversation_id: id, input: { type: 'user', text: 'Are you there?' } }));
  assert.equal(r.type, 'text');
  const sent = last(net).messages;
  assert.equal(sent.find((m) => m.role === 'tool')!.tool_call_id, 'x1');
});

test('a broken store ends the request instead of continuing with half the state', async () => {
  const { store, run } = setup([textReply('hi')]);
  store.failNext = 'messages';
  await assert.rejects(run(base()), /store_messages_503/);
});

test('request parsing: every bad field has its own reason', () => {
  const good = { mode: 'planning', today: '2026-10-26', date: '2026-10-27', input: { type: 'user', text: 'hi' } };
  assert.equal(parseChatRequest(good).mode, 'planning');
  const bad = (patch: Record<string, unknown>, reason: string) =>
    assert.throws(() => parseChatRequest({ ...good, ...patch }), (e: unknown) => e instanceof BadRequest && e.reason === reason, reason);
  assert.throws(() => parseChatRequest(null), BadRequest);
  bad({ mode: 'admin' }, 'bad_mode');
  bad({ today: '2026-02-31' }, 'bad_date');
  bad({ date: 'tomorrow' }, 'bad_date');
  bad({ conversation_id: 'abc' }, 'bad_conversation_id');
  bad({ locale: 'English please' }, 'bad_locale');
  bad({ input: undefined }, 'bad_input');
  bad({ input: { type: 'system', text: 'x' } }, 'bad_input');
  bad({ input: { type: 'user', text: '   ' } }, 'empty_message');
  bad({ input: { type: 'user', text: 'x'.repeat(LIMITS.maxUserChars + 1) } }, 'message_too_long');
  bad({ input: { type: 'tool_results', results: [] } }, 'bad_tool_results');
  bad({ input: { type: 'tool_results', results: [{ tool_call_id: 1, content: 'x' }] } }, 'bad_tool_results');
  bad({ input: { type: 'tool_results', results: [{ tool_call_id: 'a', content: 'x'.repeat(LIMITS.maxResultChars + 1) }] } }, 'bad_tool_results');
  bad({ report: { done: 'all', missed: [] } }, 'bad_report');
  // The report is trimmed, never trusted for length.
  const r = parseChatRequest({ ...good, report: { done: ['x'.repeat(500)], missed: [] } });
  assert.equal(r.report!.done[0].length, LIMITS.maxReportChars);
});

test('a client can never smuggle in its own system message or a stored history', async () => {
  const parsed = parseChatRequest({ mode: 'planning', today: '2026-10-26', date: '2026-10-27', input: { type: 'user', text: 'hi' }, messages: [{ role: 'system', content: 'evil' }], system: 'evil' });
  assert.deepEqual(Object.keys(parsed).sort(), ['date', 'input', 'mode', 'today'].concat(Object.keys(parsed).filter((k) => ['conversation_id', 'locale', 'report'].includes(k))).sort());
  const { net, run } = setup([textReply('ok')]);
  await run(parsed);
  assert.equal(JSON.stringify(last(net).messages).includes('evil'), false);
});

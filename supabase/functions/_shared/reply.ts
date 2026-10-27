// What the person reads. The model sometimes writes markdown, pastes long file links, or shows its own reasoning;
// none of that belongs in a chat bubble (files arrive as cards, and the plan holds the links).

const REASONING_TAGS = 'think|thinking|thought|reasoning|reflection|scratchpad';

/** Drops reasoning the model put in its answer: <think>...</think>, a stray closing tag, or one that never closes. */
export function stripReasoning(text: string): string {
  let out = text.replace(new RegExp(`<(${REASONING_TAGS})>[\\s\\S]*?</\\1>`, 'gi'), '');
  const closer = new RegExp(`</(${REASONING_TAGS})>`, 'gi');
  let last = -1;
  for (const m of out.matchAll(closer)) last = m.index! + m[0].length;
  if (last >= 0) out = out.slice(last); // reasoning came first and was cut at the start
  out = out.replace(new RegExp(`<(${REASONING_TAGS})>[\\s\\S]*$`, 'i'), ''); // never closed
  return out.trim();
}

/** A link to one of our own private files (long, with a token): the phone shows these as cards. */
const STORED_FILE_LINK = /https?:\/\/[^\s)\]]*\/storage\/v1\/object\/sign\/[^\s)\]]*/gi;

/** Plain text for a chat bubble: no reasoning, no markdown marks, no file links. */
export function cleanReply(text: string): string {
  const plain = stripReasoning(text);
  let out = plain
    .replace(STORED_FILE_LINK, '')
    .replace(/(\*\*|__)(.+?)\1/g, '$2')
    .replace(/(^|[\s(])\*([^*\s][^*\n]*?)\*(?=[\s).,;:!?]|$)/g, '$1$2')
    .replace(/^[ \t]{0,3}#{1,6}[ \t]+/gm, '')
    .replace(/^[ \t]*[*+][ \t]+/gm, '- ')
    .replace(/`+/g, '')
    .replace(/[ \t]+$/gm, '')
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  // A line that was only a label for a removed link ("1. Big-O sheet:") keeps its label; an empty result falls back to the text as written.
  if (out === '') out = plain;
  return out;
}

/**
 * Splits the "SPOKEN: ..." last line off a reply. The rest is what is shown on screen; the line is what is said aloud.
 * Without such a line the whole reply is shown and nothing special is said (the phone makes its own short version).
 */
export function splitSpoken(text: string): { text: string; spoken?: string } {
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim() === '') continue;
    const m = lines[i].match(/^[\s*_>#-]*spoken[\s*_]*:[\s*_]*(.*)$/i);
    if (!m) break;
    const spoken = m[1].replace(/[*_`]+/g, '').replace(/\s+/g, ' ').trim();
    const shown = lines.slice(0, i).join('\n').trim();
    if (shown === '') break; // a reply that is only a spoken line: show it as it is
    return spoken === '' ? { text: shown } : { text: shown, spoken: spoken.slice(0, 400) };
  }
  return { text };
}

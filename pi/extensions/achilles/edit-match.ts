/**
 * pi's edit-tool semantics, ported so the bridge can compute exactly what a pi `edit` call will write.
 *
 * Ported from @earendil-works/pi-coding-agent 0.87.1 (MIT License, Copyright (c) Earendil Works):
 *   dist/core/tools/edit-diff.js  (detectLineEnding, normalizeToLF, restoreLineEndings,
 *                                  normalizeForFuzzyMatch, fuzzyFindText, countOccurrences,
 *                                  applyReplacementsPreservingUnchangedLines, applyEditsToNormalizedContent)
 *   dist/core/tools/edit.js       (the read / splitBom / normalize / apply / restore pipeline of execute())
 *   dist/core/tools/path-utils.js + dist/utils/paths.js (resolveToCwd)
 *   dist/utils/text.js            (splitBom)
 * These are not exported from the package, so they are copied here. Keep them in step with pi;
 * pi/tests/edit-parity.test.mjs compares this port with the installed pi.
 */
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export interface PiEdit { oldText: string; newText: string }
interface Match { found: boolean; index: number; matchLength: number; usedFuzzyMatch: boolean; contentForReplacement: string }
interface Replacement { editIndex: number; matchIndex: number; matchLength: number; newText: string }

export function splitBom(content: string): { bom: string; text: string } {
  return content.startsWith('﻿') ? { bom: '﻿', text: content.slice(1) } : { bom: '', text: content };
}

export function detectLineEnding(content: string): '\r\n' | '\n' {
  const crlfIdx = content.indexOf('\r\n');
  const lfIdx = content.indexOf('\n');
  if (lfIdx === -1) return '\n';
  if (crlfIdx === -1) return '\n';
  return crlfIdx < lfIdx ? '\r\n' : '\n';
}

export function normalizeToLF(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

export function restoreLineEndings(text: string, ending: string): string {
  return ending === '\r\n' ? text.replace(/\n/g, '\r\n') : text;
}

export function normalizeForFuzzyMatch(text: string): string {
  return text
    .normalize('NFKC')
    .split('\n')
    .map((line) => line.trimEnd())
    .join('\n')
    .replace(/[‘’‚‛]/g, "'")
    .replace(/[“”„‟]/g, '"')
    .replace(/[‐‑‒–—―−]/g, '-')
    .replace(/[  -   　]/g, ' ');
}

function splitLinesWithEndings(content: string): string[] {
  return content.match(/[^\n]*\n|[^\n]+/g) ?? [];
}

function getLineSpans(content: string): Array<{ start: number; end: number }> {
  let offset = 0;
  return splitLinesWithEndings(content).map((line) => {
    const span = { start: offset, end: offset + line.length };
    offset = span.end;
    return span;
  });
}

function getReplacementLineRange(lines: Array<{ start: number; end: number }>, r: Replacement): { startLine: number; endLine: number } {
  const replacementStart = r.matchIndex;
  const replacementEnd = r.matchIndex + r.matchLength;
  let startLine = -1;
  for (let i = 0; i < lines.length; i++) {
    if (replacementStart >= lines[i].start && replacementStart < lines[i].end) { startLine = i; break; }
  }
  if (startLine === -1) throw new Error('Replacement range is outside the base content.');
  let endLine = startLine;
  while (endLine < lines.length && lines[endLine].end < replacementEnd) endLine++;
  if (endLine >= lines.length) throw new Error('Replacement range is outside the base content.');
  return { startLine, endLine: endLine + 1 };
}

function applyReplacements(content: string, replacements: Replacement[], offset = 0): string {
  let result = content;
  for (let i = replacements.length - 1; i >= 0; i--) {
    const r = replacements[i];
    const matchIndex = r.matchIndex - offset;
    result = result.substring(0, matchIndex) + r.newText + result.substring(matchIndex + r.matchLength);
  }
  return result;
}

function applyReplacementsPreservingUnchangedLines(originalContent: string, baseContent: string, replacements: Replacement[]): string {
  const originalLines = splitLinesWithEndings(originalContent);
  const baseLines = getLineSpans(baseContent);
  if (originalLines.length !== baseLines.length) {
    throw new Error('Cannot preserve unchanged lines because the base content has a different line count.');
  }
  const groups: Array<{ startLine: number; endLine: number; replacements: Replacement[] }> = [];
  const sorted = [...replacements].sort((a, b) => a.matchIndex - b.matchIndex);
  for (const r of sorted) {
    const range = getReplacementLineRange(baseLines, r);
    const current = groups[groups.length - 1];
    if (current && range.startLine < current.endLine) {
      current.endLine = Math.max(current.endLine, range.endLine);
      current.replacements.push(r);
      continue;
    }
    groups.push({ ...range, replacements: [r] });
  }
  let originalLineIndex = 0;
  let result = '';
  for (const group of groups) {
    result += originalLines.slice(originalLineIndex, group.startLine).join('');
    const groupStartOffset = baseLines[group.startLine].start;
    const groupEndOffset = baseLines[group.endLine - 1].end;
    result += applyReplacements(baseContent.slice(groupStartOffset, groupEndOffset), group.replacements, groupStartOffset);
    originalLineIndex = group.endLine;
  }
  result += originalLines.slice(originalLineIndex).join('');
  return result;
}

export function fuzzyFindText(content: string, oldText: string): Match {
  const exactIndex = content.indexOf(oldText);
  if (exactIndex !== -1) {
    return { found: true, index: exactIndex, matchLength: oldText.length, usedFuzzyMatch: false, contentForReplacement: content };
  }
  const fuzzyContent = normalizeForFuzzyMatch(content);
  const fuzzyOldText = normalizeForFuzzyMatch(oldText);
  const fuzzyIndex = fuzzyContent.indexOf(fuzzyOldText);
  if (fuzzyIndex === -1) {
    return { found: false, index: -1, matchLength: 0, usedFuzzyMatch: false, contentForReplacement: content };
  }
  return { found: true, index: fuzzyIndex, matchLength: fuzzyOldText.length, usedFuzzyMatch: true, contentForReplacement: fuzzyContent };
}

export function countOccurrences(content: string, oldText: string): number {
  return normalizeForFuzzyMatch(content).split(normalizeForFuzzyMatch(oldText)).length - 1;
}

/** pi's applyEditsToNormalizedContent. Throws (with pi's reason) wherever pi rejects the edit. */
export function applyEditsToNormalizedContent(normalizedContent: string, edits: PiEdit[], filePath: string): { baseContent: string; newContent: string } {
  const normalizedEdits = edits.map((e) => ({ oldText: normalizeToLF(e.oldText), newText: normalizeToLF(e.newText) }));
  const n = normalizedEdits.length;
  for (let i = 0; i < n; i++) {
    if (normalizedEdits[i].oldText.length === 0) throw new Error(n === 1 ? `oldText must not be empty in ${filePath}.` : `edits[${i}].oldText must not be empty in ${filePath}.`);
  }
  const initialMatches = normalizedEdits.map((e) => fuzzyFindText(normalizedContent, e.oldText));
  const usedFuzzyMatch = initialMatches.some((m) => m.usedFuzzyMatch);
  const replacementBaseContent = usedFuzzyMatch ? normalizeForFuzzyMatch(normalizedContent) : normalizedContent;
  const matched: Replacement[] = [];
  for (let i = 0; i < n; i++) {
    const e = normalizedEdits[i];
    const m = fuzzyFindText(replacementBaseContent, e.oldText);
    if (!m.found) throw new Error(n === 1 ? `Could not find the exact text in ${filePath}.` : `Could not find edits[${i}] in ${filePath}.`);
    const occurrences = countOccurrences(replacementBaseContent, e.oldText);
    if (occurrences > 1) throw new Error(n === 1 ? `Found ${occurrences} occurrences of the text in ${filePath}.` : `Found ${occurrences} occurrences of edits[${i}] in ${filePath}.`);
    matched.push({ editIndex: i, matchIndex: m.index, matchLength: m.matchLength, newText: e.newText });
  }
  matched.sort((a, b) => a.matchIndex - b.matchIndex);
  for (let i = 1; i < matched.length; i++) {
    const prev = matched[i - 1], cur = matched[i];
    if (prev.matchIndex + prev.matchLength > cur.matchIndex) throw new Error(`edits[${prev.editIndex}] and edits[${cur.editIndex}] overlap in ${filePath}.`);
  }
  const baseContent = normalizedContent;
  const newContent = usedFuzzyMatch
    ? applyReplacementsPreservingUnchangedLines(normalizedContent, replacementBaseContent, matched)
    : applyReplacements(replacementBaseContent, matched);
  if (baseContent === newContent) throw new Error(`No changes made to ${filePath}.`);
  return { baseContent, newContent };
}

/** The bytes pi's edit tool writes for `edits` applied to the decoded file `raw`; throws where pi rejects. */
export function applyPiEdits(raw: string, edits: PiEdit[], filePath = 'file'): string {
  const { bom, text } = splitBom(raw);
  const ending = detectLineEnding(text);
  const { newContent } = applyEditsToNormalizedContent(normalizeToLF(text), edits, filePath);
  return bom + restoreLineEndings(newContent, ending);
}

const UNICODE_SPACES = /[  -   　]/g;

/** pi's resolveToCwd (POSIX): Unicode spaces to ' ', strip a leading '@', expand '~', accept file:// URLs. */
export function resolveToCwd(filePath: string, cwd: string, home: string = os.homedir()): string {
  let p = filePath.replace(UNICODE_SPACES, ' ');
  if (p.startsWith('@')) p = p.slice(1);
  if (p === '~') p = home;
  else if (p.startsWith('~/')) p = path.join(home, p.slice(2));
  else if (/^file:\/\//.test(p)) p = fileURLToPath(p);
  return path.isAbsolute(p) ? path.resolve(p) : path.resolve(cwd, p);
}

/** True when `needle` occurs exactly once in `hay` (overlapping occurrences count). */
function unique(hay: string, needle: string): boolean {
  if (!needle) return false;
  const at = hay.indexOf(needle);
  return at >= 0 && hay.indexOf(needle, at + 1) < 0;
}

/**
 * The smallest whole-line span of `before` that, replaced, yields `after`, and whose text occurs
 * exactly once in `before`: trim the common prefix and suffix, widen to line boundaries, then widen
 * one line each way until the span is unique (capped at the whole file).
 */
export function minimalSpan(before: string, after: string): { old_string: string; new_string: string } {
  let pre = 0;
  const max = Math.min(before.length, after.length);
  while (pre < max && before[pre] === after[pre]) pre++;
  let suf = 0;
  while (suf < max - pre && before[before.length - 1 - suf] === after[after.length - 1 - suf]) suf++;
  const lineStart = (i: number) => (i <= 0 ? 0 : before.lastIndexOf('\n', i - 1) + 1);
  const lineEnd = (i: number) => (i <= 0 || before[i - 1] === '\n' ? i : before.indexOf('\n', i) + 1 || before.length);
  let start = lineStart(pre);
  let end = lineEnd(before.length - suf);
  while (!unique(before, before.slice(start, end)) && (start > 0 || end < before.length)) {
    if (start > 0) start = lineStart(start - 1);
    if (end < before.length) end = before.indexOf('\n', end) + 1 || before.length;
  }
  const tail = before.length - end;
  return { old_string: before.slice(start, end), new_string: after.slice(start, after.length - tail) };
}

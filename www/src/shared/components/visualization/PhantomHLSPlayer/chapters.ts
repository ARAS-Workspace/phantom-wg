// ── Two-tier chapter data ────────────────────────────────────────
// Single source of truth: main chapters (→ player VTT) each holding
// optional sub-chapters (→ dynamic ChapterStrip). Main-chapter times
// live ONLY here, so the VTT and the strip can never drift.

export interface SubChapter {
  /** Sub-chapter label. */
  title: string;
  /** Start time in seconds. */
  start: number;
}

export interface MainChapter {
  /** Main-chapter label — shown in the player's native chapters. */
  title: string;
  /** Start time in seconds. */
  start: number;
  /** Sub-steps for this chapter. Empty → the strip shows the main
   *  chapter itself as a single item. */
  chapters: SubChapter[];
}

export type ChaptersData = MainChapter[];

// Structurally matches the `Chapter` type that ChapterStrip consumes
// ({ slug, label, start }). Kept as a local type so this module has no
// dependency on the app's shared types; TypeScript structural typing
// makes StripItem[] assignable to Chapter[] since the fields line up.
export interface StripItem {
  slug: string;
  label: string;
  start: number;
}

// ── Derivation 1: WebVTT for the player (from main chapters) ──────
// Each cue runs from its start to the next main chapter's start; the
// last cue runs to `duration` (known once the player has metadata).

function toVTTTimestamp(seconds: number): string {
  const hh = Math.floor(seconds / 3600);
  const mm = Math.floor((seconds % 3600) / 60);
  const ss = Math.floor(seconds % 60);
  const ms = Math.round((seconds - Math.floor(seconds)) * 1000);
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  return `${pad(hh)}:${pad(mm)}:${pad(ss)}.${pad(ms, 3)}`;
}

export function generateVTT(data: ChaptersData, duration: number): string {
  const lines = ['WEBVTT', ''];
  data.forEach((main, i) => {
    const start = main.start;
    const end = data[i + 1]?.start ?? duration;
    lines.push(`${toVTTTimestamp(start)} --> ${toVTTTimestamp(end)}`);
    lines.push(main.title);
    lines.push('');
  });
  return lines.join('\n').trim();
}

// ── Derivation 2: strip items for the active main chapter ─────────
// Given the playhead, find which main chapter we're in, then return
// its sub-chapters as strip items. If it has none, return the main
// chapter itself as a single item (strip is never empty).

export function getActiveStripItems(
  data: ChaptersData,
  currentTime: number,
): StripItem[] {
  if (data.length === 0) return [];

  // Find the active main chapter: last one whose start <= currentTime.
  let activeIndex = 0;
  for (let i = 0; i < data.length; i++) {
    if (currentTime >= data[i].start) activeIndex = i;
    else break;
  }

  const main = data[activeIndex];

  if (main.chapters.length === 0) {
    // No sub-chapters → show the main chapter as a single strip item.
    return [{ slug: `main-${activeIndex}`, label: main.title, start: main.start }];
  }

  return main.chapters.map((sub, j) => ({
    slug: `sub-${activeIndex}-${j}`,
    label: sub.title,
    start: sub.start,
  }));
}
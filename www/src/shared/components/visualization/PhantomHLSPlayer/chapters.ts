// ── Chapter data (player-native, VTT only) ───────────────────────
// A flat list of main chapters. Each becomes a cue in a WebVTT
// `chapters` track handed to the player, which renders them natively
// (timeline splits + settings-menu list + active chapter title). No
// custom strip — the player owns the entire chapter experience.
//
// Times are authored as FCP timecodes "HH:MM:SS:FF" (frame-accurate,
// copy-paste straight from Final Cut) and converted to seconds without
// rounding. The frame rate travels WITH the data (`fps`), since the
// frame field (FF) is meaningless without it — falls back to DEFAULT_FPS.

/** Default frame rate if a ChaptersData omits `fps`. */
export const DEFAULT_FPS = 30;

/** "HH:MM:SS:FF" timecode string (FF = frame, 0..fps-1). */
export type Timecode = string;

export interface Chapter {
  /** Chapter label — shown in the player's native chapters UI. */
  title: string;
  /** Start timecode "HH:MM:SS:FF". */
  start: Timecode;
}

/**
 * The chapters payload. `fps` is the frame rate the timecodes were
 * authored at (needed to interpret the FF field). Optional — omitted
 * data is read at DEFAULT_FPS.
 */
export interface ChaptersData {
  /** Frame rate for timecode → seconds conversion. Defaults to 30. */
  fps?: number;
  /** Ordered chapters. */
  chapters: Chapter[];
}

// ── Timecode → seconds (frame-accurate, no rounding) ─────────────
// "00:01:42:05" @ 30fps → 102 + 5/30 = 102.16666… (full precision).

export function timecodeToSeconds(tc: Timecode, fps: number): number {
  const parts = tc.split(':').map(Number);
  if (parts.length !== 4 || parts.some(Number.isNaN)) {
    throw new Error(`Invalid timecode "${tc}" (expected "HH:MM:SS:FF")`);
  }
  const [h, m, s, f] = parts;
  return h * 3600 + m * 60 + s + f / fps;
}

// ── WebVTT for the player's native chapters ──────────────────────
// Each cue runs from its start to the next chapter's start; the last
// cue runs to `duration` (known once the player has metadata).

function toVTTTimestamp(seconds: number): string {
  const hh = Math.floor(seconds / 3600);
  const mm = Math.floor((seconds % 3600) / 60);
  const ss = Math.floor(seconds % 60);
  const ms = Math.round((seconds - Math.floor(seconds)) * 1000);
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  return `${pad(hh)}:${pad(mm)}:${pad(ss)}.${pad(ms, 3)}`;
}

export function generateVTT(data: ChaptersData, duration: number): string {
  const fps = data.fps ?? DEFAULT_FPS;
  const chapters = data.chapters;
  const lines = ['WEBVTT', ''];
  chapters.forEach((ch, i) => {
    const start = timecodeToSeconds(ch.start, fps);
    const end = chapters[i + 1]
      ? timecodeToSeconds(chapters[i + 1].start, fps)
      : duration;
    lines.push(`${toVTTTimestamp(start)} --> ${toVTTTimestamp(end)}`);
    lines.push(ch.title);
    lines.push('');
  });
  return lines.join('\n').trim();
}

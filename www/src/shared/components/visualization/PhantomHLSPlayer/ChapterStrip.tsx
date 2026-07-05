// noinspection DuplicatedCode

import React from 'react';
import type { Chapter } from '@shared/types/chapters';
import './ChapterStrip.scss';

interface ChapterStripProps {
  chapters: Chapter[];
  /** Total video duration in seconds. */
  duration: number;
  /** Playhead position used to highlight the active segment. */
  currentTime: number;
  /** Called with the chapter start time when a segment is clicked. */
  onCue: (seconds: number) => void;
}

function formatTime(sec: number): string {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

const ChapterStrip: React.FC<ChapterStripProps> = ({
  chapters,
  duration,
  currentTime,
  onCue,
}) => {
  return (
    <div className="chapter-strip" role="list">
      {chapters.map((ch, i) => {
        const start = ch.start;
        const end = chapters[i + 1]?.start ?? duration;
        const widthPct = ((end - start) / duration) * 100;
        const active = currentTime >= start && currentTime < end;
        return (
          <button
            type="button"
            key={ch.slug}
            className={`chapter-strip__segment${active ? ' chapter-strip__segment--active' : ''}`}
            style={{ flexBasis: `${widthPct}%` }}
            onClick={() => onCue(start)}
            role="listitem"
            aria-label={`${ch.label} — ${formatTime(start)}`}
          >
            <span className="chapter-strip__label">{ch.label}</span>
            <span className="chapter-strip__time">{formatTime(start)}</span>
          </button>
        );
      })}
    </div>
  );
};

export default ChapterStrip;

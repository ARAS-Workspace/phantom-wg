import React, { useEffect, useState } from 'react';
import type { Chapter } from '@shared/types/chapters';
import './styles/ChapterStrip.scss';

const CUE_EVENT = 'phantom-stream:cue';
const TIME_EVENT = 'phantom-stream:time';

interface ChapterStripProps {
  chapters: Chapter[];
  /** Total video duration in seconds. */
  duration: number;
  /** Player wrapper selector for smooth scroll-into-view. */
  playerSelector?: string;
}

function formatTime(sec: number): string {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

const ChapterStrip: React.FC<ChapterStripProps> = ({
  chapters,
  duration,
  playerSelector = '.phantom-stream-player',
}) => {
  const [currentTime, setCurrentTime] = useState(0);

  useEffect(() => {
    const handler = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (typeof detail?.currentTime === 'number') {
        setCurrentTime(detail.currentTime);
      }
    };
    window.addEventListener(TIME_EVENT, handler);
    return () => window.removeEventListener(TIME_EVENT, handler);
  }, []);

  const handleClick = (start: number) => {
    window.dispatchEvent(
      new CustomEvent(CUE_EVENT, { detail: { seconds: start } }),
    );
    if (playerSelector) {
      document
        .querySelector(playerSelector)
        ?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  };

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
            onClick={() => handleClick(start)}
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

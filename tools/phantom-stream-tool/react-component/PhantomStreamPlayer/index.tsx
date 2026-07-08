import React, { lazy, Suspense, useEffect, useRef, useState } from 'react';
import { SkeletonPlaceholder } from '@carbon/react';
import { useTheme } from '@shared/hooks/useTheme';
import { useIsClient } from '@shared/hooks/useIsClient';
import { useLocale } from '@shared/hooks';
import type { Chapter } from '@shared/types/chapters';
import ChapterStrip from './ChapterStrip';
import './PhantomStreamPlayer.scss';

// ── Types ────────────────────────────────────────────────────────

interface ChapterStripConfig {
  /** Ordered list of chapters covering the timeline. */
  chapters: Chapter[];
}

interface PhantomStreamPlayerProps {
  /** Cloudflare Stream video UUID (phantom-stream-tool upload output). */
  uuid: string;
  /** Show player controls. Defaults to true. */
  controls?: boolean;
  /** Autoplay on mount (most browsers require `muted` as well). */
  autoplay?: boolean;
  /** Start muted. */
  muted?: boolean;
  /** Loop playback when it ends. */
  loop?: boolean;
  /** Browser preload strategy. Defaults to `'metadata'`. */
  preload?: 'none' | 'metadata' | 'auto';
  /** Custom poster image URL (falls back to Cloudflare auto-thumbnail). */
  poster?: string;
  /**
   * BCP-47 language tag for the default caption track (`'en'`, `'tr'`, …).
   * Defaults to the user's current locale.
   */
  defaultTextTrack?: string;
  /** Start position in seconds. */
  startTime?: number;
  /** Override the accent colour (play button / progress bar). Defaults to Carbon theme blue. */
  primaryColor?: string;
  /** Override the letterbox (bars) colour. Defaults to Carbon surface colour. */
  letterboxColor?: string;
  /** CSS `aspect-ratio` value for the wrapper. Defaults to `'16 / 9'`. */
  aspectRatio?: string;
  /** Accessible title for the embed (passed to the iframe and used as `aria-label`). */
  title?: string;
  /** Additional class name for the outer wrapper. */
  className?: string;
  /**
   * If present, a chapter strip is rendered under the player; clicking a
   * segment seeks the embed (auto-playing on the first cue so the poster
   * lifts). Each player owns its own strip — multiple players on a page
   * stay independent. Total duration is pulled from the player itself
   * once metadata loads.
   */
  chapterStrip?: ChapterStripConfig;
}

// ── Theme-aware defaults ─────────────────────────────────────────
// Values mirror Carbon v11 token equivalents:
//   white → blue-60 / gray-10 background
//   g100  → blue-50 / gray-100 background

const THEME_COLORS: Record<'white' | 'g100', { primary: string; letterbox: string }> = {
  white: { primary: '#0f62fe', letterbox: '#f4f4f4' },
  g100: { primary: '#4589ff', letterbox: '#161616' },
};

// ── Skeleton ─────────────────────────────────────────────────────

const PlayerSkeleton: React.FC<{ aspectRatio: string; className?: string }> = ({
  aspectRatio,
  className = '',
}) => (
  <div className={`phantom-stream-player ${className}`}>
    <div
      className="phantom-stream-player__aspect"
      style={{ aspectRatio }}
    >
      <SkeletonPlaceholder className="phantom-stream-player__skeleton" />
    </div>
  </div>
);

// ── Core (client-only, dynamically imports @cloudflare/stream-react) ─

const PhantomStreamPlayerCore: React.FC<PhantomStreamPlayerProps> = ({
  uuid,
  controls = true,
  autoplay = false,
  muted = false,
  loop = false,
  preload = 'metadata',
  poster,
  defaultTextTrack,
  startTime,
  primaryColor,
  letterboxColor,
  aspectRatio = '16 / 9',
  title,
  className = '',
  chapterStrip,
}) => {
  const { theme } = useTheme();
  const { locale } = useLocale();

  // The @cloudflare/stream-react package loads lazily on first render so
  // it never reaches the main bundle. While it resolves we keep showing
  // the Carbon skeleton.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [StreamComp, setStreamComp] = useState<React.ComponentType<any> | null>(null);

  // Stream buffers asynchronously after the iframe mounts. We keep the
  // skeleton overlay on top until the player signals it has enough data to
  // play — otherwise the user stares at a black letterbox.
  const [videoReady, setVideoReady] = useState(false);

  // Drives the chapter strip's "currently playing" highlight.
  const [currentTime, setCurrentTime] = useState(0);

  // Pulled from the player once metadata loads; the chapter strip
  // waits for this before rendering segment widths.
  const [duration, setDuration] = useState(0);

  // Imperative handle from @cloudflare/stream-react (HTMLVideoElement-shaped).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const streamRef = useRef<any>(null);

  // CF Stream keeps the poster up until playback starts; the first cue
  // also auto-plays so the user sees the chapter they asked for. Once
  // the user has played at least once, later cues only seek and leave
  // their play/pause state alone.
  const hasStartedRef = useRef(false);

  useEffect(() => {
    let cancelled = false;
    import('@cloudflare/stream-react').then((mod) => {
      if (!cancelled) setStreamComp(() => mod.Stream);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const cueTo = (seconds: number) => {
    if (!Number.isFinite(seconds) || !streamRef.current) return;
    try {
      streamRef.current.currentTime = seconds;
      if (!hasStartedRef.current) {
        const result = streamRef.current.play?.();
        if (result?.catch) {
          result.catch(() => {
            // Sound autoplay refused — retry muted so the poster
            // at least clears and frames appear.
            try {
              streamRef.current.muted = true;
              streamRef.current.play?.();
            } catch {
              /* give up silently */
            }
          });
        }
      }
    } catch {
      /* player not ready yet */
    }
  };

  const handleTimeUpdate = () => {
    setCurrentTime(streamRef.current?.currentTime ?? 0);
  };

  const handleCanPlay = () => {
    setVideoReady(true);
    // canPlay guarantees metadata is loaded, so the imperative handle's
    // duration is now valid.
    setDuration(streamRef.current?.duration ?? 0);
  };

  const themeColors = THEME_COLORS[theme] ?? THEME_COLORS.white;
  const resolvedPrimary = primaryColor ?? themeColors.primary;
  const resolvedLetterbox = letterboxColor ?? themeColors.letterbox;
  const resolvedDefaultText = defaultTextTrack ?? locale;

  return (
    <div
      className={`phantom-stream-player ${className}`}
      aria-label={title}
    >
      <div className="phantom-stream-player__aspect" style={{ aspectRatio }}>
        {StreamComp && (
          <div className="phantom-stream-player__inner">
            <StreamComp
              src={uuid}
              controls={controls}
              autoplay={autoplay}
              muted={muted}
              loop={loop}
              preload={preload}
              poster={poster}
              defaultTextTrack={resolvedDefaultText}
              startTime={startTime}
              primaryColor={resolvedPrimary}
              letterboxColor={resolvedLetterbox}
              // We drive the aspect-ratio via CSS on the wrapper, so disable
              // the built-in 16:9 padding box and let the iframe fill us.
              responsive={false}
              height="100%"
              width="100%"
              title={title}
              streamRef={streamRef}
              onCanPlay={handleCanPlay}
              onPlay={() => { hasStartedRef.current = true; }}
              onTimeUpdate={handleTimeUpdate}
            />
          </div>
        )}
        {(!StreamComp || !videoReady) && (
          <SkeletonPlaceholder className="phantom-stream-player__skeleton" />
        )}
      </div>
      {chapterStrip && duration > 0 && (
        <ChapterStrip
          chapters={chapterStrip.chapters}
          duration={duration}
          currentTime={currentTime}
          onCue={cueTo}
        />
      )}
    </div>
  );
};

// ── Lazy Wrapper ─────────────────────────────────────────────────

const LazyPhantomStreamPlayer = lazy(() =>
  Promise.resolve({ default: PhantomStreamPlayerCore }),
);

const PhantomStreamPlayer: React.FC<PhantomStreamPlayerProps> = (props) => {
  const isClient = useIsClient();
  const aspectRatio = props.aspectRatio ?? '16 / 9';

  if (!isClient) {
    return <PlayerSkeleton aspectRatio={aspectRatio} className={props.className} />;
  }

  return (
    <Suspense fallback={<PlayerSkeleton aspectRatio={aspectRatio} className={props.className} />}>
      <LazyPhantomStreamPlayer {...props} />
    </Suspense>
  );
};

export default PhantomStreamPlayer;

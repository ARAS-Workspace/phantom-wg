import React, { lazy, Suspense, useEffect, useState } from 'react';
import { SkeletonPlaceholder } from '@carbon/react';
import { useTheme } from '@shared/hooks/useTheme';
import { useIsClient } from '@shared/hooks/useIsClient';
import { useLocale } from '@shared/hooks';
import './styles/PhantomStreamPlayer.scss';

// ── Types ────────────────────────────────────────────────────────

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

  useEffect(() => {
    let cancelled = false;
    import('@cloudflare/stream-react').then((mod) => {
      if (!cancelled) setStreamComp(() => mod.Stream);
    });
    return () => {
      cancelled = true;
    };
  }, []);

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
              onCanPlay={() => setVideoReady(true)}
            />
          </div>
        )}
        {(!StreamComp || !videoReady) && (
          <SkeletonPlaceholder className="phantom-stream-player__skeleton" />
        )}
      </div>
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

import React, { lazy, Suspense, useEffect, useRef } from 'react';
import { SkeletonPlaceholder } from '@carbon/react';
import {
  MediaPlayer,
  MediaProvider,
  Poster,
  Track,
  isHLSProvider,
  useMediaState,
  type MediaPlayerInstance,
  type MediaProviderAdapter,
  type MediaProviderChangeEvent,
} from '@vidstack/react';
import {
  defaultLayoutIcons,
  DefaultVideoLayout,
} from '@vidstack/react/player/layouts/default';
import { useTheme } from '@shared/hooks/useTheme';
import { useIsClient } from '@shared/hooks/useIsClient';
import { useLocale } from '@shared/hooks';
import { type ChaptersData, generateVTT } from './chapters';

// Vidstack styles — theme + the default video layout skin.
import '@vidstack/react/player/styles/default/theme.css';
import '@vidstack/react/player/styles/default/layouts/video.css';
import './PhantomHLSPlayer.scss';

// ── Types ────────────────────────────────────────────────────────

interface CaptionTrack {
  /** BCP-47 language tag (`'en'`, `'tr'`, …). */
  srclang: string;
  /** Human-readable label shown in the track menu. */
  label: string;
  /** WebVTT file URL. */
  src: string;
}

interface PhantomHLSPlayerProps {
  /**
   * HLS master playlist URL, e.g.
   * `https://media.phantom.tc/quickstart/master.m3u8`
   * (output of phantom-hls-encode.sh, served from R2).
   */
  src: string;
  /** Autoplay on mount (most browsers require `muted` as well). */
  autoplay?: boolean;
  /** Start muted. */
  muted?: boolean;
  /** Loop playback when it ends. */
  loop?: boolean;
  /** Poster image URL shown before playback starts. */
  poster?: string;
  /** Optional caption tracks (WebVTT). */
  captions?: CaptionTrack[];
  /**
   * BCP-47 language tag for the default caption track (`'en'`, `'tr'`, …).
   * Defaults to the user's current locale.
   */
  defaultTextTrack?: string;
  /** Start position in seconds. */
  startTime?: number;
  /** Override the letterbox (bars) colour. Defaults to Carbon surface colour. */
  letterboxColor?: string;
  /** CSS `aspect-ratio` value for the wrapper. Defaults to `'16 / 9'`. */
  aspectRatio?: string;
  /** Accessible title for the player. */
  title?: string;
  /** Additional class name for the outer wrapper. */
  className?: string;
  /**
   * Chapters for the player's native chapter UI. A flat list of
   * (title + start) becomes a WebVTT chapters track — timeline splits,
   * settings-menu list, and active chapter title, all rendered by the
   * player. Omit for a plain player with no chapter track.
   */
  chaptersData?: ChaptersData;
}

// ── Theme-aware letterbox ────────────────────────────────────────

const THEME_LETTERBOX: Record<'white' | 'g100', string> = {
  white: '#f4f4f4',
  g100: '#161616',
};

// ── Skeleton ─────────────────────────────────────────────────────

const PlayerSkeleton: React.FC<{ aspectRatio: string; className?: string }> = ({
                                                                                 aspectRatio,
                                                                                 className = '',
                                                                               }) => (
    <div className={`phantom-hls-player ${className}`}>
      <div className="phantom-hls-player__aspect" style={{ aspectRatio }}>
        <SkeletonPlaceholder className="phantom-hls-player__skeleton" />
      </div>
    </div>
);

// ── Core (client-only) ───────────────────────────────────────────

const PhantomHLSPlayerCore: React.FC<PhantomHLSPlayerProps> = ({
                                                                 src,
                                                                 autoplay = false,
                                                                 muted = false,
                                                                 loop = false,
                                                                 poster,
                                                                 captions,
                                                                 defaultTextTrack,
                                                                 startTime,
                                                                 letterboxColor,
                                                                 aspectRatio = '16 / 9',
                                                                 title,
                                                                 className = '',
                                                                 chaptersData,
                                                               }) => {
  const { theme } = useTheme();
  const { locale } = useLocale();

  const player = useRef<MediaPlayerInstance>(null);

  // Skeleton overlay stays up until the player can play. `canPlay` is a
  // Vidstack media-state flag that flips once metadata + first frames are
  // ready — this covers the mobile case where native `canplay` alone was
  // unreliable.
  const canPlay = useMediaState('canPlay', player);
  const duration = useMediaState('duration', player);

  // Build the player's native chapter track from the main chapters, once
  // duration is known (needed for the final cue's end time). Added
  // programmatically via textTracks.add — the reliable path (a blob/src
  // <track> can mis-parse and only show the first cue).
  useEffect(() => {
    const p = player.current;
    if (!chaptersData || !duration || !p) return;

    const vtt = generateVTT(chaptersData, duration);
    p.textTracks.add({
      kind: 'chapters',
      language: 'en-US',
      default: true,
      type: 'vtt',
      content: vtt,
    });

    // Grab the track we just added (last one) so we can remove it on
    // cleanup. textTracks.add doesn't return a removable handle typed as
    // TextTrack here, so we look it up by kind from the list.
    return () => {
      try {
        const tracks = p.textTracks;
        // getById is not reliable across versions; find the chapters track.
        for (let i = tracks.length - 1; i >= 0; i--) {
          const t = tracks[i];
          if (t && t.kind === 'chapters') {
            tracks.remove(t);
            break;
          }
        }
      } catch {
        /* track already gone */
      }
    };
  }, [chaptersData, duration]);

  // Apply the requested start position once the player is ready.
  useEffect(() => {
    if (startTime && canPlay && player.current && player.current.currentTime === 0) {
      player.current.currentTime = startTime;
    }
  }, [canPlay, startTime]);

  // Load hls.js from our own bundle instead of the default JSDelivr CDN.
  // `library` is set on the HLS provider here (there is no `library` prop),
  // giving us an offline-capable, self-hosted hls.js with no external CDN
  // runtime dependency. hls.js stays a managed npm dependency.
  const handleProviderChange = (
      provider: MediaProviderAdapter | null,
      _nativeEvent: MediaProviderChangeEvent,
  ) => {
    if (isHLSProvider(provider)) {
      provider.library = () => import('hls.js');
    }
  };

  const resolvedLetterbox =
      letterboxColor ?? THEME_LETTERBOX[theme] ?? THEME_LETTERBOX.white;
  const resolvedDefaultText = defaultTextTrack ?? locale;

  // Map the app theme onto Vidstack's own color scheme. Vidstack applies
  // its light/dark styles from this prop — same idea as Asciinema's
  // `theme` option: hand the library the scheme, it restyles itself. No
  // CSS-variable overrides needed. When `theme` changes, this prop
  // changes and Vidstack re-applies its styles.
  const colorScheme = theme === 'g100' ? 'dark' : 'light';

  return (
      <div
          className={`phantom-hls-player ${className}`}
          style={
            {
              '--phantom-hls-letterbox': resolvedLetterbox,
            } as React.CSSProperties
          }
      >
        <div className="phantom-hls-player__aspect" style={{ aspectRatio }}>
          <MediaPlayer
              ref={player}
              className="phantom-hls-player__vds"
              title={title}
              // Explicit HLS type hint so the provider always picks hls.js.
              src={{ src, type: 'application/vnd.apple.mpegurl' }}
              poster={poster}
              autoPlay={autoplay}
              muted={muted}
              loop={loop}
              playsInline
              onProviderChange={handleProviderChange}
          >
            <MediaProvider>
              {poster && <Poster className="vds-poster" src={poster} alt={title ?? ''} />}
              {captions?.map((t) => (
                  <Track
                      key={t.srclang}
                      kind="subtitles"
                      src={t.src}
                      label={t.label}
                      lang={t.srclang}
                      default={t.srclang === resolvedDefaultText}
                  />
              ))}
            </MediaProvider>

            {/* Polished, pre-built controls + buffering spinner. */}
            <DefaultVideoLayout icons={defaultLayoutIcons} colorScheme={colorScheme} />
          </MediaPlayer>

          {!canPlay && (
              <SkeletonPlaceholder className="phantom-hls-player__skeleton" />
          )}
        </div>
      </div>
  );
};

// ── Lazy Wrapper ─────────────────────────────────────────────────

const LazyPhantomHLSPlayer = lazy(() =>
    Promise.resolve({ default: PhantomHLSPlayerCore }),
);

const PhantomHLSPlayer: React.FC<PhantomHLSPlayerProps> = (props) => {
  const isClient = useIsClient();
  const aspectRatio = props.aspectRatio ?? '16 / 9';

  if (!isClient) {
    return <PlayerSkeleton aspectRatio={aspectRatio} className={props.className} />;
  }

  return (
      <Suspense fallback={<PlayerSkeleton aspectRatio={aspectRatio} className={props.className} />}>
        <LazyPhantomHLSPlayer {...props} />
      </Suspense>
  );
};

export default PhantomHLSPlayer;
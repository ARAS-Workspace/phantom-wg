import React, { lazy, Suspense, useEffect, useRef, useState } from 'react';
import { SkeletonPlaceholder } from '@carbon/react';
import { useTheme } from '@shared/hooks/useTheme';
import { useIsClient } from '@shared/hooks/useIsClient';
import { useLocale } from '@shared/hooks';
import type { Chapter } from '@shared/types/chapters';
import ChapterStrip from './ChapterStrip';
import './PhantomHLSPlayer.scss';

// ── Types ────────────────────────────────────────────────────────

interface ChapterStripConfig {
    /** Ordered list of chapters covering the timeline. */
    chapters: Chapter[];
}

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
    /** Show native player controls. Defaults to true. */
    controls?: boolean;
    /** Autoplay on mount (most browsers require `muted` as well). */
    autoplay?: boolean;
    /** Start muted. */
    muted?: boolean;
    /** Loop playback when it ends. */
    loop?: boolean;
    /** Browser preload strategy. Defaults to `'metadata'`. */
    preload?: 'none' | 'metadata' | 'auto';
    /** Poster image URL shown before playback starts. */
    poster?: string;
    /**
     * Optional caption tracks (WebVTT). The track whose `srclang` matches
     * `defaultTextTrack` (or the current locale) is marked as default.
     */
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
    /** Accessible title for the embed (used as `aria-label`). */
    title?: string;
    /** Additional class name for the outer wrapper. */
    className?: string;
    /**
     * If present, a chapter strip is rendered under the player; clicking a
     * segment seeks the video (auto-playing on the first cue so the poster
     * lifts). Each player owns its own strip — multiple players on a page
     * stay independent. Total duration is pulled from the video itself
     * once metadata loads.
     */
    chapterStrip?: ChapterStripConfig;
}

// ── Theme-aware defaults ─────────────────────────────────────────
// Values mirror Carbon v11 token equivalents:
//   white → blue-60 / gray-10 background
//   g100  → blue-50 / gray-100 background

const THEME_COLORS: Record<'white' | 'g100', { letterbox: string }> = {
    white: { letterbox: '#f4f4f4' },
    g100: { letterbox: '#161616' },
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

// ── Core (client-only, dynamically imports hls.js) ───────────────

const PhantomHLSPlayerCore: React.FC<PhantomHLSPlayerProps> = ({
                                                                   src,
                                                                   controls = true,
                                                                   autoplay = false,
                                                                   muted = false,
                                                                   loop = false,
                                                                   preload = 'metadata',
                                                                   poster,
                                                                   captions,
                                                                   defaultTextTrack,
                                                                   startTime,
                                                                   letterboxColor,
                                                                   aspectRatio = '16 / 9',
                                                                   title,
                                                                   className = '',
                                                                   chapterStrip,
                                                               }) => {
    const { theme } = useTheme();
    const { locale } = useLocale();

    // Skeleton overlay stays on top until the video signals it has enough
    // data to play — otherwise the user stares at a black letterbox.
    const [videoReady, setVideoReady] = useState(false);

    // Drives the chapter strip's "currently playing" highlight.
    const [currentTime, setCurrentTime] = useState(0);

    // Pulled from the video once metadata loads; the chapter strip waits
    // for this before rendering segment widths.
    const [duration, setDuration] = useState(0);

    // The <video> element hls.js attaches to. All imperative calls
    // (currentTime, play, duration) go through this standard HTMLVideoElement.
    const videoRef = useRef<HTMLVideoElement | null>(null);

    // The hls.js instance, kept so we can destroy it on unmount.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const hlsRef = useRef<any>(null);

    // The poster stays up until playback starts; the first cue also
    // auto-plays so the user sees the chapter they asked for. Once the
    // user has played at least once, later cues only seek and leave their
    // play/pause state alone.
    const hasStartedRef = useRef(false);

    // Attach hls.js to the <video> element. hls.js loads lazily on first
    // render so it never reaches the main bundle. Safari plays HLS
    // natively, so there we skip hls.js and set the src directly.
    useEffect(() => {
        const video = videoRef.current;
        if (!video) return;

        let cancelled = false;

        // Native HLS support (Safari / iOS) — no hls.js needed.
        if (video.canPlayType('application/vnd.apple.mpegurl')) {
            video.src = src;
            return;
        }

        import('hls.js').then(({ default: Hls }) => {
            if (cancelled || !videoRef.current) return;

            if (Hls.isSupported()) {
                const hls = new Hls({
                    // Keep the buffer modest; docs videos are watched linearly and
                    // we don't want to pull the whole 14-min ladder up front.
                    maxBufferLength: 30,
                    startLevel: -1, // let ABR pick the initial rendition
                    // Smoother chapter seeks: tolerate tiny gaps and flush old buffer
                    // on a jump so the decoder repaints from a clean keyframe quickly
                    // instead of briefly showing a half-decoded (blocky) frame.
                    maxBufferHole: 0.5,
                    nudgeMaxRetry: 5,
                });
                hlsRef.current = hls;
                hls.loadSource(src);
                hls.attachMedia(videoRef.current);
            } else {
                // Last-resort fallback: hand the URL to the browser directly.
                videoRef.current.src = src;
            }
        });

        return () => {
            cancelled = true;
            if (hlsRef.current) {
                hlsRef.current.destroy();
                hlsRef.current = null;
            }
        };
    }, [src]);

    const cueTo = (seconds: number) => {
        const video = videoRef.current;
        if (!Number.isFinite(seconds) || !video) return;
        try {
            video.currentTime = seconds;
            if (!hasStartedRef.current) {
                const result = video.play();
                if (result?.catch) {
                    result.catch(() => {
                        // Sound autoplay refused — retry muted so the poster
                        // at least clears and frames appear. The retry's promise is
                        // explicitly ignored (there is nothing left to fall back to).
                        video.muted = true;
                        void video.play().catch(() => {
                            /* give up silently */
                        });
                    });
                }
            }
        } catch {
            /* video not ready yet */
        }
    };

    const handleTimeUpdate = () => {
        setCurrentTime(videoRef.current?.currentTime ?? 0);
    };

    const handleCanPlay = () => {
        setVideoReady(true);
        // canPlay guarantees metadata is loaded, so duration is now valid.
        setDuration(videoRef.current?.duration ?? 0);
        // Apply the requested start position once, after metadata is ready.
        if (startTime && videoRef.current && videoRef.current.currentTime === 0) {
            videoRef.current.currentTime = startTime;
        }
    };

    const themeColors = THEME_COLORS[theme] ?? THEME_COLORS.white;
    const resolvedLetterbox = letterboxColor ?? themeColors.letterbox;
    const resolvedDefaultText = defaultTextTrack ?? locale;

    return (
        <div
            className={`phantom-hls-player ${className}`}
            aria-label={title}
            style={
                {
                    '--phantom-hls-letterbox': resolvedLetterbox,
                } as React.CSSProperties
            }
        >
            <div className="phantom-hls-player__aspect" style={{ aspectRatio }}>
                <div className="phantom-hls-player__inner">
                    <video
                        ref={videoRef}
                        className="phantom-hls-player__video"
                        controls={controls}
                        autoPlay={autoplay}
                        muted={muted}
                        loop={loop}
                        preload={preload}
                        poster={poster}
                        playsInline
                        title={title}
                        onCanPlay={handleCanPlay}
                        onPlay={() => {
                            hasStartedRef.current = true;
                        }}
                        onTimeUpdate={handleTimeUpdate}
                    >
                        {captions?.map((track) => (
                            <track
                                key={track.srclang}
                                kind="subtitles"
                                srcLang={track.srclang}
                                label={track.label}
                                src={track.src}
                                default={track.srclang === resolvedDefaultText}
                            />
                        ))}
                    </video>
                </div>
                {!videoReady && (
                    <SkeletonPlaceholder className="phantom-hls-player__skeleton" />
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
import React, { useEffect, useRef, useState, lazy, Suspense } from 'react';
import { SkeletonPlaceholder } from '@carbon/react';
import { useTheme } from '@shared/hooks/useTheme';
import { useIsClient } from '@shared/hooks/useIsClient';
import './styles/AsciinemaPlayer.scss';

// ── Types ────────────────────────────────────────────────────────

interface AsciinemaPlayerProps {
  src: string;
  cols?: number;
  rows?: number;
  autoPlay?: boolean;
  loop?: boolean;
  speed?: number;
  idleTimeLimit?: number;
  terminalFontSize?: string;
  fit?: 'width' | 'height' | 'both' | 'none';
  className?: string;
}

// ── Skeleton ─────────────────────────────────────────────────────

const PlayerSkeleton: React.FC<{ className?: string }> = ({ className = '' }) => (
  <div className={`asciinema-player-wrapper asciinema-player-skeleton ${className}`}>
    <SkeletonPlaceholder className="asciinema-player-skeleton__inner" />
  </div>
);

// ── Core Player (lazy-loaded internals) ──────────────────────────

const AsciinemaPlayerCore: React.FC<AsciinemaPlayerProps> = ({
  src,
  cols = 120,
  rows = 48,
  autoPlay = false,
  loop = true,
  speed = 1,
  idleTimeLimit = 2,
  terminalFontSize,
  fit = 'width',
  className = '',
}) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const playerRef = useRef<any>(null);
  const [loaded, setLoaded] = useState(false);
  const { theme } = useTheme();

  useEffect(() => {
    if (!containerRef.current) return;

    let disposed = false;

    Promise.all([
      import('asciinema-player'),
      import('asciinema-player/dist/bundle/asciinema-player.css'),
    ]).then(([AsciinemaPlayerLib]) => {
      if (disposed || !containerRef.current) return;

      if (playerRef.current) {
        playerRef.current.dispose();
        playerRef.current = null;
      }

      containerRef.current.innerHTML = '';

      playerRef.current = AsciinemaPlayerLib.create(src, containerRef.current, {
        cols,
        rows,
        autoPlay,
        loop,
        speed,
        idleTimeLimit,
        fit,
        theme: theme === 'g100' ? 'solarized-dark' : 'solarized-light',
        ...(terminalFontSize ? { terminalFontSize } : {}),
      });

      setLoaded(true);
    });

    return () => {
      disposed = true;
      if (playerRef.current) {
        playerRef.current.dispose();
        playerRef.current = null;
      }
    };
  }, [src, theme, cols, rows, autoPlay, loop, speed, idleTimeLimit, terminalFontSize, fit]);

  return (
    <div className={`asciinema-player-wrapper ${className}`}>
      {!loaded && <SkeletonPlaceholder className="asciinema-player-skeleton__inner" />}
      <div ref={containerRef} style={loaded ? undefined : { display: 'none' }} />
    </div>
  );
};

// ── Lazy Wrapper ─────────────────────────────────────────────────

const LazyAsciinemaPlayer = lazy(() =>
  Promise.resolve({ default: AsciinemaPlayerCore })
);

const AsciinemaPlayer: React.FC<AsciinemaPlayerProps> = (props) => {
  const isClient = useIsClient();

  if (!isClient) {
    return <PlayerSkeleton className={props.className} />;
  }

  return (
    <Suspense fallback={<PlayerSkeleton className={props.className} />}>
      <LazyAsciinemaPlayer {...props} />
    </Suspense>
  );
};

export default AsciinemaPlayer;

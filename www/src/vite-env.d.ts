/// <reference types="vite/client" />

declare module 'asciinema-player' {
  interface PlayerOptions {
    cols?: number;
    rows?: number;
    autoPlay?: boolean;
    loop?: boolean;
    speed?: number;
    idleTimeLimit?: number;
    fit?: 'width' | 'height' | 'both' | 'none';
    theme?: string;
    poster?: string;
    startAt?: number | string;
    preload?: boolean;
    terminalFontFamily?: string;
    terminalFontSize?: string;
    terminalLineHeight?: number;
  }

  interface Player {
    dispose(): void;
    play(): void;
    pause(): void;
    seek(location: number | string): void;
    getCurrentTime(): number;
    getDuration(): number;
  }

  export function create(
    src: string | { url: string; fetchOpts?: RequestInit },
    elem: HTMLElement,
    opts?: PlayerOptions,
  ): Player;
}

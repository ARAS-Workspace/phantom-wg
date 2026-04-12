export interface Position {
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface BoundingBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export enum GameState {
  WAITING = 'WAITING',
  RUNNING = 'RUNNING',
  CRASHED = 'CRASHED',
}

export interface GameConfig {
  gravity: number;
  speed: number;
  maxSpeed: number;
  acceleration: number;
  jumpVelocity: number;
  groundY: number;
}

export interface GameMessages {
  startMessage: string;
  gameOver: string;
  restartMessage: string;
  score: string;
}

export type ThemeMode = 'light' | 'dark';

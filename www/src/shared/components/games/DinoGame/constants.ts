import type { GameConfig } from './types';

export const GAME_CONFIG: GameConfig = {
  gravity: 0.5,
  speed: 6,
  maxSpeed: 13,
  acceleration: 0.001,
  jumpVelocity: -10,
  groundY: 0,
};

export const GAME_AREA = {
  WIDTH: 600,
  HEIGHT: 200,
};

export const DINO = {
  WIDTH: 48,
  HEIGHT: 48,
  INIT_X: 50,
};

export const OBSTACLE = {
  WIDTH: 40,
  HEIGHT: 40,
  GAP_MIN: 400,
  GAP_MAX: 700,
};

export const CLOUD = {
  WIDTH: 32,
  HEIGHT: 32,
  GAP_MIN: 100,
  GAP_MAX: 400,
  Y_MIN: 20,
  Y_MAX: 60,
};
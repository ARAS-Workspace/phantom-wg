import type { BoundingBox } from '../types';
import { OBSTACLE, GAME_AREA } from '../constants';

export class Obstacle {
  x: number;
  private readonly y: number;
  private readonly width: number;
  private readonly height: number;
  readonly variantIndex: number;

  constructor(x: number, variantCount: number = 1) {
    this.x = x;
    this.width = OBSTACLE.WIDTH;
    this.height = OBSTACLE.HEIGHT;
    this.y = GAME_AREA.HEIGHT - this.height;
    this.variantIndex = Math.floor(Math.random() * variantCount);
  }

  update(speed: number): void {
    this.x -= speed;
  }

  getBoundingBox(): BoundingBox {
    return { x: this.x, y: this.y, width: this.width, height: this.height };
  }

  isOffScreen(): boolean {
    return this.x + this.width < 0;
  }
}
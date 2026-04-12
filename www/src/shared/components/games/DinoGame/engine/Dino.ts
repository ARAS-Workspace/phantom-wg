import type { BoundingBox, GameConfig } from '../types';
import { DINO, GAME_AREA } from '../constants';

export class Dino {
  private readonly x: number;
  private y: number;
  private velocityY: number;
  private jumping: boolean;
  private readonly groundY: number;

  constructor(config: GameConfig) {
    this.x = DINO.INIT_X;
    this.groundY = GAME_AREA.HEIGHT - DINO.HEIGHT - config.groundY;
    this.y = this.groundY;
    this.velocityY = 0;
    this.jumping = false;
  }

  jump(jumpVelocity: number): void {
    if (!this.jumping) {
      this.velocityY = jumpVelocity;
      this.jumping = true;
    }
  }

  update(gravity: number): void {
    if (this.jumping) {
      this.velocityY += gravity;
      this.y += this.velocityY;
      if (this.y >= this.groundY) {
        this.y = this.groundY;
        this.velocityY = 0;
        this.jumping = false;
      }
    }
  }

  getBoundingBox(): BoundingBox {
    return {
      x: this.x + 5,
      y: this.y + 5,
      width: DINO.WIDTH - 10,
      height: DINO.HEIGHT - 10,
    };
  }

  reset(): void {
    this.y = this.groundY;
    this.velocityY = 0;
    this.jumping = false;
  }
}
import type { GameConfig, GameMessages } from '../types';
import { GameState } from '../types';
import { GAME_AREA, CLOUD, GAME_CONFIG, OBSTACLE } from '../constants';
import { Dino } from './Dino';
import { Obstacle } from './Obstacle';
import { Cloud } from './Cloud';
import { checkCollision, randomRange } from '../utils/collision';

export interface GameRenderState {
  state: GameState;
  score: number;
  messages: GameMessages;
  dino: { x: number; y: number; width: number; height: number };
  obstacles: Array<{ x: number; y: number; width: number; height: number; variantIndex: number }>;
  clouds: Array<{ x: number; y: number; width: number; height: number; variantIndex: number }>;
}

export interface VariantCounts {
  obstacle: number;
  cloud: number;
}

export class GameEngine {
  private dino: Dino;
  private obstacles: Obstacle[] = [];
  private clouds: Cloud[] = [];
  private readonly config: GameConfig;
  private state: GameState = GameState.WAITING;
  private score: number = 0;
  private distanceMeter: number = 0;
  private speed: number;
  private readonly messages: GameMessages;
  private readonly variantCounts: VariantCounts;

  constructor(messages: GameMessages, variantCounts: VariantCounts) {
    this.messages = messages;
    this.variantCounts = variantCounts;
    this.config = { ...GAME_CONFIG };
    this.speed = this.config.speed;
    this.dino = new Dino(this.config);
    this.initClouds();
  }

  private initClouds(): void {
    for (let i = 0; i < 3; i++) {
      this.clouds.push(
        new Cloud(
          randomRange(0, GAME_AREA.WIDTH),
          randomRange(CLOUD.Y_MIN, CLOUD.Y_MAX),
          this.variantCounts.cloud
        )
      );
    }
  }

  start(): void {
    this.state = GameState.RUNNING;
  }

  reset(): void {
    this.state = GameState.WAITING;
    this.score = 0;
    this.distanceMeter = 0;
    this.speed = this.config.speed;
    this.obstacles = [];
    this.dino.reset();
  }

  jump(): void {
    if (this.state === GameState.WAITING) this.start();
    if (this.state === GameState.RUNNING) this.dino.jump(this.config.jumpVelocity);
    if (this.state === GameState.CRASHED) this.reset();
  }

  update(): void {
    if (this.state !== GameState.RUNNING) return;

    this.dino.update(this.config.gravity);
    this.speed = Math.min(this.config.maxSpeed, this.speed + this.config.acceleration);
    this.distanceMeter += this.speed;
    this.score = Math.floor(this.distanceMeter / 10);

    this.obstacles.forEach((o) => o.update(this.speed));
    this.obstacles = this.obstacles.filter((o) => !o.isOffScreen());

    if (
      this.obstacles.length === 0 ||
      this.obstacles[this.obstacles.length - 1].x <
        GAME_AREA.WIDTH - randomRange(OBSTACLE.GAP_MIN, OBSTACLE.GAP_MAX)
    ) {
      this.obstacles.push(new Obstacle(GAME_AREA.WIDTH, this.variantCounts.obstacle));
    }

    this.clouds.forEach((c) => c.update(this.speed));
    this.clouds = this.clouds.filter((c) => !c.isOffScreen());

    if (
      this.clouds.length < 5 &&
      (this.clouds.length === 0 ||
        this.clouds[this.clouds.length - 1].x <
          GAME_AREA.WIDTH - randomRange(CLOUD.GAP_MIN, CLOUD.GAP_MAX))
    ) {
      this.clouds.push(
        new Cloud(GAME_AREA.WIDTH, randomRange(CLOUD.Y_MIN, CLOUD.Y_MAX), this.variantCounts.cloud)
      );
    }

    const dinoBB = this.dino.getBoundingBox();
    for (const obstacle of this.obstacles) {
      if (checkCollision(dinoBB, obstacle.getBoundingBox())) {
        this.state = GameState.CRASHED;
        break;
      }
    }
  }

  getState(): GameRenderState {
    return {
      state: this.state,
      score: this.score,
      messages: this.messages,
      dino: {
        x: this.dino.getBoundingBox().x,
        y: this.dino.getBoundingBox().y,
        width: OBSTACLE.WIDTH,
        height: OBSTACLE.HEIGHT,
      },
      obstacles: this.obstacles.map((obs) => ({
        x: obs.x,
        y: obs.getBoundingBox().y,
        width: OBSTACLE.WIDTH,
        height: OBSTACLE.HEIGHT,
        variantIndex: obs.variantIndex,
      })),
      clouds: this.clouds.map((cloud) => ({
        x: cloud.x,
        y: cloud.getBoundingBox().y,
        width: CLOUD.WIDTH,
        height: CLOUD.HEIGHT,
        variantIndex: cloud.variantIndex,
      })),
    };
  }
}
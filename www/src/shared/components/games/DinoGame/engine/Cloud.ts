import { CLOUD } from '../constants';

export class Cloud {
  x: number;
  private readonly y: number;
  private readonly width: number;
  private readonly height: number;
  readonly variantIndex: number;

  constructor(x: number, y: number, variantCount: number = 1) {
    this.x = x;
    this.y = y;
    this.width = CLOUD.WIDTH;
    this.height = CLOUD.HEIGHT;
    this.variantIndex = Math.floor(Math.random() * variantCount);
  }

  update(speed: number): void {
    this.x -= speed * 0.5;
  }

  isOffScreen(): boolean {
    return this.x + this.width < 0;
  }

  getBoundingBox() {
    return { x: this.x, y: this.y, width: this.width, height: this.height };
  }
}
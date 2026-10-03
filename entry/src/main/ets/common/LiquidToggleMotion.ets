// Native adaptation of Bencho's MIT-licensed Liquid Toggle (bencho.dev/licence).
// A single opaque body stretches with velocity; no trailing blobs or SVG goo filter.
export class LiquidToggleFrame {
  position: number;
  velocity: number;

  constructor(position: number, velocity: number) {
    this.position = position;
    this.velocity = velocity;
  }
}

export class LiquidToggleMotion {
  // Compact settings-row proportions; the component keeps a separate 48 vp hit area.
  static readonly railWidth: number = 52;
  static readonly railHeight: number = 28;
  static readonly thumbSize: number = 22;
  static readonly pad: number = 3;
  static readonly travel: number = LiquidToggleMotion.railWidth - LiquidToggleMotion.thumbSize - LiquidToggleMotion.pad * 2;
  static readonly duration: number = 800;

  static clamp(value: number, low: number, high: number): number {
    return Math.min(high, Math.max(low, value));
  }

  static endpoint(on: boolean): number {
    return on ? LiquidToggleMotion.travel : 0;
  }

  static selection(position: number): boolean {
    return position >= LiquidToggleMotion.travel / 2;
  }

  static stretch(velocity: number, amount: number): number {
    // Keep area by pairing this horizontal stretch with its reciprocal vertically.
    return 1 + Math.min(0.4, Math.abs(velocity) / 600) * LiquidToggleMotion.clamp(amount, 0, 100) / 100;
  }

  static sample(from: number, target: number, velocity: number, seconds: number, speed: number): LiquidToggleFrame {
    // Same mass/damping/stiffness as Bencho and Motion.thumb. An analytical spring
    // keeps frame-rate independence and exposes the actual position when interrupted.
    const mass = 0.9;
    const damping = 21.5;
    const stiffness = 170 - (50 - LiquidToggleMotion.clamp(speed, 0, 100)) * 1.1;
    const alpha = damping / (2 * mass);
    const delta = stiffness / mass - alpha * alpha;
    const displacement = from - target;
    const t = Math.max(0, seconds);
    let offset = 0;
    let v = 0;
    if (delta > 0.000001) {
      const w = Math.sqrt(delta);
      const b = (velocity + alpha * displacement) / w;
      const decay = Math.exp(-alpha * t);
      const cos = Math.cos(w * t);
      const sin = Math.sin(w * t);
      offset = decay * (displacement * cos + b * sin);
      v = decay * ((w * b - alpha * displacement) * cos - (w * displacement + alpha * b) * sin);
    } else if (delta < -0.000001) {
      const beta = Math.sqrt(-delta);
      const r1 = -alpha + beta;
      const r2 = -alpha - beta;
      const a = (velocity - r2 * displacement) / (r1 - r2);
      const b = displacement - a;
      offset = a * Math.exp(r1 * t) + b * Math.exp(r2 * t);
      v = r1 * a * Math.exp(r1 * t) + r2 * b * Math.exp(r2 * t);
    } else {
      const b = velocity + alpha * displacement;
      const decay = Math.exp(-alpha * t);
      offset = decay * (displacement + b * t);
      v = decay * (b - alpha * (displacement + b * t));
    }
    return new LiquidToggleFrame(target + offset, v);
  }
}

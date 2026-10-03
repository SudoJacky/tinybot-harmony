// Spring regression checks; gesture dispatch and settings persistence are exercised on device.
// Run: node scripts/test-liquid-toggle.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/common/LiquidToggleMotion.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
}).outputText;
const loaded = { exports: {} };
vm.runInNewContext(compiled, loaded);
const { LiquidToggleMotion: motion } = loaded.exports;
const near = (actual, expected, tolerance = 1e-8) => assert.ok(Math.abs(actual - expected) < tolerance,
  `${actual} should be within ${tolerance} of ${expected}`);

// Includes the overdamped, critical and underdamped cases across the exposed speed range.
const criticalSpeed = 50 + ((21.5 * 21.5 / (4 * 0.9)) - 170) / 1.1;
for (const speed of [0, criticalSpeed, 25, 50, 100]) {
  for (const target of [0, motion.travel]) {
    const from = motion.travel - target;
    for (const velocity of [-400, 0, 400]) {
      const initial = motion.sample(from, target, velocity, 0, speed);
      near(initial.position, from);
      near(initial.velocity, velocity);
      for (let ms = 0; ms <= motion.duration; ms += 8) {
        const frame = motion.sample(from, target, velocity, ms / 1000, speed);
        assert.ok(Number.isFinite(frame.position) && Number.isFinite(frame.velocity));
      }
      near(motion.sample(from, target, velocity, motion.duration / 1000, speed).position, target, 0.3);
    }
  }
}
// Reversing a running spring starts at the current position/velocity, not its old target.
const interrupted = motion.sample(0, motion.travel, 0, 0.08, 50);
const reversed = motion.sample(interrupted.position, 0, interrupted.velocity, 0, 50);
near(reversed.position, interrupted.position);
near(reversed.velocity, interrupted.velocity);
near(motion.sample(reversed.position, 0, reversed.velocity, 0.8, 50).position, 0, 0.1);
assert.equal(motion.selection(motion.travel / 2 - 0.1), false);
assert.equal(motion.selection(motion.travel / 2 + 0.1), true);
assert.equal(motion.stretch(100000, 100), 1.4);
assert.equal(motion.stretch(100000, 0), 1);
console.log('LiquidToggle spring: PASS (convergence, speed range, interruption, deformation bounds)');

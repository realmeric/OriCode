// Loaded into the engine with --import, so a test can wait out the 90 s idle limit and its sweep
// in under a second each: the engine's clock and its timers run a hundred times fast.
const speed = 100;
const real = Date.now;
const start = real();
Date.now = () => start + (real() - start) * speed;
const timeout = globalThis.setTimeout;
globalThis.setTimeout = ((handler: () => void, ms = 0, ...rest: unknown[]) => timeout(handler, ms / speed, ...rest)) as typeof setTimeout;

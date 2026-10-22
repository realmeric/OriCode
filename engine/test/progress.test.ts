// A long job's progress and time left, worked out from how its steps have actually gone.
import { test } from "node:test";
import assert from "node:assert/strict";
import { planProgress } from "../plan.ts";
import { progressLine, secondsLeft, spokenLine, type Step } from "../progress.ts";

const steps = (kind: string, guess: number, count: number): Step[] => Array.from({ length: count }, () => ({ kind, guess }));

test("gives no time before a step has ended", () => {
  assert.equal(secondsLeft(steps("keys", 15, 3), []), undefined);
  assert.equal(progressLine(steps("keys", 15, 3), 1000, [], 1010), "0/3");
  assert.equal(spokenLine(steps("keys", 15, 3), 1000, [], 1010), "0 of 3 done · time left: can't tell yet");
});

test("a kind that has run is expected to take what it took", () => {
  const plan = [0, 1, 2].flatMap(() => [{ kind: "keys", guess: 15 }, { kind: "stream", guess: 18 }]);
  assert.equal(secondsLeft(plan, [30, 40]), 2 * 30 + 2 * 40);
});

test("a kind that hasn't run takes its guess at the pace so far", () => {
  const plan = [{ kind: "keys", guess: 15 }, { kind: "stream", guess: 18 }, { kind: "idle", guess: 250 }];
  assert.equal(secondsLeft(plan, [30]), 18 * 2 + 250 * 2);
});

test("the estimate follows a job that slows down and then speeds up", () => {
  const plan = steps("keys", 15, 12);
  const took = [15, 15, 15];
  assert.equal(secondsLeft(plan, took), 9 * 15);
  const perStep: number[] = [];
  for (const seconds of [30, 30, 30, 30]) {
    took.push(seconds);
    perStep.push(secondsLeft(plan, took)! / (12 - took.length));
  }
  assert.deepEqual(perStep, [...perStep].sort((a, b) => a - b));
  assert.ok(perStep.at(-1)! > 28);
  took.push(10, 10, 10);
  assert.ok(secondsLeft(plan, took)! / (12 - took.length) < 13);
});

test("the line", () => {
  const idle = steps("idle", 250, 15);
  assert.equal(progressLine(idle, 0, [250, 500], 500), "2/15 · 54 min");
  assert.equal(progressLine([...idle, ...idle], 0, [250], 250), "1/30 · 2 h 01");
  assert.equal(progressLine(steps("keys", 15, 2), 0, [20], 20), "1/2 · <1 min");
  assert.equal(progressLine(steps("keys", 15, 2), 0, [20, 3700], 3700), null);
});

test("the line in words, for a terminal", () => {
  const idle = steps("idle", 250, 15);
  assert.equal(spokenLine(idle, 0, [250, 500], 500), "2 of 15 done · about 54 min left");
  assert.equal(spokenLine(steps("keys", 15, 2), 0, [20], 20), "1 of 2 done · under a minute left");
  assert.equal(spokenLine(steps("keys", 15, 2), 0, [20, 3700], 3700), "2 of 2 done, took 1 h 02 min");
});

test("a plan's line goes by when its tasks ended, each agent's at its own pace", () => {
  assert.equal(planProgress(["claude", "codex", "claude"], 0, [], 30), "0/3");
  assert.equal(planProgress(["claude", "codex", "claude", "codex"], 0, [600, 1800], 1800), "2/4 · 30 min");
});

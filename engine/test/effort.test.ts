// Effort as the engine learns it, against stand-ins for the CLI, so nothing here starts Claude.
import { test } from "node:test";
import assert from "node:assert/strict";
import type { Query } from "@anthropic-ai/claude-agent-sdk";
import { withDefaults, type Model } from "../models.ts";
import { changedEffort } from "../thread.ts";

const every = ["low", "medium", "high", "xhigh", "max"];

function model(id: string, efforts: string[]): Model {
  return { id, name: id, description: "", efforts, fast: false, defaultEffort: null, ultra: false, ultraBlocked: null };
}

/// withDefaults against two stand-in CLIs, one launched plain and one with Ultracode, that know
/// each model's default level, the models Ultracode runs on, and the settings they loaded. Each
/// keeps a log of the calls it gets.
async function learn(models: Model[], defaults: Record<string, string | null>, ultra: string[], effective?: object) {
  const cli = (launchedUltra: boolean) => {
    const calls: string[] = [];
    let current = "";
    const probe = {
      async setModel(id: string) {
        calls.push(`model ${id}`);
        current = id;
      },
      async applyFlagSettings(settings: object) {
        calls.push(`flags ${JSON.stringify(settings)}`);
      },
      async getSettings() {
        const ultracode = launchedUltra && ultra.includes(current);
        return { effective, applied: { effort: ultracode ? "xhigh" : (defaults[current] ?? null), ultracode } };
      },
    };
    return { probe: probe as unknown as Query, calls };
  };
  const plain = cli(false);
  const launched = cli(true);
  return { ...(await withDefaults(plain.probe, launched.probe, models)), calls: plain.calls, ultraCalls: launched.calls };
}

test("defaults come from the plain CLI and Ultracode from the one launched with it", async () => {
  const { models } = await learn([model("default", every), model("opus", every), model("haiku", [])], { default: "medium", opus: "high", haiku: null }, ["default", "opus"]);
  // Read on the Ultracode CLI, they would all say xhigh.
  assert.deepEqual(models.map((found) => found.defaultEffort), ["medium", "high", null]);
  assert.deepEqual(models.map((found) => found.ultra), [true, true, false]);
});

test("neither probe is ever given flag settings", async () => {
  const { calls, ultraCalls } = await learn([model("opus", every), model("haiku", [])], { opus: "medium", haiku: null }, ["opus"], { enableWorkflows: false });
  // applyFlagSettings({ ultracode }) writes Claude Code's unpin flags into ~/.claude.json for good.
  assert.deepEqual([...calls, ...ultraCalls].filter((call) => call.startsWith("flags")), []);
});

test("a model without xhigh is never switched to on the Ultracode CLI", async () => {
  const { models, ultraCalls } = await learn(
    [model("opus", every), model("sonnet", ["low", "medium", "high"]), model("haiku", [])],
    { opus: "medium", sonnet: "medium", haiku: null },
    ["opus", "sonnet", "haiku"],
  );
  assert.deepEqual(ultraCalls, ["model opus"]);
  assert.deepEqual(models.map((found) => found.ultra), [true, false, false]);
});

test("a maxEffortLevel takes the levels above it off every model", async () => {
  const { models, ultraCalls } = await learn([model("opus", every), model("sonnet", every)], { opus: "xhigh", sonnet: "medium" }, ["opus", "sonnet"], {
    maxEffortLevel: "high",
    enableWorkflows: false,
  });
  assert.deepEqual(models.map((found) => found.efforts), [["low", "medium", "high"], ["low", "medium", "high"]]);
  // A default above the cap isn't a level the thread can be at.
  assert.deepEqual(models.map((found) => found.defaultEffort), [null, "medium"]);
  // Under xhigh there's no Ultracode to try, and none to call blocked.
  assert.deepEqual(ultraCalls, []);
  assert.deepEqual(models.map((found) => [found.ultra, found.ultraBlocked]), [[false, null], [false, null]]);
});

test("a cap at xhigh takes only max, and a level the list doesn't know takes nothing", async () => {
  const [xhigh] = (await learn([model("opus", every)], { opus: "medium" }, ["opus"], { maxEffortLevel: "xhigh" })).models;
  assert.deepEqual(xhigh.efforts, ["low", "medium", "high", "xhigh"]);
  assert.equal(xhigh.ultra, true);
  const [unknown] = (await learn([model("opus", every)], { opus: "medium" }, ["opus"], { maxEffortLevel: "turbo" })).models;
  assert.deepEqual(unknown.efforts, every);
});

test("Ultracode the CLI turns down while workflows are off is blocked by workflows", async () => {
  const ultraOf = async (ultra: string[], effective: object) => {
    const [opus] = (await learn([model("opus", every)], { opus: "medium" }, ultra, effective)).models;
    return [opus.ultra, opus.ultraBlocked];
  };
  assert.deepEqual(await ultraOf([], { enableWorkflows: false }), [false, "workflows"]);
  // Unset leaves workflows to the plan, so a refusal has no reason the app can name.
  assert.deepEqual(await ultraOf([], {}), [false, null]);
  assert.deepEqual(await ultraOf(["opus"], { enableWorkflows: false }), [true, null]);
});

test("settingsEffort is the settings' effortLevel when it names a level", async () => {
  const settingsEffort = async (effortLevel?: string) => (await learn([], {}, [], { effortLevel })).settingsEffort;
  assert.equal(await settingsEffort("medium"), "medium");
  assert.equal(await settingsEffort("turbo"), null);
  assert.equal(await settingsEffort(), null);
});

test("CLIs whose settings say nothing leave every field at its fallback", async () => {
  const silent = { async setModel() {}, async applyFlagSettings() {}, async getSettings() {} } as unknown as Query;
  const { models, settingsEffort } = await withDefaults(silent, silent, [model("opus", every)]);
  assert.deepEqual(models, [model("opus", every)]);
  assert.equal(settingsEffort, null);
});

test("an effort reading is told only when the level or Ultracode changes", () => {
  const first = changedEffort(undefined, { effort: "medium", ultracode: false });
  assert.deepEqual(first, { level: "medium", ultracode: false });
  assert.equal(changedEffort(first, { effort: "medium" }), undefined);
  assert.deepEqual(changedEffort(first, { effort: "xhigh", ultracode: true }), { level: "xhigh", ultracode: true });
  assert.deepEqual(changedEffort(first, { effort: "medium", ultracode: true }), { level: "medium", ultracode: true });
  assert.deepEqual(changedEffort(first, {}), { level: null, ultracode: false });
  assert.deepEqual(changedEffort(undefined, {}), { level: null, ultracode: false });
});

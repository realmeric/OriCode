// Model names and Claude Code's catalog, from rows the SDK and the CLI's cache really had.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo, Query } from "@anthropic-ai/claude-agent-sdk";
import { readCatalog, readSettingsEffort, type CatalogModel } from "../catalog.ts";
import { adaptive, fromSDK, helloList, newer, older, settled, withDefaults, type Patience } from "../models.ts";

const every = ["low", "medium", "high", "xhigh", "max"];

/// supportedModels() from Claude Code 2.1.278 with no settings.
const sdk: ModelInfo[] = [
  { value: "default", resolvedModel: "claude-opus-5[1m]", displayName: "Default (recommended)", description: "Opus 5 with 1M context · Best for everyday, complex tasks" },
  { value: "opus[1m]", resolvedModel: "claude-opus-5[1m]", displayName: "Opus (1M context)", description: "Opus 5 with 1M context · Best for everyday, complex tasks" },
  { value: "claude-fable-5-1[1m]", resolvedModel: "claude-fable-5-1", displayName: "Fable", description: "Fable 5.1 · Most capable for your hardest and longest-running tasks" },
  { value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet", description: "Sonnet 5 · Efficient for routine tasks" },
  { value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku", description: "Haiku 4.5 · Fastest for quick answers" },
];

function row(id: string, name: string, more = false, extra: Partial<CatalogModel> = {}): CatalogModel {
  return { id, name, description: null, more, efforts: [], defaultEffort: null, fast: false, adaptive: false, minVersion: null, ...extra };
}

const catalog = [
  row("claude-opus-5-5", "Opus 5.5", false, { minVersion: "2.1.280" }),
  row("claude-fable-5-1", "Fable 5.1"),
  row("claude-sonnet-5", "Sonnet 5"),
  row("claude-haiku-4-5-20251001", "Haiku 4.5"),
  row("claude-opus-5", "Opus 5", true, { efforts: every, defaultEffort: "high", fast: true, adaptive: true }),
  row("claude-opus-4-8", "Opus 4.8", true, { efforts: every, defaultEffort: "high", fast: true, adaptive: true }),
  row("claude-sonnet-4-6", "Sonnet 4.6", true, { efforts: ["low", "medium", "high", "max"], defaultEffort: "high", adaptive: true }),
  row("claude-next", "Next", true, { minVersion: "9.0.0" }),
];

const names = (models: { name: string; description: string }[]) => models.map((model) => [model.name, model.description]);

const expected = [
  ["Default (recommended)", "Opus 5 with 1M context · Best for everyday, complex tasks"],
  ["Opus 5", "1M context · Best for everyday, complex tasks"],
  ["Fable 5.1", "Most capable for your hardest and longest-running tasks"],
  ["Sonnet 5", "Efficient for routine tasks"],
  ["Haiku 4.5", "Fastest for quick answers"],
];

test("rows take the catalog's name for the model they run, and their lines lose it", () => {
  assert.deepEqual(names(fromSDK(sdk, catalog)), expected);
});

test("without a catalog the version comes from the row's line", () => {
  assert.deepEqual(names(fromSDK(sdk)), expected);
});

test("the catalog's name wins over a line that says something else", () => {
  const renamed = [row("claude-sonnet-5", "Sonnet 5 (preview)")];
  assert.deepEqual(names(fromSDK([sdk[3]], renamed)), [["Sonnet 5 (preview)", "Sonnet 5 · Efficient for routine tasks"]]);
});

test("a row whose line doesn't start with its family keeps its name and its line", () => {
  const custom: ModelInfo = { value: "my-model", displayName: "My model", description: "Custom model (my-model)" };
  assert.deepEqual(names(fromSDK([custom])), [["My model", "Custom model (my-model)"]]);
});

async function cache(files: Record<string, unknown>): Promise<string> {
  const home = await mkdtemp(join(tmpdir(), "oricode-catalog-"));
  const folder = join(home, "cache", "model-catalog");
  await mkdir(folder, { recursive: true });
  for (const [name, body] of Object.entries(files)) {
    await writeFile(join(folder, name), typeof body === "string" ? body : JSON.stringify(body));
  }
  return home;
}

const file = (fetchedAt: number, surface: string, models: object[]) => ({ version: 2, fetchedAt, catalog: { surface, config: { id: surface, models } } });

test("the newest cc catalog is read, and the desktop's, a broken file and retired rows are not", async () => {
  const home = await cache({
    "org-old-cc.json": file(1, "cc", [{ id: "claude-opus-4-8", name: "Opus 4.8" }]),
    "org-new-cc.json": file(2, "cc", [
      { id: "claude-opus-5-5", name: "Opus 5.5", description: "Most capable for ambitious work", section: "main", min_claude_code_version: "2.1.280" },
      {
        id: "claude-opus-4-8",
        name: "Opus 4.8",
        section: "overflow",
        thinking: { type: "effort", effort_options: [...every.map((id) => ({ id })), { id: "turbo" }].map((option) => (option.id === "high" ? { ...option, badge: { message: "Default" } } : option)) },
        fast_mode: { type: "toggle" },
      },
      { id: "claude-opus-4-1", name: "Opus 4.1", section: "deprecated" },
      { id: "claude-secret", name: "Secret", disabled: true },
      { id: 7 },
    ]),
    "tok-desktop-ccd.json": file(3, "ccd", [{ id: "claude-desktop-only", name: "Desktop" }]),
    "tok-broken-cc.json": "{ not json",
  });
  assert.deepEqual(await readCatalog(home), [
    row("claude-opus-5-5", "Opus 5.5", false, { description: "Most capable for ambitious work", minVersion: "2.1.280" }),
    row("claude-opus-4-8", "Opus 4.8", true, { efforts: every, defaultEffort: "high", fast: true, adaptive: true }),
  ]);
});

test("no cache is no catalog", async () => {
  assert.deepEqual(await readCatalog(join(tmpdir(), "oricode-no-such-folder")), []);
});

test("older models are the catalog's overflow rows the SDK's rows don't already run", () => {
  const found = older(catalog, sdk);
  assert.deepEqual(found.map((model) => model.id), ["claude-opus-4-8", "claude-sonnet-4-6"]);
  assert.deepEqual(found[1], {
    id: "claude-sonnet-4-6", name: "Sonnet 4.6", description: "", efforts: ["low", "medium", "high", "max"], fast: false,
    defaultEffort: "high", ultra: false, ultraBlocked: null, more: true,
  });
  assert.ok(adaptive.has("claude-opus-4-8"));
});

test("with a newer Opus in the SDK's rows, the Opus it replaced is an older model too", () => {
  const newer = sdk.map((model) => ({ ...model, resolvedModel: model.resolvedModel?.replace("claude-opus-5", "claude-opus-5-5") }));
  assert.deepEqual(older(catalog, newer).map((model) => model.name), ["Opus 5", "Opus 4.8", "Sonnet 4.6"]);
});

test("Default on an older model lands on the settings' level when the model has it", () => {
  const [opus, sonnet] = older(catalog, sdk);
  assert.equal(settled(opus, "xhigh"), "xhigh");
  assert.equal(settled(sonnet, "xhigh"), "high");
  assert.equal(settled(sonnet, null), "high");
});

test("under a cap, Default on an older model comes down to the highest level left", () => {
  const [opus] = older(catalog, sdk);
  assert.equal(settled({ ...opus, efforts: ["low", "medium"] }, "xhigh"), "medium");
  assert.equal(settled({ ...opus, efforts: [] }, "high"), null);
});

test("a catalog model that needs a newer Claude Code is listed with the version, until a row runs it", () => {
  assert.deepEqual(newer(catalog, sdk), [
    {
      id: "claude-opus-5-5", name: "Opus 5.5", description: "Needs Claude Code 2.1.280", efforts: [], fast: false,
      defaultEffort: null, ultra: false, ultraBlocked: null, needs: "2.1.280",
    },
  ]);
  const updated = sdk.map((model) => ({ ...model, resolvedModel: model.resolvedModel?.replace("claude-opus-5", "claude-opus-5-5") }));
  assert.deepEqual(newer(catalog, updated), []);
});

/// supportedModels() from Claude Code 2.1.281 with no settings, and the catalog it cached.
const sdk281: ModelInfo[] = [
  { value: "default", resolvedModel: "claude-opus-5-5[1m]", displayName: "Default (recommended)", description: "Opus 5.5 with 1M context · Best for everyday, complex tasks", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAdaptiveThinking: true, supportsFastMode: true },
  { value: "opus[1m]", resolvedModel: "claude-opus-5-5[1m]", displayName: "Opus (1M context)", description: "Opus 5.5 with 1M context · Best for everyday, complex tasks", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAdaptiveThinking: true, supportsFastMode: true },
  { value: "claude-fable-5-1[1m]", resolvedModel: "claude-fable-5-1", displayName: "Fable", description: "Fable 5.1 · Most capable for your hardest and longest-running tasks", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAdaptiveThinking: true },
  { value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet", description: "Sonnet 5 · Efficient for routine tasks", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"], supportsAdaptiveThinking: true },
  { value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku", description: "Haiku 4.5 · Fastest for quick answers" },
];

const noMax = ["low", "medium", "high", "max"];

const catalog281 = [
  row("claude-opus-5-5", "Opus 5.5", false, { efforts: every, defaultEffort: "medium", adaptive: true, minVersion: "2.1.280" }),
  row("claude-fable-5-1", "Fable 5.1", false, { efforts: every, defaultEffort: "high", adaptive: true, minVersion: "2.1.251" }),
  row("claude-sonnet-5", "Sonnet 5", false, { efforts: every, defaultEffort: "high", adaptive: true }),
  row("claude-haiku-4-5-20251001", "Haiku 4.5"),
  row("claude-opus-5", "Opus 5", true, { efforts: every, defaultEffort: "high", fast: true, adaptive: true }),
  row("claude-fable-5", "Fable 5", true, { efforts: every, defaultEffort: "high", adaptive: true }),
  row("claude-opus-4-8", "Opus 4.8", true, { efforts: every, defaultEffort: "high", fast: true, adaptive: true }),
  row("claude-opus-4-7", "Opus 4.7", true, { efforts: every, defaultEffort: "xhigh", adaptive: true }),
  row("claude-opus-4-6", "Opus 4.6", true, { efforts: noMax, defaultEffort: "high", fast: true, adaptive: true }),
  row("claude-sonnet-4-6", "Sonnet 4.6", true, { efforts: noMax, defaultEffort: "high", adaptive: true }),
];

/// Hello's list: the SDK's rows, then the models that need a newer Claude Code, then the older ones.
const hello = [...fromSDK(sdk281, catalog281), ...newer(catalog281, sdk281), ...older(catalog281, sdk281)];

test("hello's rows start on the catalog's default for the model they run", () => {
  assert.deepEqual(fromSDK(sdk281, catalog281).map((model) => [model.id, model.defaultEffort]), [
    ["default", "medium"],
    ["opus[1m]", "medium"],
    ["claude-fable-5-1[1m]", "high"],
    ["sonnet", "high"],
    ["haiku", null],
  ]);
});

/// An idle CLI as the probes use it: switched through models and read with get_settings. It
/// knows each model's default level, the settings it loaded and, when it was launched with
/// Ultracode, the models Ultracode runs on. It turns a model in `refused` down the way Claude
/// Code turns down a full id it couldn't confirm in time, never answers a switch to one in
/// `stuck`, and never answers anything at all when `mute`.
type Stand = { defaults?: Record<string, string | null>; ultracode?: string[]; effective?: object; refused?: string[]; stuck?: string[]; mute?: boolean };

function cli(stand: Stand, launchedUltra: boolean) {
  const calls: string[] = [];
  let current = "default";
  const never = new Promise<never>(() => {});
  const session = {
    async setModel(id: string) {
      calls.push(id);
      if (stand.mute || stand.stuck?.includes(id)) return never;
      if (stand.refused?.includes(id)) throw new Error(`Couldn't confirm model "${id}" with the API. Try again, or run /model to see available models.`);
      current = id;
    },
    async getSettings() {
      if (stand.mute) return never;
      const ultracode = launchedUltra && (stand.ultracode ?? []).includes(current);
      return { effective: stand.effective ?? {}, applied: { effort: ultracode ? "xhigh" : (stand.defaults?.[current] ?? null), ultracode } };
    },
  };
  return { session: session as unknown as Query, calls };
}

/// What Meriç's CLI reported with effortLevel medium and workflows on.
const reads = { defaults: { default: "medium", "opus[1m]": "medium", "claude-fable-5-1[1m]": "medium", sonnet: "medium", haiku: null }, effective: { effortLevel: "medium", enableWorkflows: true } };
const everywhere = ["default", "opus[1m]", "claude-fable-5-1[1m]", "sonnet"];

async function learnAll(plain: Stand, ultra: Stand, patience?: Patience) {
  const probe = cli(plain, false);
  const ultraProbe = cli(ultra, true);
  const learned = await withDefaults(probe.session, ultraProbe.session, hello, patience);
  const byId = new Map(learned.models.map((model) => [model.id, model]));
  const of = (id: string) => byId.get(id)!;
  return { ...learned, of, calls: probe.calls, ultraCalls: ultraProbe.calls };
}

const quick: Patience = { startMs: 50, stepMs: 50 };

test("a model Claude Code won't confirm keeps its fallback, and the models after it are still read", async () => {
  const plain = { ...reads, defaults: { ...reads.defaults, sonnet: "low" }, refused: ["claude-fable-5-1[1m]"] };
  const { of, calls, missed } = await learnAll(plain, { ...reads, ultracode: everywhere });
  assert.deepEqual(calls, ["default", "opus[1m]", "claude-fable-5-1[1m]", "sonnet"]);
  // The settings' level, as Claude Code would land Default on Fable, and Sonnet as its CLI read it.
  assert.equal(of("claude-fable-5-1[1m]").defaultEffort, "medium");
  assert.equal(of("sonnet").defaultEffort, "low");
  assert.deepEqual(missed.map((miss) => [miss.id, miss.ultracode]), [["claude-fable-5-1[1m]", false]]);
});

test("without an effortLevel in the settings, a model left unread lands on the catalog's default", async () => {
  const { of } = await learnAll({ ...reads, effective: {}, refused: ["claude-fable-5-1[1m]"] }, { ...reads, effective: {}, ultracode: everywhere });
  assert.deepEqual(["claude-fable-5-1[1m]", "claude-opus-4-7", "claude-sonnet-4-6"].map((id) => of(id).defaultEffort), ["high", "xhigh", "high"]);
});

test("a switch that never answers ends that CLI's run and keeps what it read", async () => {
  const { of, calls, ultraCalls, missed } = await learnAll({ ...reads, stuck: ["claude-fable-5-1[1m]"] }, { ...reads, ultracode: everywhere }, { startMs: 1000, stepMs: 50 });
  assert.deepEqual(calls, ["default", "opus[1m]", "claude-fable-5-1[1m]"]);
  assert.deepEqual(ultraCalls, ["default", "opus[1m]", "sonnet"]);
  assert.deepEqual(["default", "claude-fable-5-1[1m]", "sonnet"].map((id) => of(id).defaultEffort), ["medium", "medium", "medium"]);
  assert.ok(of("sonnet").ultra);
  assert.deepEqual(missed.map((miss) => miss.id), ["claude-fable-5-1[1m]"]);
});

test("CLIs that never answer leave hello's list as it was, and the list still comes back", async () => {
  const { models, settingsEffort, ultraKnown, missed } = await learnAll({ mute: true }, { mute: true }, quick);
  assert.deepEqual(models, hello);
  assert.equal(settingsEffort, null);
  assert.equal(ultraKnown, false);
  assert.deepEqual(missed.map((miss) => [miss.id, miss.ultracode]), [["settings", false], ["settings", true]]);
});

test("Ultracode on the aliases answers for every model with xhigh, and the Ultracode CLI never switches to a full id", async () => {
  const { models, ultraCalls, ultraKnown } = await learnAll(reads, { ...reads, ultracode: everywhere });
  assert.deepEqual(ultraCalls, ["default", "opus[1m]", "sonnet"]);
  assert.equal(ultraKnown, true);
  assert.deepEqual(models.filter((model) => model.ultra).map((model) => model.id), [
    "default", "opus[1m]", "claude-fable-5-1[1m]", "sonnet", "claude-opus-5", "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7",
  ]);
  assert.ok(models.every((model) => model.ultraBlocked === null));
});

test("with workflows off in the settings, every model with xhigh is blocked by them", async () => {
  const off = { ...reads, effective: { effortLevel: "medium", enableWorkflows: false } };
  const { models, ultraKnown } = await learnAll(off, off);
  assert.equal(ultraKnown, true);
  assert.ok(models.every((model) => !model.ultra));
  assert.deepEqual(models.filter((model) => model.ultraBlocked === "workflows").map((model) => model.id), [
    "default", "opus[1m]", "claude-fable-5-1[1m]", "sonnet", "claude-opus-5", "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7",
  ]);
});

test("an Ultracode CLI that never answers says so, and keeps the defaults", async () => {
  const { models, of, ultraKnown } = await learnAll(reads, { mute: true }, quick);
  // Not known, so the app keeps a thread's Ultracode rather than taking this for a no.
  assert.equal(ultraKnown, false);
  assert.ok(models.every((model) => !model.ultra && model.ultraBlocked === null));
  assert.equal(of("sonnet").defaultEffort, "medium");
});

test("a maxEffortLevel caps the older models too, and their defaults come down to it", async () => {
  const capped = { ...reads, effective: { maxEffortLevel: "high" } };
  const { of, ultraCalls } = await learnAll(capped, { ...capped, ultracode: everywhere });
  assert.deepEqual(of("claude-opus-4-7").efforts, ["low", "medium", "high"]);
  assert.equal(of("claude-opus-4-7").defaultEffort, "high");
  assert.deepEqual(ultraCalls, []);
  assert.ok(!of("claude-opus-4-7").ultra);
});

test("hello's rows start where the user's settings put Default, and on the catalog's default without them", () => {
  const withSettings = helloList(sdk281, catalog281, "medium");
  assert.deepEqual(withSettings.slice(0, 5).map((model) => model.defaultEffort), ["medium", "medium", "medium", "medium", null]);
  const without = helloList(sdk281, catalog281, null);
  assert.deepEqual(without.slice(0, 5).map((model) => model.defaultEffort), fromSDK(sdk281, catalog281).slice(0, 5).map((model) => model.defaultEffort));
});

test("the settings' effortLevel is read from the user's config folder, and anything else is none", async () => {
  const folder = await mkdtemp(join(tmpdir(), "oricode-settings-"));
  assert.equal(await readSettingsEffort(folder), null);
  await writeFile(join(folder, "settings.json"), JSON.stringify({ effortLevel: "high", model: "opus" }));
  assert.equal(await readSettingsEffort(folder), "high");
  await writeFile(join(folder, "settings.json"), JSON.stringify({ effortLevel: "extreme" }));
  assert.equal(await readSettingsEffort(folder), null);
  await writeFile(join(folder, "settings.json"), "not json");
  assert.equal(await readSettingsEffort(folder), null);
});

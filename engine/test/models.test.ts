// Model names and Claude Code's catalog, from rows the SDK and the CLI's cache really had.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { readCatalog, type CatalogModel } from "../catalog.ts";
import { adaptive, fromSDK, newer, older, settled } from "../models.ts";

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
  assert.equal(settled(opus, "xhigh").defaultEffort, "xhigh");
  assert.equal(settled(sonnet, "xhigh").defaultEffort, "high");
  assert.equal(settled(sonnet, null).defaultEffort, "high");
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

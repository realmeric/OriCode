// Model names and Claude Code's catalog, from rows the SDK and the CLI's cache really had.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { readCatalog } from "../catalog.ts";
import { fromSDK } from "../models.ts";

/// supportedModels() from Claude Code 2.1.278 with no settings.
const sdk: ModelInfo[] = [
  { value: "default", resolvedModel: "claude-opus-5[1m]", displayName: "Default (recommended)", description: "Opus 5 with 1M context · Best for everyday, complex tasks" },
  { value: "opus[1m]", resolvedModel: "claude-opus-5[1m]", displayName: "Opus (1M context)", description: "Opus 5 with 1M context · Best for everyday, complex tasks" },
  { value: "claude-fable-5-1[1m]", resolvedModel: "claude-fable-5-1", displayName: "Fable", description: "Fable 5.1 · Most capable for your hardest and longest-running tasks" },
  { value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet", description: "Sonnet 5 · Efficient for routine tasks" },
  { value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku", description: "Haiku 4.5 · Fastest for quick answers" },
];

const catalog = [
  { id: "claude-opus-5", name: "Opus 5" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
  { id: "claude-sonnet-5", name: "Sonnet 5" },
  { id: "claude-haiku-4-5-20251001", name: "Haiku 4.5" },
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
  const renamed = [{ id: "claude-sonnet-5", name: "Sonnet 5 (preview)" }];
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
      { id: "claude-opus-5-5", name: "Opus 5.5", section: "main" },
      { id: "claude-opus-4-8", name: "Opus 4.8", section: "overflow" },
      { id: "claude-opus-4-1", name: "Opus 4.1", section: "deprecated" },
      { id: "claude-secret", name: "Secret", disabled: true },
      { id: 7 },
    ]),
    "tok-desktop-ccd.json": file(3, "ccd", [{ id: "claude-desktop-only", name: "Desktop" }]),
    "tok-broken-cc.json": "{ not json",
  });
  assert.deepEqual(await readCatalog(home), [
    { id: "claude-opus-5-5", name: "Opus 5.5" },
    { id: "claude-opus-4-8", name: "Opus 4.8" },
  ]);
});

test("no cache is no catalog", async () => {
  assert.deepEqual(await readCatalog(join(tmpdir(), "oricode-no-such-folder")), []);
});

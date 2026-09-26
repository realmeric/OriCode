// The engine's cache of models, in a scratch folder: nothing here starts a CLI.
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { cacheLife, cachedModels, defaultsKey, readCache, writeCache, type Cache } from "../cache.ts";
import { fallback } from "../models.ts";

const version = "2.1.282 (Claude Code)";
const models = [{ value: "default", displayName: "Default", description: "Recommended" }] as ModelInfo[];

test("what's written is read back, and with no folder nothing is kept", async () => {
  const folder = join(await mkdtemp(join(tmpdir(), "oricode-cache-")), "engine");
  assert.equal(await readCache(folder), undefined);
  const cache: Cache = { version, at: 1, models, defaults: { key: "k", models: fallback, settingsEffort: "high", ultraKnown: true } };
  await writeCache(folder, cache);
  assert.deepEqual(await readCache(folder), cache);
  await writeCache(undefined, cache);
  assert.equal(await readCache(undefined), undefined);
});

test("the list is used for the Claude Code that gave it, and read again behind it once a day old", () => {
  const now = Date.now();
  const cache: Cache = { version, at: now - 1000, models };
  assert.deepEqual(cachedModels(cache, version, now), { models, stale: false });
  assert.deepEqual(cachedModels({ ...cache, at: now - cacheLife }, version, now), { models, stale: true });
});

test("another Claude Code, or one that can't say its version, reads the list before hello answers", () => {
  const cache: Cache = { version, at: Date.now(), models };
  assert.equal(cachedModels(cache, "2.1.283 (Claude Code)"), undefined);
  assert.equal(cachedModels(cache, null), undefined);
  assert.equal(cachedModels(undefined, version), undefined);
});

test("the defaults are kept for the list and the settings they were read under", () => {
  const key = defaultsKey(fallback, '{"effortLevel":"high"}');
  assert.equal(defaultsKey(fallback, '{"effortLevel":"high"}'), key);
  assert.notEqual(defaultsKey(fallback, '{"effortLevel":"low"}'), key);
  assert.notEqual(defaultsKey(fallback.slice(1), '{"effortLevel":"high"}'), key);
});

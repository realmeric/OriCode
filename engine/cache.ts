import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import type { Model } from "./models.ts";

/// What only a CLI can tell the engine about the models, kept between launches so that a launch
/// starts none: the SDK's list, for the Claude Code version that gave it, and each model's
/// defaults, for the list and the user settings they were read under. It lives in the folder the
/// app names, its own in Application Support; with none, nothing is kept.
export type Cache = {
  /// What `claude --version` printed.
  version: string;
  /// When the list was read.
  at: number;
  models: ModelInfo[];
  defaults?: Defaults;
};

/// A `models` event, and the `defaultsKey` it was read under.
export type Defaults = { key: string; models: Model[]; settingsEffort: string | null; ultraKnown: boolean };

/// The list is read again behind the cache once it's a day old, and before hello answers once
/// Claude Code's version has changed.
export const cacheLife = 24 * 60 * 60_000;

function file(folder: string): string {
  return join(folder, "models.json");
}

export async function readCache(folder: string | undefined): Promise<Cache | undefined> {
  if (!folder) return undefined;
  return readFile(file(folder), "utf8").then(
    (text) => JSON.parse(text) as Cache,
    () => undefined,
  );
}

export async function writeCache(folder: string | undefined, cache: Cache): Promise<void> {
  if (!folder) return;
  await mkdir(folder, { recursive: true });
  const partial = `${file(folder)}.${process.pid}`;
  await writeFile(partial, JSON.stringify(cache));
  await rename(partial, file(folder));
}

/// The cached list, when this Claude Code gave it, and whether it's a day old.
export function cachedModels(cache: Cache | undefined, version: string | null, now = Date.now()): { models: ModelInfo[]; stale: boolean } | undefined {
  if (!cache || !version || cache.version !== version || !Array.isArray(cache.models)) return undefined;
  return { models: cache.models, stale: now - cache.at >= cacheLife };
}

/// The defaults follow the list they were read for and the user's settings, whose effortLevel,
/// maxEffortLevel and enableWorkflows the probes read.
export function defaultsKey(list: Model[], settings: string): string {
  return createHash("sha256").update(JSON.stringify(list)).update("\0").update(settings).digest("hex");
}

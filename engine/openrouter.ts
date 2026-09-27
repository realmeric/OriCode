import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { cacheLife } from "./cache.ts";
import type { Model } from "./models.ts";
import { log } from "./wire.ts";

// OpenRouter's catalog is hundreds of models. A thread on it offers the ones OpenRouter files
// under programming, best coder first, from its public list, which takes no key: the user's key
// goes only to the Claude Code that runs the thread. The list is kept a day, in memory and in
// the engine's cache folder, so the model menu never waits on it twice.

/// The levels Claude Code sends, which OpenRouter's Messages endpoint takes as output_config.effort.
const levels = ["low", "medium", "high", "xhigh", "max"];

type Listed = {
  id: string;
  name: string;
  context_length: number;
  supported_parameters?: string[];
  reasoning?: { supported_efforts?: string[]; default_effort?: string };
};

type Kept = { at: number; models: Model[] };

let kept: Kept | undefined;
let reading: Promise<Model[]> | undefined;

/// "OpenAI: GPT-5.6 Sol" at 1,050,000 tokens is GPT-5.6 Sol, "OpenAI · 1M context". Claude Code
/// assumes 200K unless the id ends in [1m], which OpenRouter strips before routing.
function model(listed: Listed): Model {
  const [maker, name] = listed.name.includes(": ") ? listed.name.split(": ", 2) : [null, listed.name];
  const long = listed.context_length >= 1_000_000;
  const context = long ? `${Math.floor(listed.context_length / 1_000_000)}M context` : `${Math.round(listed.context_length / 1000)}K context`;
  const efforts = levels.filter((level) => listed.reasoning?.supported_efforts?.includes(level));
  const defaultEffort = listed.reasoning?.default_effort;
  return {
    id: long ? `${listed.id}[1m]` : listed.id,
    name,
    description: maker ? `${maker} · ${context}` : context,
    efforts,
    fast: false,
    defaultEffort: defaultEffort && efforts.includes(defaultEffort) ? defaultEffort : null,
    ultra: false,
    ultraBlocked: null,
  };
}

function file(folder: string): string {
  return join(folder, "openrouter-models.json");
}

/// OpenRouter's coding models, only those that call tools, since Claude Code is nothing without them.
async function fetched(): Promise<Model[]> {
  // Tests point it at a stand-in.
  const catalog = process.env.ORICODE_OPENROUTER_MODELS ?? "https://openrouter.ai/api/v1/models?category=programming&sort=coding-high-to-low";
  const response = await fetch(catalog, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`OpenRouter answered ${response.status}`);
  const { data } = (await response.json()) as { data: Listed[] };
  return data.filter((listed) => listed.supported_parameters?.includes("tools")).map(model);
}

/// The list, from memory or the cache folder while it's under a day old, from OpenRouter
/// otherwise, and a stale copy when OpenRouter can't be reached.
export function openRouterModels(folder = process.env.ORICODE_CACHE, now = Date.now()): Promise<Model[]> {
  if (kept && now - kept.at < cacheLife) return Promise.resolve(kept.models);
  reading ??= (async () => {
    try {
      kept ??= folder ? await readFile(file(folder), "utf8").then((text) => JSON.parse(text) as Kept, () => undefined) : undefined;
      if (kept && now - kept.at < cacheLife) return kept.models;
      try {
        kept = { at: now, models: await fetched() };
      } catch (error) {
        if (!kept) throw new Error(`OpenRouter's models couldn't be read: ${(error as Error).message}`);
        log(`OpenRouter's models not read again, keeping the last: ${(error as Error).message}`);
        return kept.models;
      }
      if (folder) {
        await mkdir(folder, { recursive: true });
        const partial = `${file(folder)}.${process.pid}`;
        await writeFile(partial, JSON.stringify(kept));
        await rename(partial, file(folder));
      }
      return kept.models;
    } finally {
      reading = undefined;
    }
  })();
  return reading;
}

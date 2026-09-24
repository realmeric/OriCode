import type { ModelInfo, Query } from "@anthropic-ai/claude-agent-sdk";
import type { CatalogModel } from "./catalog.ts";

export type Model = {
  id: string;
  name: string;
  description: string;
  efforts: string[];
  fast: boolean;
  /// The level Claude Code uses when the thread picks none, or null when the model has no
  /// levels or it isn't known yet.
  defaultEffort: string | null;
  /// Whether the session can run as Ultracode on this model: xhigh effort with standing
  /// multi-agent workflows. Needs an xhigh model and workflows turned on for the account.
  ultra: boolean;
  /// Why an xhigh model has no Ultracode when the user can change it: `workflows` while
  /// enableWorkflows is off in their settings.
  ultraBlocked: "workflows" | null;
  /// One of the account's older models, from the catalog's overflow section; the app lists
  /// them under More models. Absent on the SDK's own rows.
  more?: boolean;
  /// The Claude Code version a catalog model needs, when the running one is older: the app
  /// shows it dimmed and doesn't pick it.
  needs?: string;
};

/// Models that take adaptive thinking, filled from the SDK's list. Asking one that doesn't
/// for it is an error, so a model the engine hasn't heard about gets no thinking option.
export const adaptive = new Set<string>();

/// The catalog row an SDK row runs: the model it resolves to, without the 1M suffix.
function runs(model: ModelInfo): string | undefined {
  return model.resolvedModel?.replace(/\[1m\]$/i, "");
}

/// Each row starts with the catalog's default for the model it runs, which is where Default
/// lands until the probe reads what Claude Code makes of the user's settings.
export function fromSDK(models: ModelInfo[], catalog: CatalogModel[] = []): Model[] {
  for (const model of models) {
    if (model.supportsAdaptiveThinking) adaptive.add(model.value);
  }
  return models.map((model) => {
    const efforts: string[] = model.supportsEffort ? (model.supportedEffortLevels ?? []) : [];
    const marked = catalog.find((row) => row.id === runs(model))?.defaultEffort;
    return {
      id: model.value,
      ...versioned(model, catalog),
      efforts,
      fast: model.supportsFastMode ?? false,
      defaultEffort: marked && efforts.includes(marked) ? marked : null,
      ultra: false,
      ultraBlocked: null,
    };
  });
}

/// Hello's list: the SDK's rows, the catalog's models this Claude Code can't run yet and its older
/// ones, each with Default where the user's settings put it, or the catalog's default, until the
/// probe reads what Claude Code makes of them.
export function helloList(models: ModelInfo[], catalog: CatalogModel[], settingsEffort: string | null): Model[] {
  return [...fromSDK(models, catalog), ...newer(catalog, models), ...older(catalog, models)].map((model) => ({
    ...model,
    defaultEffort: settled(model, settingsEffort),
  }));
}

/// The catalog's older models for the More models list, each with the levels, default level and
/// fast mode the catalog gives it. One the SDK's rows already run is left out, and so is one
/// that names a Claude Code version, which a model new enough to need one isn't yet.
export function older(catalog: CatalogModel[], models: ModelInfo[]): Model[] {
  const running = new Set(models.map(runs));
  return catalog
    .filter((row) => row.more && !row.minVersion && !running.has(row.id))
    .map((row) => {
      if (row.adaptive) adaptive.add(row.id);
      return {
        id: row.id,
        name: row.name,
        description: row.description ?? "",
        efforts: row.efforts,
        fast: row.fast,
        defaultEffort: row.defaultEffort,
        ultra: false,
        ultraBlocked: null,
        more: true,
      };
    });
}

/// The catalog's models this Claude Code can't run yet: one from the main section that names the
/// version it needs, which no row of the SDK's runs. Once Claude Code is updated a row runs it.
export function newer(catalog: CatalogModel[], models: ModelInfo[]): Model[] {
  const running = new Set(models.map(runs));
  return catalog
    .filter((row) => !row.more && row.minVersion && !running.has(row.id))
    .map((row) => ({
      id: row.id,
      name: row.name,
      description: `Needs Claude Code ${row.minVersion}`,
      efforts: [],
      fast: false,
      defaultEffort: null,
      ultra: false,
      ultraBlocked: null,
      needs: row.minVersion ?? undefined,
    }));
}

/// Where Default lands on a model the probe didn't read: the effortLevel in the user's settings
/// when the model has it, as Claude Code does, or else the catalog's default. A level over a cap
/// comes down to the highest one left, as Claude Code clamps it.
export function settled(model: Model, settingsEffort: string | null): string | null {
  const level = settingsEffort && model.efforts.includes(settingsEffort) ? settingsEffort : model.defaultEffort;
  if (!level) return null;
  return model.efforts.filter((effort) => levels.indexOf(effort) <= levels.indexOf(level)).at(-1) ?? null;
}

/// The SDK names a row by family ("Opus (1M context)") and puts the version in its line ("Opus 5
/// with 1M context · Best for…"). The name becomes the version, the catalog's for the model the
/// row runs or else the line's, and the line loses it. Default keeps its name and its line,
/// which says what it runs.
export function versioned(model: ModelInfo, catalog: CatalogModel[]): { name: string; description: string } {
  const unchanged = { name: model.displayName, description: model.description };
  if (model.value === "default") return unchanged;
  const head = model.description.split(" · ")[0].replace(/ with 1M context$/, "");
  const family = model.displayName.split(" (")[0];
  const name = catalog.find((row) => row.id === runs(model))?.name ?? (head.startsWith(`${family} `) ? head : undefined);
  if (!name) return unchanged;
  const description = model.description.startsWith(`${name} `)
    ? model.description.slice(name.length).replace(/^ (with |· )/, "")
    : model.description;
  return { name, description };
}

const levels = ["low", "medium", "high", "xhigh", "max"];

/// What get_settings reports: `effective` is the settings the CLI loaded, merged, and `applied`
/// what the session will actually send. The SDK has the control request but not yet a typed
/// method for it, so any of it may be missing.
type Effective = { effortLevel?: string; maxEffortLevel?: string; enableWorkflows?: boolean };
type Reported = { effective?: Effective; applied?: Applied };
export type Applied = { effort?: string | null; ultracode?: boolean };

async function reported(session: Query): Promise<Reported> {
  return (await (session as unknown as { getSettings(): Promise<Reported | undefined> }).getSettings()) ?? {};
}

export async function applied(session: Query): Promise<Applied> {
  return (await reported(session)).applied ?? {};
}

/// How long a probe gets: its first reading waits for the CLI to start, and a switch to a full
/// model id waits on Claude Code's own check with the API, which it gives five seconds.
export type Patience = { startMs: number; stepMs: number };

class TimedOut extends Error {}

function within<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new TimedOut(`no answer in ${ms / 1000}s`)), ms);
  });
  return Promise.race([work, late]).finally(() => clearTimeout(timer));
}

/// The levels a model offers under a maxEffortLevel: the CLI clamps anything above it down to it.
function under(effective: Effective, efforts: string[]): string[] {
  const cap = levels.indexOf(effective.maxEffortLevel ?? "");
  return cap < 0 ? efforts : efforts.filter((effort) => levels.indexOf(effort) <= cap);
}

/// Claude Code confirms a model named by its full id with a one-token request to the API before
/// it switches to it, and gives up on the switch when that takes over five seconds. An alias it
/// switches to at once.
const fullId = (id: string) => id.startsWith("claude-");

/// A reading the probes couldn't take: `settings` when a CLI never answered at all.
export type Missed = { id: string; ultracode: boolean; error: unknown };

/// One probe's settings, then what it reports on each model `pick` names. A switch Claude Code
/// turns down leaves the CLI on the model before it, so the next one goes on; one that doesn't
/// answer in time ends the run, since it could still land under a later reading.
async function readThrough(session: Query, pick: (effective: Effective) => Model[], patience: Patience) {
  const read = new Map<string, Applied>();
  const missed: { id: string; error: unknown }[] = [];
  let effective: Effective | undefined;
  try {
    effective = (await within(reported(session), patience.startMs)).effective ?? {};
  } catch (error) {
    return { effective, read, missed: [{ id: "settings", error }] };
  }
  for (const model of pick(effective)) {
    try {
      await within(session.setModel(model.id), patience.stepMs);
      read.set(model.id, await within(applied(session), patience.stepMs));
    } catch (error) {
      missed.push({ id: model.id, error });
      if (error instanceof TimedOut) break;
    }
  }
  return { effective, read, missed };
}

/// Each model's default effort and whether it can run as Ultracode, read from idle CLIs by
/// switching them through the models: settings only, no model call. `ultraProbe` has to be
/// launched with Ultracode on, never switched to it: applyFlagSettings({ ultracode }) saves
/// Claude Code's unpin…LaunchEffort flags into the user's ~/.claude.json for good, where a
/// launch flag releases them for its own session only. `settingsEffort` is the effortLevel in
/// the probe's settings, when it names a level.
///
/// Ultracode needs xhigh on the model and workflows on the account, so one model it runs on
/// answers for every model with xhigh: the Ultracode CLI is switched to aliases only, and an
/// older model, a full id or one the probe couldn't read takes that answer. A model the plain
/// CLI couldn't read gets the default `settled` gives it.
export async function withDefaults(
  probe: Query,
  ultraProbe: Query,
  models: Model[],
  patience: Patience = { startMs: 20_000, stepMs: 10_000 },
): Promise<{ models: Model[]; settingsEffort: string | null; ultraKnown: boolean; missed: Missed[] }> {
  const probed = (model: Model) => !model.more && !model.needs && model.efforts.length > 0;
  const [plain, ultra] = await Promise.all([
    readThrough(probe, () => models.filter(probed), patience),
    readThrough(ultraProbe, (effective) => models.filter((model) => probed(model) && !fullId(model.id) && under(effective, model.efforts).includes("xhigh")), patience),
  ]);
  const effective = plain.effective ?? ultra.effective ?? {};
  const settingsEffort = effective.effortLevel && levels.includes(effective.effortLevel) ? effective.effortLevel : null;
  const workflows = [...ultra.read.values()].some((reading) => reading.ultracode === true);
  const found = models.map((model): Model => {
    const efforts = under(effective, model.efforts);
    const reading = plain.read.get(model.id);
    const level = reading ? (reading.effort ?? null) : settled({ ...model, efforts }, settingsEffort);
    const ultraReading = ultra.read.get(model.id);
    const xhigh = efforts.includes("xhigh");
    const ultracode = xhigh && (ultraReading ? ultraReading.ultracode === true : workflows);
    return {
      ...model,
      efforts,
      // A default above the cap isn't a level the thread can be at.
      defaultEffort: level && efforts.includes(level) ? level : null,
      ultra: ultracode,
      ultraBlocked: xhigh && !ultracode && effective.enableWorkflows === false ? "workflows" : null,
    };
  });
  const missed = [...plain.missed.map((miss) => ({ ...miss, ultracode: false })), ...ultra.missed.map((miss) => ({ ...miss, ultracode: true }))];
  // Whether the Ultracode above is known: the Ultracode CLI read a model, or the settings turn
  // workflows off. Otherwise every model says no Ultracode only because nothing answered.
  const ultraKnown = ultra.read.size > 0 || effective.enableWorkflows === false;
  return { models: found, settingsEffort, ultraKnown, missed };
}

/// Fallback for when the SDK's supported-models call fails. Aliases, so they keep
/// pointing at the newest model of each family.
export const fallback: Model[] = [
  { id: "default", name: "Default", description: "The model Claude Code picks", efforts: ["low", "medium", "high", "xhigh", "max"], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
  { id: "opus", name: "Opus", description: "Most capable", efforts: ["low", "medium", "high", "xhigh", "max"], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
  { id: "sonnet", name: "Sonnet", description: "Fast and capable", efforts: ["low", "medium", "high", "xhigh", "max"], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
  { id: "haiku", name: "Haiku", description: "Fastest", efforts: [], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
];

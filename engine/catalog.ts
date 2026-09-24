import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/// A model in the catalog Claude Code keeps of what the account can run. Anthropic serves it
/// and the CLI caches it in its config folder, one file per account and surface; the engine
/// reads the CLI's own surface, `cc`, and never writes there.
export type CatalogModel = {
  id: string;
  name: string;
  description: string | null;
  /// In the overflow section, which Claude Code's own picker shows under More models and the
  /// SDK's list leaves out: the account's older models.
  more: boolean;
  efforts: string[];
  /// The level the catalog marks Default, or null.
  defaultEffort: string | null;
  fast: boolean;
  /// Whether it thinks with effort, which Claude Code runs as adaptive thinking.
  adaptive: boolean;
  /// The oldest Claude Code that can run it, when the catalog says.
  minVersion: string | null;
};

type File = { fetchedAt?: number; catalog?: { surface?: string; config?: { models?: Row[] } } };
type Row = {
  id?: unknown;
  name?: unknown;
  description?: unknown;
  section?: unknown;
  disabled?: unknown;
  thinking?: { type?: unknown; effort_options?: { id?: unknown; badge?: { message?: unknown } }[] };
  fast_mode?: unknown;
  min_claude_code_version?: unknown;
};

const levels = ["low", "medium", "high", "xhigh", "max"];

/// The newest `cc` catalog in the CLI's cache. None, or one this can't read, is an empty list:
/// the names then come from the SDK's lines, and there are no older models.
export async function readCatalog(configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): Promise<CatalogModel[]> {
  const folder = join(configDir, "cache", "model-catalog");
  let newest: File | undefined;
  for (const name of await readdir(folder).catch(() => [])) {
    if (!name.endsWith("-cc.json")) continue;
    const file = await readFile(join(folder, name), "utf8")
      .then((text) => JSON.parse(text) as File)
      .catch(() => undefined);
    if (file?.catalog?.surface !== "cc" || !Array.isArray(file.catalog.config?.models)) continue;
    if (!newest || (file.fetchedAt ?? 0) > (newest.fetchedAt ?? 0)) newest = file;
  }
  return (newest?.catalog?.config?.models ?? []).flatMap(parse);
}

/// The effortLevel in the user's own Claude Code settings, which is where Default lands on a
/// model that has that level; null when there's none, or no level the engine knows.
export async function readSettingsEffort(configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): Promise<string | null> {
  const settings = await readFile(join(configDir, "settings.json"), "utf8")
    .then((text) => JSON.parse(text) as { effortLevel?: unknown })
    .catch(() => undefined);
  const level = settings?.effortLevel;
  return typeof level === "string" && levels.includes(level) ? level : null;
}

function parse(row: Row): CatalogModel[] {
  if (typeof row.id !== "string" || typeof row.name !== "string" || row.disabled === true || row.section === "deprecated") return [];
  const effort = row.thinking?.type === "effort";
  const options = effort && Array.isArray(row.thinking?.effort_options) ? row.thinking.effort_options : [];
  const efforts = options.flatMap((option) => (typeof option.id === "string" && levels.includes(option.id) ? [option.id] : []));
  const marked = options.find((option) => option.badge?.message === "Default")?.id;
  return [
    {
      id: row.id,
      name: row.name,
      description: typeof row.description === "string" ? row.description : null,
      more: row.section === "overflow",
      efforts,
      defaultEffort: typeof marked === "string" && efforts.includes(marked) ? marked : null,
      fast: row.fast_mode != null,
      adaptive: effort,
      minVersion: typeof row.min_claude_code_version === "string" ? row.min_claude_code_version : null,
    },
  ];
}

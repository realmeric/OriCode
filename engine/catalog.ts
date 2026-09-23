import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/// A model in the catalog Claude Code keeps of what the account can run. Anthropic serves it
/// and the CLI caches it in its config folder, one file per account and surface; the engine
/// reads the CLI's own surface, `cc`, and never writes there.
export type CatalogModel = { id: string; name: string };

type File = { fetchedAt?: number; catalog?: { surface?: string; config?: { models?: Row[] } } };
type Row = { id?: unknown; name?: unknown; section?: unknown; disabled?: unknown };

/// The newest `cc` catalog in the CLI's cache. None, or one this can't read, is an empty list,
/// and the names then come from the SDK's lines.
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
  return (newest?.catalog?.config?.models ?? []).flatMap((row) =>
    typeof row.id === "string" && typeof row.name === "string" && row.disabled !== true && row.section !== "deprecated"
      ? [{ id: row.id, name: row.name }]
      : [],
  );
}

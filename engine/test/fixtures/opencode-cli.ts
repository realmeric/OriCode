// A stand-in for the two OpenCode commands an import runs: `opencode session list --format json`,
// which lists the sessions of the project it's run in, one of them in a folder of its own inside,
// and `opencode export <id>`, which writes a session out. Each run's arguments and folder go to
// OPENCODE_LOG.
import { appendFileSync, readFileSync } from "node:fs";

const [command, ...rest] = process.argv.slice(2);
appendFileSync(process.env.OPENCODE_LOG!, JSON.stringify({ args: [command, ...rest], cwd: process.cwd() }) + "\n");

if (command === "session") {
  const here = process.cwd();
  process.stdout.write(
    JSON.stringify([
      { id: "ses_tidy", title: "Tidy the README", updated: 1790000500000, created: 1790000400000, projectId: "p", directory: here },
      { id: "ses_sub", title: "In a folder inside", updated: 1790000600000, created: 1790000400000, projectId: "p", directory: `${here}/sub` },
    ]),
  );
} else if (command === "export") {
  process.stdout.write(readFileSync(new URL("./sessions/opencode-export.json", import.meta.url), "utf8"));
}

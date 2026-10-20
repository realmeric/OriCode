// progress.mts: engine/progress.ts for a shell script that runs a long job.
//   node scripts/progress.mts plan <file> <kind>:<seconds> …   the job's steps in the order they
//                                                            run, each with a guess at its seconds
//   node scripts/progress.mts step <file> [label …]            the next step has ended
// Each prints the time and the job's line. The file keeps when the job began, its plan and when
// each step ended, so every call is a fresh process and the script keeps no state of its own.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { progressLine, type Step } from "../engine/progress.ts";

const [command, path, ...words] = process.argv.slice(2);
const now = Date.now() / 1000;
const clock = new Date().toTimeString().slice(0, 8);

if (command === "plan" && path) {
  const plan: Step[] = words.map((word) => {
    const at = word.lastIndexOf(":");
    return { kind: word.slice(0, at), guess: Number(word.slice(at + 1)) };
  });
  writeFileSync(path, `began ${now}\n` + plan.map((step) => `plan ${step.kind} ${step.guess}\n`).join(""));
  console.log(`${clock} ${progressLine(plan, now, [], now)}`);
} else if (command === "step" && path) {
  appendFileSync(path, `ended ${now}\n`);
  let began = now;
  const plan: Step[] = [];
  const ended: number[] = [];
  for (const row of readFileSync(path, "utf8").split("\n")) {
    const [word, ...rest] = row.split(" ");
    if (word === "began") began = Number(rest[0]);
    else if (word === "plan") plan.push({ kind: rest.slice(0, -1).join(" "), guess: Number(rest.at(-1)) });
    else if (word === "ended") ended.push(Number(rest[0]));
  }
  const label = words.join(" ");
  console.log(`${clock} ${label ? `${label} · ` : ""}${progressLine(plan, began, ended, now)}`);
} else {
  console.error("progress.mts plan <file> <kind>:<seconds> … | step <file> [label …]");
  process.exit(2);
}

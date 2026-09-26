// What an agent speaking the Agent Client Protocol says, in the words the app already reads: a
// tool call's kind and the arguments it shows, an edit's diff as hunks, and a plan in
// TodoWrite's shape. Nothing here keeps state, so each piece is tested on its own.

export type Hunk = { oldStart: number; newStart: number; lines: string[] };

export type Todo = { content: string; activeForm: string; status: string };

/// The arguments of a call the app shows, whichever agent made it (K-175).
export type View = { path?: string; command?: string; pattern?: string; url?: string; query?: string; description?: string; todos?: Todo[] };

export type Location = { path: string; line?: number | null };

export type ToolContent =
  | { type: "content"; content: { type: string; text?: string } }
  | { type: "diff"; path: string; oldText?: string | null; newText: string }
  | { type: "terminal"; terminalId: string };

export type PlanEntry = { content: string; priority?: string; status: string };

/// ACP's kinds as K-175 names them. A mode switch is what Claude Code's ExitPlanMode is.
export function toolKind(kind: unknown): string {
  switch (kind) {
    case "execute":
      return "run";
    case "switch_mode":
      return "planning";
    case "read":
    case "edit":
    case "delete":
    case "move":
    case "search":
    case "think":
    case "fetch":
      return kind;
    default:
      return "other";
  }
}

/// Agents name the same argument differently: OpenCode's read takes `filePath`, Cursor's `path`,
/// and a call's locations or its diff often say the file before its input does.
export function toolView(rawInput: unknown, locations: readonly Location[] | null | undefined, content: readonly ToolContent[] | null | undefined): View {
  const input = rawInput && typeof rawInput === "object" && !Array.isArray(rawInput) ? (rawInput as Record<string, unknown>) : {};
  const command = Array.isArray(input.command) ? input.command.filter((part) => typeof part === "string").join(" ") : text(input.command) ?? text(input.cmd);
  const view: View = {
    path: text(locations?.[0]?.path) ?? text(input.path) ?? text(input.filePath) ?? text(input.file_path) ?? diffOf(content)?.path,
    command,
    pattern: text(input.pattern) ?? text(input.glob) ?? text(input.regex),
    url: text(input.url),
    query: text(input.query),
    description: text(input.description),
  };
  return Object.fromEntries(Object.entries(view).filter(([, value]) => value !== undefined)) as View;
}

export function diffOf(content: readonly ToolContent[] | null | undefined): Extract<ToolContent, { type: "diff" }> | undefined {
  return content?.find((item) => item.type === "diff");
}

/// What a finished call says: its text content, or else what its raw output carries, which is
/// where Cursor puts a file it read.
export function resultText(content: readonly ToolContent[] | null | undefined, rawOutput: unknown): string {
  const said = (content ?? []).flatMap((item) => (item.type === "content" && item.content.type === "text" && item.content.text ? [item.content.text] : []));
  if (said.length) return said.join("\n");
  if (typeof rawOutput === "string") return rawOutput;
  const output = rawOutput as { output?: unknown; content?: unknown; error?: unknown } | null | undefined;
  return text(output?.output) ?? text(output?.content) ?? text(output?.error) ?? "";
}

export function todos(entries: readonly PlanEntry[]): Todo[] {
  return entries.map((entry) => ({
    content: entry.content,
    activeForm: entry.content,
    status: entry.status === "in_progress" || entry.status === "completed" ? entry.status : "pending",
  }));
}

/// ACP's stop reasons as a Claude turn ends: a turn cut off at the agent's own limit on requests
/// didn't end by itself, so it's an error, and one cancelled was stopped.
export function stopReason(reason: unknown): string {
  switch (reason) {
    case "max_turn_requests":
      return "error_max_turns";
    case "cancelled":
      return "interrupted";
    case "end_turn":
    case "max_tokens":
    case "refusal":
      return reason;
    default:
      return "end_turn";
  }
}

type Op = { sign: " " | "-" | "+"; line: string };

const context = 3;

/// The hunks that take `oldText` to `newText`, with three lines of context as git gives them. A
/// new file has no old text, and all of it is added.
export function hunks(oldText: string | null | undefined, newText: string): Hunk[] {
  const ops = editScript(lines(oldText ?? ""), lines(newText));
  const changes = ops.flatMap((op, index) => (op.sign === " " ? [] : [index]));
  const result: Hunk[] = [];
  // Where each op sits in the old file and in the new one, counted from 1.
  const oldAt: number[] = [];
  const newAt: number[] = [];
  let old = 1;
  let now = 1;
  for (const op of ops) {
    oldAt.push(old);
    newAt.push(now);
    if (op.sign !== "+") old += 1;
    if (op.sign !== "-") now += 1;
  }
  let index = 0;
  while (index < changes.length) {
    const start = Math.max(0, changes[index] - context);
    let end = changes[index] + context + 1;
    while (index + 1 < changes.length && changes[index + 1] - context <= end) end = changes[++index] + context + 1;
    end = Math.min(ops.length, end);
    const lines = ops.slice(start, end);
    const hasOld = lines.some((op) => op.sign !== "+");
    result.push({ oldStart: hasOld ? oldAt[start] : oldAt[start] - 1, newStart: newAt[start], lines: lines.map((op) => op.sign + op.line) });
    index += 1;
  }
  return result;
}

/// Lines both texts start and end with stay as they are, and Myers' diff takes the middle. A
/// middle that differs in more than a thousand places is shown as taken out and put back, which
/// is still a true diff and keeps a rewritten file from holding up the turn.
function editScript(a: string[], b: string[]): Op[] {
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start += 1;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA -= 1;
    endB -= 1;
  }
  const oldMiddle = a.slice(start, endA);
  const newMiddle = b.slice(start, endB);
  const middle = myers(oldMiddle, newMiddle, 1000) ?? [
    ...oldMiddle.map((line): Op => ({ sign: "-", line })),
    ...newMiddle.map((line): Op => ({ sign: "+", line })),
  ];
  const same = (line: string): Op => ({ sign: " ", line });
  return [...a.slice(0, start).map(same), ...middle, ...a.slice(endA).map(same)];
}

function myers(a: string[], b: string[], limit: number): Op[] | undefined {
  const n = a.length;
  const m = b.length;
  if (n === 0 || m === 0) return undefined;
  const offset = limit + 1;
  const v = new Int32Array(2 * limit + 3);
  // The furthest x on each diagonal after each round, kept for the walk back.
  const rounds: Int32Array[] = [];
  for (let d = 0; d <= limit; d += 1) {
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x += 1;
        y += 1;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        rounds.push(v.slice(offset - d, offset + d + 1));
        return walkBack(rounds, a, b);
      }
    }
    rounds.push(v.slice(offset - d, offset + d + 1));
  }
  return undefined;
}

function walkBack(rounds: Int32Array[], a: string[], b: string[]): Op[] {
  const ops: Op[] = [];
  let x = a.length;
  let y = b.length;
  for (let d = rounds.length - 1; d > 0; d -= 1) {
    const before = rounds[d - 1];
    const at = (k: number) => before[k + d - 1];
    const k = x - y;
    const from = k === -d || (k !== d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
    const fromX = at(from);
    const fromY = fromX - from;
    while (x > fromX && y > fromY) {
      ops.push({ sign: " ", line: a[--x] });
      y -= 1;
    }
    if (x === fromX) ops.push({ sign: "+", line: b[--y] });
    else ops.push({ sign: "-", line: a[--x] });
  }
  while (x > 0 && y > 0) {
    ops.push({ sign: " ", line: a[--x] });
    y -= 1;
  }
  return ops.reverse();
}

/// A file's lines, the newline that ends the last one not making another.
function lines(text: string): string[] {
  if (text === "") return [];
  const split = text.split("\n");
  if (split.at(-1) === "") split.pop();
  return split;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value !== "" ? value : undefined;
}

// A call the user allowed before a quit, matched against the call Claude makes again once resumed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { sameCall } from "../thread.ts";

test("the same command is covered, whatever its description says now", () => {
  const grant = { tool: "Bash", input: { command: "make test", description: "Run the tests" } };
  assert.equal(sameCall(grant, "Bash", { command: "make test", description: "Run the test suite" }), true);
  assert.equal(sameCall(grant, "Bash", { command: "make test" }), true);
});

test("another command, or another tool, is asked about", () => {
  const grant = { tool: "Bash", input: { command: "make test" } };
  assert.equal(sameCall(grant, "Bash", { command: "make app" }), false);
  assert.equal(sameCall(grant, "Bash", { command: "make test", timeout: 1000 }), false);
  assert.equal(sameCall(grant, "Write", { command: "make test" }), false);
});

test("an edit is compared all the way down, in any key order", () => {
  const edits = [{ old_string: "a", new_string: "b" }];
  const grant = { tool: "MultiEdit", input: { file_path: "/x.swift", edits } };
  assert.equal(sameCall(grant, "MultiEdit", { edits: [{ new_string: "b", old_string: "a" }], file_path: "/x.swift" }), true);
  assert.equal(sameCall(grant, "MultiEdit", { file_path: "/x.swift", edits: [{ old_string: "a", new_string: "c" }] }), false);
});

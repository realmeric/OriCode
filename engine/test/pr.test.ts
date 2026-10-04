// A pull request's checks as gh reports them, read without gh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkOf, runOf, tail } from "../pr.ts";

test("a check run and a commit status come down to pass, fail, pending or skipped", () => {
  const link = "https://github.com/o/r/actions/runs/123/job/456";
  assert.deepEqual(checkOf({ __typename: "CheckRun", workflowName: "CI", name: "test", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: link }), { name: "CI / test", state: "pass", link });
  assert.equal(checkOf({ __typename: "CheckRun", name: "test", status: "IN_PROGRESS" }).state, "pending");
  assert.equal(checkOf({ __typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "CANCELLED" }).state, "fail");
  assert.equal(checkOf({ __typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED" }).state, "skipped");
  assert.deepEqual(checkOf({ __typename: "StatusContext", context: "deploy/preview", state: "PENDING", targetUrl: "https://x" }), { name: "deploy/preview", state: "pending", link: "https://x" });
  assert.equal(checkOf({ __typename: "StatusContext", context: "deploy", state: "ERROR" }).state, "fail");
});

test("a check's link names its Actions run and job, and another service's names none", () => {
  assert.deepEqual(runOf("https://github.com/o/r/actions/runs/123/job/456"), { run: "123", job: "456" });
  assert.deepEqual(runOf("https://github.com/o/r/actions/runs/123"), { run: "123", job: null });
  assert.equal(runOf("https://vercel.com/x"), null);
  assert.equal(runOf(null), null);
});

test("a failing log loses gh's prefixes and keeps its end", () => {
  const log = "test\tRun make test\t2026-10-04T10:00:00.0000000Z one\ntest\tRun make test\t2026-10-04T10:00:01.0000000Z two\ntest\tRun make test\t2026-10-04T10:00:02.0000000Z three\n";
  assert.equal(tail(log, 1000), "one\ntwo\nthree");
  assert.equal(tail(log, 9), "…\nthree");
});

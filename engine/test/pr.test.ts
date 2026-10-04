// A pull request's checks as gh reports them, read without gh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkOf, pullFrom, runOf, tail } from "../pr.ts";

test("a check run and a commit status come down to pass, fail, pending or skipped", () => {
  const link = "https://github.com/o/r/actions/runs/123/job/456";
  assert.deepEqual(checkOf({ __typename: "CheckRun", workflowName: "CI", name: "test", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: link }), { name: "CI / test", state: "pass", link, seconds: null });
  assert.equal(checkOf({ __typename: "CheckRun", name: "test", status: "IN_PROGRESS" }).state, "pending");
  assert.equal(checkOf({ __typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "CANCELLED" }).state, "fail");
  assert.equal(checkOf({ __typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED" }).state, "skipped");
  assert.deepEqual(checkOf({ __typename: "StatusContext", context: "deploy/preview", state: "PENDING", targetUrl: "https://x" }), { name: "deploy/preview", state: "pending", link: "https://x", seconds: null });
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
  // As GitHub sent a real one: a byte-order mark, a group around the command, colour, an error marker.
  const real =
    "test\tRun the tests\t\uFEFF2026-10-04T17:12:34.4474559Z ##[group]Run sh test.sh\n" +
    "test\tRun the tests\t2026-10-04T17:12:34.4480000Z \x1b[36;1msh test.sh\x1b[0m\n" +
    "test\tRun the tests\t2026-10-04T17:12:34.4490000Z ##[endgroup]\n" +
    "test\tRun the tests\t2026-10-04T17:12:34.4600000Z FAIL: sum.txt should hold 4, it holds 5\n" +
    "test\tRun the tests\t2026-10-04T17:12:34.4700000Z ##[error]Process completed with exit code 1.\n";
  assert.equal(tail(real, 1000), "sh test.sh\nFAIL: sum.txt should hold 4, it holds 5\nProcess completed with exit code 1.");
});

test("a pull request carries its branches, whether it can merge, and how long each finished check ran", () => {
  const pull = pullFrom({
    number: 7, title: "Sum is five", url: "https://github.com/o/r/pull/7", state: "OPEN", headRefName: "check/t-1", baseRefName: "main", isDraft: false, mergeable: "CONFLICTING",
    statusCheckRollup: [{ __typename: "CheckRun", workflowName: "CI", name: "test", status: "COMPLETED", conclusion: "FAILURE", startedAt: "2026-10-04T17:12:20Z", completedAt: "2026-10-04T17:12:34Z" }],
  });
  assert.deepEqual([pull.head, pull.base, pull.draft, pull.mergeable], ["check/t-1", "main", false, "CONFLICTING"]);
  assert.deepEqual(pull.checks, [{ name: "CI / test", state: "fail", link: null, seconds: 14 }]);
  assert.equal(pullFrom({ number: 1, title: "t", url: "u", state: "OPEN" }).mergeable, "UNKNOWN");
});

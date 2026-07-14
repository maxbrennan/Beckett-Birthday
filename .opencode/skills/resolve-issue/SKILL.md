---
name: resolve-issue
description: "Use when asked to resolve, fix, or implement a GitHub issue in this repo (e.g. \"resolve issue 42\", \"fix #42\", \"work on the IQ timer issue\"). Drives the full workflow - open the issue, create an isolated git worktree off origin/main, write failing tests first, get plan approval, implement, verify npm test + coverage floors, then push a draft PR and clean up the worktree."
---

# Resolve a GitHub issue

Follow these steps IN ORDER. Do not skip steps. Do not start implementing before
the user approves the plan in step 5.

Definitions used throughout:

- `<N>` = the issue number.
- `BRANCH` = `issue-<N>-<short-slug>` (e.g. `issue-42-fix-iq-timer`).
- `ROOT` = the main checkout: `/Users/maxbrennan/Documents/Beckett-Birthday`
- `WT` = the worktree: `ROOT/.claude/worktrees/BRANCH`
- `REASONER` = a Task subagent backed by the deepseek-r1 reasoning model. Used
  for the hard-thinking parts of this workflow (root-causing, test design,
  planning, diagnosing failures). It has no tool access — it cannot run bash,
  read files, or use gh/git. It only sees what's pasted into its prompt and
  only returns text back. Treat it as a very sharp collaborator who can only
  be reached by letter.
- `EXPLORE-RUNNER` = a Task subagent with real tool access (glob/grep/read/
  bash) that drives Step 3. It has no judgment of its own about what's
  relevant — it takes direction from DEEPSEEK-EXPLORE and executes the actual
  searches/reads on its behalf, feeding raw results back to it.
- `DEEPSEEK-EXPLORE` = the deepseek-r1 model in a search-planning role. It
  decides what's worth looking at and does the relevance judgment, but has no
  working tools of its own — it describes what it wants in plain language and
  EXPLORE-RUNNER fetches it. You never call this directly; you call
  EXPLORE-RUNNER, which manages the back-and-forth with it and hands you a
  final, code-grounded report. You do not read files yourself during Step 3.
- `GENERAL` = opencode's built-in general-purpose subagent. Used to run
  commands whose raw output would be large (`npm install`, `npm run build`,
  `npm test`, coverage checks) so those logs don't eat your context. Tell it
  what to run, where, and to report back only pass/fail plus any error output.

CRITICAL RULE: after step 2, every bash command must use `workdir: WT`, and every
Read/Edit/Write must use absolute paths under `WT`. Never touch files under `ROOT`
directly — other agents may be working there. This rule binds whoever is actually
running the command — you, EXPLORE-RUNNER, or GENERAL — none of them know it
unless you tell them, so it's your job to include it every time you hand off work
to one of them. REASONER and DEEPSEEK-EXPLORE are the exception: neither touches
the filesystem, so neither can violate this, but they also can't know it exists
unless you (or EXPLORE-RUNNER, for DEEPSEEK-EXPLORE) tell them.

## Working with REASONER

You are the one talking to REASONER (Steps 4 onward) — it does the thinking,
you do the gathering. It has no memory between invocations and no ability to go
fetch something it's missing — never point it at a file path expecting it to
read that file, paste the actual content into whatever you hand it.

These files run thousands of lines, so "paste the actual content" means the
relevant excerpt, not the whole file — the function(s) touched plus enough
surrounding code (imports, related functions, the type/struct they operate on)
that REASONER isn't reasoning about a fragment stripped of context. Keep the
original line numbers attached to whatever you excerpt so `file:line`
references stay accurate. Don't over-trim either — when in doubt, include a
little more of the surrounding function/module rather than a bare line or two.
When REASONER's answer references something outside what you gave it, go get
that (the wider excerpt, or a different file) and hand it over rather than
guessing on its behalf.

## Step 1 — Open the issue

Run these commands to open the issue and read its body + comments. DO NOT make an agent run these. Run the commands yourself in the terminal, so you can read the full text and extract the expected behavior, test cases, and acceptance criteria.

```bash
gh issue view <N>
gh issue view <N> --comments
```

Read the full body and all comments. Keep the raw text around — you'll paste it
into REASONER calls verbatim in later steps, don't paraphrase it away. Extract:
the expected behavior, any test cases the issue describes, and any acceptance
criteria. If the issue number is ambiguous or missing, ask the user which issue
to work on before continuing.

## Step 2 — Create an isolated worktree off origin/main

```bash
git fetch origin
git worktree add .claude/worktrees/BRANCH -b BRANCH origin/main
```

(If the branch already exists, pick a different slug or remove the stale
worktree first with `git worktree remove .claude/worktrees/BRANCH`.)

Then set up the worktree (git-ignored files are missing in a fresh worktree).
`npm install` and `npm run build` both dump a lot of log output you don't need
in full, so hand this batch to a GENERAL agent task rather than running it yourself. Give it
`workdir: WT` and tell it to report back only success/failure plus any error
output — not the full log. These are the commands we want the agent to run:

```bash
# workdir: WT
npm install
```

```bash
# assets/ is git-ignored but the GUI test needs it (e.g. assets/jeopardy-theme.mp3)
cp -R "ROOT/assets/." "WT/assets/"
```

```bash
# workdir: WT — compiles elm-server.js + elm-client.js, required by integration/GUI tests
npm run build
```

Do NOT copy `config/app-config.json` into the worktree: tests don't need it, and
its absence stops the prebuild hook (`scripts/sync-config.js`) from rewriting
tracked files (`package.json` productName, `index.html` title).

Certs are NOT needed up front — Jest globalSetup generates self-signed certs
into `WT/certs/` automatically.

## Step 3 — Hand exploration off to EXPLORE-RUNNER

Do not read files yourself in this step. Call EXPLORE-RUNNER with the full
issue text (body + comments, verbatim) and the known layout of this repo:

- Elm client logic: `src/Main.elm`, `src/Game/*.elm`, `src/View.elm`
- Elm server logic: `src/Server.elm`, `src/Sync.elm`
- JS glue: `client/bridge.js`, `server/index.js`, `server/codec.js`, `scripts/`
- Existing tests to imitate: `tests/*.elm`, `tests/unit/`, `tests/integration/`
- It should also check `AGENTS.md` and the relevant sections of `CLAUDE.md`
  (architecture, module layout, test conventions)

Tell it to work only under `WT`, and that it's looking for the tests closest
to the affected feature — new tests must follow their patterns (integration
tests use `tests/helpers/testServer.js` + `distClient.js` / `playerClient.js`).

EXPLORE-RUNNER doesn't judge relevance itself — it relays your task to
DEEPSEEK-EXPLORE, which decides what's worth looking at, and EXPLORE-RUNNER
fetches whatever it asks for and loops until DEEPSEEK-EXPLORE has enough to
report FINAL: confirmed files, anything likely missing (callers, the Elm↔JS
boundary, sync/codec logic), and the closest test pattern to imitate. What
you get back has already gone through that process — it's not EXPLORE-RUNNER's
own first-pass guess.

Take that final report — file paths, the relevant excerpts, and the vetted
summary — as your context for the rest of this workflow. You shouldn't need to
re-read those files yourself later unless something changes on disk.

## Step 4 — Write the tests from the issue FIRST, and prove their status

Before writing any test yourself, hand the design work to REASONER: paste the
full issue text, the relevant excerpts EXPLORE-RUNNER gathered in Step 3, and the
closest existing test file(s) it identified to imitate, and ask REASONER to design the
specific test cases (inputs, expected outputs, edge cases) and write the
actual test code in the style of the imitated file. Take its code as your
draft — adapt only what's needed to fit real import paths/module names, don't
redesign the logic yourself.

Route by type:

- Pure Elm decision logic → `tests/<Module>Test.elm` (elm-test)
- JS unit behavior → `tests/unit/<name>.test.js`
- Client/server protocol behavior → `tests/integration/<name>.test.js`

Run ONLY the new tests, focused:

```bash
# workdir: WT
npx elm-test tests/<File>.elm
npx jest --selectProjects unit tests/unit/<file>.test.js
npx jest --selectProjects integration tests/integration/<file>.test.js   # needs npm run build:server first
```

Verify the outcome is what it should be BEFORE any fix exists:

- Tests for the bug/missing feature must FAIL now. If one passes, the test is
  wrong or the issue is misunderstood — fix the test, do not proceed.
- Regression-guard tests for behavior the issue says must be KEPT must PASS now.

If a test's pass/fail status doesn't match what it should be, don't just tweak
it yourself — send REASONER the test code, the run output, and the source file
it's exercising, and ask it whether the test is wrong or the understanding of
the issue is wrong. Act on its diagnosis, then re-run.

Report the pass/fail status of each new test to the user.

## Step 5 — Propose a plan and WAIT for approval

This step is almost entirely reasoning, so let REASONER draft it. Gather and
paste everything it needs in one call:

- The full issue body + comments
- Relevant excerpts of every file EXPLORE-RUNNER gathered in Step 3 that's in scope
  (not full files — the functions/sections that matter, with line numbers)
- The new test files from Step 4 and their current pass/fail output
- The relevant AGENTS.md/CLAUDE.md excerpts
- The CONSTRAINTS block: the CRITICAL RULE plus the repo-specific rules from
  Step 6 (95% Elm coverage floor, no version bump, never run deploy/undeploy)

Ask it for exactly the plan structure below, with `file:line` references
grounded in the pasted content — not invented:

1. Root cause / current behavior (with `file:line` references)
2. Exact changes: each file, each function, what changes and why
3. Which new tests (from step 4) prove the fix, plus any additional tests needed
4. Risks / alternatives considered

Present REASONER's plan to the user essentially as-is (light editing for
clarity is fine, don't rewrite the substance), then use the `question` tool to
ask the user to approve it (options: approve / revise). Do NOT modify any
non-test source file until the user approves. If the user asks for changes,
send REASONER a follow-up call with the original context plus the user's
requested changes, and re-present.

## Step 6 — Implement

Make the planned changes in `WT` only. For each file the plan touches, if the
exact code isn't already spelled out in REASONER's plan, ask it for the
precise change — paste the function/section being changed plus enough
surrounding context (imports, callers, the type it operates on) for REASONER
to get the edit right, not the whole file, and ask for the new version of just
that function/section. Apply what it returns with Edit, don't freehand a
different implementation than what was planned and approved.

Repo-specific rules (include these in every REASONER call in this step):

- New Elm decision logic must be pure functions unit-tested in `tests/*.elm`,
  not inline effects (CI enforces a 95% Elm coverage floor).
- Do not bump `package.json` version — a GitHub Action does that on merge.
- Never run `npm run deploy:*` / `undeploy` — they hit the production server.

## Step 7 — Full verification (repeat 6→7 until everything passes)

`npm run build`, `npm test`, and the coverage checks all produce heavy output
(elm-coverage + jest unit/integration + GUI smoke test) — delegate this whole
batch to GENERAL rather than running it yourself, same as Step 2. Give it
`workdir: WT` and tell it to report back pass/fail per command plus any
failure output, coverage numbers, and error text — not the full log:

```bash
# workdir: WT
npm run build
npm test
```

`npm test` = elm-coverage + jest unit (with coverage) + jest integration + GUI
smoke test. After it passes, check the coverage floors using the reports it
just produced:

```bash
# workdir: WT
node ci/check-elm-coverage.js 95    # reads .coverage/ from the elm test run
node ci/check-js-coverage.js 20     # reads coverage/js/coverage-summary.json from the unit run
```

If ANY test or coverage check fails and the cause isn't immediately obvious,
don't iterate blindly — package it for REASONER: the failure/error output
GENERAL reported, the relevant excerpt of the file(s) it points at, and the
relevant slice of the approved plan. Ask REASONER to diagnose the cause and
propose the specific fix. Apply the fix, then re-run this whole step. Only
skip the REASONER round-trip for trivial, unambiguous failures (e.g. an
obvious typo you introduced).

Do not proceed to step 8 with any failure.

## Step 8 — Commit and push

```bash
# workdir: WT
git status
git diff
git log --oneline -10
```

Before staging, check `git diff package.json index.html` — if `productName` or
`<title>` churned, revert those hunks (`git checkout -- package.json index.html`
only if they contain no intended changes). Stage only intended files (never
`.env`, `config/app-config.json`, certs, assets, or `app-uuid.json`), write a
concise commit message matching the log style, then:

```bash
# workdir: WT
git push -u origin BRANCH
```

## Step 9 — Create a draft PR

Write the PR body to a file first (this guarantees real newlines — NEVER pass
a body string containing literal `\n` to gh):

Use the Write tool to create `/tmp/pr-body-<N>.md` with real markdown. Draw the
Summary section straight from REASONER's Step 5 plan (root cause + exact
changes) — it's already correct and grounded, no need for a fresh REASONER call
just to reformat it:

```markdown
## Summary

<what changed and why, 2-5 bullets>

## Test plan

- <new tests added and what they prove>
- `npm test` passes; coverage floors verified (Elm 95 / JS 20)

Fixes #<N>
```

Then:

```bash
# workdir: WT
gh pr create --draft --title "<concise title>" --body-file /tmp/pr-body-<N>.md
```

Draft is mandatory — marking ready triggers the code-review action.

## Step 10 — Clean up and report

From the MAIN checkout (workdir: ROOT — you cannot remove a worktree from
inside itself):

```bash
git worktree remove .claude/worktrees/BRANCH
# if it refuses due to leftover ignored files (node_modules etc.):
git worktree remove --force .claude/worktrees/BRANCH
```

The local branch survives worktree removal and its commits are already on
`origin`, so nothing is lost.

Finally, give the user the PR URL (from the `gh pr create` output) and a
one-paragraph summary of what was changed.

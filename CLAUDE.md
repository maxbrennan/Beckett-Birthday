# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
npm run build              # compile both Elm apps (elm-server.js + elm-client.js)
npm run build:server       # compile src/Server.elm → elm-server.js
npm run build:client       # compile src/Main.elm → elm-client.js

# Run (via PM2)
npm run start:dev          # build + start both server and client in dev mode (DEV=true)
npm run start:server:dev   # build + start server only in dev mode
npm run start:client:dev   # build + start client (Electron) only in dev mode
npm run stop               # stop all PM2 processes

# Tests
npm test                   # runs elm-test (tests/ directory)

# Distribution (admin only — requires credentials in .auth/)
npm run deploy:mac         # build Electron DMG and upload to production server
npm run deploy:win         # build Electron EXE and upload to production server
npm run undeploy           # remove a deployed build from the server
npm run add-admin          # add an admin user to .auth/users.jsonl
```

## Architecture

This is a birthday-present interactive game delivered as an Electron desktop app, with a shared-state WebSocket server so multiple clients stay in sync.

### Two Elm programs

**Client** (`src/Main.elm` → `elm-client.js`): A `Browser.application` Elm app running inside Electron. It manages all game screens (IQ test, music quiz, etc.) and syncs state with the server after every user action. The file `client/bridge.js` (bundled into the Electron app) is the JS glue: it initialises `Elm.Main`, wires all Elm ports to Node.js/Electron APIs (WebSocket via `ws`, file reads, DOM property manipulation, Protobuf codec).

**Server** (`src/Server.elm` → `elm-server.js`): A `Platform.worker` Elm app (no UI). It manages connected players, persists game state, and handles app distribution. The Node.js host (`server/index.js`) manages raw WebSocket/HTTPS connections and delegates to the Elm worker via ports.

### Communication

All WebSocket messages use Protobuf, defined in `proto/messages.proto` and encoded/decoded by `server/codec.js` (protobufjs). The Elm client communicates with its JS host via ports; the JS host serialises to/from Protobuf before sending over the wire.

Client→Server flow: Elm port → `bridge.js` → `codec.encodeClient` → WebSocket → `server/index.js` → `codec.decodeClient` → Elm port → `Server.elm` update.

### State persistence

The server stores each player's game state as JSON in `app-builds/builds.jsonl` (a JSONL file keyed by UUID). When a client sends a `stateUpdate`, the server writes the new state. When a client disconnects, the server snapshots the current screen into a `savedState` field and resets to `BeginScreen` so the next connection resumes from the saved position.

### Auth system

Two-level challenge–response auth (Ed25519 keys or username/password), implemented in `server/auth.js`:
- **Admin (level 2)**: required for deploying builds, undeploying, and listing. Credentials stored in `.auth/users.jsonl`; per-session UUIDs + public keys in `.auth/uuids.jsonl`.
- On first password auth, the client generates an Ed25519 keypair, stores it in `~/.birthday-auth/keys/`, and the server registers the public key so future logins are passwordless via key signing.
- If key auth fails, `auth.js` sets `_keyAuthFailed = true`, reconnects, and retries with password auth.

### Distribution system

`scripts/deploy.js` authenticates with the server (`distRegister` → auth challenge), runs `electron-builder`, then uploads the built DMG/EXE in a single HTTPS `POST /upload` (bearer token from the auth ack) and finalizes with a `distComplete` message. The server stores uploads under `app-builds/` and records them in `builds.jsonl`. Players download their build via HTTPS GET `/<uuid>`.

### Dev vs. production

`DEV` is set to `true`/`false` via PM2's `env`/`env_dev` blocks in `ecosystem.config.js` (not `.env` — `.env` only holds ports/TLS paths). Dev uses port 8443 (localhost); production uses port 443 with TLS certs from `certs/`. Uuid validation is identical in both modes: a uuid must have a matching entry in `app-builds/builds.jsonl` or the connection is rejected — the only difference between dev and prod is which host/port the client connects to. The Electron client opens DevTools automatically when `DEV=true`.

### Elm module layout

```
src/
  Main.elm          — client entry point: init/update/subscriptions/main, wired to Types/Sync/View
  Server.elm        — server entry point, top-level Model/Msg/update
  View.elm          — rendering: Html Msg view functions, plus pure helpers like formatTimer
  Audio.elm         — audio element rendering, plus pure helpers like currentQuizSong
  Sync.elm          — ServerEnvelope decoding and Model/Screen JSON encode/decode
  Types.elm         — canonical Model/Screen/Msg/PausedState/PendingEvent type definitions
  Game/
    IQTest.elm      — IQ test screen: ding scheduling, fake-flash trap, scoring
    Quiz.elm        — music quiz: questions, answer validation, flow
  Server/
    Distribution.elm — DistInfo/DistStage type declarations (the one genuinely thin module here)
    Protocol.elm     — client envelope decoder, server envelope builders
    Registry.elm     — RegistryEntry JSONL encode/decode, writeRegistry, snapshotForJeopardy
```

`Main.elm`'s `update` pulls its per-`Msg` decision logic into pure functions wherever the Msg carries real business logic, mirroring `Server.elm`'s pattern (`classifyDing`, `advanceOnClear`, etc., exercised directly by `tests/ServerTest.elm`): functions typed only over `Game.IQTest`'s/`Game.Quiz`'s own state (e.g. `decideSpaceBar`, `nextFfPhase`, `decideAnswer`) live in those sibling modules, since `Types.elm` imports them and a reverse import would be circular; functions that need `Screen`/`Model`/`PausedState` (e.g. `screenAllowsTimeout`, `videoSeekTime`, `trackEndedTarget`) stay inline in `Main.elm` just above `update`. `Server.Distribution.elm` is the only module above that's genuinely a stub (type declarations only, no functions).

### Test coverage conventions

`View.elm`'s `Html Msg`-producing functions are excluded from the elm-coverage unit-test target (`ci/check-elm-coverage.js`'s `EXCLUDED_MODULES`) — every one of them takes the full `Model` rather than narrow view-model data, so unit-testing them meaningfully would mean either full-`Model` snapshot fixtures per screen or a view-model refactor, neither warranted today. They're verified instead by `tests/integration/gui.electron.js`, which drives the real rendered Electron app. `View.elm`'s pure non-rendering helpers (e.g. `formatTimer`) are still unit-tested normally, in `tests/AudioViewTest.elm`.

The elm-coverage floor in `.github/workflows/ci.yml`'s `elm-coverage` job (95%, excluding `View`) meets the 95% target from issue #26; the JS floor in the `js-coverage` job is an interim ratchet (currently 20%), raised whenever new unit coverage lands. The small residual gap in `Main.elm`/`Server.elm` is genuinely unreachable via `elm-test`, not undertested:
- `Task.perform`/port-subscription callbacks (e.g. `Server.elm`'s `scheduleCountdownStep`/`scheduleDing`, `Main.elm`'s `ShowQuestion`'s DOM-focus callback) only run when the real runtime resolves the underlying `Task`/port event — a pure `update` call in a test never executes them.
- `init`/`subscriptions`/`main` are `Platform.worker`/`Browser.element` program wiring, not decision logic.
- `Main.elm` and `Server.elm` both declare a port named `readFile` (and `readFileResult`) — since `elm-test` compiles every test module's dependencies into one program, calling *both* `Main.init` and `Server.init` from tests in the same run makes both same-named ports "reachable" at once, which crashes at runtime ("There can only be one port named `readFile`"). Only one of the two `init`s can be exercised via a direct test; the other's declaration is left uncovered.
- `Server.elm`'s `reconcileIqTimerAfterEdit` has one `Err _ -> model` branch that's provably dead: `decodeEditedIqScreen`'s `Decode.oneOf` always falls back to `Decode.succeed EditedIqOther`, so decoding it can never fail.

## Plan Implementation Workflow

When implementing changes from an approved plan:
1. Choose a short, meaningful, kebab-case branch name that describes the task itself (e.g. `refactor-dev-mode`, `add-integration-tests`) — never a random slug, and never the plan file's own filename.
2. Create the branch and worktree manually, then switch into it: `git worktree add .claude/worktrees/<branch-name> -b <branch-name> origin/main`, followed by `EnterWorktree` with `path: .claude/worktrees/<branch-name>`. This avoids `EnterWorktree name:`'s automatic `worktree-` branch prefix while still giving an isolated worktree that keeps changes off `main` and prevents conflicts with other active Claude sessions.
3. After implementation is complete and committed, create a draft PR with `gh pr create --draft`. Draft PRs prevent accidental merging and defer the Claude Code Review action until the PR is explicitly marked ready.
4. After the PR is created, call `ExitWorktree` with `action: "keep"` to return the session to the main project directory, then remove the worktree with `git worktree remove .claude/worktrees/<branch-name>`. This frees the branch so the user's IDE can check it out without a "branch already checked out" lock (issue #29). A worktree left on disk holds that lock and blocks IDE branch operations. Note: because the worktree was created manually with `git worktree add` (step 2) and entered via `EnterWorktree path:`, `ExitWorktree(action: "remove")` will refuse to delete it — use `git worktree remove` instead. The local branch is preserved (only the worktree directory is removed), so its commits — already pushed to `origin` by `gh pr create` — remain available.

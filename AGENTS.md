# AGENTS.md

## Project Overview

This is a birthday-present interactive game delivered as an Electron desktop app, with a shared-state WebSocket server so multiple clients stay in sync.

The app is two Elm programs compiled to JavaScript:
- **Client** (`src/Main.elm` → `elm-client.js`) — runs inside Electron; all the game screens (music quiz, IQ test, etc.)
- **Server** (`src/Server.elm` → `elm-server.js`) — headless; tracks players, persists state, and handles app distribution

## Architecture Notes

### Elm Architecture
- Client is a `Browser.application` Elm app running inside Electron
- Server is a `Platform.worker` Elm app (no UI)
- Communication via Protobuf (`proto/messages.proto`, `server/codec.js`)
- State persistence in `app-builds/builds.json`
- Authentication uses Ed25519 keys or username/password with two-level system

### Dev vs. Production
- `DEV` is set to `true`/`false` via PM2's `env`/`env_dev` blocks in `ecosystem.config.js` (not `.env`)
- Dev uses port 8443 (localhost); production uses port 443 with TLS certs from `certs/`
- Client opens DevTools automatically when `DEV=true`

## Testing Requirements

### Coverage Targets
- Elm coverage: **95%** (excluding View module)
- JS coverage: **20%** (interim ratchet)

Before committing changes, ensure:
```bash
npm run test
```

## Development Workflow

### Running Commands
```bash
# Build  
npm run build              # compile both Elm apps
npm run build:server       # compile server only
npm run build:client       # compile client only

# Run (via PM2)
npm run start:dev          # build + start both server and client in dev mode
npm run start:server:dev   # build + start server only in dev mode  
npm run start:client:dev   # build + start client only in dev mode
npm run stop               # stop all PM2 processes

# Tests
npm test                   # runs all tests (Elm + JS)
```

### Deployment
- Admin credentials required for deploying builds
- Distribution system uploads built binaries to server via HTTPS POST `/upload`
- Builds are stored under `app-builds/` and recorded in `builds.json`
- Players download their build via HTTPS GET `/<uuid>`

## Important Conventions

1. All logic should be implemented in Elm when possible, not JavaScript
2. When adding changes, create git worktree off origin/main to avoid conflicts with other agents:
   ```bash
   git worktree add .claude/worktrees/<branch-name> -b <branch-name> origin/main
   ```
3. After implementation, push changes before deleting the worktree:
   ```bash
   git push origin <branch-name>
   git worktree remove .claude/worktrees/<branch-name>
   ```
4. ** never make changes to the locally checked out branch. ALWAYS make a new worktree when making changes, then commit to the PR (or make a new one), then delete the worktree**

## Implementation and PR Process

When implementing changes or creating a pull request:

1. **Create a new worktree** for your changes:
   ```bash
   git worktree add .claude/worktrees/<branch-name> -b <branch-name> origin/main
   ```
2. **Make your changes** in the appropriate files within your existing worktree
3. **Test your changes locally** by running `npm run test` to ensure no regressions
4. **Commit your changes** with clear commit messages following conventional commits format
5. **Push to your branch** using `git push origin <branch-name>`
6. **Create a draft pull request** using:
   ```bash
   gh pr create --draft --title "<PR title>" --body "<PR description>"
   ```
   **Important:** When providing content for the PR body, use actual newlines (`\n`) rather than escaped newlines (`\\n`) to avoid parsing issues.

7. **Submit your PR** and ensure all checks pass before merging
8. **Delete the worktree** when finished:
   ```bash
   git worktree remove .claude/worktrees/<branch-name>
   ```

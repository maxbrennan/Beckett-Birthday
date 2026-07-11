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
4. Follow the plan implementation workflow:
   1. Create branch and worktree manually 
   2. Implement changes and commit
   3. Create draft PR with `gh pr create --draft`
   4. Exit worktree with `ExitWorktree action: "keep"` then remove it

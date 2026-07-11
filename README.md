# Ryan Birthday

An interactive birthday‑present game delivered as an Electron desktop app, backed by
a shared‑state WebSocket + HTTPS server so a player's progress is saved and resumable.

The app is two Elm programs compiled to JavaScript:

- **Client** (`src/Main.elm` → `elm-client.js`) — runs inside Electron; all the game
  screens (music quiz, IQ test, …). JS glue lives in `client/bridge.js`.
- **Server** (`src/Server.elm` → `elm-server.js`) — headless; tracks players, persists
  state, and hands out builds. Node host is `server/index.js`.

Client and server talk over `wss://` using Protobuf (`proto/messages.proto`,
`server/codec.js`). Process management is via PM2 (`ecosystem.config.js`).

This README covers, step by step: setting up and running a server, adding trivia
questions, editing the reward text, deploying a build, and connecting a client both on
the **same computer** (development) and from **another computer**.

---

## 1. Prerequisites & install

You need **Node.js + npm**. The Elm compiler is run through `npx`, so no global install
is required.

```bash
git clone <this-repo>
cd Beckett-Birthday
npm install
```

### 1a. Configure `.env`

Copy the example and edit it. `.env` is git‑ignored (it is local config, and it gets
baked into distributed builds — see §7).

```bash
cp .env.example .env
```

| Variable          | Meaning                                             | Typical value    |
|-------------------|-----------------------------------------------------|------------------|
| `DEV_SERVER_PORT` | Port the dev server listens on / client dials       | `8443`           |
| `PROD_SERVER_HOST`| Host a **production** client connects to            | `localhost` or a LAN IP / domain |
| `PROD_SERVER_PORT`| Port a production client connects to                | `443`            |
| `SSL_CERT_FILE`   | Path to the TLS certificate                         | `certs/cert.pem` |
| `SSL_KEY_FILE`    | Path to the TLS private key                         | `certs/key.pem`  |

> `DEV` (dev vs. production mode) is **not** set here — it comes from PM2's `--env dev`
> flag (see §3), which only changes host/port, not game behavior.

### 1b. TLS certificates

The server always serves over TLS and reads `certs/cert.pem` + `certs/key.pem` at
startup — **it will crash if they are missing.** The client accepts self‑signed certs
(`rejectUnauthorized: false` in `client/bridge.js`), so the cert never needs to be
"trusted" on a player's machine.

#### Quick temporary certs with mkcert

[mkcert](https://github.com/FiloSottile/mkcert) makes locally‑trusted certs in one line.

```bash
# Install (macOS)
brew install mkcert
# (Windows: choco install mkcert   •   Linux: see mkcert README)

# Optional: trust mkcert's local CA on THIS machine (removes browser warnings here)
mkcert -install

# Development (same computer only):
mkcert localhost 127.0.0.1 ::1
#   → produces  localhost+2.pem  and  localhost+2-key.pem

# Another computer on your LAN — include the server's LAN IP (see §8):
#   mkcert localhost 192.168.1.50

# Install them where the server expects (matches .env):
cp localhost+2.pem     certs/cert.pem
cp localhost+2-key.pem certs/key.pem
```

> You do **not** need to install mkcert's CA on other players' machines — the client
> accepts the cert regardless. mkcert here is just a fast way to generate a valid
> cert/key pair; a plain `openssl` self‑signed pair works too.

### 1c. App config

Copy the example and edit it. `config/app-config.json` is git‑ignored — it holds
the real trivia answers and win‑screen text, both spoilers for the birthday recipient
(see §4/§5), plus the app's display name and the IQ‑test skip‑offer toggle (§5a). It
is read only by the **server** and by build‑time scripts; nothing under `config/` is
ever bundled into a client build (see §2) — the client instead discovers songs by
listing `assets/songs/` directly, in numeric filename order (see §4/§6).

```bash
cp config/app-config.example.json config/app-config.json
```

---

## 2. Project layout you'll edit

```
config/
  app-config.json           ← app name, trivia questions & answers, win‑screen text — git‑ignored, server‑only (§1c, §4, §5)
  app-config.example.json   ← template for the above, tracked in git
assets/
  songs/                ← all quiz songs, numbered 0.ext, 1.ext, ... (§4, §6)
  jeopardy-theme.mp3  airpods.png  ding.mp3  loud.mp4  icon.icns  icon.ico   ← other media (stay at root)
.env                    ← ports, prod host, cert paths   (§1a)
```

Nothing under `config/` is ever bundled into a client build or read by the client —
it's all server‑side (`config/app-config.json`'s `quizQuestions` answers and
`winScreen` reward text). Everything under `assets/` (§6) is loaded at client
**startup** and bundled into distributed builds; editing it changes the game
**without touching Elm source** — but already‑distributed builds must be
rebuilt/redeployed to pick up changes. `config/app-config.example.json` is a
dev‑only template (§1c), neither loaded at runtime nor bundled into builds.

---

## 3. Run a server (development, same computer)

```bash
npm run start:server:dev
```

This builds `elm-server.js` and starts the `birthday-server` PM2 process in dev mode
(`DEV=true`) on port **8443**, bound to `0.0.0.0`.

```bash
npm run stop            # stop everything
npm run stop:server     # stop just the server
npx pm2 logs birthday-server   # tail server logs
```

Production equivalent (port 443, `DEV=false`): `npm run start:server`.

---

## 4. Add / edit trivia questions & answers

`config/app-config.json` is git‑ignored (see §1c). If you don't have it yet:

```bash
cp config/app-config.example.json config/app-config.json
```

Then edit **`config/app-config.json`**'s `quizQuestions` field. It is a JSON array of
`{ "answers": [...] }` objects — no `song` field. Questions are asked in order, and a
question's position in this array **is** its song's index: the 1st entry (index 0) is
answered by whichever file in `assets/songs/` starts with `0.` (see §6), the 2nd entry
(index 1) by `1.`, and so on. The client never reads this file at all — it discovers
songs purely by listing `assets/songs/` and sorting by that leading number
(`songOrder` in `src/Game/Quiz.elm`), so keeping the array order and the filename
numbers in sync is what ties a question to its song.

```jsonc
[
  { "answers": ["Baby Shark Hip Hop", "Baby Shark (Hip Hop Version)"] },
  { "answers": ["Manchild"] }
]
```

`answers` — a list of accepted answers for that position. A player's guess is correct
if it matches **any** entry in the list.

**Answer matching is fuzzy.** Guesses are normalized before comparison
(`normalize` in `src/Game/Quiz.elm`): lower‑cased, hyphens → spaces, punctuation
stripped, whitespace collapsed. So `"...Ready For It?"` is matched by `ready for it`.
Write answers in their natural form; you don't need to add punctuation variants.

### Adding a new question

1. Put the media file in `assets/songs/`, named with the next number in sequence and
   a generic (spoiler‑free) extension — e.g. if `assets/songs/` currently goes up to
   `9.mp3`, add `assets/songs/10.mp3` (or `.mp4` for a video).
2. Append the matching entry to the **end** of `config/app-config.json`'s
   `quizQuestions` array, so its array position lines up with the new filename's
   number:

```jsonc
  { "answers": ["My Song", "My Song (Live)"] }
```

---

## 5. Edit the winning‑screen text

Edit **`config/app-config.json`**'s `winScreen` field:

```json
{
  "winScreen": "Text \"creeper... awwww man\" to Max to claim your reward!"
}
```

Whatever you put in `winScreen` is read by `scripts/deploy.js` at deploy time (§7c)
and sent to the server along with that build, which stores it per‑build in
`app-builds/builds.json` and delivers it to that player at win time. If
`config/app-config.json` is missing or `winScreen` is empty, the deploy fails
outright rather than shipping a build with no win text.

### 5a. Enable/disable the IQ‑test skip offer

The IQ test's one‑time "skip this and take on a mystery challenge later" offer
(shown after the player's first qualifying failure) is on by default. To turn it
off for a build, set **`config/app-config.json`**'s `iqSkipOfferEnabled` to `false`:

```json
{
  "iqSkipOfferEnabled": false
}
```

Like `winScreen`, this is read by `scripts/deploy.js`/`scripts/deploy-replacement.js`
at deploy time and stored per‑build in `app-builds/builds.json`, then delivered to
that player once they connect. Unlike `winScreen`, it's optional — a missing field
(or an existing `config/app-config.json` from before this option existed) is treated
as `true` (offer enabled), so older configs keep working unchanged.

---

## 6. Song assets

All quiz song files live under **`assets/songs/`**, named `0.<ext>`, `1.<ext>`,
`2.<ext>`, ... — a generic, spoiler‑free number, not the song's real name (the whole
point is that opening the packaged app or `assets/songs/` shouldn't reveal any
answer). `.mp4` files play as a fullscreen video; anything else plays as audio. The
following stay at the `assets/` root and are **not** quiz songs: `jeopardy-theme.mp3`,
`airpods.png`, `ding.mp3`, `loud.mp4`, `icon.icns`, `icon.ico`.

The client lists `assets/songs/` itself at startup (`client/bridge.js`'s `readDir`
port) and orders the results by each filename's leading number — it never reads
`config/app-config.json` or any other config file to know what to play (see §4).

`assets/` is git‑ignored (large binaries are distributed separately), but the whole
folder — including `assets/songs/` — is bundled into builds via `assets/**/*` in
`package.json`.

---

## 7. Deploy a build

Deploying builds the Electron app, uploads it to the **production** server, and registers
it so a player can download and connect. It requires an admin account.

### 7a. One‑time: create an admin

```bash
npm run add-admin      # prompts for a username + password → .auth/users.json (level 2)
```

The first deploy prompts for these credentials, then stores an Ed25519 keypair under
`~/.birthday-auth/keys/`, so subsequent deploys authenticate passwordlessly.

### 7b. Point the build at the right server (do this *before* deploying)

`scripts/deploy.js` uploads to `PROD_SERVER_HOST:PROD_SERVER_PORT` from `.env`, and that
same `.env` is **baked into the build**, so it is also where each installed client will
connect. Set it before you build:

- Local testing → `PROD_SERVER_HOST=localhost`
- Another computer → the server's LAN IP or domain (see §8)

### 7c. Deploy

```bash
npm run deploy:mac     # or: deploy:win / deploy:linux
```

This will: generate a fresh per‑build UUID into `app-uuid.json`, authenticate to the
server, run `electron-builder`, and upload the artifact (a single HTTPS `POST /upload`
with a one‑time token). The server saves the binary under `app-builds/` and records it in
`app-builds/builds.json`, keyed by that UUID.

### Manage deployed builds

```bash
npm run undeploy                    # list all deployed builds (uuid  filename  platform)
node scripts/undeploy.js <uuid>     # remove one build

# Replace an existing build but carry over the player's saved state:
npm run deploy:replacement:mac -- <old-uuid>
```

---

## 8. Access the app from a client

A client is identified to the server by the **UUID** baked into its build
(`app-uuid.json`); that UUID must have a matching row in `app-builds/builds.json` or the
connection is refused.

### 8a. Same computer (development)

Run the client (Electron) in dev mode — either alongside a dev server, or on its own:

```bash
npm run start:dev          # build + start BOTH server and client (dev)
# or, if the server is already running:
npm run start:client:dev   # client only
```

In dev mode the client ignores `PROD_SERVER_HOST` and always dials
**`wss://localhost:8443`** (`DEV_SERVER_PORT`). DevTools opens automatically. Stop with
`npm run stop`.

### 8b. Another computer (LAN or remote)

Players run the **packaged app** (the DMG/EXE they download), not the repo. Two things
have to be right:

1. **Point clients at the server.** Before deploying (§7b), set in `.env`:

   ```
   PROD_SERVER_HOST=192.168.1.50      # the SERVER machine's LAN IP (or a domain)
   PROD_SERVER_PORT=443               # 443 → port omitted from the URL; other → wss://HOST:PORT
   ```

   This value is bundled into the build, so it must be set **before** `npm run deploy:*`.
   Ideally regenerate certs to include that host (see §1b) — though the client accepts the
   cert either way.

2. **Distribute the build.** After deploying, the player downloads their build over HTTPS:

   ```
   https://<PROD_SERVER_HOST>/<uuid>
   ```

   (The server streams the file for any UUID present in `builds.json`; unknown UUIDs get
   a 404.) They install and launch — the bundled `.env` sends them to your server and the
   bundled `app-uuid.json` identifies them.

**Networking checklist for remote/LAN:**

- The server binds `0.0.0.0`, so make sure the chosen port is reachable: open the
  firewall on the server machine, and for internet access add a router port‑forward.
- Connections are always `wss://` (TLS); self‑signed certs are fine (§1b).
- Find the server's LAN IP with `ipconfig getifaddr en0` (macOS) or `ip addr` (Linux).

---

## 9. Tests

```bash
npm test        # Elm tests (elm-coverage) + JS tests (jest) + a GUI/Electron smoke test
```

---

## Command reference

| Command | What it does |
|---|---|
| `npm run build` | Compile both Elm programs |
| `npm run start:server:dev` / `start:server` | Start the server (dev port 8443 / prod 443) |
| `npm run start:client:dev` / `start:client` | Start the Electron client |
| `npm run start:dev` / `start` | Start server **and** client |
| `npm run stop` | Stop all PM2 processes |
| `npm run add-admin` | Create an admin (needed to deploy) |
| `npm run deploy:mac` / `deploy:win` / `deploy:linux` | Build + upload + register a build |
| `npm run undeploy` | List deployed builds (or `node scripts/undeploy.js <uuid>` to remove) |
| `npm test` | Run the test suite |

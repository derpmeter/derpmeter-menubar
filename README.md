# DerpMeter (macOS)

Menu bar app (AppKit `NSStatusItem` + SwiftUI panel, macOS 14+). It shows the selected agent's 24h Derp Score and lets you vote Smart / Meh / Dumb in one click. It uses the same `/api/index`, `/api/models` and `/api/votes` contract as the `derp` CLI.

## Derp Smash (optional desktop CRT)

A small retro CRT on your desktop that you can smash with a hammer or a baseball bat. **Off by default.**

- **Enable:** Settings → Derp Smash → _Enable Derp Smash_, or the panel's `…` menu → _Derp Smash desktop CRT_. Settings also pick the weapon, the size (Small by default, Medium, Large; the vote prompt stays readable), mute impact sounds, and _Keep above other windows_ (off: the CRT sits just above the desktop icons, so app windows cover it).
- **Use:** click to smash, drag to move (the spot is remembered per display and kept on screen), right-click for _Change Weapon_, _Repair CRT_, _Change Agent_, _Size_, _Mute Sounds_, _Keep Above Windows_, _Hide Derp Smash_, _Open DerpMeter_.
- **Damage:** 1–2 hits light, 3–4 heavy, 5 broken. At 5 hits an optional _Smart / Meh / Dumb_ prompt appears. Nothing is preselected; _Not now_ closes it and the CRT stays broken; _Repair_ resets it without voting.
- **Votes:** only a button you press in the prompt is a vote. It goes through the same queue, token and cooldown as the panel (per agent and model; the countdown shows while you wait). Paused or offline votes are queued as usual. Hits are counted only on this Mac and never sent or added to the Derp Score.
- **Disable:** _Hide Derp Smash_ or the Settings toggle closes the window and releases it.
- **Resources:** no timers or polling; animations run only briefly after a hit or during a repair (respecting Reduce Motion). The app opts out of App Nap for about 1.5 s after an interaction so the animation is smooth, then idles. No Accessibility, Screen Recording or Input Monitoring permission; the window never takes keyboard focus and is not shown over full-screen apps or the lock screen.
- **QA:** `.build/debug/DerpMeterCompanion --render-smash <dir>` renders each state to PNG offscreen (own views only).

## Beta download

`npm run companion:pack` builds a universal (Apple Silicon + Intel) app and, for notarized releases, requires Developer ID signing plus a Keychain notarization profile (see below). It writes `public/downloads/DerpMeter-<version>-beta-macOS-notarized.zip`; `/apps` links it with its SHA-256. Bump `release.json` and notarize each new beta.

## Build and run

```sh
cd packages/companion
swift test                 # DerpCore: vote contract, offline queue, mascot, local integration, API client
swift run                  # run unbundled (notifications and launch-at-login unavailable)
./scripts/bundle.sh        # build "build/DerpMeter.app" (ad-hoc signed, LSUIElement)
open "build/DerpMeter.app"
```

For UI inspection, `build/DerpMeter.app/Contents/MacOS/DerpMeterCompanion --open-panel` opens the actual menu bar popover anchored to its status icon, with real data. Add `--capture-panel /absolute/existing/directory` to render only the app’s own panel and status button into PNG QA artifacts (no desktop capture or screen recording access). Normal launches wait for a click.

## Setup

1. The server must list `menu-bar` in `VOTE_CHANNELS`. Without that, votes are rejected with "channel not enabled".
2. Nothing to configure: derpmeter.com is built in and not shown in the app. (Development only: `defaults write com.derpmeter.companion endpoint <origin>`; `defaults delete com.derpmeter.companion endpoint` restores it.) The first vote gets a Menu Bar token automatically and stores it only in the login Keychain (this device, after first unlock). An expired or revoked token is replaced once, automatically. You can also paste your own `dm_menubar_…` token.

## Features

- Menu bar uses the CLI statusline mood format without a model: `(•‿•) · Derp 20`, `(•_•) · Derp 50`, `(⊙_☉) · Derp 80`. Thresholds match statusline: Smart <35 / green, Meh 35–<65 / yellow, Dumb ≥65 / red. Native adaptive colors match ANSI's semantic colors; exact terminal RGB varies by terminal theme. Red has brighter dark-appearance and darker light-appearance variants, and semibold text improves small-size legibility. Missing data shows `(·_·) · Derp —`. Low sample (<30), cached/offline and paused details remain in the tooltip and panel. The status item reserves a fixed width for the widest face and a three-digit score; left alignment keeps the face anchored when agents or scores change. Identical titles are not redrawn.
- Website-aligned dark panel: approved lavender raster logo, locally bundled Geist typography, provider marks, three visible agent scores, a sentiment scale and independent Smart / Meh / Dumb vote controls. The score is community sentiment, not a capability benchmark. Explicit low-sample and demo labels remain visible. Reason and queue controls expand inline; footer links to the dashboard and settings. The optional mascot setting still shows a small independent meter illustration.
- Model step (02): **Auto** uses the detected model, **No model**, or any current catalog model; the choice is remembered per agent and the cooldown countdown follows it. With "Detect the model" on (off by default) Auto reads each agent's own setting: `model` in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`), `model` in `~/.codex/config.toml`, `model.name` in `~/.gemini/settings.json`. Exact ids win (`[1m]`/date suffixes ignored); Claude aliases (`opus`, `sonnet`, `haiku`, `fable`, `opusplan`) map to the single current catalog model of that family. Without a `model` key the agent uses its account default, which no file records, so pick one. Optional, nested: the live Claude Code session model from the DerpMeter statusline (`derp privacy session on`), which wins when fresh and marks votes session-linked. Antigravity's Claude/GPT models have DerpMeter-only `agy-*` ids, so they are picked manually.
- Keychain reads do not prompt or block startup. An inaccessible existing token is preserved; voting shows an access notice instead of replacing it.
- One-click votes with an optional failure reason. Global shortcuts ⌥⌘1 / ⌥⌘2 / ⌥⌘3 use Carbon hot keys, which need **no Accessibility or Input Monitoring permission**. They are off by default.
- **Offline queue** (max 20 votes, 24h lifetime). It retries with the same body and key, backing off from 30s up to a 1h cap. It stops on 401, 409 and 429 and never retries those automatically. You can inspect and discard pending items. A vote is never sent to an origin other than the one it was queued for, and redirects are refused.
- **Undo last vote** cancels your own vote within 24h. The agent's cooldown still applies.
- **Cooldown countdown**: shows "Next vote in 37 min" for the selected agent (from `GET /api/votes/status`) and disables the buttons until then.
- Index cache in `~/Library/Application Support/DerpMeter/` (0600). Refreshes every 5 minutes. Shows cache age when offline.
- **Active session (explicit local integration, opt-in twice).** With `derp privacy session on` in the CLI and "Use local session observations" here, the app reads only `~/.derpmeter/observed.json` (agent, model, time). It shows the active agent and model, and votes for that agent carry `sessionLinked` plus a catalog-listed model. No process scanning, transcripts, screen access or broad file access.
- Notifications (vote results; Derp Score jump of 10+ points with 30+ votes) and launch at login work in the bundled app only.
- Privacy controls: pause (no network, votes stay queued) and clear local state. Clearing does not delete votes the server already accepted.

## Signing and notarization

Beta 0.1.4 is Developer ID signed, Apple notarized and stapled (2026-10-22). The universal download supports Apple Silicon and Intel. Open normally; no Gatekeeper override is needed.

To reproduce a notarized release, use a valid Developer ID Application identity and an existing notarytool Keychain profile. No credentials belong in the repo:

```sh
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
NOTARY_PROFILE="<existing-keychain-profile>" npm run companion:pack
```

For releases marked `notarized` in `release.json`, packing fails before rebuilding if signing or notarization configuration is absent. The pack script builds universal, signs with hardened runtime, submits to Apple, staples the ticket, verifies Gatekeeper acceptance and only then replaces the downloadable ZIP. A distinct `-notarized.zip` URL avoids stale pre-notarization downloads. Each new binary needs fresh notarization; do not re-sign or alter a stapled bundle.

Local development: `./scripts/bundle.sh` remains ad-hoc signed by default. Hardened runtime is enabled. No additional entitlements are required.

## Uninstall

Quit the app, delete it, then optionally remove `~/Library/Application Support/DerpMeter`, the `com.derpmeter.companion` Keychain item and `defaults delete com.derpmeter.companion`. Ask the operator to revoke the Menu Bar credential.

# Pelmeni Clicker

A mobile-first Telegram Mini App prototype built with plain HTML, CSS, JavaScript, and inline SVG. It has no build step or third-party game libraries.

## Run locally on a Mac

Open `index.html` from Finder or run `open index.html`. Outside Telegram the game uses local browser storage. For multi-device cloud sync, open the HTTPS version inside the Telegram Mini App.

Run the rule tests with `node --test tests/game-rules.test.cjs`.

## Gameplay

- New batches take 10 seconds for the current prototype. Active batches keep their saved start and end timestamps across reloads and devices.
- One batch can cook at a time; buying the Second Pot upgrade unlocks two concurrent batches.
- Collecting a batch gives 10–15 dumplings. Grandma's Recipe and A Bigger Pot improve dumpling rewards.
- The pot can be tapped for dumplings, up to 40 rewarded taps each UTC day.
- Upgrades use dumplings, have bounded levels, and increase in cost by about 1.5x each level.
- Daily login gives 50 dumplings automatically. Starting a batch and buying an upgrade each unlock a claimable daily task worth 100 or 150 dumplings.
- Achievements and the original decoration upgrades remain available. The Tasks tab shows where referral features will appear once supported by the server.
- Dumplings are an in-game value, not cryptocurrency. The old game-points balance converts to dumplings the first time the updated game loads a save.

## Save format and synchronization

The existing fields `balance`, `score`, `points`, `batches`, `startedAt`, `endsAt`, `batchDurationMs`, `upgrades`, `equipped`, `taskDay`, `taskBatches`, `taskClaimedOn`, `taskBalanceRewardVersion`, and `referralCode` remain in the serialized save for compatibility. The retired `points` field is written as zero; `score` is retained as legacy data but no longer displayed or used as currency. Old spendable points convert to dumplings once, recorded by `pointsRetired`. Other fields include active batches, upgrade levels, daily task state, achievements, tap count, and profile dates. Old saves receive defaults during load; an active old batch keeps its original timestamp and duration.

The client still sends raw Telegram `initData` to the configured Edge Function. Local state is not applied until the cloud load has completed. The UI expects the successful load response to have `game_state` containing an object or `null`, based on the supplied API description. The app falls back to local storage on an error and shows a sync status. A public publishable Supabase key is used in the frontend; bot tokens and service-role keys must only be held server-side.

The existing API only exposes whole-state `load` and `save` operations. It does not provide referral registration, invite statistics, atomic game actions, action IDs, state revisions, or server checks for cooking, purchases, tap limits, or task claims. Referral links and rewards therefore remain unavailable; the Tasks screen explains this instead of showing generated demo codes or statistics. Those game mechanics currently run in the browser and can be changed by a player. Cross-device use works by loading and then saving the snapshot, but simultaneous edits or an older device saving later can still overwrite newer cloud progress. This prototype does not claim cheat resistance or transaction-safe rewards.

## Supabase changes

The new game data fits in the existing `player_state.game_state` JSONB field, so no table migration or SQL command is required for this prototype. The current Edge Function source was not present in this project; its internals and successful response format could not be inspected here. Before relying on rewards or purchases, update the existing function to validate Telegram `initData` and perform game actions transactionally, with idempotency keys and server-owned rules. The client integration must then call those verified actions instead of uploading a trusted game balance. Keep secrets in Supabase Function secrets, never in the public files.

## Checks

The built-in rule tests cover the 10-second base time, upgrade price/level limits, reward math, second-pot settings, dumpling tap rewards and tap caps, and one-time task eligibility. Manual checks are still needed inside Telegram for Mini App layout and actual Supabase cross-device sync. To check sync, open the hosted HTTPS Mini App on two devices with the same Telegram account, make an in-game change on the first device, wait for `Cloud sync saved.` in the console, then reopen the app on the second device.

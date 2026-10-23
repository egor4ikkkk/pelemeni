# Pelmeni Clicker

A mobile-first Telegram Mini App prototype built with plain HTML, CSS, JavaScript, and inline SVG. It has no build step or third-party game libraries.

## Run locally on a Mac

Open `index.html` from Finder or run `open index.html`. Outside Telegram the game uses local browser storage. For multi-device cloud sync, open the HTTPS version inside the Telegram Mini App.

Run the rule tests with `node --test tests/game-rules.test.cjs`.

## Gameplay

- New batches take 10 seconds for the current prototype. Active batches keep their saved start and end timestamps across reloads and devices.
- One batch cooks at a time by default. Buying and equipping the Second Pot kitchen decoration unlocks a removable second burner and a second independent cooking slot; it costs 1,000 dumplings.
- Collecting a batch gives 10–15 dumplings. The kitchen shows the updated range after an equipped reward upgrade.
- The pot tap reward and Quick Shaping upgrade have been removed.
- Kitchen upgrades cost one and a half times less than before and retain their bounded levels.
- Daily task rewards are 5 dumplings for a later daily visit, 10 for starting a batch, and 15 for buying an upgrade. A brand-new account starts at zero and receives a welcome achievement instead of a first-visit reward.
- Player levels use the cumulative overall score. The thresholds are 0, 500, 1,000, 1,500, 2,000, 3,000, 4,000, 5,500, 7,500, and 10,000 points. Level-up rewards range from 10 to 50 dumplings in steps of 5.
- Achievements and the original decoration upgrades remain available. The Tasks tab shows where referral features will appear once supported by the server.
- Dumplings are an in-game value, not cryptocurrency. The old game-points balance converts to dumplings the first time the updated game loads a save.

## Save format and synchronization

The existing fields `balance`, `score`, `points`, `batches`, `startedAt`, `endsAt`, `batchDurationMs`, `upgrades`, `equipped`, `taskDay`, `taskBatches`, `taskClaimedOn`, `taskBalanceRewardVersion`, and `referralCode` remain in the serialized save for compatibility. The retired `points` field is written as zero; `score` tracks cumulative earned dumplings for level progression and future rankings, but is not a spendable currency. Old spendable points convert to dumplings once, recorded by `pointsRetired`. Other fields include active batches, upgrade levels, daily task state, achievements, lifetime dumplings earned, level reward claims, and profile dates. Old saves receive defaults during load; an active old batch keeps its original timestamp and duration.

The client still sends raw Telegram `initData` to the configured Edge Function. Local state is not applied until the cloud load has completed. The UI expects the successful load response to have `game_state` containing an object or `null`, based on the supplied API description. The app falls back to local storage on an error and shows a sync status. A public publishable Supabase key is used in the frontend; bot tokens and service-role keys must only be held server-side.

The existing API only exposes whole-state `load` and `save` operations. It does not provide username reservation, referral registration, invite statistics, atomic game actions, action IDs, state revisions, or server checks for cooking, purchases, or task claims. A globally unique locked username and referral attribution/rewards therefore need backend support before they can be safely enabled. The Tasks screen explains that referral tracking is inactive rather than showing generated demo codes or statistics. Those game mechanics currently run in the browser and can be changed by a player. Cross-device use works by loading and then saving the snapshot, but simultaneous edits or an older device saving later can still overwrite newer cloud progress. This prototype does not claim cheat resistance or transaction-safe rewards.

## Supabase changes

The new game data fits in the existing `player_state.game_state` JSONB field, so no table migration or SQL command is required for this prototype. The current Edge Function source was not present in this project; its internals and successful response format could not be inspected here. Before relying on rewards or purchases, update the existing function to validate Telegram `initData` and perform game actions transactionally, with idempotency keys and server-owned rules. The client integration must then call those verified actions instead of uploading a trusted game balance. Keep secrets in Supabase Function secrets, never in the public files.

## Checks

The built-in rule tests cover the 10-second base time, reduced upgrade prices, ten level thresholds and rewards, batch reward ranges, second-pot settings, and one-time task eligibility. Manual checks are still needed inside Telegram for Mini App layout and actual Supabase cross-device sync. To check sync, open the hosted HTTPS Mini App on two devices with the same Telegram account, make an in-game change on the first device, wait for `Cloud sync saved.` in the console, then reopen the app on the second device.

# Pelmeni Clicker

A mobile-first, Telegram Mini App-ready game prototype built with plain HTML, CSS, JavaScript, and inline SVG. It uses no package installs, paid assets, or external font requests.

## Run on a Mac

From this folder, run `open index.html`, or open `index.html` from Finder.

## Prototype features

- 10-second base cooking timer; upgrades can shorten it.
- Collect 10–15 base dumplings per batch, plus bonuses from owned upgrades.
- Kitchen upgrades have gameplay effects: herb pots add 2 dumplings, blue tiles reduce cooking time by 3 seconds, and the carved spoon adds 3 dumplings and saves another 3 seconds.
- Owned upgrades can be equipped or removed for free. Equipped items appear in the SVG kitchen scene and their effects apply to the next batch.
- Previously purchased items stay owned and equipped after this update, so there is no need to buy them again.
- Balance, score, batch count, upgrades, timer, and daily task progress save locally and sync through the configured Supabase Edge Function when valid Telegram `initData` is available.
- Five navigation tabs: Kitchen, Upgrades, Tasks, Leaders, and Profile.
- Daily task reward is 5 dumplings added to the balance and 5 game score after collecting a batch. Players who already claimed today's task before this fix receive the missing 5 dumplings once.
- The Tasks tab generates a referral code and can copy/share an invite message.
- If opened inside Telegram, the app calls Telegram Web App `ready()` and `expand()` when available.

## Telegram integration and trust

The official Telegram Web Apps SDK is loaded in `index.html`; normal browser use still works if Telegram is not present. The app sends the raw `Telegram.WebApp.initData` to the configured Edge Function for load/save requests. The user ID shown in the profile still comes from `initDataUnsafe` and is display/local-storage information only; the frontend does not treat it as verified identity. Cloud state is loaded before the interface becomes interactive. The client expects a successful `load` response shaped as `{ "game_state": object | null }`, based on the supplied table/API description. I could verify that the live function rejects invalid Telegram data, but without valid Mini App `initData` I could not confirm its successful response shape. If the server has no save, the local save is uploaded; if cloud loading fails or returns an unexpected format, the app keeps using local storage and logs the issue. Never put the Telegram bot token or a Supabase secret/service-role key in these client files. The publishable key is public by design.

## Referral and prototype limits

The referral card shares a code, but the current Edge Function integration only syncs game state; it does not verify another player's signup or award referral rewards. Progress and cooking time remain client-controlled, so cloud synchronization does not prevent cheating. Server-authoritative cooking, rewards, purchases, online leaderboards, wallet connections, TVC balances, and token payouts are not implemented. In-game dumplings and points are not cryptocurrency.

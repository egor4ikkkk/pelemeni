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
- Balance, score, batch count, upgrades, timer, and daily task progress save in this browser.
- Five navigation tabs: Kitchen, Upgrades, Tasks, Leaders, and Profile.
- Daily task reward is 5 game points after collecting a batch.
- The Tasks tab generates a referral code and can copy/share an invite message.
- If opened inside Telegram, the app calls Telegram Web App `ready()` and `expand()` when available.

## Telegram integration and trust

The official Telegram Web Apps SDK is loaded in `index.html`; normal browser use still works if Telegram is not present. The client does not use `initDataUnsafe` as authentication. Before multiplayer launch, send `Telegram.WebApp.initData` to a backend and validate it there. Never put the Telegram bot token in these client files.

## Referral and prototype limits

The referral card shares a code, but this local demo cannot verify another player's signup or award referral rewards. That needs an online game server and a Telegram bot link. Progress and cooking time are also stored in this browser, so they can be changed by the player. Telegram login validation, online leaderboards, wallet connections, TVC balances, and token payouts are not implemented. In-game dumplings and points are not cryptocurrency.

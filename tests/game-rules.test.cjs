const test = require('node:test');
const assert = require('node:assert/strict');
const rules = require('../game-rules.js');

function loadAppNormalizer() {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const start = app.indexOf('function normalizeState(saved) {');
  const end = app.indexOf('\n  function loadLocalState()', start);
  assert.ok(start >= 0 && end > start, 'normalizeState source should be present');
  const normalizerSource = app.slice(start, end).trim();
  const createNormalizer = new Function('freshState', 'legacyUpgradeIds', 'safeInt', 'rules', 'DAILY_TASK_IDS', 'ACHIEVEMENT_IDS', 'emptyDailyTasks', 'nowDay', `return (${normalizerSource});`);
  return createNormalizer(
    () => ({}), ['herb-pot', 'blue-tile', 'wooden-spoon', 'second-pot'],
    value => Number.isSafeInteger(value) && value >= 0 ? value : 0,
    rules, ['login', 'cook', 'upgrade', 'collect', 'collect-dumplings', 'collect-two', 'two-pots'],
    ['first-visit','first-start','first-batch','first-upgrade','dumpling-100','dumpling-500','dumpling-thousand','dumpling-5000','dumpling-10000','starts-ten','starts-fifty','five-batches','ten-batches','twenty-five-batches','fifty-batches','upgrade-five','upgrade-ten','second-pot','three-decorations','master-kitchen','both-burners','streak-three','streak-seven','streak-fourteen','streak-thirty','score-1000'],
    () => Object.fromEntries(['login', 'cook', 'upgrade', 'collect', 'collect-dumplings', 'collect-two', 'two-pots'].map(id => [id, { progress: 0, claimed: false }])),
    () => '2026-11-07'
  );
}

function loadAchievementDefinitions(state) {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const marker = 'const achievementDefinitions = ';
  const start = app.indexOf(marker);
  const end = app.indexOf('\n  ];', start) + 5;
  assert.ok(start >= 0 && end > start, 'achievement definitions should be present');
  const definitions = app.slice(start + marker.length, end);
  const totalUpgradeCount = () => Object.values(state.upgradeLevels || {}).reduce((sum, value) => sum + (Number.isSafeInteger(value) && value > 0 ? value : 0), 0) + (state.upgrades || []).length;
  const startedBatchCount = () => (state.batches || 0) + (state.activeBatches || []).length;
  return new Function('state', 'rules', 'totalUpgradeCount', 'startedBatchCount', `return ${definitions};`)(state, rules, totalUpgradeCount, startedBatchCount);
}

function loadDailyTaskSet(state, capacity = () => 1) {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const start = app.indexOf('function dailyTaskSet() {');
  const end = app.indexOf('\n  }\n  function renderAchievements', start) + 4;
  assert.ok(start >= 0 && end > start, 'dailyTaskSet should be present');
  const source = app.slice(start, end);
  const fn = new Function('state', 'rules', 'capacity', `return (${source});`)(state, rules, capacity);
  return fn();
}

function loadIsFirstVisit(state) {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const start = app.indexOf('function isFirstVisit() {');
  const end = app.indexOf('\n  }', start) + 4;
  assert.ok(start >= 0 && end > start, 'isFirstVisit should be present');
  const source = app.slice(start, end);
  const safeInt = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
  const fn = new Function('state', 'safeInt', 'totalUpgradeLevels', `return (${source});`)(state, safeInt, () => Object.values(state.upgradeLevels).reduce((sum, value) => sum + safeInt(value), 0));
  return fn();
}

test('new batches use a twelve-hour base cooking duration', () => {
  assert.equal(rules.cookDuration({}), 12 * 60 * 60 * 1000);
});

test('each stove level reduces cooking by five percent and level ten is exactly six hours', () => {
  assert.deepEqual(Array.from({ length: 11 }, (_, level) => rules.cookDuration({ 'good-stove': level })), [
    43200000, 41040000, 38880000, 36720000, 34560000, 32400000,
    30240000, 28080000, 25920000, 23760000, 21600000
  ]);
  assert.equal(rules.cookDuration({ 'good-stove': 10 }, 10), 6 * 60 * 60 * 1000);
});

test('all ten upgrade levels use the approved prices and exact category totals', () => {
  const expected = {
    'good-stove': [15,25,40,60,90,130,180,250,350,500],
    'large-pot': [75,125,200,300,450,650,900,1200,1550,2000],
    'grandma-recipe': [100,150,250,400,600,900,1250,1750,2300,3000]
  };
  const expectedTotals = { 'good-stove': 1640, 'large-pot': 7450, 'grandma-recipe': 10700 };
  for (const [id, prices] of Object.entries(expected)) {
    const definition = rules.UPGRADE_DEFINITIONS.find(item => item.id === id);
    assert.equal(definition.maxLevel, 10);
    assert.deepEqual(Array.from({ length: definition.maxLevel }, (_, level) => rules.upgradeCost(definition, level)), prices);
    assert.equal(prices.reduce((sum, price) => sum + price, 0), expectedTotals[id]);
  }
  const sql = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'supabase/migrations/20261029000000_server_economy.sql'), 'utf8');
  for (const [id, prices] of Object.entries(expected)) {
    const escapedId = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = sql.match(new RegExp(`WHEN '${escapedId}' THEN \\(ARRAY\\[([^\\]]+)\\]::bigint\\[\\]\\)\\[v_level \\+ 1\\]`));
    assert.ok(match, `${id} should have an explicit server-side price table`);
    assert.deepEqual(match[1].split(',').map(value => Number(value.trim())), prices);
  }
});

test('decoration prices match in the rules, displayed cards, and purchase handler', () => {
  const pot = rules.DECORATION_DEFINITIONS.find(item => item.id === 'second-pot');
  assert.equal(pot.cost, 1500);
  assert.equal(rules.UPGRADE_DEFINITIONS.some(item => item.id === 'second-pot'), false);

  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const displayedPrices = Object.fromEntries([...app.matchAll(/\{ id:'(herb-pot|blue-tile|wooden-spoon)',[^\n]*?cost:(\d+) \}/g)].map(([, id, cost]) => [id, Number(cost)]));
  const purchasePrices = Object.fromEntries([...app.matchAll(/'(herb-pot|blue-tile|wooden-spoon|second-pot)': \['[^']+', ?(\d+)\]/g)].map(([, id, cost]) => [id, Number(cost)]));
  assert.deepEqual(displayedPrices, { 'herb-pot': 100, 'blue-tile': 50, 'wooden-spoon': 200 });
  assert.deepEqual(purchasePrices, { 'herb-pot': 100, 'blue-tile': 50, 'wooden-spoon': 200, 'second-pot': 1500 });
  assert.match(app, /state\.balance < item\[1\]/);
  assert.match(app, /state\.balance -= item\[1\]; state\.upgrades\.push\(id\)/);
  const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase/migrations/20261029000000_server_economy.sql'), 'utf8');
  assert.match(sql, /v_cost := CASE v_id WHEN 'herb-pot' THEN 100 WHEN 'blue-tile' THEN 50 WHEN 'wooden-spoon' THEN 200 WHEN 'second-pot' THEN 1500 ELSE NULL END/);
});

test('ten player levels use the requested cumulative score thresholds', () => {
  assert.equal(rules.playerLevel(0), 1);
  assert.equal(rules.playerLevel(499), 1);
  assert.equal(rules.playerLevel(500), 2);
  assert.equal(rules.playerLevel(1000), 3);
  assert.equal(rules.playerLevel(2000), 5);
  assert.equal(rules.playerLevel(4000), 7);
  assert.equal(rules.playerLevel(5500), 8);
  assert.equal(rules.playerLevel(7500), 9);
  assert.equal(rules.playerLevel(10000), 10);
  assert.equal(rules.levelReward(2), 10);
  assert.equal(rules.levelReward(10), 50);
});

test('daily task and streak login rewards use the specified amounts', () => {
  assert.deepEqual(rules.DAILY_TASK_REWARDS, { cook: 10, upgrade: 15 });
  assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 8].map(rules.streakRewardAmount), [1, 2, 2, 3, 3, 4, 4, 5]);
  assert.equal(rules.streakRewardAmount(17), 9);
  assert.equal(rules.streakRewardAmount(18), 10);
  assert.equal(rules.streakRewardAmount(200), 10);
});

test('upgrade purchase checks use dumplings and reject low balance and maximum levels', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  assert.deepEqual(rules.upgradePurchaseQuote({ balance: 14, upgradeLevels: {} }, stove), { allowed: false, reason: 'insufficient-dumplings', level: 0, cost: 15 });
  assert.deepEqual(rules.upgradePurchaseQuote({ balance: 15, upgradeLevels: {} }, stove), { allowed: true, reason: null, level: 0, cost: 15 });
  assert.equal(rules.upgradePurchaseQuote({ balance: 9999, upgradeLevels: { 'good-stove': 10 } }, stove).reason, 'max-level');
});

test('all existing level upgrades quote, charge, advance, and cap at their configured maximum', () => {
  for (const definition of rules.UPGRADE_DEFINITIONS) {
    const state = { balance: 1_000_000, upgradeLevels: {} };
    for (let level = 0; level < definition.maxLevel; level++) {
      const quote = rules.upgradePurchaseQuote(state, definition);
      assert.equal(quote.allowed, true, `${definition.id} level ${level} should be purchasable`);
      assert.equal(quote.level, level);
      assert.equal(quote.cost, rules.upgradeCost(definition, level));
      const balanceBefore = state.balance;
      state.balance -= quote.cost;
      state.upgradeLevels[definition.id] = quote.level + 1;
      assert.equal(state.balance, balanceBefore - quote.cost);
      assert.ok(state.balance >= 0);
    }
    const maxQuote = rules.upgradePurchaseQuote(state, definition);
    assert.equal(maxQuote.allowed, false);
    assert.equal(maxQuote.reason, 'max-level');
  }
});

test('each level upgrade is unavailable one dumpling below its next price', () => {
  for (const definition of rules.UPGRADE_DEFINITIONS) {
    const cost = rules.upgradeCost(definition, 0);
    const before = { balance: cost - 1, upgradeLevels: {} };
    const quote = rules.upgradePurchaseQuote(before, definition);
    assert.equal(quote.allowed, false, definition.id);
    assert.equal(quote.reason, 'insufficient-dumplings');
    assert.equal(before.balance, cost - 1, 'a rejected quote must not spend dumplings');
    assert.deepEqual(before.upgradeLevels, {});
  }
});

test('purchasing each existing upgrade changes only its configured effect', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  const pot = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'large-pot');
  const recipe = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'grandma-recipe');
  const state = { balance: 100_000, upgradeLevels: {} };
  for (const definition of [stove, pot, recipe]) {
    const quote = rules.upgradePurchaseQuote(state, definition);
    state.balance -= quote.cost;
    state.upgradeLevels[definition.id] = quote.level + 1;
  }
  assert.equal(rules.cookDuration(state.upgradeLevels), 11.4 * 60 * 60 * 1000);
  assert.equal(rules.batchDumplingReward(10, state.upgradeLevels), 12); // +1 pot, then +5% recipe rounded.
  assert.equal(rules.batchDumplingReward(15, state.upgradeLevels), 17);
});

test('upgrade levels survive normalization and remain included in cloud-save serialization', () => {
  const normalizeState = loadAppNormalizer();
  const upgradeLevels = { 'good-stove': 4, 'large-pot': 3, 'grandma-recipe': 2 };
  const restored = normalizeState({ balance: 321, upgradeLevels });
  assert.deepEqual(restored.upgradeLevels, upgradeLevels);
  assert.equal(restored.balance, 321);
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /upgradeLevels: \{ \.\.\.state\.upgradeLevels \}/);
});

test('purchase handler rechecks the current quote before debiting and advances that quoted level', () => {
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  const handler = app.match(/\$\('upgradeList'\)\.addEventListener\('click', event => \{([\s\S]*?)\n  \}\);/)?.[1];
  assert.ok(handler, 'upgrade click handler should exist');
  const quoteIndex = handler.indexOf('rules.upgradePurchaseQuote(state, definition)');
  const debitIndex = handler.indexOf('state.balance -= quote.cost');
  const levelIndex = handler.indexOf('state.upgradeLevels[definition.id] = quote.level + 1');
  assert.ok(quoteIndex >= 0 && quoteIndex < debitIndex && debitIndex < levelIndex);
  assert.match(handler, /if \(!quote\.allowed\)/);
  assert.match(handler, /saveState\(\); render\(\)/);
});

test('the game stays dark-only and uses the standard cooking duration', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  assert.match(app, /document\.body\.dataset\.theme = 'dark'/);
  assert.doesNotMatch(html, /id="themeToggle"/);
  assert.match(app, /const TEST_COOK_DURATION_MS = null/);
});

test('loading hides all game placeholders until the initialized state has rendered', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '..', 'styles.css'), 'utf8');
  assert.match(html, /<div class="loading-screen" id="loadingScreen" role="status"/);
  assert.match(html, /<main class="app-shell" id="appShell"[^>]* hidden>/);
  assert.doesNotMatch(html, /00:10|takes 10 seconds/);
  assert.match(app, /function revealInitializedApp\(\) \{\s*\$\('loadingScreen'\)\.hidden = true;\s*appShell\.hidden = false;/);
  assert.equal((app.match(/revealInitializedApp\(\);/g) || []).length, 2, 'local and cloud/fallback startup reveal only after rendering');
  assert.match(css, /\.loading-screen\{[^}]*var\(--tg-viewport-stable-height,100svh\)/);
});

test('mobile controls have larger tap targets and two-pot countdowns do not use ellipsis', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '..', 'styles.css'), 'utf8');
  assert.match(css, /\.upgrade-button,[\s\S]*?min-height:44px/);
  assert.match(css, /\.task-claim,\.achievement-claim\{min-height:44px/);
  assert.match(css, /\.nav-item\{min-height:44px\}/);
  assert.match(css, /\.cook-actions\.two-pots \.primary-button span:first-child\{[^}]*text-overflow:clip/);
  assert.match(css, /font-variant-numeric:tabular-nums/);
  assert.match(app, /`P\$\{pot\} · \$\{formatTime\(batch\.endsAt - Date\.now\(\)\)\}`/);
  assert.match(css, /\.toast\{[^}]*max-width:calc\(100vw - 24px\);white-space:normal/);
  assert.match(css, /@media\(max-width:380px\)/);
});

test('batch rewards apply kitchen bonuses and decorations without a Second Pot income multiplier', () => {
  assert.equal(rules.batchDumplingReward(10, {}, 0), 10);
  assert.equal(rules.batchDumplingReward(10, { 'grandma-recipe': 2, 'large-pot': 3 }, 5), 19);
  assert.deepEqual(rules.batchDumplingRange({ 'grandma-recipe': 2, 'large-pot': 3 }, 5), { min: 19, max: 25 });
  assert.deepEqual(rules.batchDumplingRange({}), { min: 10, max: 15 });
  assert.equal(rules.batchDumplingReward(15, {}), 15);
});

test('recipe percentage is rounded before adding pot and legacy bonuses', () => {
  // 11 * 1.05 = 11.55 -> 12, then +2 pot and +3 legacy bonus = 17.
  assert.equal(rules.batchDumplingReward(11, { 'grandma-recipe': 1, 'large-pot': 2 }, 3), 17);
  // 15 * 1.10 = 16.5 -> 17, then +10 pot and +5 legacy bonus = 32.
  assert.equal(rules.batchDumplingReward(15, { 'grandma-recipe': 2, 'large-pot': 10 }, 5), 32);
});

test('base batch roll is clamped to the inclusive 10–15 range', () => {
  for (let roll = 0; roll <= 20; roll++) {
    const reward = rules.batchDumplingReward(roll, {});
    assert.ok(reward >= 10 && reward <= 15);
  }
});

test('legacy save fields remain readable by the compatibility normalizer source', () => {
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  for (const field of ['saved.balance', 'saved.score', 'saved.lifetimeDumplings', 'saved.activeBatches', "saved.upgradeLevels?.['second-pot']", 'saved.taskClaimedOn', 'saved.dailyTasks']) {
    assert.ok(app.includes(field), `normalizeState should continue to handle ${field}`);
  }
  assert.ok(app.includes('if (!hasSavedDuration) return { startedAt: batch.startedAt, endsAt: batch.endsAt, durationMs: elapsedDuration };'));
  assert.ok(app.includes('return { startedAt: batch.startedAt, endsAt: batch.endsAt, durationMs: batch.durationMs }'));
  assert.ok(app.includes('activeBatches: state.activeBatches.map(batch => ({ ...batch }))'));
});

test('normalizer preserves a valid ordinary saved batch exactly', () => {
  const normalizeState = loadAppNormalizer();
  const batch = { id: 'ordinary', pot: 1, startedAt: 1000, endsAt: 11000, durationMs: 10000 };
  const restored = normalizeState({ activeBatches: [batch] }).activeBatches[0];
  assert.deepEqual(restored, batch);
});

test('normalizer preserves valid saved batch times longer than twelve hours', () => {
  const normalizeState = loadAppNormalizer();
  const durationMs = 13 * 60 * 60 * 1000;
  const batch = { id: 'long', pot: 1, startedAt: 2000, endsAt: 2000 + durationMs, durationMs };
  assert.deepEqual(normalizeState({ activeBatches: [batch] }).activeBatches[0], batch);
});

test('normalizer does not reconcile valid but mismatched endsAt and durationMs', () => {
  const normalizeState = loadAppNormalizer();
  const batch = { id: 'mismatch', pot: 1, startedAt: 3000, endsAt: 18000, durationMs: 10000 };
  assert.deepEqual(normalizeState({ activeBatches: [batch] }).activeBatches[0], batch);
});

test('legacy batch without durationMs derives it from the saved timestamps', () => {
  const normalizeState = loadAppNormalizer();
  const startedAt = 4000;
  const endsAt = startedAt + 13 * 60 * 60 * 1000;
  assert.deepEqual(normalizeState({ activeBatches: [{ id: 'legacy', pot: 1, startedAt, endsAt }] }).activeBatches[0], {
    id: 'legacy', pot: 1, startedAt, endsAt, durationMs: endsAt - startedAt
  });
});

test('invalid batch data is discarded and malformed duration uses the safe recovery fallback', () => {
  const normalizeState = loadAppNormalizer();
  const invalidTimes = { id: 'bad-time', pot: 1, startedAt: 9000, endsAt: 8000, durationMs: 1000 };
  assert.deepEqual(normalizeState({ activeBatches: [invalidTimes] }).activeBatches, []);

  const startedAt = 5000;
  const endsAt = startedAt + 13 * 60 * 60 * 1000;
  const malformedDuration = { id: 'bad-duration', pot: 1, startedAt, endsAt, durationMs: 1.5 };
  const restored = normalizeState({ activeBatches: [malformedDuration] }).activeBatches[0];
  assert.equal(restored.durationMs, rules.BASE_COOK_MS);
  assert.equal(restored.endsAt, startedAt + rules.BASE_COOK_MS);
});

test('saved batch times remain unchanged with standard cooking restored and two pots restore independently', () => {
  const normalizeState = loadAppNormalizer();
  const first = { id: 'pot-1', pot: 1, startedAt: 10000, endsAt: 25000, durationMs: 15000 };
  const second = { id: 'pot-2', pot: 2, startedAt: 12000, endsAt: 42000, durationMs: 30000 };
  const restored = normalizeState({ upgrades: ['second-pot'], equipped: ['second-pot'], activeBatches: [first, second] }).activeBatches;
  assert.deepEqual(restored, [first, second]);
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /const TEST_COOK_DURATION_MS = null/);
  assert.match(app, /const durationMs = cookDurationMs\(\);[\s\S]*?state\.activeBatches\.push\(\{ id, pot, startedAt, endsAt: startedAt \+ durationMs, durationMs \}\)/);
});

test('daily task reward is claimable once after its progress is complete', () => {
  const task = { progress: 1, claimed: false };
  assert.equal(rules.taskClaimAllowed(task), true);
  assert.equal(rules.taskClaimAllowed({ progress: 29, goal: 30, claimed: false }), false);
  assert.equal(rules.taskClaimAllowed({ progress: 30, goal: 30, claimed: false }), true);
  task.claimed = true;
  assert.equal(rules.taskClaimAllowed(task), false);
  assert.equal(rules.taskClaimAllowed({ progress: 0, claimed: false }), false);
});

test('daily task variants rotate deterministically by UTC date without changing reward values', () => {
  const days = ['2026-11-06', '2026-11-07', '2026-11-08'];
  const variants = days.map(rules.dailyTaskVariantForDate);
  assert.equal(new Set(variants).size, 3);
  assert.deepEqual(days.map(rules.dailyTaskVariantForDate), variants);
  assert.equal(rules.dailyTaskVariantForDate('2026-02-30'), null);
  assert.deepEqual(rules.DAILY_TASK_REWARDS, { cook: 10, upgrade: 15 });
  assert.deepEqual(rules.DAILY_TASK_VARIANTS.classic, { cookGoal: 1, collectMode: 'collect', collectGoal: 1, dumplingMode: 'amount', dumplingGoal: 30 });
});

test('daily task progress variants use existing starts, collections, and collected-batch counts', () => {
  const dailyTasks = {
    cook: { progress: 2 }, collect: { progress: 1 }, 'collect-dumplings': { progress: 24 }, 'collect-two': { progress: 2 }
  };
  assert.equal(rules.dailyTaskProgress('cook', 'batch-focus', dailyTasks), 2);
  assert.equal(rules.dailyTaskProgress('collect', 'classic', dailyTasks), 1);
  assert.equal(rules.dailyTaskProgress('collect', 'kitchen-rhythm', dailyTasks), 1);
  assert.equal(rules.dailyTaskProgress('collect-dumplings', 'classic', dailyTasks), 24);
  assert.equal(rules.dailyTaskProgress('collect-dumplings', 'kitchen-rhythm', dailyTasks), 2);
  assert.equal(rules.taskClaimAllowed({ progress: rules.dailyTaskProgress('collect-dumplings', 'kitchen-rhythm', dailyTasks), goal: rules.dailyTaskVariant('kitchen-rhythm').dumplingGoal }), true);
});

test('daily task compatibility keeps old current-day tasks classic and persists new variant progress', () => {
  const normalizeState = loadAppNormalizer();
  const legacy = normalizeState({ dailyDate: '2026-11-07', dailyTasks: { cook: { progress: 1, claimed: false } } });
  assert.equal(legacy.dailyTaskVariant, 'classic');
  assert.deepEqual(legacy.dailyTasks['collect-two'], { progress: 0, claimed: false });
  const modern = normalizeState({ dailyDate: '2026-11-07', dailyTaskVariant: 'kitchen-rhythm', dailyTasks: { 'collect-two': { progress: 2, claimed: true } } });
  assert.equal(modern.dailyTaskVariant, 'kitchen-rhythm');
  assert.deepEqual(modern.dailyTasks['collect-two'], { progress: 2, claimed: true });
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /dailyTasks: JSON\.parse\(JSON\.stringify\(state\.dailyTasks\)\), dailyTaskVariant: state\.dailyTaskVariant/);
});

test('daily task actions advance quest progress immediately and claims use the selected daily goal once', () => {
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /markTaskProgress\('cook'\)/);
  assert.match(app, /markTaskProgress\('collect'\)/);
  assert.match(app, /markTaskProgress\('collect-dumplings', reward\)/);
  assert.match(app, /markTaskProgress\('collect-two'\)/);
  assert.match(app, /markTaskProgress\('upgrade'\)/);
  assert.match(app, /dailyTaskSet\(\)\.find\(item => item\.id === id\)/);
  assert.match(app, /state\.dailyDate !== nowDay\(\) \|\| !task \|\| !dailyDefinition/);
  assert.match(app, /task\.claimed = true; addDumplings\(dailyDefinition\.reward\)/);
  assert.match(app, /state\.dailyTasks = emptyDailyTasks\(\);\s*state\.dailyTaskVariant = rules\.dailyTaskVariantForDate\(today\)/);
});

test('streak starts on first visit and does not grow on a second visit the same UTC day', () => {
  assert.deepEqual(rules.advanceStreak(0, 0, null, '2026-10-23'), { current: 1, best: 1, lastVisit: '2026-10-23', changed: true });
  assert.deepEqual(rules.advanceStreak(1, 1, '2026-10-23', '2026-10-23'), { current: 1, best: 1, lastVisit: '2026-10-23', changed: false });
});

test('streak increments on the next UTC day and resets after a skipped day while keeping best', () => {
  assert.deepEqual(rules.advanceStreak(4, 4, '2026-10-23', '2026-10-24'), { current: 5, best: 5, lastVisit: '2026-10-24', changed: true });
  assert.deepEqual(rules.advanceStreak(5, 8, '2026-10-23', '2026-10-25'), { current: 1, best: 8, lastVisit: '2026-10-25', changed: true });
});

test('streak login reward follows each daily visit and restarts at one after a missed day', () => {
  const visits = [
    ['2026-11-13', 1], ['2026-11-14', 2], ['2026-11-15', 3], ['2026-11-16', 4]
  ];
  let current = 0;
  let best = 0;
  let lastVisit = null;
  for (const [day, expectedDay] of visits) {
    const next = rules.advanceStreak(current, best, lastVisit, day);
    current = next.current;
    best = next.best;
    lastVisit = next.lastVisit;
    assert.equal(current, expectedDay);
    assert.equal(rules.streakRewardAmount(current), [1, 2, 2, 3][expectedDay - 1]);
  }
  const afterGap = rules.advanceStreak(current, best, lastVisit, '2026-11-18');
  assert.equal(afterGap.current, 1);
  assert.equal(afterGap.best, 4);
  assert.equal(rules.streakRewardAmount(afterGap.current), 1);
});

test('invalid or backwards UTC dates cannot increase a streak', () => {
  assert.equal(rules.validUtcDay('2026-02-30'), false);
  assert.deepEqual(rules.advanceStreak(5, 8, '2026-10-24', '2026-10-23'), { current: 5, best: 8, lastVisit: '2026-10-24', changed: false });
});

test('streak reward must be claimed once and the next UTC day has a separate claim', () => {
  const today = '2026-11-13';
  const state = { dailyDate: today, streakLastVisitDate: today, streakCurrent: 1, streakRewardClaims: [] };
  const firstClaim = rules.prepareStreakRewardClaim(state, today);
  assert.equal(firstClaim.amount, 1);
  assert.equal(firstClaim.loginRewardDate, today);
  assert.ok(firstClaim.streakRewardClaims.includes(rules.streakClaimKey(today)));
  assert.equal(rules.prepareStreakRewardClaim({ ...state, streakRewardClaims: firstClaim.streakRewardClaims }, today), null);
  assert.equal(rules.prepareStreakRewardClaim(state, '2026-11-14'), null);

  const nextDay = '2026-11-14';
  const nextDayState = { dailyDate: nextDay, streakLastVisitDate: nextDay, streakCurrent: 2, streakRewardClaims: firstClaim.streakRewardClaims };
  assert.equal(rules.prepareStreakRewardClaim(nextDayState, nextDay).amount, 2);
});

test('legacy automatic login rewards migrate as claimed without blocking a new pending visit', () => {
  const today = '2026-11-13';
  const legacyPaid = rules.normalizeStreakRewardClaims([], today, false, today);
  assert.ok(legacyPaid.includes(rules.streakClaimKey(today)));
  assert.equal(rules.canClaimStreakReward(today, legacyPaid, today), false);

  const legacyFirstVisitNoReward = rules.normalizeStreakRewardClaims([], today, true, today);
  assert.equal(rules.canClaimStreakReward(today, legacyFirstVisitNoReward, today), true);

  const newVisitPending = rules.recordStreakVisit([], today);
  const normalizedPending = rules.normalizeStreakRewardClaims(newVisitPending, today, false, today);
  assert.equal(rules.canClaimStreakReward(today, normalizedPending, today), true);
  assert.deepEqual(rules.recordStreakVisit(newVisitPending, today), newVisitPending);
});

test('app records a daily visit without crediting the streak reward until the claim action', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const visitBody = app.match(/function applyDailyState\(\) \{([\s\S]*?)\n  \}/)?.[1];
  assert.ok(visitBody, 'applyDailyState should exist');
  assert.match(visitBody, /advanceStreak/);
  assert.match(visitBody, /recordStreakVisit/);
  assert.doesNotMatch(visitBody, /addDumplings/);
  assert.match(app, /function claimStreakReward\(\)/);
  assert.match(app, /prepareStreakRewardClaim\(state, today\)/);
  assert.match(app, /addDumplings\(claim\.amount\)/);
  assert.match(app, /streakRewardClaims: \[\.\.\.state\.streakRewardClaims\]/);
});

test('streak countdown targets the next UTC midnight and formats HH:MM', () => {
  assert.equal(rules.utcMidnightCountdown(Date.parse('2026-11-13T22:30:00.000Z')), '01:30');
  assert.equal(rules.utcMidnightCountdown(Date.parse('2026-11-13T23:59:30.000Z')), '00:01');
  assert.equal(rules.utcMidnightCountdown(Date.parse('2026-11-13T00:00:00.000Z')), '24:00');
});

test('legacy streak saves infer the beginning of the active run from its length', () => {
  assert.equal(rules.inferStreakStartDate(5, '2026-10-24'), '2026-10-20');
  assert.equal(rules.inferStreakStartDate(0, '2026-10-24'), null);
  assert.equal(rules.inferStreakStartDate(5, 'invalid'), null);
});

test('new batches use the standard formula while restored batches preserve their saved times', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /const TEST_COOK_DURATION_MS = null/);
  assert.match(app, /return TEST_COOK_DURATION_MS \?\? rules\.cookDuration\(state\.upgradeLevels, legacySecondsOff\(\)\)/);
  assert.match(app, /function legacySecondsOff\(\) \{ return \(state\.equipped\.includes\('blue-tile'\) \? 3 : 0\) \+ \(state\.equipped\.includes\('wooden-spoon'\) \? 3 : 0\); \}/);
  assert.match(app, /function startBatch\(pot = 1\)[\s\S]*?const durationMs = cookDurationMs\(\);[\s\S]*?endsAt: startedAt \+ durationMs/);
  assert.match(app, /const restoreBatchTimes = batch => \{[\s\S]*?if \(Number\.isSafeInteger\(batch\.durationMs\) && batch\.durationMs > 0\)[\s\S]*?endsAt: batch\.endsAt, durationMs: batch\.durationMs/);
  assert.match(rules.cookDuration.toString(), /BASE_COOK_MS \* \(1 - reduction\)/);
  // The current game-rules implementation accepts this legacy argument but does not apply it.
  assert.equal(rules.cookDuration({}, 6), 12 * 60 * 60 * 1000);
});

test('pot visuals map empty, cooking, and ready states independently and collecting stays one-shot', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '..', 'styles.css'), 'utf8');
  assert.match(app, /visualState = isCooking \? 'cooking' : isReady \? 'ready' : 'empty'/);
  assert.match(app, /potArt\.classList\.toggle\('burner-on', isCooking\)/);
  assert.match(app, /steam\.style\.display = isCooking \|\| isReady \? 'inline' : 'none'/);
  assert.match(css, /pot-one-cooking \.main-pot \.steam-stream/);
  assert.match(css, /pot-one-ready \.main-pot \.dumplings/);
  const collectBody = app.match(/function collectBatch\(id\) \{([\s\S]*?)\n  \}/)?.[1];
  assert.ok(collectBody);
  assert.ok(collectBody.indexOf('if (!batch || Date.now() < batch.endsAt) return false;') < collectBody.indexOf('playDumplingCollection(batch.pot)'));
  assert.match(collectBody, /state\.activeBatches = state\.activeBatches\.filter\(item => item\.id !== id\)/);
  assert.match(app, /function playDumplingCollection\(pot\)/);
});

test('the approved achievement list contains 25 milestones with exactly 560 dumplings in rewards', () => {
  const definitions = loadAchievementDefinitions({
    achievements: [], achievementClaims: [], batches: 0, activeBatches: [], lifetimeDumplings: 0,
    upgradeLevels: {}, upgrades: [], streakBest: 0, potCollections: { 1: 0, 2: 0 }
  });
  assert.equal(definitions.length, 25);
  assert.deepEqual(definitions.map(item => item.id), [
    'first-visit', 'first-start', 'first-batch', 'first-upgrade',
    'dumpling-100', 'dumpling-500', 'dumpling-thousand', 'dumpling-5000', 'dumpling-10000',
    'starts-ten', 'starts-fifty', 'five-batches', 'ten-batches', 'twenty-five-batches', 'fifty-batches',
    'upgrade-five', 'upgrade-ten', 'second-pot', 'three-decorations', 'master-kitchen', 'both-burners',
    'streak-three', 'streak-seven', 'streak-fourteen', 'streak-thirty'
  ]);
  assert.deepEqual([4, 5, 6, 6, 4].map((count, index) => definitions.slice([0, 4, 9, 15, 21][index], [4, 9, 15, 21, 25][index]).length), [4, 5, 6, 6, 4]);
  assert.equal(definitions.reduce((sum, item) => sum + item.reward, 0), 560);
});

test('each achievement condition opens from the approved existing game statistics', () => {
  const defaults = () => ({ achievements: [], achievementClaims: [], batches: 0, activeBatches: [], lifetimeDumplings: 0, upgradeLevels: {}, upgrades: [], streakBest: 0, potCollections: { 1: 0, 2: 0 } });
  const cases = {
    'first-visit': state => { state.achievements = ['first-visit']; },
    'first-start': state => { state.activeBatches = [{ id: 'active' }]; },
    'first-batch': state => { state.batches = 1; },
    'first-upgrade': state => { state.upgradeLevels['good-stove'] = 1; },
    'dumpling-100': state => { state.lifetimeDumplings = 100; },
    'dumpling-500': state => { state.lifetimeDumplings = 500; },
    'dumpling-thousand': state => { state.lifetimeDumplings = 1000; },
    'dumpling-5000': state => { state.lifetimeDumplings = 5000; },
    'dumpling-10000': state => { state.lifetimeDumplings = 10000; },
    'starts-ten': state => { state.batches = 10; },
    'starts-fifty': state => { state.batches = 49; state.activeBatches = [{ id: 'active' }]; },
    'five-batches': state => { state.batches = 5; },
    'ten-batches': state => { state.batches = 10; },
    'twenty-five-batches': state => { state.batches = 25; },
    'fifty-batches': state => { state.batches = 50; },
    'upgrade-five': state => { state.upgradeLevels['good-stove'] = 5; },
    'upgrade-ten': state => { state.upgradeLevels['good-stove'] = 10; },
    'second-pot': state => { state.upgrades = ['second-pot']; },
    'three-decorations': state => { state.upgrades = ['herb-pot', 'blue-tile', 'wooden-spoon']; },
    'master-kitchen': state => { state.upgradeLevels['good-stove'] = 10; },
    'both-burners': state => { state.potCollections = { 1: 1, 2: 1 }; },
    'streak-three': state => { state.streakBest = 3; },
    'streak-seven': state => { state.streakBest = 7; },
    'streak-fourteen': state => { state.streakBest = 14; },
    'streak-thirty': state => { state.streakBest = 30; }
  };
  assert.equal(Object.keys(cases).length, 25);
  for (const [id, prepare] of Object.entries(cases)) {
    const state = defaults();
    const before = loadAchievementDefinitions(state).find(item => item.id === id);
    assert.equal(before.achieved(), false, `${id} should start locked`);
    prepare(state);
    const after = loadAchievementDefinitions(state).find(item => item.id === id);
    assert.ok(after, `${id} should have a definition`);
    assert.equal(after.achieved(), true, `${id} should open at its goal`);
  }
});

test('achievement claims normalize old saves, preserve unlocked IDs, and remain one-shot without lifetime credit', () => {
  const normalizeState = loadAppNormalizer();
  const legacy = normalizeState({ achievements: ['first-batch', 'streak-seven', 'score-1000'] });
  assert.deepEqual(legacy.achievements, ['first-batch', 'streak-seven', 'score-1000']);
  assert.deepEqual(legacy.achievementClaims, []);
  const restored = normalizeState({ achievements: ['first-batch'], achievementClaims: ['first-batch', 'unknown', 'first-batch'] });
  assert.deepEqual(restored.achievementClaims, ['first-batch']);

  const state = { achievements: ['first-batch'], achievementClaims: [], balance: 0, score: 0, lifetimeDumplings: 25 };
  const definition = { id: 'first-batch', reward: 10 };
  const claim = rules.prepareAchievementClaim(state, definition);
  assert.deepEqual(claim, { achievementClaims: ['first-batch'], amount: 10 });
  state.achievementClaims = claim.achievementClaims;
  state.balance += claim.amount;
  state.score += claim.amount;
  assert.equal(rules.prepareAchievementClaim(state, definition), null);
  assert.equal(rules.prepareAchievementClaim({ ...state, achievementClaims: [] }, { ...definition, id: 'locked' }), null);
  assert.equal(state.balance, 10);
  assert.equal(state.lifetimeDumplings, 25);

  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /achievementClaims: \[\.\.\.state\.achievementClaims\]/);
  assert.match(app, /addDumplings\(claim\.amount, false\)/);
  assert.match(app, /achievementList'\)\.addEventListener\('click'/);
});

test('starting a batch refreshes achievement unlocks using collected plus active batch count', () => {
  const app = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'app.js'), 'utf8');
  assert.match(app, /function startedBatchCount\(\) \{ return state\.batches \+ state\.activeBatches\.length; \}/);
  const start = app.match(/function startBatch\(pot = 1\) \{([\s\S]*?)\n  \}/)?.[1];
  assert.ok(start);
  assert.ok(start.indexOf('state.activeBatches.push') < start.indexOf('ensureAchievements()'), 'start must be counted before checking achievements');
  assert.match(start, /const unlocked = ensureAchievements\(\)/);
});

test('profile statistics read existing save fields and achievements remain grouped 4/5/6/6/4', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const app = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '..', 'styles.css'), 'utf8');
  assert.match(app, /\$\('profileLifetimeDumplings'\)\.textContent = state\.lifetimeDumplings/);
  assert.match(app, /\$\('profileStartedBatches'\)\.textContent = startedBatchCount\(\)/);
  assert.match(app, /\$\('profileCurrentStreak'\)\.textContent = state\.streakCurrent/);
  assert.match(app, /\$\('profileBestStreak'\)\.textContent = state\.streakBest/);
  assert.match(app, /\$\('profileStoveLevel'\)\.textContent = state\.upgradeLevels\['good-stove'\]/);
  assert.match(app, /\$\('profileAchievementsCount'\).*achievementDefinitions\.filter/);
  assert.match(app, /\$\('profileAchievementClaimsCount'\).*achievementDefinitions\.filter/);
  assert.match(app, /function completedDailyTaskCount\(\) \{ return rules\.completedDailyTaskCount\(dailyTaskSet\(\), state\.dailyDate === nowDay\(\)\); \}/);
  assert.match(app, /\$\('profileDailyTasksCompleted'\)\.textContent = completedDailyTaskCount\(\)/);
  assert.match(html, /id="profileBatches"/);
  for (const id of ['profileBalance','profileLifetimeDumplings','profileStartedBatches','profileBatches','profileCurrentStreak','profileBestStreak','profileDailyTasksCompleted','profileStoveLevel','profilePotLevel','profileRecipeLevel','profileAchievementsCount','profileAchievementClaimsCount']) assert.ok(html.includes(`id="${id}"`), `${id} should be rendered in the profile`);
  const start = app.indexOf('const achievementGroups = ');
  const end = app.indexOf('\n  ];', start) + 5;
  const groups = new Function(`return ${app.slice(start + 'const achievementGroups = '.length, end)};`)();
  assert.deepEqual(groups.map(group => group.ids.length), [4, 5, 6, 6, 4]);
  assert.equal(new Set(groups.flatMap(group => group.ids)).size, 25);
  assert.match(css, /\.profile-detail-grid\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css, /@media\(max-width:380px\)/);
});

test('completed daily task profile count is zero for empty or stale saves and counts finished current tasks only', () => {
  assert.equal(rules.completedDailyTaskCount([], true), 0);
  assert.equal(rules.completedDailyTaskCount([
    { id: 'login', progress: 1, goal: 1 },
    { id: 'cook', progress: 1, goal: 1 },
    { id: 'upgrade', progress: 0, goal: 1 },
    { id: 'collect', progress: 2, goal: 2 }
  ], true), 2);
  assert.equal(rules.completedDailyTaskCount([
    { id: 'cook', progress: 1, goal: 1 }, { id: 'bad', progress: 1, goal: 0 }
  ], false), 0);

  const normalizeState = loadAppNormalizer();
  const oldEmpty = normalizeState({ dailyDate: '2026-11-07' });
  assert.deepEqual(oldEmpty.dailyTasks.cook, { progress: 0, claimed: false });
  const oldProgress = normalizeState({ dailyDate: '2026-11-07', dailyTasks: { cook: { progress: 1, claimed: false }, upgrade: { progress: 0, claimed: false } } });
  assert.deepEqual(oldProgress.dailyTasks.cook, { progress: 1, claimed: false });
  assert.deepEqual(oldProgress.dailyTasks.upgrade, { progress: 0, claimed: false });
  assert.equal(rules.completedDailyTaskCount([
    { id: 'cook', progress: oldProgress.dailyTasks.cook.progress, goal: 1 },
    { id: 'upgrade', progress: oldProgress.dailyTasks.upgrade.progress, goal: 1 }
  ], oldProgress.dailyDate === '2026-11-07'), 1);
});

test('the two-pot daily task stays visible and claimable after removing the second burner', () => {
  const dailyTasks = Object.fromEntries(['login', 'cook', 'upgrade', 'collect', 'collect-dumplings', 'collect-two', 'two-pots'].map(id => [id, { progress: 0, claimed: false }]));
  const state = { dailyTaskVariant: 'classic', dailyTasks };
  assert.equal(loadDailyTaskSet(state, () => 1).some(task => task.id === 'two-pots'), false, 'do not show the task to a player without the second burner');

  state.dailyTasks['two-pots'].progress = 1;
  const completed = loadDailyTaskSet(state, () => 1).find(task => task.id === 'two-pots');
  assert.ok(completed, 'keep the completed task visible even after unequipping the second pot');
  assert.equal(completed.progress, 1);
  assert.equal(completed.claimed, false, 'leave its reward available to claim');

  state.dailyTasks['two-pots'].claimed = true;
  assert.equal(loadDailyTaskSet(state, () => 1).find(task => task.id === 'two-pots').claimed, true);
});

test('legacy visit markers prevent an old profile from being classified as a first visit', () => {
  const base = {
    joinedAt: null, balance: 0, score: 0, lifetimeDumplings: 0, batches: 0, activeBatches: [], upgrades: [], upgradeLevels: {},
    streakCurrent: 0, streakBest: 0, streakLastVisitDate: null, loginRewardDate: null, streakRewardClaims: [], taskBatches: 0,
    taskClaimedOn: null, taskPotsUsed: [], potCollections: { 1: 0, 2: 0 }, levelClaims: [], achievements: [], lastBatchAt: null,
    referralCode: null, dailyTasks: { login: { progress: 0, claimed: false } }
  };
  assert.equal(loadIsFirstVisit(base), true);
  const oldVisitCases = [
    { streakLastVisitDate: '2026-11-07' },
    { loginRewardDate: '2026-11-07' },
    { dailyTasks: { login: { progress: 1, claimed: true } } },
    { taskClaimedOn: '2026-11-07' },
    { streakBest: 3 },
    { joinedAt: '2026-11-01T00:00:00.000Z' }
  ];
  for (const marker of oldVisitCases) assert.equal(loadIsFirstVisit({ ...base, ...marker }), false);
});

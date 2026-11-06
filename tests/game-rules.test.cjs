const test = require('node:test');
const assert = require('node:assert/strict');
const rules = require('../game-rules.js');

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

test('stove levels use the specified exact prices without the legacy multiplier', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  assert.deepEqual(Array.from({ length: 10 }, (_, level) => rules.upgradeCost(stove, level)), [15,20,30,40,55,70,90,115,145,180]);
  assert.equal(stove.maxLevel, 10);
});

test('Second Pot is a removable decoration priced at 1000 dumplings', () => {
  const pot = rules.DECORATION_DEFINITIONS.find(item => item.id === 'second-pot');
  assert.equal(pot.cost, 1000);
  assert.equal(rules.UPGRADE_DEFINITIONS.some(item => item.id === 'second-pot'), false);
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
  assert.ok(app.includes('const savedDuration = safeInt(batch.durationMs) || batch.endsAt - batch.startedAt;'));
  assert.ok(app.includes('endsAt: batch.startedAt + durationMs'));
  assert.ok(app.includes('activeBatches: state.activeBatches.map(batch => ({ ...batch }))'));
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

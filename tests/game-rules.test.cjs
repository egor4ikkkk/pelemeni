const test = require('node:test');
const assert = require('node:assert/strict');
const rules = require('../game-rules.js');

test('new batches use a ten-second base cooking duration', () => {
  assert.equal(rules.cookDuration({}), 10_000);
});

test('stove levels reduce the next batch by five percent, with a four-second minimum duration', () => {
  assert.equal(rules.cookDuration({ 'good-stove': 1 }), 9_500);
  assert.equal(rules.cookDuration({ 'good-stove': 10 }), 5_000);
  assert.equal(rules.cookDuration({ 'good-stove': 10 }, 10), 4_000);
});

test('Kitchen upgrade costs are 1.5 times lower and still increase by level', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  assert.equal(rules.upgradeCost(stove, 0), 67);
  assert.equal(rules.upgradeCost(stove, 1), 100);
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

test('daily tasks use the requested dumpling rewards', () => {
  assert.deepEqual(rules.DAILY_TASK_REWARDS, { login: 5, cook: 10, upgrade: 15 });
});

test('upgrade purchase checks use dumplings and reject low balance and maximum levels', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  assert.deepEqual(rules.upgradePurchaseQuote({ balance: 66, upgradeLevels: {} }, stove), { allowed: false, reason: 'insufficient-dumplings', level: 0, cost: 67 });
  assert.deepEqual(rules.upgradePurchaseQuote({ balance: 67, upgradeLevels: {} }, stove), { allowed: true, reason: null, level: 0, cost: 67 });
  assert.equal(rules.upgradePurchaseQuote({ balance: 9999, upgradeLevels: { 'good-stove': 10 } }, stove).reason, 'max-level');
});

test('batch rewards apply kitchen bonuses and decorations without a Second Pot income multiplier', () => {
  assert.equal(rules.batchDumplingReward(10, {}, 0), 10);
  assert.equal(rules.batchDumplingReward(10, { 'grandma-recipe': 2, 'large-pot': 3 }, 5), 19);
  assert.deepEqual(rules.batchDumplingRange({ 'grandma-recipe': 2, 'large-pot': 3 }, 5), { min: 19, max: 25 });
  assert.deepEqual(rules.batchDumplingRange({}), { min: 10, max: 15 });
  assert.equal(rules.batchDumplingReward(15, {}), 15);
});

test('daily task reward is claimable once after its progress is complete', () => {
  const task = { progress: 1, claimed: false };
  assert.equal(rules.taskClaimAllowed(task), true);
  task.claimed = true;
  assert.equal(rules.taskClaimAllowed(task), false);
  assert.equal(rules.taskClaimAllowed({ progress: 0, claimed: false }), false);
});

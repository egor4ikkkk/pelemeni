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

test('upgrade costs grow by about 1.5 and stop at the configured maximum level', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  assert.equal(rules.upgradeCost(stove, 0), 100);
  assert.equal(rules.upgradeCost(stove, 1), 150);
  assert.equal(stove.maxLevel, 10);
});

test('large pot unlock is the only upgrade that increases capacity', () => {
  const pot = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'second-pot');
  assert.equal(pot.baseCost, 1000);
  assert.equal(pot.maxLevel, 1);
});

test('tapping earns dumplings with the original daily tap cap', () => {
  assert.equal(rules.tapDumplings({}), 1);
  assert.equal(rules.tapDumplings({ 'fast-shaping': 5 }), 6);
  assert.equal(rules.MAX_TAPS_PER_DAY, 40);
});

test('upgrade purchase checks use dumplings and reject low balance and maximum levels', () => {
  const stove = rules.UPGRADE_DEFINITIONS.find(item => item.id === 'good-stove');
  assert.deepEqual(rules.upgradePurchaseQuote({ balance: 99, upgradeLevels: {} }, stove), { allowed: false, reason: 'insufficient-dumplings', level: 0, cost: 100 });
  assert.deepEqual(rules.upgradePurchaseQuote({ balance: 100, upgradeLevels: {} }, stove), { allowed: true, reason: null, level: 0, cost: 100 });
  assert.equal(rules.upgradePurchaseQuote({ balance: 9999, upgradeLevels: { 'good-stove': 10 } }, stove).reason, 'max-level');
});

test('batch rewards apply recipe, pot size, and previously owned decoration bonuses', () => {
  assert.equal(rules.batchDumplingReward(10, {}, 0), 10);
  assert.equal(rules.batchDumplingReward(10, { 'grandma-recipe': 2, 'large-pot': 3 }, 5), 19);
});

test('daily task reward is claimable once after its progress is complete', () => {
  const task = { progress: 1, claimed: false };
  assert.equal(rules.taskClaimAllowed(task), true);
  task.claimed = true;
  assert.equal(rules.taskClaimAllowed(task), false);
  assert.equal(rules.taskClaimAllowed({ progress: 0, claimed: false }), false);
});

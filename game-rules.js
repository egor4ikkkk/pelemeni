((root) => {
  const BASE_COOK_MS = 10 * 1000;
  const MAX_TAPS_PER_DAY = 40;
  const UPGRADE_DEFINITIONS = [
    { id: 'good-stove', name: 'A Better Stove', description: 'Cook each batch 5% faster per level.', baseCost: 100, maxLevel: 10, effect: level => `${level * 5}% faster` },
    { id: 'large-pot', name: 'A Bigger Pot', description: 'Add one dumpling to every batch per level.', baseCost: 150, maxLevel: 10, effect: level => `+${level} dumplings / batch` },
    { id: 'grandma-recipe', name: "Grandma's Recipe", description: 'Increase the base batch reward by 5% per level.', baseCost: 200, maxLevel: 10, effect: level => `+${level * 5}% batch reward` },
    { id: 'fast-shaping', name: 'Quick Shaping', description: 'Earn extra dumplings when tapping the pot.', baseCost: 100, maxLevel: 5, effect: level => `+${level} dumpling per tap` },
    { id: 'second-pot', name: 'Second Pot', description: 'Cook two batches at the same time.', baseCost: 1000, maxLevel: 1, effect: level => level ? '2 active batches' : '1 active batch' }
  ];

  function upgradeCost(definition, currentLevel) {
    return Math.round(definition.baseCost * Math.pow(1.5, currentLevel));
  }
  function kitchenLevel(levels) {
    const total = Object.values(levels || {}).reduce((sum, level) => sum + (Number.isSafeInteger(level) && level > 0 ? level : 0), 0);
    return 1 + Math.floor(total / 2);
  }
  function cookDuration(levels, legacySecondsOff = 0) {
    const stoveLevel = Math.max(0, Math.min(10, Number.isSafeInteger(levels?.['good-stove']) ? levels['good-stove'] : 0));
    const reduction = Math.min(0.5, stoveLevel * 0.05);
    return Math.max(4 * 1000, Math.round(BASE_COOK_MS * (1 - reduction)) - Math.max(0, legacySecondsOff) * 1000);
  }
  function tapDumplings(levels) {
    const level = Math.max(0, Math.min(5, Number.isSafeInteger(levels?.['fast-shaping']) ? levels['fast-shaping'] : 0));
    return 1 + level;
  }
  function upgradePurchaseQuote(state, definition) {
    const level = Math.max(0, Math.min(definition.maxLevel, Number.isSafeInteger(state?.upgradeLevels?.[definition.id]) ? state.upgradeLevels[definition.id] : 0));
    if (level >= definition.maxLevel) return { allowed: false, reason: 'max-level', level, cost: null };
    const cost = upgradeCost(definition, level);
    if (!Number.isSafeInteger(state?.balance) || state.balance < cost) return { allowed: false, reason: 'insufficient-dumplings', level, cost };
    return { allowed: true, reason: null, level, cost };
  }
  function batchDumplingReward(baseRoll, levels, legacyBonus = 0) {
    const base = Math.max(10, Math.min(15, Math.trunc(baseRoll)));
    const recipeLevel = Math.max(0, Math.min(10, Number.isSafeInteger(levels?.['grandma-recipe']) ? levels['grandma-recipe'] : 0));
    const potLevel = Math.max(0, Math.min(10, Number.isSafeInteger(levels?.['large-pot']) ? levels['large-pot'] : 0));
    return Math.round(base * (1 + recipeLevel * 0.05)) + potLevel + Math.max(0, Math.trunc(legacyBonus));
  }
  function taskClaimAllowed(task) {
    return Boolean(task && task.progress >= 1 && task.claimed !== true);
  }

  const rules = { BASE_COOK_MS, MAX_TAPS_PER_DAY, UPGRADE_DEFINITIONS, upgradeCost, kitchenLevel, cookDuration, tapDumplings, upgradePurchaseQuote, batchDumplingReward, taskClaimAllowed };
  if (typeof module !== 'undefined' && module.exports) module.exports = rules;
  else root.PelmeniRules = rules;
})(globalThis);

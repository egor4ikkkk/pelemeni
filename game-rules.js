((root) => {
  const BASE_COOK_MS = 10 * 1000;
  const LEVEL_THRESHOLDS = [0, 500, 1000, 1500, 2000, 3000, 4000, 5500, 7500, 10000];
  const DAILY_TASK_REWARDS = { login: 5, cook: 10, upgrade: 15 };
  const UPGRADE_DEFINITIONS = [
    { id: 'good-stove', name: 'A Better Stove', description: 'Cook each batch 5% faster per level.', baseCost: 100, maxLevel: 10, effect: level => `${level * 5}% faster` },
    { id: 'large-pot', name: 'A Bigger Pot', description: 'Add one dumpling to every batch per level.', baseCost: 150, maxLevel: 10, effect: level => `+${level} dumplings / batch` },
    { id: 'grandma-recipe', name: "Grandma's Recipe", description: 'Increase the base batch reward by 5% per level.', baseCost: 200, maxLevel: 10, effect: level => `+${level * 5}% batch reward` }
  ];
  const DECORATION_DEFINITIONS = [
    { id: 'second-pot', name: 'Second Pot', description: 'Equip a second burner and pot to cook another batch at the same time.', cost: 1000, effect: '2 independent cooking slots', icon: '♨♨' }
  ];

  function upgradeCost(definition, currentLevel) {
    if (currentLevel === 0 && Number.isSafeInteger(definition.temporaryCost)) return definition.temporaryCost;
    return Math.round(definition.baseCost * Math.pow(1.5, currentLevel) / 1.5);
  }
  function playerLevel(totalScore) {
    let level = 1;
    LEVEL_THRESHOLDS.forEach((threshold, index) => { if (totalScore >= threshold) level = index + 1; });
    return level;
  }
  function levelReward(level) { return 10 + Math.max(0, level - 2) * 5; }
  function kitchenLevel(levels) {
    const total = Object.values(levels || {}).reduce((sum, level) => sum + (Number.isSafeInteger(level) && level > 0 ? level : 0), 0);
    return 1 + Math.floor(total / 2);
  }
  function cookDuration(levels, legacySecondsOff = 0) {
    const stoveLevel = Math.max(0, Math.min(10, Number.isSafeInteger(levels?.['good-stove']) ? levels['good-stove'] : 0));
    const reduction = Math.min(0.5, stoveLevel * 0.05);
    return Math.max(4 * 1000, Math.round(BASE_COOK_MS * (1 - reduction)) - Math.max(0, legacySecondsOff) * 1000);
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
  function batchDumplingRange(levels, legacyBonus = 0) {
    return { min: batchDumplingReward(10, levels, legacyBonus), max: batchDumplingReward(15, levels, legacyBonus) };
  }
  function taskClaimAllowed(task) {
    const goal = Number.isSafeInteger(task?.goal) && task.goal > 0 ? task.goal : 1;
    return Boolean(task && Number.isFinite(task.progress) && task.progress >= goal && task.claimed !== true);
  }
  function validUtcDay(day) {
    if (typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
    const date = new Date(`${day}T00:00:00.000Z`);
    return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === day;
  }
  function advanceStreak(current, best, lastVisit, today) {
    const safeCurrent = Number.isSafeInteger(current) && current > 0 ? current : 0;
    const safeBest = Math.max(safeCurrent, Number.isSafeInteger(best) && best > 0 ? best : 0);
    if (!validUtcDay(today)) return { current: safeCurrent, best: safeBest, lastVisit: validUtcDay(lastVisit) ? lastVisit : null, changed: false };
    if (!validUtcDay(lastVisit)) return { current: 1, best: Math.max(1, safeBest), lastVisit: today, changed: true };
    if (today === lastVisit) return { current: safeCurrent || 1, best: safeBest, lastVisit, changed: false };
    const elapsedDays = (Date.parse(`${today}T00:00:00.000Z`) - Date.parse(`${lastVisit}T00:00:00.000Z`)) / 86_400_000;
    if (elapsedDays < 0) return { current: safeCurrent, best: safeBest, lastVisit, changed: false };
    const next = elapsedDays === 1 ? safeCurrent + 1 : 1;
    return { current: next, best: Math.max(safeBest, next), lastVisit: today, changed: true };
  }

  const rules = { BASE_COOK_MS, LEVEL_THRESHOLDS, DAILY_TASK_REWARDS, UPGRADE_DEFINITIONS, DECORATION_DEFINITIONS, upgradeCost, playerLevel, levelReward, kitchenLevel, cookDuration, upgradePurchaseQuote, batchDumplingReward, batchDumplingRange, taskClaimAllowed, validUtcDay, advanceStreak };
  if (typeof module !== 'undefined' && module.exports) module.exports = rules;
  else root.PelmeniRules = rules;
})(globalThis);

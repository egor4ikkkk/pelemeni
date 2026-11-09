((root) => {
  const BASE_COOK_MS = 12 * 60 * 60 * 1000;
  const STOVE_LEVEL_COSTS = [15, 25, 40, 60, 90, 130, 180, 250, 350, 500];
  const POT_LEVEL_COSTS = [75, 125, 200, 300, 450, 650, 900, 1200, 1550, 2000];
  const RECIPE_LEVEL_COSTS = [100, 150, 250, 400, 600, 900, 1250, 1750, 2300, 3000];
  const LEVEL_THRESHOLDS = [0, 500, 1000, 1500, 2000, 3000, 4000, 5500, 7500, 10000];
  const DAILY_TASK_REWARDS = { cook: 10, upgrade: 15 };
  const DAILY_TASK_VARIANTS = {
    classic: { cookGoal: 1, collectMode: 'collect', collectGoal: 1, dumplingMode: 'amount', dumplingGoal: 30 },
    'batch-focus': { cookGoal: 2, collectMode: 'collect', collectGoal: 2, dumplingMode: 'amount', dumplingGoal: 30 },
    'kitchen-rhythm': { cookGoal: 1, collectMode: 'start-and-collect', collectGoal: 1, dumplingMode: 'batch-count', dumplingGoal: 2 }
  };
  const DAILY_TASK_VARIANT_IDS = Object.keys(DAILY_TASK_VARIANTS);
  const UPGRADE_DEFINITIONS = [
    { id: 'good-stove', name: 'A Better Stove', description: 'Cook each batch 5% faster per level.', baseCost: 15, maxLevel: 10, levelCosts: STOVE_LEVEL_COSTS, effect: level => `${level * 5}% faster` },
    { id: 'large-pot', name: 'A Bigger Pot', description: 'Add one dumpling to every batch per level.', baseCost: 75, maxLevel: 10, levelCosts: POT_LEVEL_COSTS, effect: level => `+${level} dumplings / batch` },
    { id: 'grandma-recipe', name: "Grandma's Recipe", description: 'Increase the base batch reward by 5% per level.', baseCost: 100, maxLevel: 10, levelCosts: RECIPE_LEVEL_COSTS, effect: level => `+${level * 5}% batch reward` }
  ];
  const DECORATION_DEFINITIONS = [
    { id: 'second-pot', name: 'Second Pot', description: 'Equip a second burner and pot to cook another batch at the same time.', cost: 1500, effect: '2 independent cooking slots', icon: '♨♨' }
  ];

  function upgradeCost(definition, currentLevel) {
    if (Array.isArray(definition.levelCosts) && Number.isSafeInteger(definition.levelCosts[currentLevel])) return definition.levelCosts[currentLevel];
    if (currentLevel === 0 && Number.isSafeInteger(definition.temporaryCost)) return definition.temporaryCost;
    return Math.round(definition.baseCost * Math.pow(1.5, currentLevel) / 1.5);
  }
  function playerLevel(totalScore) {
    let level = 1;
    LEVEL_THRESHOLDS.forEach((threshold, index) => { if (totalScore >= threshold) level = index + 1; });
    return level;
  }
  function levelReward(level) { return 10 + Math.max(0, level - 2) * 5; }
  function streakRewardAmount(streakDay) {
    if (!Number.isSafeInteger(streakDay) || streakDay < 1) return 0;
    return Math.min(10, Math.floor(streakDay / 2) + 1);
  }
  function streakVisitKey(day) { return validUtcDay(day) ? `${day}:0:0` : null; }
  function streakClaimKey(day) { return validUtcDay(day) ? `${day}:0:1` : null; }
  function canClaimStreakReward(visitDate, claims, today) {
    const key = streakClaimKey(today);
    return Boolean(key && visitDate === today && Array.isArray(claims) && !claims.includes(key));
  }
  function prepareStreakRewardClaim(state, today) {
    if (!state || state.dailyDate !== today || !canClaimStreakReward(state.streakLastVisitDate, state.streakRewardClaims, today)) return null;
    return {
      amount: streakRewardAmount(state.streakCurrent),
      loginRewardDate: today,
      streakRewardClaims: recordStreakRewardClaim(state.streakRewardClaims, today)
    };
  }
  function recordStreakRewardClaim(claims, today) {
    const key = streakClaimKey(today);
    return key ? [...new Set([...(Array.isArray(claims) ? claims : []), key])] : [...(Array.isArray(claims) ? claims : [])];
  }
  function recordStreakVisit(claims, today) {
    const key = streakVisitKey(today);
    return key ? [...new Set([...(Array.isArray(claims) ? claims : []), key])] : [...(Array.isArray(claims) ? claims : [])];
  }
  function normalizeStreakRewardClaims(claims, loginRewardDate, firstLoginNoReward, today) {
    const validClaims = Array.isArray(claims)
      ? [...new Set(claims.filter(key => typeof key === 'string' && /^\d{4}-\d{2}-\d{2}:\d+:\d+$/.test(key) && validUtcDay(key.split(':')[0])))]
      : [];
    // Before manual claims existed, loginRewardDate meant the automatic reward
    // had already been paid. New visit markers distinguish the new protocol.
    const hasNewVisitMarker = validClaims.includes(streakVisitKey(today));
    const hasClaimMarker = validClaims.includes(streakClaimKey(today));
    return loginRewardDate === today && !hasNewVisitMarker && !hasClaimMarker && firstLoginNoReward !== true
      ? recordStreakRewardClaim(validClaims, today)
      : validClaims;
  }
  function kitchenLevel(levels) {
    const total = Object.values(levels || {}).reduce((sum, level) => sum + (Number.isSafeInteger(level) && level > 0 ? level : 0), 0);
    return 1 + Math.floor(total / 2);
  }
  function cookDuration(levels, legacySecondsOff = 0) {
    const stoveLevel = Math.max(0, Math.min(10, Number.isSafeInteger(levels?.['good-stove']) ? levels['good-stove'] : 0));
    const reduction = Math.min(0.5, stoveLevel * 0.05);
    return Math.round(BASE_COOK_MS * (1 - reduction));
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
  function completedDailyTaskCount(tasks, isCurrentDay) {
    if (!isCurrentDay || !Array.isArray(tasks)) return 0;
    return tasks.filter(task => task && task.id !== 'login' && Number.isFinite(task.progress)
      && Number.isFinite(task.goal) && task.goal > 0 && task.progress >= task.goal).length;
  }
  function prepareAchievementClaim(state, definition) {
    if (!state || !definition || !Array.isArray(state.achievements) || !state.achievements.includes(definition.id)
      || !Array.isArray(state.achievementClaims) || state.achievementClaims.includes(definition.id)
      || !Number.isSafeInteger(definition.reward) || definition.reward < 0) return null;
    return { achievementClaims: [...new Set([...state.achievementClaims, definition.id])], amount: definition.reward };
  }
  function dailyTaskVariantForDate(day) {
    if (!validUtcDay(day)) return null;
    const dayNumber = Math.floor(Date.parse(`${day}T00:00:00.000Z`) / 86_400_000);
    return DAILY_TASK_VARIANT_IDS[dayNumber % DAILY_TASK_VARIANT_IDS.length];
  }
  function dailyTaskVariant(variant) { return DAILY_TASK_VARIANTS[variant] || DAILY_TASK_VARIANTS.classic; }
  function dailyTaskProgress(id, variant, tasks) {
    const selected = dailyTaskVariant(variant);
    const safeProgress = key => Number.isSafeInteger(tasks?.[key]?.progress) && tasks[key].progress >= 0 ? tasks[key].progress : 0;
    if (id === 'collect' && selected.collectMode === 'start-and-collect') return Math.min(safeProgress('cook'), safeProgress('collect'));
    if (id === 'collect-dumplings' && selected.dumplingMode === 'batch-count') return safeProgress('collect-two');
    return safeProgress(id);
  }
  function validUtcDay(day) {
    if (typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
    const date = new Date(`${day}T00:00:00.000Z`);
    return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === day;
  }
  function utcMidnightCountdown(nowMs) {
    if (!Number.isFinite(nowMs)) return '00:00';
    const now = new Date(nowMs);
    const nextUtcMidnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
    const minutesLeft = Math.max(0, Math.ceil((nextUtcMidnight - nowMs) / 60_000));
    return `${String(Math.floor(minutesLeft / 60)).padStart(2, '0')}:${String(minutesLeft % 60).padStart(2, '0')}`;
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
  function streakRewardKey(runStartedDate, cycle, day) {
    if (!validUtcDay(runStartedDate) || !Number.isSafeInteger(cycle) || cycle < 0 || !Number.isSafeInteger(day) || day < 1 || day > 7) return null;
    return `${runStartedDate}:${cycle}:${day}`;
  }
  function inferStreakStartDate(streakLength, lastVisitDate) {
    if (!Number.isSafeInteger(streakLength) || streakLength < 1 || !validUtcDay(lastVisitDate)) return null;
    const start = new Date(`${lastVisitDate}T00:00:00.000Z`);
    start.setUTCDate(start.getUTCDate() - Math.min(streakLength - 1, 36_500));
    return start.toISOString().slice(0, 10);
  }
  const rules = { BASE_COOK_MS, STOVE_LEVEL_COSTS, LEVEL_THRESHOLDS, DAILY_TASK_REWARDS, DAILY_TASK_VARIANTS, UPGRADE_DEFINITIONS, DECORATION_DEFINITIONS, upgradeCost, playerLevel, levelReward, streakRewardAmount, streakVisitKey, streakClaimKey, canClaimStreakReward, prepareStreakRewardClaim, recordStreakRewardClaim, recordStreakVisit, normalizeStreakRewardClaims, kitchenLevel, cookDuration, upgradePurchaseQuote, batchDumplingReward, batchDumplingRange, taskClaimAllowed, completedDailyTaskCount, prepareAchievementClaim, dailyTaskVariantForDate, dailyTaskVariant, dailyTaskProgress, validUtcDay, utcMidnightCountdown, advanceStreak, streakRewardKey, inferStreakStartDate };
  if (typeof module !== 'undefined' && module.exports) module.exports = rules;
  else root.PelmeniRules = rules;
})(globalThis);

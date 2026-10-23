(() => {
  const CLOUD_URL = 'https://qcagyjlsqlihdcdbxgxc.supabase.co/functions/v1/quick-function';
  const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_ejIIlpOGM6SViZ_ZcYYi-g_tDChykDP';
  const LEGACY_STORAGE_KEY = 'pelmeni-clicker-mini-v2';
  const legacyUpgradeIds = ['herb-pot', 'blue-tile', 'wooden-spoon', 'second-pot'];
  const telegramWebApp = window.Telegram?.WebApp;
  const telegramInitData = typeof telegramWebApp?.initData === 'string' ? telegramWebApp.initData : '';
  const telegramUser = telegramWebApp?.initDataUnsafe?.user || null;
  const telegramUserId = Number.isSafeInteger(telegramUser?.id) && telegramUser.id > 0 ? telegramUser.id : null;
  const STORAGE_KEY = telegramUserId ? `${LEGACY_STORAGE_KEY}:telegram:${telegramUserId}` : LEGACY_STORAGE_KEY;
  const $ = id => document.getElementById(id);
  const safeInt = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
  const nowDay = () => new Date().toISOString().slice(0, 10);
  const DAILY_TASK_IDS = ['login', 'cook', 'upgrade', 'collect', 'collect-dumplings', 'two-pots'];
  const emptyDailyTasks = () => Object.fromEntries(DAILY_TASK_IDS.map(id => [id, { progress: 0, claimed: false }]));
  const freshState = () => ({
    balance: 0, score: 0, points: 0, pointsRetired: true, batches: 0, startedAt: null, endsAt: null, batchDurationMs: null,
    activeBatches: [], upgrades: [], equipped: [], upgradeLevels: {}, taskDay: nowDay(), taskBatches: 0,
    taskClaimedOn: null, taskBalanceRewardVersion: 1, referralCode: null, dailyDate: nowDay(),
    dailyTasks: emptyDailyTasks(), loginRewardDate: null, firstLoginNoReward: false, lifetimeDumplings: 0, levelClaims: [], achievements: [],
    streakCurrent: 0, streakBest: 0, streakLastVisitDate: null, streakRunStartedDate: null, streakRewardClaims: [], taskPotsUsed: [], potCollections: { 1: 0, 2: 0 },
    joinedAt: null, lastBatchReward: null, lastBatchAt: null
  });
  const appShell = $('appShell');
  const rules = window.PelmeniRules;
  let state = loadLocalState();
  let toastTimer;
  let stateReady = false;
  let cloudSyncEnabled = false;
  let saveVersion = 0;
  let syncedVersion = 0;
  let saveTimer = null;
  let retryTimer = null;
  let retryDelay = 2000;
  let saveInFlight = false;

  function normalizeState(saved) {
    if (!saved || typeof saved !== 'object' || Array.isArray(saved)) return freshState();
    const ownedLegacy = Array.isArray(saved.upgrades) ? saved.upgrades.filter(id => legacyUpgradeIds.includes(id)) : [];
    const legacySecondPotLevel = safeInt(saved.upgradeLevels?.['second-pot']) > 0;
    if (legacySecondPotLevel && !ownedLegacy.includes('second-pot')) ownedLegacy.push('second-pot');
    const secondPotEquipped = ownedLegacy.includes('second-pot') && (legacySecondPotLevel && !(saved.upgrades || []).includes('second-pot') || Array.isArray(saved.equipped) && saved.equipped.includes('second-pot'));
    const currentLevels = {};
    for (const item of rules.UPGRADE_DEFINITIONS) {
      const level = safeInt(saved.upgradeLevels?.[item.id]);
      currentLevels[item.id] = Math.min(item.maxLevel, level);
    }
    let activeBatches = [];
    if (Array.isArray(saved.activeBatches)) {
      activeBatches = saved.activeBatches.filter(batch => batch && typeof batch.id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(batch.id) && Number.isFinite(batch.startedAt) && Number.isFinite(batch.endsAt) && batch.endsAt > batch.startedAt)
        .slice(0, (secondPotEquipped || ownedLegacy.includes('second-pot')) ? 2 : 1)
        .map((batch, index) => {
          const savedDuration = safeInt(batch.durationMs) || batch.endsAt - batch.startedAt;
          const durationMs = savedDuration > rules.BASE_COOK_MS ? rules.BASE_COOK_MS : savedDuration;
          const pot = batch.pot === 1 || batch.pot === 2 ? batch.pot : index + 1;
          return { id: batch.id, pot, startedAt: batch.startedAt, endsAt: batch.startedAt + durationMs, durationMs };
        });
    } else if (Number.isFinite(saved.startedAt) && Number.isFinite(saved.endsAt) && saved.endsAt > saved.startedAt) {
      const savedDuration = safeInt(saved.batchDurationMs) || saved.endsAt - saved.startedAt;
      const durationMs = savedDuration > rules.BASE_COOK_MS ? rules.BASE_COOK_MS : savedDuration;
      activeBatches = [{ id: 'legacy-batch', pot: 1, startedAt: saved.startedAt, endsAt: saved.startedAt + durationMs, durationMs }];
    }
    const dailyTasks = emptyDailyTasks();
    for (const id of DAILY_TASK_IDS) {
      const oldTask = saved.dailyTasks?.[id];
      if (oldTask && typeof oldTask === 'object') dailyTasks[id] = { progress: Math.min(1_000_000, safeInt(oldTask.progress)), claimed: oldTask.claimed === true };
    }
    if (!saved.dailyTasks && safeInt(saved.taskBatches) > 0) dailyTasks.cook.progress = 1;
    if (!saved.dailyTasks && saved.taskClaimedOn === nowDay()) dailyTasks.cook.claimed = true;
    return {
      balance: safeInt(saved.balance) + (saved.taskClaimedOn === nowDay() && saved.taskBalanceRewardVersion !== 1 ? 5 : 0) + (saved.pointsRetired === true ? 0 : (saved.points === undefined ? safeInt(saved.score) : safeInt(saved.points))),
      lifetimeDumplings: Number.isSafeInteger(saved.lifetimeDumplings) && saved.lifetimeDumplings >= 0 ? saved.lifetimeDumplings : safeInt(saved.balance),
      levelClaims: Array.isArray(saved.levelClaims) ? [...new Set(saved.levelClaims.filter(level => Number.isSafeInteger(level) && level >= 2 && level <= 10))] : [],
      score: Math.max(safeInt(saved.score), safeInt(saved.lifetimeDumplings), safeInt(saved.balance)), points: 0, pointsRetired: true,
      batches: safeInt(saved.batches), startedAt: activeBatches[0]?.startedAt ?? (Number.isFinite(saved.startedAt) ? saved.startedAt : null),
      endsAt: activeBatches[0]?.endsAt ?? (Number.isFinite(saved.endsAt) ? saved.endsAt : null),
      batchDurationMs: activeBatches[0]?.durationMs ?? (safeInt(saved.batchDurationMs) || null), activeBatches,
      upgrades: ownedLegacy, equipped: Array.isArray(saved.equipped) ? [...new Set([...saved.equipped.filter(id => ownedLegacy.includes(id)), ...(secondPotEquipped ? ['second-pot'] : [])])] : [...ownedLegacy],
      upgradeLevels: currentLevels, taskDay: typeof saved.taskDay === 'string' ? saved.taskDay : nowDay(),
      taskBatches: safeInt(saved.taskBatches), taskClaimedOn: typeof saved.taskClaimedOn === 'string' ? saved.taskClaimedOn : null,
      taskBalanceRewardVersion: 1,
      referralCode: typeof saved.referralCode === 'string' && /^PC-[A-Z0-9]{6}$/.test(saved.referralCode) ? saved.referralCode : null,
      dailyDate: rules.validUtcDay(saved.dailyDate) ? saved.dailyDate : (rules.validUtcDay(saved.taskDay) ? saved.taskDay : null),
      dailyTasks, loginRewardDate: typeof saved.loginRewardDate === 'string' ? saved.loginRewardDate : null,
      streakCurrent: safeInt(saved.streakCurrent), streakBest: Math.max(safeInt(saved.streakBest), safeInt(saved.streakCurrent)),
      streakLastVisitDate: rules.validUtcDay(saved.streakLastVisitDate) ? saved.streakLastVisitDate : null,
      streakRunStartedDate: rules.validUtcDay(saved.streakRunStartedDate) ? saved.streakRunStartedDate : rules.inferStreakStartDate(safeInt(saved.streakCurrent), saved.streakLastVisitDate),
      streakRewardClaims: Array.isArray(saved.streakRewardClaims) ? [...new Set(saved.streakRewardClaims.filter(key => typeof key === 'string' && /^\d{4}-\d{2}-\d{2}:\d+:\d+$/.test(key) && rules.validUtcDay(key.split(':')[0])))] : [],
      taskPotsUsed: Array.isArray(saved.taskPotsUsed) ? [...new Set(saved.taskPotsUsed.filter(pot => pot === 1 || pot === 2))] : [],
      potCollections: { 1: safeInt(saved.potCollections?.[1]), 2: safeInt(saved.potCollections?.[2]) },
      firstLoginNoReward: saved.firstLoginNoReward === true,
      achievements: Array.isArray(saved.achievements) ? [...new Set(saved.achievements.filter(id => ['first-batch','score-1000','five-batches','ten-batches','twenty-five-batches','first-upgrade','master-kitchen','first-visit','dumpling-thousand','streak-three','streak-seven','streak-fourteen','streak-thirty','both-burners'].includes(id)))] : [],
      joinedAt: typeof saved.joinedAt === 'string' && !Number.isNaN(Date.parse(saved.joinedAt)) ? saved.joinedAt : null,
      lastBatchReward: saved.lastBatchReward && Number.isSafeInteger(saved.lastBatchReward.dumplings) && saved.lastBatchReward.dumplings >= 0 ? { dumplings: saved.lastBatchReward.dumplings } : null,
      lastBatchAt: typeof saved.lastBatchAt === 'string' && !Number.isNaN(Date.parse(saved.lastBatchAt)) ? saved.lastBatchAt : null
    };
  }
  function loadLocalState() {
    try {
      let raw = localStorage.getItem(STORAGE_KEY);
      let saved = raw ? JSON.parse(raw) : null;
      if (!saved && telegramUserId && localStorage.getItem(`${LEGACY_STORAGE_KEY}:telegram-migrated`) !== '1') {
        const legacy = localStorage.getItem(LEGACY_STORAGE_KEY);
        if (legacy) {
          saved = JSON.parse(legacy);
          if (saved.taskClaimedOn === nowDay() && saved.taskBalanceRewardVersion !== 1) saved.balance = safeInt(saved.balance) + 5;
          saved.taskBalanceRewardVersion = 1;
          localStorage.setItem(STORAGE_KEY, JSON.stringify(saved));
          localStorage.setItem(`${LEGACY_STORAGE_KEY}:telegram-migrated`, '1');
        }
      }
      return normalizeState(saved);
    } catch (error) {
      console.error('[Pelmeni Clicker] Could not read local save; starting with a safe default.', error);
      return freshState();
    }
  }
  function serializeState() {
    return {
      balance: state.balance, score: state.score, points: 0, pointsRetired: true, batches: state.batches,
      startedAt: state.startedAt, endsAt: state.endsAt, batchDurationMs: state.batchDurationMs,
      activeBatches: state.activeBatches.map(batch => ({ ...batch })), upgrades: [...state.upgrades], equipped: [...state.equipped],
      upgradeLevels: { ...state.upgradeLevels }, taskDay: state.taskDay, taskBatches: state.taskBatches,
      lifetimeDumplings: state.lifetimeDumplings, levelClaims: [...state.levelClaims],
      taskClaimedOn: state.taskClaimedOn, taskBalanceRewardVersion: state.taskBalanceRewardVersion,
      referralCode: state.referralCode, dailyDate: state.dailyDate, dailyTasks: JSON.parse(JSON.stringify(state.dailyTasks)),
      loginRewardDate: state.loginRewardDate, firstLoginNoReward: state.firstLoginNoReward,
      streakCurrent: state.streakCurrent, streakBest: state.streakBest, streakLastVisitDate: state.streakLastVisitDate,
      streakRunStartedDate: state.streakRunStartedDate, streakRewardClaims: [...state.streakRewardClaims], taskPotsUsed: [...state.taskPotsUsed], potCollections: { ...state.potCollections },
      achievements: [...state.achievements], joinedAt: state.joinedAt, lastBatchReward: state.lastBatchReward,
      lastBatchAt: state.lastBatchAt, schemaVersion: 6
    };
  }
  function saveLocalState() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(serializeState())); }
    catch (error) { setSyncStatus('Local save failed', 'error'); console.error('[Pelmeni Clicker] Local save failed.', error); }
  }
  function saveState() {
    saveLocalState();
    if (!stateReady || !cloudSyncEnabled) return;
    saveVersion++;
    scheduleCloudSave();
  }
  function scheduleCloudSave(delay = 650) {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(flushCloudSave, delay);
  }
  async function postToCloud(payload) {
    const response = await fetch(CLOUD_URL, {
      method: 'POST', headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const responseText = await response.text();
    let result = {};
    try { result = responseText ? JSON.parse(responseText) : {}; } catch { result = { message: responseText }; }
    if (!response.ok) throw new Error(typeof result.error === 'string' ? result.error : `HTTP ${response.status}`);
    return result;
  }
  async function flushCloudSave() {
    if (!cloudSyncEnabled || !stateReady || saveInFlight || syncedVersion >= saveVersion) return;
    saveInFlight = true;
    const versionBeingSent = saveVersion;
    try {
      await postToCloud({ action: 'save', initData: telegramInitData, state: serializeState() });
      syncedVersion = versionBeingSent;
      retryDelay = 2000;
      setSyncStatus('Synced', 'ok');
      console.info('[Pelmeni Clicker] Cloud sync saved.');
    } catch (error) {
      setSyncStatus('Saved on this device · sync retrying', 'error');
      console.error('[Pelmeni Clicker] Cloud sync error; progress remains saved locally.', error.message);
      clearTimeout(retryTimer);
      retryTimer = setTimeout(() => { retryTimer = null; scheduleCloudSave(0); }, retryDelay);
      retryDelay = Math.min(retryDelay * 2, 30000);
    } finally {
      saveInFlight = false;
      if (syncedVersion < saveVersion && !retryTimer) scheduleCloudSave(0);
    }
  }
  async function initializeState() {
    if (!telegramInitData) {
      stateReady = true;
      applyDailyState();
      ensureAchievements();
      state.joinedAt ||= new Date().toISOString();
      saveLocalState();
      render();
      setSyncStatus('This device only', 'local');
      console.info('[Pelmeni Clicker] No Telegram initData; using this browser’s local save.');
      appShell.inert = false; appShell.setAttribute('aria-busy', 'false');
      return;
    }
    setSyncStatus('Loading cloud save…', 'loading');
    try {
      const result = await postToCloud({ action: 'load', initData: telegramInitData });
      if (!Object.prototype.hasOwnProperty.call(result, 'game_state')) throw new Error('Unexpected load response: expected a game_state field.');
      if (result.game_state === null) {
        state = loadLocalState();
        cloudSyncEnabled = true;
        console.info('[Pelmeni Clicker] No cloud save found; local progress queued for upload.');
      } else if (typeof result.game_state === 'object' && !Array.isArray(result.game_state)) {
        state = normalizeState(result.game_state);
        cloudSyncEnabled = true;
        console.info('[Pelmeni Clicker] Cloud save loaded successfully.');
      } else {
        throw new Error('Unexpected load response: game_state must be an object or null.');
      }
      stateReady = true;
      applyDailyState();
      ensureAchievements();
      state.joinedAt ||= new Date().toISOString();
      saveLocalState();
      setSyncStatus('Synced', 'ok');
      if (result.game_state === null) { saveVersion++; scheduleCloudSave(0); }
      else if (state.dailyDate === nowDay() && state.loginRewardDate === nowDay()) { /* Cloud state already includes today’s claim. */ }
      if (JSON.stringify(result.game_state) !== JSON.stringify(serializeState())) { saveVersion++; scheduleCloudSave(0); }
    } catch (error) {
      state = loadLocalState(); stateReady = true; cloudSyncEnabled = false;
      applyDailyState(); ensureAchievements(); state.joinedAt ||= new Date().toISOString(); saveLocalState();
      setSyncStatus('Offline · saved on this device', 'error');
      console.error('[Pelmeni Clicker] Cloud load/sync error; using local progress. Check the Edge Function response and network.', error.message);
    }
    render();
    appShell.inert = false; appShell.setAttribute('aria-busy', 'false');
  }
  function setSyncStatus(message, status) {
    const badge = $('syncStatus');
    if (!badge) return;
    badge.textContent = message;
    badge.dataset.status = status;
  }
  function toast(message) {
    const el = $('toast'); el.textContent = message; el.classList.add('show');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('show'), 2400);
  }
  function utcDateLabel() { return new Intl.DateTimeFormat('en', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date()); }
  function legacySecondsOff() { return (state.equipped.includes('blue-tile') ? 3 : 0) + (state.equipped.includes('wooden-spoon') ? 3 : 0); }
  function cookDurationMs() { return rules.cookDuration(state.upgradeLevels, legacySecondsOff()); }
  function capacity() { return state.equipped.includes('second-pot') ? 2 : 1; }
  function batchForPot(pot) { return state.activeBatches.find(batch => batch.pot === pot) || null; }
  function firstReadyBatch() { return state.activeBatches.filter(batch => Date.now() >= batch.endsAt).sort((a, b) => a.endsAt - b.endsAt)[0] || null; }
  function formatTime(ms) {
    const totalSeconds = Math.max(0, Math.ceil(ms / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    return hours ? `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}` : `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
  }
  function applyDailyState() {
    const today = nowDay();
    if (rules.validUtcDay(state.dailyDate) && today < state.dailyDate) return;
    const previousStreakDate = state.streakLastVisitDate;
    const elapsedVisitDays = rules.validUtcDay(previousStreakDate) ? (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${previousStreakDate}T00:00:00Z`)) / 86_400_000 : null;
    const streak = rules.advanceStreak(state.streakCurrent, state.streakBest, previousStreakDate, today);
    state.streakCurrent = streak.current;
    state.streakBest = streak.best;
    state.streakLastVisitDate = streak.lastVisit;
    if (streak.changed && (!previousStreakDate || elapsedVisitDays > 1)) state.streakRunStartedDate = today;
    state.streakRunStartedDate ||= streak.lastVisit;
    const firstVisit = !state.joinedAt && state.batches === 0 && state.balance === 0 && state.upgrades.length === 0 && totalUpgradeLevels() === 0;
    if (state.dailyDate !== today) {
      state.dailyDate = today;
      state.dailyTasks = emptyDailyTasks();
      state.loginRewardDate = null;
      state.firstLoginNoReward = false;
      state.taskDay = today;
      state.taskBatches = 0;
      state.taskClaimedOn = null;
      state.taskPotsUsed = [];
    }
    if (state.loginRewardDate !== today) {
      if (firstVisit) { state.achievements.push('first-visit'); state.firstLoginNoReward = true; }
      else addDumplings(rules.DAILY_TASK_REWARDS.login);
      state.loginRewardDate = today;
      state.dailyTasks.login = { progress: 1, claimed: true };
      if (!firstVisit) toast('Daily login reward: +5 dumplings.');
    } else {
      state.dailyTasks.login = { progress: 1, claimed: true };
    }
    if (state.dailyTasks.cook?.progress) state.taskBatches = Math.max(1, state.taskBatches);
  }
  const achievementDefinitions = [
    { id: 'first-batch', title: 'First batch', description: 'Collect your first pot of dumplings.', progress: () => state.batches, goal: 1, achieved: () => state.batches >= 1 },
    { id: 'first-visit', title: 'First day in the kitchen', description: 'Welcome to Pelmeni Clicker.', progress: () => state.achievements.includes('first-visit') ? 1 : 0, goal: 1, achieved: () => state.achievements.includes('first-visit') },
    { id: 'five-batches', title: 'Five batches', description: 'Collect five batches.', progress: () => state.batches, goal: 5, achieved: () => state.batches >= 5 },
    { id: 'ten-batches', title: 'Regular chef', description: 'Collect ten batches.', progress: () => state.batches, goal: 10, achieved: () => state.batches >= 10 },
    { id: 'twenty-five-batches', title: 'Kitchen favorite', description: 'Collect twenty-five batches.', progress: () => state.batches, goal: 25, achieved: () => state.batches >= 25 },
    { id: 'first-upgrade', title: 'First upgrade', description: 'Improve your kitchen for the first time.', progress: () => totalUpgradeLevels() + state.upgrades.length, goal: 1, achieved: () => totalUpgradeLevels() > 0 || state.upgrades.length > 0 },
    { id: 'master-kitchen', title: 'Master kitchen', description: 'Reach kitchen level 6.', progress: () => rules.kitchenLevel(state.upgradeLevels), goal: 6, achieved: () => rules.kitchenLevel(state.upgradeLevels) >= 6 },
    { id: 'dumpling-thousand', title: 'A thousand dumplings', description: 'Earn 1,000 dumplings over time.', progress: () => state.lifetimeDumplings, goal: 1000, achieved: () => state.lifetimeDumplings >= 1000 },
    { id: 'streak-three', title: 'Three-day rhythm', description: 'Visit on three consecutive UTC days.', progress: () => state.streakBest, goal: 3, achieved: () => state.streakBest >= 3 },
    { id: 'streak-seven', title: 'A week in the kitchen', description: 'Visit on seven consecutive UTC days.', progress: () => state.streakBest, goal: 7, achieved: () => state.streakBest >= 7 },
    { id: 'streak-fourteen', title: 'Kitchen regular', description: 'Visit on fourteen consecutive UTC days.', progress: () => state.streakBest, goal: 14, achieved: () => state.streakBest >= 14 },
    { id: 'streak-thirty', title: 'Thirty-day tradition', description: 'Visit on thirty consecutive UTC days.', progress: () => state.streakBest, goal: 30, achieved: () => state.streakBest >= 30 },
    { id: 'both-burners', title: 'Two burners, one chef', description: 'Collect a batch from each pot.', progress: () => Math.min(state.potCollections[1], 1) + Math.min(state.potCollections[2], 1), goal: 2, achieved: () => state.potCollections[1] > 0 && state.potCollections[2] > 0 }
  ];
  function totalUpgradeLevels() { return Object.values(state.upgradeLevels).reduce((sum, value) => sum + safeInt(value), 0); }
  function ensureAchievements() {
    const unlocked = [];
    for (const definition of achievementDefinitions) if (definition.achieved() && !state.achievements.includes(definition.id)) { state.achievements.push(definition.id); unlocked.push(definition); }
    if (unlocked.length) saveLocalState();
    return unlocked;
  }
  function scheduleAchievementNotice(unlocked) {
    if (unlocked.length) setTimeout(() => toast(`Achievement unlocked: ${unlocked[0].title}`), 2600);
  }
  function addDumplings(amount, countForLevel = true) {
    state.balance += amount;
    state.score += amount;
    if (countForLevel) state.lifetimeDumplings += amount;
  }
  function markTaskProgress(id, amount = 1) {
    const task = state.dailyTasks[id];
    if (task) task.progress = Math.min(1_000_000, safeInt(task.progress) + amount);
  }
  function kitchenUpgradeIcon(id) {
    const icons = {
      'good-stove': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M8 22h32v19H8z" fill="#3985bb" stroke="#bdeaff"/><path d="M12 27h24M14 34h20" fill="none" stroke="#d2f0ff" stroke-width="1.5"/><ellipse cx="24" cy="18" rx="10" ry="6" fill="#18334d" stroke="#f1c779"/><ellipse cx="24" cy="18" rx="5" ry="2.5" fill="none" stroke="#ffcf79" stroke-width="1.5"/><path d="M24 12c-4-4 3-5 0-9 6 4 3 7 0 9Z" fill="#ff9d45" stroke="#ffd17a" stroke-width="1.2" stroke-linejoin="round"/></svg>',
      'large-pot': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M12 18h24l-2 23H14z" fill="#3985bb" stroke="#d2f0ff"/><path d="M10 18h28M15 15h18" fill="none" stroke="#f1c779" stroke-width="2.4" stroke-linecap="round"/><path d="M12 25H7v7h6m23-7h5v7h-6" fill="none" stroke="#d2f0ff" stroke-width="2.5" stroke-linejoin="round"/><path d="M17 18q1-6 7-6t7 6" fill="#fff1cf" stroke="#f1c779" stroke-width="1.6"/><path d="M20 14q4-3 8 0" fill="none" stroke="#fff" stroke-width="1.3"/></svg>',
      'grandma-recipe': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M7 11q9-4 17 2 8-6 17-2v27q-10-3-17 3-7-6-17-3z" fill="#f3d59a" stroke="#fff0c7"/><path d="M24 13v26M12 17q5-2 9 1m-9 5q5-2 9 1m14-7q-4-2-8 1m8 5q-4-2-8 1" fill="none" stroke="#a66e3e" stroke-width="1.8" stroke-linecap="round"/><path d="M32 5c-3-3-7 1-4 4l4 4 4-4c3-3-1-7-4-4Z" fill="#d98a87" stroke="#f8cbc0" stroke-width="1.2"/></svg>'
    };
    return icons[id] || '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16"/><path d="M24 13v22M13 24h22"/></svg>';
  }
  function legacyUpgradeIcon(id) {
    const icons = {
      'herb-pot': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M15 26h18l-2 16H17z" fill="#c9824b" stroke="#f1c779"/><path d="M24 27V13m0 8-8-7m8 10 8-9" fill="none" stroke="#55bb75"/><circle cx="24" cy="11" r="4" fill="#d8a7f0" stroke="#f1c779"/><path d="M15 14c-4-2-5-6-2-8 4 0 7 3 7 7m12 0c0-4 3-7 7-7 2 3 1 7-3 9" fill="#77cf88" stroke="#a9e2aa" stroke-width="1.6"/></svg>',
      'blue-tile': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M7 7h15v15H7zM26 7h15v15H26zM7 26h15v15H7zM26 26h15v15H26z" fill="#4b9ec6" stroke="#bdeaff"/><path d="M10 10h9v9h-9zm19 0h9v9h-9zM10 29h9v9h-9zm19 0h9v9h-9z" fill="#72c2e5" stroke="none"/></svg>',
      'wooden-spoon': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M14 8c-5 0-8 4-8 9 0 5 4 9 9 9s9-4 9-9c0-5-4-9-10-9Z" fill="#c98746" stroke="#ffcf82"/><path d="m20 23 18 18c2 2 5-1 3-3L23 20" fill="#c98746" stroke="#ffcf82"/><path d="M12 12c-2 2-2 5 0 7" fill="none" stroke="#ffe0aa" stroke-width="1.5"/></svg>',
      'second-pot': '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M6 22h36v19H6z" fill="#3985bb" stroke="#bdeaff"/><path d="M10 27h28M12 34h24" fill="none" stroke="#d2f0ff" stroke-width="1.5"/><ellipse cx="15" cy="18" rx="8" ry="5" fill="#18334d" stroke="#f1c779"/><ellipse cx="33" cy="18" rx="8" ry="5" fill="#18334d" stroke="#f1c779"/><ellipse cx="15" cy="18" rx="4" ry="2" fill="none" stroke="#ffcf79" stroke-width="1.4"/><ellipse cx="33" cy="18" rx="4" ry="2" fill="none" stroke="#ffcf79" stroke-width="1.4"/><path d="M15 12c-4-4 3-5 0-9 6 4 3 7 0 9Zm18 0c-4-4 3-5 0-9 6 4 3 7 0 9Z" fill="#ff9d45" stroke="#ffd17a" stroke-width="1.2" stroke-linejoin="round"/></svg>'
    };
    return icons[id] || '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16"/><path d="M24 13v22M13 24h22"/></svg>';
  }
  function renderLevelledUpgrades() {
    const container = $('upgradeList');
    const cards = rules.UPGRADE_DEFINITIONS.map(item => {
      const level = state.upgradeLevels[item.id] || 0;
      const maxed = level >= item.maxLevel;
      const cost = maxed ? 0 : rules.upgradeCost(item, level);
      const enough = state.balance >= cost;
      const buttonLabel = maxed ? 'MAX LEVEL' : enough ? `Upgrade · ${cost} dumplings` : `Need ${cost} dumplings`;
      return `<article class="upgrade-card level-card"><div class="upgrade-art level-upgrade-art">${kitchenUpgradeIcon(item.id)}</div><div class="upgrade-copy"><div class="upgrade-title-row"><h2>${item.name}</h2><span class="level-pill">Lv. ${level}/${item.maxLevel}</span></div><p>${item.description}</p><small class="upgrade-effect">${item.effect(level)}${!maxed ? ` · Next: ${item.effect(level + 1)}` : ' · Max level reached'}</small><small class="upgrade-affordability">${maxed ? 'Fully upgraded' : enough ? 'Ready to upgrade' : `You have ${state.balance} dumplings`}</small></div><button class="upgrade-button" data-level-upgrade="${item.id}" type="button" ${maxed || !enough ? 'disabled' : ''}>${buttonLabel}</button></article>`;
    }).join('');
    const legacy = [
      { id:'herb-pot', name:'Fresh herb pots', desc:'+2 dumplings with every collected batch.', effect:'+2 dumplings / batch', cost:20 },
      { id:'blue-tile', name:'Blue kitchen tiles', desc:'Keep your original decorative upgrade.', effect:'Kitchen decoration', cost:35 },
      { id:'wooden-spoon', name:'Carved wooden spoon', desc:'+3 dumplings and a tiny cook-time bonus.', effect:'+3 dumplings / batch', cost:50 },
      ...rules.DECORATION_DEFINITIONS.map(item => ({ ...item, desc:item.description }))
    ].map(item => {
      const owned = state.upgrades.includes(item.id);
      const equipped = state.equipped.includes(item.id);
      return `<article class="upgrade-card legacy-card ${equipped ? 'equipped' : ''}"><div class="upgrade-art decor-upgrade-art decor-icon-${item.id}">${legacyUpgradeIcon(item.id)}</div><div class="upgrade-copy"><h2>${item.name}</h2><p>${item.desc}</p><small class="upgrade-effect">${item.effect}</small></div><button class="upgrade-button" data-upgrade="${item.id}" type="button" ${!owned && state.balance < item.cost ? 'disabled' : ''}>${owned ? equipped ? 'REMOVE' : 'EQUIP' : `Get · ${item.cost} dumplings`}</button></article>`;
    }).join('');
    container.innerHTML = `<div class="upgrade-section-label">Kitchen upgrades <span>Spend dumplings</span></div>${cards}<div class="upgrade-section-label legacy-label">Kitchen decorations <span>Buy, equip, or remove</span></div>${legacy}`;
  }
  function renderDailyTasks() {
    const firstVisitToday = state.firstLoginNoReward && state.loginRewardDate === nowDay();
    const clockBehind = rules.validUtcDay(state.dailyDate) && nowDay() < state.dailyDate;
    const loginStatus = clockBehind ? 'Device date is earlier than your last saved game day; no new visit was counted.' : firstVisitToday ? 'Welcome badge received. The first visit has no login dumpling reward.' : `Today's +${rules.DAILY_TASK_REWARDS.login} dumplings were added automatically.`;
    const cycleLength = rules.STREAK_REWARD_SCHEDULE.length;
    const dayInCycle = state.streakCurrent ? ((state.streakCurrent - 1) % cycleLength) + 1 : 0;
    const nextDay = dayInCycle >= cycleLength ? 1 : Math.max(1, dayInCycle + 1);
    const daysToNext = state.streakCurrent ? (dayInCycle >= cycleLength ? 1 : nextDay - dayInCycle) : 1;
    const nextReward = rules.STREAK_REWARD_SCHEDULE.find(reward => reward.day === nextDay);
    const nextStatus = dayInCycle === 0 ? 'Your first daily reward is ready to view.' : `Next: Day ${nextDay} in ${daysToNext} ${daysToNext === 1 ? 'day' : 'days'}${nextReward ? ` · +${nextReward.amount} dumplings` : ''}.`;
    $('streakSummary').innerHTML = `<div class="streak-flame" aria-hidden="true">✦</div><div class="streak-copy"><span class="task-tag">DAILY STREAK · UTC</span><strong>${state.streakCurrent} ${state.streakCurrent === 1 ? 'day' : 'days'} <small>· best ${state.streakBest}</small></strong><p>${loginStatus}</p><small>${nextStatus}</small></div><span class="streak-check" aria-label="${clockBehind ? 'Visit not counted because device date is behind saved game date' : 'Today’s visit recorded'}">${clockBehind ? '!' : '✓'}</span>`;
    const calendarDays = rules.streakCalendar(rules.STREAK_REWARD_SCHEDULE, state.streakCurrent, state.streakRunStartedDate, state.streakRewardClaims);
    $('streakCalendar').innerHTML = calendarDays.map(reward => {
      const statusLabel = { received: 'Received', available: 'Available today', future: 'Coming up', missed: 'Missed' }[reward.status];
      const actionLabel = reward.status === 'available' ? 'Claim paused' : statusLabel;
      return `<article class="streak-day streak-day-${reward.status}"><span class="streak-day-number">DAY ${reward.day}</span><span class="streak-day-icon" aria-hidden="true">✦</span><strong>+${reward.amount}</strong><small>dumplings</small><span class="streak-day-status">${statusLabel}</span><button type="button" class="streak-day-claim" disabled aria-label="${statusLabel}: ${reward.amount} dumplings. Claims paused until server support is available">${actionLabel}</button></article>`;
    }).join('');
    $('streakCycleLabel').textContent = `Day ${dayInCycle || 1} of ${cycleLength}`;
    const tasks = [
      { id:'login', title:'Visit the kitchen', description:'Your daily login reward is added automatically.', reward:firstVisitToday ? 0 : rules.DAILY_TASK_REWARDS.login, progress:state.dailyTasks.login.progress, claimed:state.dailyTasks.login.claimed, goal:1, auto:true },
      { id:'cook', title:'Start a batch', description:'Put a pot of dumplings on the stove.', reward:rules.DAILY_TASK_REWARDS.cook, progress:state.dailyTasks.cook.progress, claimed:state.dailyTasks.cook.claimed, goal:1 },
      { id:'collect', title:'Collect a fresh batch', description:'Finish cooking and collect one batch today.', reward:5, progress:state.dailyTasks.collect.progress, claimed:state.dailyTasks.collect.claimed, goal:1 },
      { id:'collect-dumplings', title:'Gather 30 dumplings', description:'Collect at least 30 dumplings from finished batches today.', reward:10, progress:state.dailyTasks['collect-dumplings'].progress, claimed:state.dailyTasks['collect-dumplings'].claimed, goal:30 },
      { id:'upgrade', title:'Improve your kitchen', description:'Buy one kitchen upgrade today.', reward:rules.DAILY_TASK_REWARDS.upgrade, progress:state.dailyTasks.upgrade.progress, claimed:state.dailyTasks.upgrade.claimed, goal:1 }
    ];
    if (capacity() === 2) tasks.push({ id:'two-pots', title:'Use both pots', description:'Start one cooking batch in each pot today.', reward:5, progress:state.dailyTasks['two-pots'].progress, claimed:state.dailyTasks['two-pots'].claimed, goal:1 });
    const nextLevel = Array.from({ length: 9 }, (_, index) => index + 2).find(level => !state.levelClaims.includes(level));
    if (nextLevel) {
      const threshold = rules.LEVEL_THRESHOLDS[nextLevel - 1];
      tasks.push({ id:`level-${nextLevel}`, title:`Reach level ${nextLevel}`, description:`Reach ${threshold.toLocaleString('en-US')} total score to reach level ${nextLevel}.`, reward:rules.levelReward(nextLevel), progress:Math.min(state.score, threshold), claimed:false, goal:threshold, levelTask:true });
    }
    $('taskList').innerHTML = tasks.map(task => {
      const complete = task.progress >= task.goal;
      const label = task.claimed ? task.auto ? 'Added today' : 'Collected' : complete ? 'Collect reward' : `${task.progress}/${task.goal}`;
      const progressPercent = Math.min(100, task.progress / task.goal * 100);
      const progressLabel = task.levelTask ? `${task.progress.toLocaleString('en-US')} / ${task.goal.toLocaleString('en-US')} total score` : complete ? task.claimed ? 'Reward collected' : 'Complete · reward ready' : `${task.progress.toLocaleString('en-US')} / ${task.goal.toLocaleString('en-US')}`;
      return `<article class="task-card ${task.claimed || complete ? 'task-complete' : ''}"><div class="task-icon">${task.levelTask ? '★' : task.id === 'login' ? '↗' : task.id === 'cook' ? '♨' : task.id === 'upgrade' ? '✦' : '✓'}</div><div class="task-copy"><span class="task-tag">${task.levelTask ? 'LEVEL MILESTONE' : `DAILY · ${utcDateLabel()}`}</span><h2>${task.title}</h2><p>${task.description}</p><div class="task-progress"><span style="width:${progressPercent}%"></span></div><small>${progressLabel}</small></div><div class="task-reward"><b>+${task.reward}</b><small>dumplings</small><button class="task-claim" type="button" data-claim-task="${task.id}" ${task.claimed || !complete || task.auto ? 'disabled' : ''}>${label}</button></div></article>`;
    }).join('');
    $('taskDot').hidden = !tasks.some(task => task.progress >= task.goal && !task.claimed && !task.auto);
  }
  function renderAchievements() {
    $('achievementList').innerHTML = achievementDefinitions.map(item => {
      const unlocked = state.achievements.includes(item.id);
      const progress = Math.min(item.goal, item.progress());
      return `<article class="achievement-card ${unlocked ? 'unlocked' : ''}"><span class="achievement-icon">${unlocked ? '✦' : '○'}</span><div><h3>${item.title}</h3><p>${item.description}</p><small class="achievement-progress">${unlocked ? 'Milestone earned' : `${progress.toLocaleString('en-US')} / ${item.goal.toLocaleString('en-US')}`}</small></div><small>${unlocked ? 'UNLOCKED' : 'LOCKED'}</small></article>`;
    }).join('');
  }
  function updateBatchFields() {
    const batches = state.activeBatches;
    const ready = firstReadyBatch();
    const secondUnlocked = capacity() === 2 || Boolean(batchForPot(2));
    const art = $('kitchenArt');
    art.classList.toggle('second-pot-unlocked', secondUnlocked);
    art.classList.toggle('cooking', batches.some(batch => Date.now() < batch.endsAt));
    art.classList.toggle('ready', Boolean(ready));
    for (const pot of [1, 2]) {
      const batch = batchForPot(pot);
      const isReady = Boolean(batch && Date.now() >= batch.endsAt);
      const isCooking = Boolean(batch && !isReady);
      art.classList.toggle(`pot-${pot}-cooking`, isCooking);
      art.classList.toggle(`pot-${pot}-ready`, isReady);
      const potArt = art.querySelector(pot === 1 ? '.main-pot' : '.second-pot-art');
      const lid = potArt?.querySelector('.pot-lid');
      const dumplings = potArt?.querySelector('.dumplings');
      const steam = potArt?.querySelector('.steam-svg');
      const visualState = isCooking ? 'cooking' : isReady ? 'ready' : 'empty';
      if (potArt) potArt.classList.toggle('burner-on', isCooking);
      if (potArt && potArt.dataset.visualState !== visualState) {
        potArt.dataset.visualState = visualState;
        if (lid) lid.style.animation = isCooking ? 'lidBoil .55s ease-in-out infinite' : 'none';
      }
      if (lid) {
        lid.style.display = isCooking ? 'inline' : 'none';
        lid.style.visibility = isCooking ? 'visible' : 'hidden';
        lid.style.opacity = isCooking ? '1' : '0';
      }
      if (dumplings) {
        dumplings.style.visibility = isReady ? 'visible' : 'hidden';
        dumplings.style.opacity = isReady ? '1' : '0';
      }
      if (steam) {
        steam.style.display = isReady ? 'inline' : 'none';
        steam.style.visibility = isReady ? 'visible' : 'hidden';
      }
      const button = pot === 1 ? $('cookButton') : $('cookButton2');
      const label = pot === 1 ? $('buttonText') : $('buttonText2');
      if (pot === 2) button.hidden = !secondUnlocked;
      if (secondUnlocked) label.textContent = isReady ? `Collect Pot ${pot}` : isCooking ? `Cooking · ${formatTime(batch.endsAt - Date.now())}` : `Start Pot ${pot}`;
      else if (pot === 1) label.textContent = isReady ? 'Collect dumplings' : isCooking ? `Cooking · ${formatTime(batch.endsAt - Date.now())}` : 'Start cooking';
      button.disabled = isCooking || (pot === 2 && !secondUnlocked);
      button.setAttribute('aria-label', isReady ? `Collect dumplings from pot ${pot}` : isCooking ? `Pot ${pot} is cooking` : `Start cooking in pot ${pot}`);
    }
    $('cookActions').classList.toggle('two-pots', secondUnlocked);
    $('gameCard').classList.toggle('cooking', batches.some(batch => Date.now() < batch.endsAt));
    $('gameCard').classList.toggle('ready', Boolean(ready));
    $('statusText').textContent = ready ? `Pot ${ready.pot} is ready to collect` : batches.length ? `${batches.length} ${batches.length === 1 ? 'pot is' : 'pots are'} cooking` : 'Kitchen is ready';
    $('artStatus').textContent = ready ? `POT ${ready.pot} · READY TO COLLECT` : batches.length ? 'POT ON · GOOD THINGS TAKE TIME' : 'FRESH FROM THE KITCHEN';
    $('batchTag').textContent = ready ? `POT ${ready.pot} · READY` : batches.length ? `COOKING · ${batches.length}/${capacity()}` : 'NEW BATCH';
    $('timerLabel').textContent = ready ? `POT ${ready.pot} COMPLETE` : batches.length ? 'TIME LEFT · NEXT POT' : 'COOKING TIME';
    const displayBatch = ready || batches.filter(batch => Date.now() < batch.endsAt).sort((a,b) => a.endsAt-b.endsAt)[0];
    $('timer').textContent = ready ? 'READY!' : displayBatch ? formatTime(displayBatch.endsAt - Date.now()) : formatTime(cookDurationMs());
    $('progress').style.width = ready ? '100%' : displayBatch ? `${Math.min(100, Math.max(0, (Date.now() - displayBatch.startedAt) / displayBatch.durationMs * 100))}%` : '0%';
    $('cookHint').textContent = ready ? `Pot ${ready.pot} is ready. Collect its dumplings with the matching button.` : batches.length >= capacity() ? 'Both pots are cooking. Collect a batch when it is ready.' : batches.length ? 'The other pot is free. Start a batch there while this one cooks.' : `A fresh batch takes ${formatTime(cookDurationMs())}. You can close the app and return later.`;
    const range = rules.batchDumplingRange(state.upgradeLevels, (state.equipped.includes('herb-pot') ? 2 : 0) + (state.equipped.includes('wooden-spoon') ? 3 : 0));
    $('rewardNote').innerHTML = `<span>✦</span> <b>${range.min}–${range.max} dumplings</b> per batch`;
    $('activeBatchList').innerHTML = '';
  }
  function render() {
    $('balance').textContent = state.balance.toLocaleString('en-US');
    $('overallScore').textContent = state.score.toLocaleString('en-US');
    $('upgradeBalance').textContent = state.balance.toLocaleString('en-US');
    $('leaderScore').textContent = `${state.score.toLocaleString('en-US')} points`;
    $('batches').textContent = state.batches.toLocaleString('en-US');
    $('playerName').textContent = telegramUser ? (telegramUser.first_name || telegramUser.username || 'Telegram Chef') : 'Little Chef';
    $('accountStatus').textContent = telegramUser ? `TELEGRAM · @${telegramUser.username || 'CHEF'}` : 'LOCAL DEMO · THIS DEVICE';
    $('profileBalance').textContent = state.balance.toLocaleString('en-US');
    $('profileScore').textContent = state.score.toLocaleString('en-US');
    $('profileBatches').textContent = state.batches.toLocaleString('en-US');
    $('profileKitchenLevel').textContent = rules.playerLevel(state.score);
    $('profileUpgradeCount').textContent = totalUpgradeLevels() + state.upgrades.length;
    $('joinedDate').textContent = state.joinedAt ? new Intl.DateTimeFormat('en', { dateStyle: 'medium' }).format(new Date(state.joinedAt)) : 'Today';
    $('kitchenLevel').textContent = `PLAYER LEVEL ${rules.playerLevel(state.score)}`;
    $('kitchenLevelBanner').textContent = `COZY KITCHEN · LEVEL ${rules.playerLevel(state.score)}`;
    $('seasonTitle').textContent = state.lastBatchReward ? `Last batch · ${state.lastBatchReward.dumplings} dumplings` : 'Your kitchen story starts here';
    $('lastBatchText').textContent = state.lastBatchReward ? `Last batch: +${state.lastBatchReward.dumplings} dumplings.` : 'Your first batch is waiting to be cooked.';
    $('kitchenArt').classList.toggle('decor-herb-pot', state.equipped.includes('herb-pot'));
    $('kitchenArt').classList.toggle('decor-blue-tile', state.equipped.includes('blue-tile'));
    $('kitchenArt').classList.toggle('decor-wooden-spoon', state.equipped.includes('wooden-spoon'));
    updateBatchFields();
    renderLevelledUpgrades(); renderDailyTasks(); renderAchievements();
  }
  function startBatch(pot = 1) {
    if (pot > capacity() || batchForPot(pot)) return false;
    const startedAt = Date.now();
    const durationMs = cookDurationMs();
    const id = globalThis.crypto?.randomUUID ? crypto.randomUUID() : `batch-${startedAt}-${Math.random().toString(36).slice(2, 8)}`;
    state.activeBatches.push({ id, pot, startedAt, endsAt: startedAt + durationMs, durationMs });
    state.activeBatches.sort((a, b) => a.pot - b.pot);
    syncLegacyBatchFields();
    markTaskProgress('cook');
    if (capacity() === 2) {
      state.taskPotsUsed = [...new Set([...state.taskPotsUsed, pot])];
      if (state.taskPotsUsed.includes(1) && state.taskPotsUsed.includes(2)) state.dailyTasks['two-pots'].progress = 1;
    }
    saveState(); render(); toast('The pot is on. See you when it is ready!');
    return true;
  }
  function syncLegacyBatchFields() {
    const primary = batchForPot(1) || state.activeBatches[0] || null;
    state.startedAt = primary?.startedAt ?? null;
    state.endsAt = primary?.endsAt ?? null;
    state.batchDurationMs = primary?.durationMs ?? null;
  }
  function collectBatch(id) {
    const batch = state.activeBatches.find(item => item.id === id);
    if (!batch || Date.now() < batch.endsAt) return false;
    const oldBonus = (state.equipped.includes('herb-pot') ? 2 : 0) + (state.equipped.includes('wooden-spoon') ? 3 : 0);
    const reward = rules.batchDumplingReward(10 + Math.floor(Math.random() * 6), state.upgradeLevels, oldBonus);
    addDumplings(reward);
    state.batches++;
    state.taskBatches++;
    markTaskProgress('collect');
    markTaskProgress('collect-dumplings', reward);
    state.potCollections[batch.pot] = Math.min(1_000_000, state.potCollections[batch.pot] + 1);
    state.lastBatchReward = { dumplings: reward };
    state.lastBatchAt = new Date().toISOString();
    state.activeBatches = state.activeBatches.filter(item => item.id !== id);
    syncLegacyBatchFields();
    const unlocked = ensureAchievements(); saveState(); render();
    toast(`Collected ${reward} dumplings.`);
    scheduleAchievementNotice(unlocked);
    return true;
  }
  function usePot(pot) {
    const batch = batchForPot(pot);
    if (batch) {
      if (Date.now() >= batch.endsAt) collectBatch(batch.id);
      return;
    }
    startBatch(pot);
  }
  $('cookButton').addEventListener('click', () => usePot(1));
  $('cookButton2').addEventListener('click', () => usePot(2));
  $('activeBatchList').addEventListener('click', event => {
    const button = event.target.closest('[data-collect-batch]');
    if (button) collectBatch(button.dataset.collectBatch);
  });
  $('upgradeList').addEventListener('click', event => {
    const levelButton = event.target.closest('[data-level-upgrade]');
    if (levelButton) {
      const definition = rules.UPGRADE_DEFINITIONS.find(item => item.id === levelButton.dataset.levelUpgrade);
      if (!definition) return;
      const quote = rules.upgradePurchaseQuote(state, definition);
      if (!quote.allowed) {
        if (quote.reason === 'insufficient-dumplings') toast(`You need ${quote.cost - state.balance} more dumplings.`);
        return;
      }
      state.balance -= quote.cost;
      state.upgradeLevels[definition.id] = quote.level + 1;
      markTaskProgress('upgrade'); const unlocked = ensureAchievements(); saveState(); render(); toast(`${definition.name} upgraded to level ${quote.level + 1}.`); scheduleAchievementNotice(unlocked);
      return;
    }
    const legacyButton = event.target.closest('[data-upgrade]');
    if (!legacyButton) return;
    const item = { 'herb-pot': ['Fresh herb pots',20], 'blue-tile': ['Blue kitchen tiles',35], 'wooden-spoon': ['Carved wooden spoon',50], 'second-pot': ['Second Pot',1000] }[legacyButton.dataset.upgrade];
    if (!item) return;
    const id = legacyButton.dataset.upgrade;
    if (state.upgrades.includes(id)) {
      const removing = state.equipped.includes(id);
      state.equipped = removing ? state.equipped.filter(value => value !== id) : [...state.equipped, id];
      saveState(); render(); toast(removing ? 'Decoration removed.' : 'Decoration equipped.'); return;
    }
    if (state.balance < item[1]) return;
    state.balance -= item[1]; state.upgrades.push(id); state.equipped.push(id);
    markTaskProgress('upgrade'); const unlocked = ensureAchievements(); saveState(); render(); toast(`${item[0]} added to your kitchen.`); scheduleAchievementNotice(unlocked);
  });
  $('taskList').addEventListener('click', event => {
    const button = event.target.closest('[data-claim-task]');
    if (!button) return;
    const id = button.dataset.claimTask;
    const task = state.dailyTasks[id];
    if (id.startsWith('level-')) {
      const level = Number(id.slice('level-'.length));
      const threshold = rules.LEVEL_THRESHOLDS[level - 1];
      if (!Number.isSafeInteger(level) || level < 2 || level > 10 || state.levelClaims.includes(level) || state.score < threshold) return;
      state.levelClaims.push(level);
      const reward = rules.levelReward(level);
      addDumplings(reward, false);
      saveState(); render(); toast(`Level ${level} reward: +${reward} dumplings.`);
      return;
    }
    const rewards = { cook: rules.DAILY_TASK_REWARDS.cook, upgrade: rules.DAILY_TASK_REWARDS.upgrade, collect: 5, 'collect-dumplings': 10, 'two-pots': 5 };
    if (!task || !rules.taskClaimAllowed({ ...task, goal: id === 'collect-dumplings' ? 30 : 1 }) || !rewards[id]) return;
    task.claimed = true; addDumplings(rewards[id]);
    if (id === 'cook') { state.taskClaimedOn = nowDay(); state.taskBalanceRewardVersion = 1; }
    saveState(); render(); toast(`Daily task complete: +${rewards[id]} dumplings.`);
  });
  document.querySelectorAll('.nav-item').forEach(button => button.addEventListener('click', () => {
    const tab = button.dataset.tab;
    document.querySelectorAll('.nav-item').forEach(item => item.classList.toggle('selected', item === button));
    document.querySelectorAll('.screen').forEach(screen => screen.classList.toggle('active', screen.dataset.screen === tab));
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }));
  const THEME_KEY = 'pelmeni-clicker-theme';
  function applyTheme(theme, persist = false) {
    const scheme = theme === 'light' ? 'light' : 'dark';
    document.body.dataset.theme = scheme;
    document.documentElement.style.colorScheme = scheme;
    const button = $('themeToggle');
    if (button) {
      button.textContent = scheme === 'dark' ? '☼ Light' : '☾ Dark';
      button.setAttribute('aria-label', `Switch to ${scheme === 'dark' ? 'light' : 'dark'} theme`);
      button.setAttribute('aria-pressed', String(scheme === 'light'));
    }
    if (persist) { try { localStorage.setItem(THEME_KEY, scheme); } catch (error) { console.warn('[Pelmeni Clicker] Theme preference could not be saved.', error); } }
  }
  try {
    if (typeof telegramWebApp?.ready === 'function') telegramWebApp.ready();
    if (typeof telegramWebApp?.expand === 'function') telegramWebApp.expand();
    applyTheme(localStorage.getItem(THEME_KEY) === 'light' ? 'light' : 'dark');
  } catch (error) { console.warn('[Pelmeni Clicker] Telegram theme setup skipped.', error); }
  $('themeToggle').addEventListener('click', () => applyTheme(document.body.dataset.theme === 'dark' ? 'light' : 'dark', true));
  initializeState();
  setInterval(() => {
    if (!stateReady) return;
    const today = nowDay();
    if (rules.validUtcDay(today) && (!rules.validUtcDay(state.dailyDate) || today > state.dailyDate)) {
      applyDailyState(); ensureAchievements(); saveState(); render();
    } else updateBatchFields();
  }, 1000);
})();

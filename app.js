(() => {
  const CLOUD_URL = 'https://qcagyjlsqlihdcdbxgxc.supabase.co/functions/v1/quick-function';
  const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_ejIIlpOGM6SViZ_ZcYYi-g_tDChykDP';
  const LEGACY_STORAGE_KEY = 'pelmeni-clicker-mini-v2';
  const legacyUpgradeIds = ['herb-pot', 'blue-tile', 'wooden-spoon'];
  const telegramWebApp = window.Telegram?.WebApp;
  const telegramInitData = typeof telegramWebApp?.initData === 'string' ? telegramWebApp.initData : '';
  const telegramUser = telegramWebApp?.initDataUnsafe?.user || null;
  const telegramUserId = Number.isSafeInteger(telegramUser?.id) && telegramUser.id > 0 ? telegramUser.id : null;
  const STORAGE_KEY = telegramUserId ? `${LEGACY_STORAGE_KEY}:telegram:${telegramUserId}` : LEGACY_STORAGE_KEY;
  const $ = id => document.getElementById(id);
  const safeInt = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
  const nowDay = () => new Date().toISOString().slice(0, 10);
  const emptyDailyTasks = () => ({ cook: { progress: 0, claimed: false }, upgrade: { progress: 0, claimed: false } });
  const freshState = () => ({
    balance: 0, score: 0, points: 0, pointsRetired: true, batches: 0, startedAt: null, endsAt: null, batchDurationMs: null,
    activeBatches: [], upgrades: [], equipped: [], upgradeLevels: {}, taskDay: nowDay(), taskBatches: 0,
    taskClaimedOn: null, taskBalanceRewardVersion: 1, referralCode: null, dailyDate: nowDay(),
    dailyTasks: emptyDailyTasks(), loginRewardDate: null, tapDate: nowDay(), tapCount: 0, achievements: [],
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
    const currentLevels = {};
    for (const item of rules.UPGRADE_DEFINITIONS) {
      const level = safeInt(saved.upgradeLevels?.[item.id]);
      currentLevels[item.id] = Math.min(item.maxLevel, level);
    }
    let activeBatches = [];
    if (Array.isArray(saved.activeBatches)) {
      activeBatches = saved.activeBatches.filter(batch => batch && typeof batch.id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(batch.id) && Number.isFinite(batch.startedAt) && Number.isFinite(batch.endsAt) && batch.endsAt > batch.startedAt)
        .slice(0, currentLevels['second-pot'] ? 2 : 1)
        .map(batch => {
          const savedDuration = safeInt(batch.durationMs) || batch.endsAt - batch.startedAt;
          const durationMs = savedDuration > rules.BASE_COOK_MS ? rules.BASE_COOK_MS : savedDuration;
          return { id: batch.id, startedAt: batch.startedAt, endsAt: batch.startedAt + durationMs, durationMs };
        });
    } else if (Number.isFinite(saved.startedAt) && Number.isFinite(saved.endsAt) && saved.endsAt > saved.startedAt) {
      const savedDuration = safeInt(saved.batchDurationMs) || saved.endsAt - saved.startedAt;
      const durationMs = savedDuration > rules.BASE_COOK_MS ? rules.BASE_COOK_MS : savedDuration;
      activeBatches = [{ id: 'legacy-batch', startedAt: saved.startedAt, endsAt: saved.startedAt + durationMs, durationMs }];
    }
    const dailyTasks = emptyDailyTasks();
    for (const id of ['cook', 'upgrade']) {
      const oldTask = saved.dailyTasks?.[id];
      if (oldTask && typeof oldTask === 'object') dailyTasks[id] = { progress: Math.min(1, safeInt(oldTask.progress)), claimed: oldTask.claimed === true };
    }
    if (!saved.dailyTasks && safeInt(saved.taskBatches) > 0) dailyTasks.cook.progress = 1;
    if (!saved.dailyTasks && saved.taskClaimedOn === nowDay()) dailyTasks.cook.claimed = true;
    return {
      balance: safeInt(saved.balance) + (saved.taskClaimedOn === nowDay() && saved.taskBalanceRewardVersion !== 1 ? 5 : 0) + (saved.pointsRetired === true ? 0 : (saved.points === undefined ? safeInt(saved.score) : safeInt(saved.points))),
      score: safeInt(saved.score), points: 0, pointsRetired: true,
      batches: safeInt(saved.batches), startedAt: activeBatches[0]?.startedAt ?? (Number.isFinite(saved.startedAt) ? saved.startedAt : null),
      endsAt: activeBatches[0]?.endsAt ?? (Number.isFinite(saved.endsAt) ? saved.endsAt : null),
      batchDurationMs: activeBatches[0]?.durationMs ?? (safeInt(saved.batchDurationMs) || null), activeBatches,
      upgrades: ownedLegacy, equipped: Array.isArray(saved.equipped) ? saved.equipped.filter(id => ownedLegacy.includes(id)) : [...ownedLegacy],
      upgradeLevels: currentLevels, taskDay: typeof saved.taskDay === 'string' ? saved.taskDay : nowDay(),
      taskBatches: safeInt(saved.taskBatches), taskClaimedOn: typeof saved.taskClaimedOn === 'string' ? saved.taskClaimedOn : null,
      taskBalanceRewardVersion: 1,
      referralCode: typeof saved.referralCode === 'string' && /^PC-[A-Z0-9]{6}$/.test(saved.referralCode) ? saved.referralCode : null,
      dailyDate: typeof saved.dailyDate === 'string' ? saved.dailyDate : (typeof saved.taskDay === 'string' ? saved.taskDay : null),
      dailyTasks, loginRewardDate: typeof saved.loginRewardDate === 'string' ? saved.loginRewardDate : null,
      tapDate: typeof saved.tapDate === 'string' ? saved.tapDate : nowDay(), tapCount: safeInt(saved.tapCount),
      achievements: Array.isArray(saved.achievements) ? [...new Set(saved.achievements.filter(id => ['first-batch','score-1000','five-batches','first-upgrade','master-kitchen'].includes(id)))] : [],
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
      taskClaimedOn: state.taskClaimedOn, taskBalanceRewardVersion: state.taskBalanceRewardVersion,
      referralCode: state.referralCode, dailyDate: state.dailyDate, dailyTasks: JSON.parse(JSON.stringify(state.dailyTasks)),
      loginRewardDate: state.loginRewardDate, tapDate: state.tapDate, tapCount: state.tapCount,
      achievements: [...state.achievements], joinedAt: state.joinedAt, lastBatchReward: state.lastBatchReward,
      lastBatchAt: state.lastBatchAt, schemaVersion: 3
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
  function capacity() { return state.upgradeLevels['second-pot'] > 0 ? 2 : 1; }
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
    if (state.dailyDate !== today) {
      state.dailyDate = today;
      state.dailyTasks = emptyDailyTasks();
      state.loginRewardDate = null;
      state.tapDate = today;
      state.tapCount = 0;
      state.taskDay = today;
      state.taskBatches = 0;
      state.taskClaimedOn = null;
    }
    if (state.tapDate !== today) { state.tapDate = today; state.tapCount = 0; }
    if (state.loginRewardDate !== today) {
      state.balance += 50; state.loginRewardDate = today;
      state.dailyTasks.login = { progress: 1, claimed: true };
      toast('Daily login reward: +50 dumplings.');
    } else {
      state.dailyTasks.login = { progress: 1, claimed: true };
    }
    if (state.dailyTasks.cook?.progress) state.taskBatches = Math.max(1, state.taskBatches);
  }
  const achievementDefinitions = [
    { id: 'first-batch', title: 'First batch', description: 'Collect your first pot of dumplings.', achieved: () => state.batches >= 1 },
    { id: 'score-1000', title: 'Kitchen regular', description: 'Collect 1,000 dumplings over time.', achieved: () => state.batches >= 100 },
    { id: 'five-batches', title: 'Five batches', description: 'Collect five batches.', achieved: () => state.batches >= 5 },
    { id: 'first-upgrade', title: 'First upgrade', description: 'Improve your kitchen for the first time.', achieved: () => totalUpgradeLevels() > 0 || state.upgrades.length > 0 },
    { id: 'master-kitchen', title: 'Master kitchen', description: 'Reach kitchen level 6.', achieved: () => rules.kitchenLevel(state.upgradeLevels) >= 6 }
  ];
  function totalUpgradeLevels() { return Object.values(state.upgradeLevels).reduce((sum, value) => sum + safeInt(value), 0); }
  function ensureAchievements() {
    let changed = false;
    for (const definition of achievementDefinitions) if (definition.achieved() && !state.achievements.includes(definition.id)) { state.achievements.push(definition.id); changed = true; }
    if (changed) saveLocalState();
  }
  function addDumplings(amount) { state.balance += amount; }
  function markTaskProgress(id) { state.dailyTasks[id].progress = 1; }
  function renderLevelledUpgrades() {
    const container = $('upgradeList');
    const cards = rules.UPGRADE_DEFINITIONS.map(item => {
      const level = state.upgradeLevels[item.id] || 0;
      const maxed = level >= item.maxLevel;
      const cost = maxed ? 0 : rules.upgradeCost(item, level);
      const enough = state.balance >= cost;
      const buttonLabel = maxed ? 'MAX LEVEL' : enough ? `Upgrade · ${cost} dumplings` : `Need ${cost} dumplings`;
      return `<article class="upgrade-card level-card"><div class="upgrade-art"><span>${item.id === 'good-stove' ? '♨' : item.id === 'large-pot' ? '◉' : item.id === 'grandma-recipe' ? '✿' : item.id === 'fast-shaping' ? '✋' : '♨♨'}</span></div><div class="upgrade-copy"><div class="upgrade-title-row"><h2>${item.name}</h2><span class="level-pill">Lv. ${level}/${item.maxLevel}</span></div><p>${item.description}</p><small class="upgrade-effect">${item.effect(level)}${!maxed ? ` · Next: ${item.effect(level + 1)}` : ' · Max level reached'}</small><small class="upgrade-affordability">${maxed ? 'Fully upgraded' : enough ? 'Ready to upgrade' : `You have ${state.balance} dumplings`}</small></div><button class="upgrade-button" data-level-upgrade="${item.id}" type="button" ${maxed || !enough ? 'disabled' : ''}>${buttonLabel}</button></article>`;
    }).join('');
    const legacy = [
      { id:'herb-pot', name:'Fresh herb pots', desc:'+2 dumplings with every collected batch.', effect:'+2 dumplings / batch', cost:20, icon:'✿' },
      { id:'blue-tile', name:'Blue kitchen tiles', desc:'Keep your original decorative upgrade.', effect:'Kitchen decoration', cost:35, icon:'▦' },
      { id:'wooden-spoon', name:'Carved wooden spoon', desc:'+3 dumplings and a tiny cook-time bonus.', effect:'+3 dumplings / batch', cost:50, icon:'⌁' }
    ].map(item => {
      const owned = state.upgrades.includes(item.id);
      const equipped = state.equipped.includes(item.id);
      return `<article class="upgrade-card legacy-card ${equipped ? 'equipped' : ''}"><div class="upgrade-art"><span>${item.icon}</span></div><div class="upgrade-copy"><h2>${item.name}</h2><p>${item.desc}</p><small class="upgrade-effect">${item.effect}</small></div><button class="upgrade-button" data-upgrade="${item.id}" type="button" ${!owned && state.balance < item.cost ? 'disabled' : ''}>${owned ? equipped ? 'REMOVE' : 'EQUIP' : `Get · ${item.cost} dumplings`}</button></article>`;
    }).join('');
    container.innerHTML = `<div class="upgrade-section-label">Kitchen upgrades <span>Spend dumplings</span></div>${cards}<div class="upgrade-section-label legacy-label">Your original decorations <span>Existing purchases kept</span></div>${legacy}`;
  }
  function renderDailyTasks() {
    const tasks = [
      { id:'login', title:'Visit the kitchen', description:'Daily dumpling reward. Added automatically on your first visit.', reward:50, progress:state.dailyTasks.login.progress, claimed:state.dailyTasks.login.claimed, goal:1, auto:true },
      { id:'cook', title:'Start a batch', description:'Put a pot of dumplings on the stove.', reward:100, progress:state.dailyTasks.cook.progress, claimed:state.dailyTasks.cook.claimed, goal:1 },
      { id:'upgrade', title:'Improve your kitchen', description:'Buy one kitchen upgrade today.', reward:150, progress:state.dailyTasks.upgrade.progress, claimed:state.dailyTasks.upgrade.claimed, goal:1 }
    ];
    $('taskList').innerHTML = tasks.map(task => {
      const complete = task.progress >= task.goal;
      const label = task.claimed ? task.auto ? 'Added today' : 'Collected' : complete ? 'Collect reward' : `${task.progress}/${task.goal}`;
      return `<article class="task-card ${task.claimed ? 'task-complete' : ''}"><div class="task-icon">${task.id === 'login' ? '↗' : task.id === 'cook' ? '♨' : '✦'}</div><div class="task-copy"><span class="task-tag">DAILY · ${utcDateLabel()}</span><h2>${task.title}</h2><p>${task.description}</p><div class="task-progress"><span style="width:${complete ? 100 : 0}%"></span></div><small>${complete ? 'Complete' : 'In progress'}</small></div><div class="task-reward"><b>+${task.reward}</b><small>dumplings</small><button class="task-claim" type="button" data-claim-task="${task.id}" ${task.claimed || !complete || task.auto ? 'disabled' : ''}>${label}</button></div></article>`;
    }).join('');
    $('taskDot').hidden = !tasks.some(task => task.progress >= task.goal && !task.claimed && !task.auto);
  }
  function renderAchievements() {
    $('achievementList').innerHTML = achievementDefinitions.map(item => {
      const unlocked = state.achievements.includes(item.id);
      return `<article class="achievement-card ${unlocked ? 'unlocked' : ''}"><span class="achievement-icon">${unlocked ? '✦' : '○'}</span><div><h3>${item.title}</h3><p>${item.description}</p></div><small>${unlocked ? 'UNLOCKED' : 'LOCKED'}</small></article>`;
    }).join('');
  }
  function updateBatchFields() {
    const batches = state.activeBatches;
    const primary = batches[0] || null;
    const ready = firstReadyBatch();
    const active = primary && Date.now() < primary.endsAt;
    $('kitchenArt').classList.toggle('cooking', Boolean(active));
    $('kitchenArt').classList.toggle('ready', Boolean(ready));
    $('gameCard').classList.toggle('cooking', Boolean(active));
    $('gameCard').classList.toggle('ready', Boolean(ready));
    $('statusText').textContent = ready ? 'A batch is ready to collect' : batches.length ? 'Dumplings are bubbling' : 'Kitchen is ready';
    $('artStatus').textContent = ready ? 'FRESHLY COOKED FOR YOU' : batches.length ? 'POT ON · GOOD THINGS TAKE TIME' : 'FRESH FROM THE KITCHEN';
    $('batchTag').textContent = ready ? 'READY' : batches.length ? `COOKING · ${batches.length}/${capacity()}` : 'NEW BATCH';
    $('timerLabel').textContent = ready ? 'BATCH COMPLETE' : batches.length ? 'TIME LEFT · NEXT POT' : 'COOKING TIME';
    const displayBatch = ready || batches.filter(batch => Date.now() < batch.endsAt).sort((a,b) => a.endsAt-b.endsAt)[0];
    $('timer').textContent = ready ? 'READY!' : displayBatch ? formatTime(displayBatch.endsAt - Date.now()) : formatTime(cookDurationMs());
    $('progress').style.width = ready ? '100%' : displayBatch ? `${Math.min(100, Math.max(0, (Date.now() - displayBatch.startedAt) / displayBatch.durationMs * 100))}%` : '0%';
    $('cookHint').textContent = ready ? 'Your batch is ready. Collect it to add the rewards.' : batches.length >= capacity() ? 'Your kitchen is full. Come back when a pot is ready.' : batches.length ? `Start another batch in pot ${batches.length + 1}, or come back when this one is ready.` : `A fresh batch takes ${formatTime(cookDurationMs())}. You can close the app and return later.`;
    $('buttonText').textContent = ready ? 'Collect dumplings' : batches.length < capacity() ? `Start cooking${capacity() === 2 && batches.length === 1 ? ' · Pot 2' : ''}` : 'Cooking…';
    $('cookButton').disabled = !ready && batches.length >= capacity();
    $('rewardNote').innerHTML = `<span>✦</span> <b>10–15 dumplings</b> per batch · Tap the pot for extra dumplings`;
    $('activeBatchList').innerHTML = batches.slice(1).map((batch, index) => {
      const isReady = Date.now() >= batch.endsAt;
      return `<article class="active-batch"><span>Pot ${index + 2}</span><strong>${isReady ? 'Ready to collect' : formatTime(batch.endsAt - Date.now())}</strong><button data-collect-batch="${batch.id}" type="button" ${isReady ? '' : 'disabled'}>${isReady ? 'Collect' : 'Cooking'}</button></article>`;
    }).join('');
    $('tapCount').textContent = `${Math.max(0, rules.MAX_TAPS_PER_DAY - state.tapCount)} pot taps left today`;
  }
  function render() {
    $('balance').textContent = state.balance.toLocaleString('en-US');
    $('dumplingStat').textContent = state.balance.toLocaleString('en-US');
    $('upgradePoints').textContent = state.balance.toLocaleString('en-US');
    $('leaderScore').textContent = `${state.balance.toLocaleString('en-US')} dumplings`;
    $('batches').textContent = state.batches.toLocaleString('en-US');
    $('playerName').textContent = telegramUser ? (telegramUser.first_name || telegramUser.username || 'Telegram Chef') : 'Little Chef';
    $('accountStatus').textContent = telegramUser ? `TELEGRAM · @${telegramUser.username || 'CHEF'}` : 'LOCAL DEMO · THIS DEVICE';
    $('profileBalance').textContent = state.balance.toLocaleString('en-US');
    $('profileBatches').textContent = state.batches.toLocaleString('en-US');
    $('profileKitchenLevel').textContent = rules.kitchenLevel(state.upgradeLevels);
    $('profileUpgradeCount').textContent = totalUpgradeLevels() + state.upgrades.length;
    $('joinedDate').textContent = state.joinedAt ? new Intl.DateTimeFormat('en', { dateStyle: 'medium' }).format(new Date(state.joinedAt)) : 'Today';
    $('kitchenLevel').textContent = `KITCHEN LEVEL ${rules.kitchenLevel(state.upgradeLevels)}`;
    $('kitchenLevelBanner').textContent = `COZY KITCHEN · LEVEL ${rules.kitchenLevel(state.upgradeLevels)}`;
    $('seasonTitle').textContent = state.lastBatchReward ? `Last batch · ${state.lastBatchReward.dumplings} dumplings` : 'Your kitchen story starts here';
    $('lastBatchText').textContent = state.lastBatchReward ? `Last batch: +${state.lastBatchReward.dumplings} dumplings.` : 'Your first batch is waiting to be cooked.';
    $('kitchenArt').classList.toggle('decor-herb-pot', state.equipped.includes('herb-pot'));
    $('kitchenArt').classList.toggle('decor-blue-tile', state.equipped.includes('blue-tile'));
    $('kitchenArt').classList.toggle('decor-wooden-spoon', state.equipped.includes('wooden-spoon'));
    updateBatchFields();
    renderLevelledUpgrades(); renderDailyTasks(); renderAchievements();
  }
  function startBatch() {
    if (state.activeBatches.length >= capacity()) return false;
    const startedAt = Date.now();
    const durationMs = cookDurationMs();
    const id = globalThis.crypto?.randomUUID ? crypto.randomUUID() : `batch-${startedAt}-${Math.random().toString(36).slice(2, 8)}`;
    state.activeBatches.push({ id, startedAt, endsAt: startedAt + durationMs, durationMs });
    syncLegacyBatchFields();
    markTaskProgress('cook');
    saveState(); render(); toast('The pot is on. See you when it is ready!');
    return true;
  }
  function syncLegacyBatchFields() {
    const primary = state.activeBatches[0] || null;
    state.startedAt = primary?.startedAt ?? null;
    state.endsAt = primary?.endsAt ?? null;
    state.batchDurationMs = primary?.durationMs ?? null;
  }
  function collectBatch(id) {
    const batch = state.activeBatches.find(item => item.id === id);
    if (!batch || Date.now() < batch.endsAt) return false;
    const oldBonus = (state.equipped.includes('herb-pot') ? 2 : 0) + (state.equipped.includes('wooden-spoon') ? 3 : 0);
    const reward = rules.batchDumplingReward(10 + Math.floor(Math.random() * 6), state.upgradeLevels, oldBonus);
    state.balance += reward;
    state.batches++;
    state.taskBatches++;
    state.lastBatchReward = { dumplings: reward };
    state.lastBatchAt = new Date().toISOString();
    state.activeBatches = state.activeBatches.filter(item => item.id !== id);
    syncLegacyBatchFields();
    ensureAchievements(); saveState(); render();
    toast(`Collected ${reward} dumplings.`);
    return true;
  }
  $('cookButton').addEventListener('click', () => {
    const ready = firstReadyBatch();
    if (ready) { collectBatch(ready.id); return; }
    startBatch();
  });
  $('activeBatchList').addEventListener('click', event => {
    const button = event.target.closest('[data-collect-batch]');
    if (button) collectBatch(button.dataset.collectBatch);
  });
  $('tapPot').addEventListener('click', () => {
    if (state.tapCount >= rules.MAX_TAPS_PER_DAY) { toast('You have used today’s pot taps. Come back tomorrow!'); return; }
    const reward = rules.tapDumplings(state.upgradeLevels);
    state.tapCount++; addDumplings(reward); saveState(); render();
    $('tapFeedback').textContent = `+${reward}`; $('tapFeedback').classList.remove('tap-pop'); void $('tapFeedback').offsetWidth; $('tapFeedback').classList.add('tap-pop');
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
      markTaskProgress('upgrade'); ensureAchievements(); saveState(); render(); toast(`${definition.name} upgraded to level ${quote.level + 1}.`);
      return;
    }
    const legacyButton = event.target.closest('[data-upgrade]');
    if (!legacyButton) return;
    const item = { 'herb-pot': ['Fresh herb pots',20], 'blue-tile': ['Blue kitchen tiles',35], 'wooden-spoon': ['Carved wooden spoon',50] }[legacyButton.dataset.upgrade];
    if (!item) return;
    const id = legacyButton.dataset.upgrade;
    if (state.upgrades.includes(id)) {
      const removing = state.equipped.includes(id);
      state.equipped = removing ? state.equipped.filter(value => value !== id) : [...state.equipped, id];
      saveState(); render(); toast(removing ? 'Decoration removed.' : 'Decoration equipped.'); return;
    }
    if (state.balance < item[1]) return;
    state.balance -= item[1]; state.upgrades.push(id); state.equipped.push(id);
    markTaskProgress('upgrade'); ensureAchievements(); saveState(); render(); toast(`${item[0]} added to your kitchen.`);
  });
  $('taskList').addEventListener('click', event => {
    const button = event.target.closest('[data-claim-task]');
    if (!button) return;
    const id = button.dataset.claimTask;
    const task = state.dailyTasks[id];
    const rewards = { cook: 100, upgrade: 150 };
    if (!task || !rules.taskClaimAllowed(task) || !rewards[id]) return;
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
  setInterval(() => { if (stateReady) updateBatchFields(); }, 1000);
})();

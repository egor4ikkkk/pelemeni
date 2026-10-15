(() => {
  const STORAGE_KEY = 'pelmeni-clicker-mini-v2';
  const freshState = () => ({ balance: 0, score: 0, batches: 0, startedAt: null, endsAt: null, batchDurationMs: null, upgrades: [], equipped: [], taskDay: todayKey(), taskBatches: 0, taskClaimedOn: null, referralCode: makeReferralCode() });
  const safeInt = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
  const safeTime = value => Number.isFinite(value) && value > 0 ? value : null;
  const $ = id => document.getElementById(id);
  let state = loadState();
  let toastTimer;

  function loadState() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
      if (!saved || typeof saved !== 'object') return freshState();
      const state = {
        balance: safeInt(saved.balance), score: safeInt(saved.score), batches: safeInt(saved.batches),
        startedAt: safeTime(saved.startedAt), endsAt: safeTime(saved.endsAt),
        batchDurationMs: safeInt(saved.batchDurationMs) || (Number.isFinite(saved.startedAt) && Number.isFinite(saved.endsAt) ? Math.max(1, saved.endsAt - saved.startedAt) : null),
        upgrades: Array.isArray(saved.upgrades) ? saved.upgrades.filter(id => ['herb-pot','blue-tile','wooden-spoon'].includes(id)) : [],
        taskDay: typeof saved.taskDay === 'string' ? saved.taskDay : todayKey(),
        taskBatches: safeInt(saved.taskBatches),
        taskClaimedOn: typeof saved.taskClaimedOn === 'string' ? saved.taskClaimedOn : null,
        referralCode: typeof saved.referralCode === 'string' && /^PC-[A-Z0-9]{6}$/.test(saved.referralCode) ? saved.referralCode : makeReferralCode()
      };
      state.equipped = Array.isArray(saved.equipped)
        ? saved.equipped.filter(id => state.upgrades.includes(id))
        : [...state.upgrades];
      return state;
    } catch { return freshState(); }
  }
  function saveState() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); }
    catch { toast('Could not save your progress on this device.'); }
  }
  function todayKey() {
    const now = new Date();
    return `${now.getFullYear()}-${now.getMonth()+1}-${now.getDate()}`;
  }
  function makeReferralCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    const values = new Uint8Array(6);
    if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(values);
    else for (let i = 0; i < values.length; i++) values[i] = Math.floor(Math.random() * 256);
    return `PC-${Array.from(values, value => alphabet[value % alphabet.length]).join('')}`;
  }
  function cookDurationMs() { return Math.max(6_000, 15_000 - (state.equipped.includes('blue-tile') ? 3_000 : 0) - (state.equipped.includes('wooden-spoon') ? 3_000 : 0)); }
  function dumplingBonus() { return (state.equipped.includes('herb-pot') ? 2 : 0) + (state.equipped.includes('wooden-spoon') ? 3 : 0); }
  function isCooking() { return state.endsAt !== null && Date.now() < state.endsAt; }
  function formatTime(ms) { return `00:${String(Math.max(0, Math.ceil(ms / 1000))).padStart(2, '0')}`; }
  function toast(message) {
    const el = $('toast'); el.textContent = message; el.classList.add('show');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('show'), 2300);
  }
  const upgrades = [
    { id:'herb-pot', name:'Fresh herb pots', desc:'+2 dumplings with every collected batch.', effect:'+2 dumplings / batch', cost:20, icon:'<path d="M18 32h24l-3 13H21zM20 32q-4-6-9-4m19 4q-3-8 2-14m1 14q8-7 12-4M31 20q-6-8-1-13m-4 12q-7-1-9-8m14 6q8-1 10-7"/>' },
    { id:'blue-tile', name:'Blue kitchen tiles', desc:'Cook each batch 3 seconds faster.', effect:'15 sec → 12 sec', cost:35, icon:'<path d="M12 12h16v16H12zM32 12h16v16H32zM12 32h16v16H12zM32 32h16v16H32z"/><path d="M16 16h8m12 0h8M16 36h8m12 0h8"/>' },
    { id:'wooden-spoon', name:'Carved wooden spoon', desc:'+3 dumplings and 3 seconds faster.', effect:'+3 dumplings · −3 sec', cost:50, icon:'<path d="M26 17c4-6 14-8 19-3s3 15-3 19L25 50l-8-8z"/><path d="m24 40 12-13"/>' }
  ];
  function renderUpgrades() {
    $('upgradeList').innerHTML = upgrades.map(item => {
      const owned = state.upgrades.includes(item.id);
      const equipped = state.equipped.includes(item.id);
      const label = !owned ? (state.balance < item.cost ? `${item.cost} dumplings` : `Get · ${item.cost}`) : equipped ? 'REMOVE' : 'EQUIP';
      const disabled = !owned && state.balance < item.cost;
      return `<article class="upgrade-card ${equipped ? 'equipped' : ''}"><div class="upgrade-art"><svg viewBox="0 0 60 60" aria-hidden="true">${item.icon}</svg></div><div class="upgrade-copy"><h2>${item.name}</h2><p>${item.desc}</p><small class="upgrade-effect">${item.effect}</small></div><button class="upgrade-button" data-upgrade="${item.id}" type="button" ${disabled ? 'disabled' : ''}>${label}</button></article>`;
    }).join('');
  }
  function updateTask() {
    if (state.taskDay !== todayKey()) {
      state.taskDay = todayKey(); state.taskBatches = 0; state.taskClaimedOn = null; saveState();
    }
    const done = state.taskBatches > 0;
    const claimed = state.taskClaimedOn === todayKey();
    $('taskProgress').style.width = done ? '100%' : '0%';
    $('taskProgressText').textContent = `${done ? 1 : 0} / 1 batches`;
    $('claimTask').disabled = !done || claimed;
    $('claimTask').textContent = claimed ? 'Reward collected today' : done ? 'Collect +5 game points' : 'Cook a batch to unlock';
    $('taskDot').hidden = !done || claimed;
  }
  function render() {
    const active = isCooking();
    const ready = state.endsAt !== null && !active;
    $('balance').textContent = state.balance.toLocaleString('en-US');
    $('score').textContent = state.score.toLocaleString('en-US');
    $('batches').textContent = state.batches.toLocaleString('en-US');
    $('leaderScore').innerHTML = `${state.score.toLocaleString('en-US')} <span>points</span>`;
    $('profileBalance').textContent = state.balance.toLocaleString('en-US');
    $('profileScore').textContent = state.score.toLocaleString('en-US');
    $('profileBatches').textContent = state.batches.toLocaleString('en-US');
    $('kitchenArt').classList.toggle('cooking', active);
    $('kitchenArt').classList.toggle('ready', ready);
    $('kitchenArt').classList.toggle('decor-herb-pot', state.equipped.includes('herb-pot'));
    $('kitchenArt').classList.toggle('decor-blue-tile', state.equipped.includes('blue-tile'));
    $('kitchenArt').classList.toggle('decor-wooden-spoon', state.equipped.includes('wooden-spoon'));
    $('gameCard').classList.toggle('cooking', active);
    $('gameCard').classList.toggle('ready', ready);
    $('statusText').textContent = active ? 'Dumplings are bubbling' : ready ? 'Ready to collect!' : 'Kitchen is ready';
    $('artStatus').textContent = active ? 'POT ON · GOOD THINGS TAKE TIME' : ready ? 'FRESHLY COOKED FOR YOU' : 'FRESH FROM THE KITCHEN';
    $('batchTag').textContent = active ? 'COOKING' : ready ? 'READY' : 'NEW BATCH';
    $('timerLabel').textContent = active ? 'TIME LEFT' : ready ? 'BATCH COMPLETE' : 'COOKING TIME';
    const duration = state.batchDurationMs || cookDurationMs();
    $('timer').textContent = active ? formatTime(state.endsAt - Date.now()) : ready ? 'READY!' : formatTime(cookDurationMs());
    $('progress').style.width = active ? `${Math.min(100, Math.max(0, Date.now() - state.startedAt) / duration * 100)}%` : ready ? '100%' : '0%';
    $('cookHint').textContent = active ? 'Your little kitchen is doing its thing. Almost there!' : ready ? 'Hot and ready! Collect your freshly cooked dumplings.' : `A fresh batch takes ${Math.ceil(cookDurationMs()/1000)} seconds. Then collect your dumplings!`;
    $('buttonText').textContent = active ? 'Cooking…' : ready ? 'Collect dumplings' : 'Start cooking';
    $('referralCode').textContent = state.referralCode;
    $('cookButton').disabled = active;
    renderUpgrades(); updateTask();
  }
  $('cookButton').addEventListener('click', () => {
    if (isCooking()) return;
    if (state.endsAt !== null) {
      const reward = 10 + Math.floor(Math.random() * 6) + dumplingBonus();
      state.balance += reward; state.score += reward; state.batches += 1;
      if (state.taskDay !== todayKey()) { state.taskDay = todayKey(); state.taskBatches = 0; state.taskClaimedOn = null; }
      state.taskBatches += 1;
      state.startedAt = state.endsAt = state.batchDurationMs = null; saveState(); render(); toast(`Yum! You collected ${reward} dumplings.`); return;
    }
    state.startedAt = Date.now(); state.batchDurationMs = cookDurationMs(); state.endsAt = state.startedAt + state.batchDurationMs;
    saveState(); render(); toast('Your pot is on!');
  });
  $('upgradeList').addEventListener('click', event => {
    const button = event.target.closest('[data-upgrade]');
    if (!button) return;
    const item = upgrades.find(upgrade => upgrade.id === button.dataset.upgrade);
    if (!item) return;
    if (state.upgrades.includes(item.id)) {
      const removing = state.equipped.includes(item.id);
      state.equipped = state.equipped.filter(id => id !== item.id);
      if (!removing) state.equipped.push(item.id);
      saveState(); render(); toast(removing ? `${item.name} removed.` : `${item.name} equipped: ${item.effect}.`); return;
    }
    if (state.balance < item.cost) return;
    state.balance -= item.cost; state.upgrades.push(item.id); state.equipped.push(item.id); saveState(); render(); toast(`${item.name} equipped: ${item.effect}.`);
  });
  $('claimTask').addEventListener('click', () => {
    if (state.taskBatches < 1 || state.taskClaimedOn === todayKey()) return;
    state.score += 5; state.taskClaimedOn = todayKey(); saveState(); render(); toast('Daily task complete! +5 game points.');
  });
  $('copyReferral').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(state.referralCode);
      toast('Invite code copied.');
    } catch { toast(`Your invite code: ${state.referralCode}`); }
  });
  $('shareReferral').addEventListener('click', async () => {
    const message = `Join my Pelmeni Clicker kitchen! My invite code is ${state.referralCode}.`;
    try {
      if (navigator.share) await navigator.share({ title: 'Pelmeni Clicker', text: message });
      else if (navigator.clipboard) { await navigator.clipboard.writeText(message); toast('Invite message copied.'); }
      else toast(`Your invite code: ${state.referralCode}`);
    } catch (error) { if (error.name !== 'AbortError') toast(`Your invite code: ${state.referralCode}`); }
  });
  document.querySelectorAll('.nav-item').forEach(button => button.addEventListener('click', () => {
    const tab = button.dataset.tab;
    document.querySelectorAll('.nav-item').forEach(item => item.classList.toggle('selected', item === button));
    document.querySelectorAll('.screen').forEach(screen => screen.classList.toggle('active', screen.dataset.screen === tab));
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }));
  document.querySelector('.season-pill').addEventListener('click', () => toast('Cozy Kitchen · Season 01'));
  try {
    const telegramWebApp = window.Telegram?.WebApp;
    if (typeof telegramWebApp?.ready === 'function') telegramWebApp.ready();
    if (typeof telegramWebApp?.expand === 'function') telegramWebApp.expand();
  } catch (error) {
    console.warn('Telegram Web App initialization was skipped.', error);
  }
  if (!state.referralCode) { state.referralCode = makeReferralCode(); saveState(); }
  render(); saveState(); setInterval(render, 250);
})();

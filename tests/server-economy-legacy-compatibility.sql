-- Legacy-state compatibility regression test.
-- Run only in a disposable PostgreSQL/Supabase database after applying the
-- local migration. This script uses synthetic IDs and rolls everything back.
-- It does not migrate or inspect production player data.
--
-- Concurrency note: the assertions below cover idempotent repeat activation
-- and the legacy-write guard in one session. The true two-session activation
-- versus old-upsert race must also be exercised manually in the isolated DB:
-- Session A: BEGIN; SELECT economy_activate_legacy_profile(<synthetic_id>);
-- Session B: while A is still open, issue the legacy INSERT ... ON CONFLICT
-- DO UPDATE for that same ID; it must wait. COMMIT A; B must fail with 55000.
-- For two activations, start Session A activation and leave its transaction
-- open, call the same activation from Session B, then commit A; B must return
-- already_active without changing balance or revision.
BEGIN;
SET LOCAL ROLE service_role;

DO $test$
DECLARE
  v_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_yesterday date := (clock_timestamp() AT TIME ZONE 'UTC')::date - 1;
  v_now_ms bigint := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  v_today_start_ms bigint;
  v_variant text;
  v_state jsonb;
  v_fixture_source jsonb;
  v_assessment jsonb;
  v_result jsonb;
  v_dry_run jsonb;
  v_after jsonb;
  v_expected_batches jsonb;
  v_balance bigint;
  v_revision bigint;
  v_claim_result jsonb;
  v_id bigint;
  v_source_hash text;
  v_candidate_hash text;
  v_dryrun_date date;
  v_game_state_nullable text;
  -- Eight unconditional fixtures; optional SQL NULL adds one, and malformed
  -- JSON null/scalar cases below add two more.
  v_expected_profile_count integer := 8;
BEGIN
  v_variant := public._pelmeni_daily_task_variant(v_today);
  v_today_start_ms := floor(extract(epoch FROM (v_today::timestamp AT TIME ZONE 'UTC')) * 1000)::bigint;

  IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id BETWEEN 9223372036854770200 AND 9223372036854770212) THEN
    RAISE EXCEPTION 'Legacy compatibility fixture IDs already exist; choose a new synthetic range';
  END IF;

  -- Past-day legacy state: no schemaVersion or dailyTaskVariant. Claim ledgers
  -- are explicitly present because its progress is high enough for rewards;
  -- omitted ledgers are tested separately as manual-review cases. It also has
  -- two independent future pots and a same-day legacy login marker.
  v_expected_batches := jsonb_build_array(
    jsonb_build_object('id','legacy-pot-one','pot',1,'startedAt',v_now_ms-86401000,
      'endsAt',v_now_ms+3599000,'durationMs',90000000),
    jsonb_build_object('id','legacy-pot-two','pot',2,'startedAt',v_now_ms-86402000,
      'endsAt',v_now_ms+7198000,'durationMs',93600000)
  );
  v_state := jsonb_build_object(
    'balance',1234,'score',100,'points',0,'pointsRetired',true,'batches',8,
    'activeBatches',v_expected_batches,'upgrades',jsonb_build_array('second-pot'),
    'equipped',jsonb_build_array('second-pot'),
    'upgradeLevels',jsonb_build_object('good-stove',2,'large-pot',1,'grandma-recipe',3,'second-pot',1),
    'taskDay',v_yesterday::text,'taskBatches',2,'lifetimeDumplings',500,
    'taskClaimedOn',v_yesterday::text,'taskBalanceRewardVersion',1,'referralCode',NULL,
    'dailyDate',v_yesterday::text,
    'dailyTasks',jsonb_build_object('cook',jsonb_build_object('progress',1,'claimed',false)),
    'loginRewardDate',v_today::text,'firstLoginNoReward',false,
    'streakCurrent',1,'streakBest',4,'streakLastVisitDate',v_yesterday::text,
    'streakRunStartedDate',v_yesterday::text,'streakRewardClaims','[]'::jsonb,
    'taskPotsUsed','[1,2]'::jsonb,'potCollections',jsonb_build_object('1',4,'2',4),
    'achievements','[]'::jsonb,'achievementClaims','[]'::jsonb,'levelClaims','[]'::jsonb,
    'joinedAt','2025-01-01T00:00:00Z',
    'legacyExtension',jsonb_build_object('keep','untouched'),
    'lastBatchReward',jsonb_build_object('dumplings',12),'lastBatchAt','2025-01-02T00:00:00Z'
  );
  v_state := v_state - 'schemaVersion' - 'dailyTaskVariant';
  v_fixture_source := v_state;

  v_assessment := public._pelmeni_prepare_legacy_state(v_state, v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'Unambiguous past-day legacy profile was not eligible: %', v_assessment;
  END IF;
  IF v_assessment #> '{candidateState,activeBatches}' IS DISTINCT FROM v_expected_batches THEN
    RAISE EXCEPTION 'Active pot timers or their original timestamps changed during preparation';
  END IF;
  IF v_assessment #>> '{candidateState,upgradeLevels,second-pot}' <> '1'
     OR NOT (v_assessment #> '{candidateState,upgrades}' @> '["second-pot"]'::jsonb)
     OR NOT (v_assessment #> '{candidateState,equipped}' @> '["second-pot"]'::jsonb)
     OR v_assessment #>> '{candidateState,balance}' <> '1234'
     OR v_assessment #>> '{candidateState,score}' <> '1234'
     OR v_assessment #>> '{candidateState,lifetimeDumplings}' <> '500'
     OR v_assessment #>> '{candidateState,batches}' <> '8'
     OR v_assessment #>> '{candidateState,legacyExtension,keep}' <> 'untouched' THEN
    RAISE EXCEPTION 'Permanent progress, balance, purchase or statistics changed in prepared state';
  END IF;
  IF v_assessment #>> '{candidateState,schemaVersion}' <> '6'
     OR v_assessment #>> '{candidateState,dailyTaskVariant}' <> v_variant
     OR v_assessment #>> '{candidateState,dailyDate}' <> v_today::text
     OR v_assessment #>> '{candidateState,taskDay}' <> v_today::text
     OR v_assessment #>> '{candidateState,taskPotsUsed}' <> '[]'
     OR v_assessment #>> '{candidateState,taskBatches}' <> '0'
     OR v_assessment #>> '{candidateState,taskClaimedOn}' IS NOT NULL THEN
    RAISE EXCEPTION 'Past-day daily rollover did not produce the expected UTC-day state';
  END IF;
  IF v_assessment #>> '{candidateState,loginRewardDate}' <> v_today::text
     OR v_assessment #> '{candidateState,streakRewardClaims}' @> jsonb_build_array(v_today::text || ':0:1') THEN
    RAISE EXCEPTION 'Preparation changed the old login marker or paid/recorded a reward';
  END IF;

  -- Mirror normalizeState()'s proven legacy points conversion exactly. It is
  -- previewed in the candidate and activated only after its hashes are approved.
  v_state := jsonb_set(v_fixture_source,'{balance}','100'::jsonb,true);
  v_state := jsonb_set(v_state,'{score}','150'::jsonb,true);
  v_state := jsonb_set(v_state,'{lifetimeDumplings}','300'::jsonb,true);
  v_state := jsonb_set(v_state,'{points}','37'::jsonb,true);
  v_state := jsonb_set(v_state,'{pointsRetired}','false'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR v_assessment #>> '{candidateState,balance}' IS DISTINCT FROM '137'
     OR v_assessment #>> '{candidateState,score}' IS DISTINCT FROM '300'
     OR v_assessment #>> '{candidateState,points}' IS DISTINCT FROM '0'
     OR v_assessment #>> '{candidateState,pointsRetired}' IS DISTINCT FROM 'true'
     OR v_assessment #>> '{candidateState,lifetimeDumplings}' IS DISTINCT FROM '300' THEN
    RAISE EXCEPTION 'Legacy points conversion did not preserve the normalized value exactly: %',v_assessment;
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_assessment -> 'candidateState',v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR v_assessment #>> '{candidateState,balance}' IS DISTINCT FROM '137' THEN
    RAISE EXCEPTION 'Prepared legacy points value was converted a second time: %',v_assessment;
  END IF;

  -- A pre-marker save uses the client's score fallback once, then persists the
  -- retirement marker so a later load cannot convert that value again.
  v_state := v_fixture_source - 'points' - 'pointsRetired';
  -- Score normalization raises this fixture above the level-claim threshold;
  -- provide the explicit empty ledger so this case tests points conversion,
  -- not the separate fail-closed policy for unknown level-claim history.
  v_state := jsonb_set(v_state,'{levelClaims}','[]'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR v_assessment #>> '{candidateState,balance}' IS DISTINCT FROM '1334'
     OR v_assessment #>> '{candidateState,points}' IS DISTINCT FROM '0'
     OR v_assessment #>> '{candidateState,pointsRetired}' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Pre-marker score fallback did not match normalizeState(): %',v_assessment;
  END IF;

  -- A missing/old task-balance conversion version is historical payout
  -- ambiguity. Never grant its +5 during activation; keep it review-only.
  v_state := jsonb_set(v_fixture_source,'{taskBalanceRewardVersion}','0'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'Unresolved legacy task-balance claim version was accepted automatically: %',v_assessment;
  END IF;
  v_state := v_fixture_source;

  -- Activation snapshots source JSON, applies the reviewed candidate, and
  -- enables server_mode last. It is idempotent and never pays during migration.
  v_id := 9223372036854770200;
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  IF v_dry_run ->> 'status' IS DISTINCT FROM 'ready'
     OR v_dry_run ->> 'ok' IS DISTINCT FROM 'true'
     OR v_dry_run ->> 'preservedUnknownTopLevelKeys' NOT LIKE '%legacyExtension%' THEN
    RAISE EXCEPTION 'Dry-run did not return a ready report and preserved unknown-key inventory: %',v_dry_run;
  END IF;
  v_source_hash := v_dry_run ->> 'sourceHash';
  v_candidate_hash := v_dry_run ->> 'candidateHash';
  v_dryrun_date := (v_dry_run ->> 'dryRunUtcDate')::date;
  IF (SELECT game_state FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM v_state
     OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id=v_id) THEN
    RAISE EXCEPTION 'Dry-run changed player_state or created a control/revision row';
  END IF;
  -- A raised error after the RPC succeeds rolls back the source rewrite,
  -- snapshot, control revision and mode switch as one subtransaction.
  BEGIN
    v_result := public.economy_activate_legacy_profile(v_id,v_source_hash,v_candidate_hash,v_dryrun_date);
    IF v_result ->> 'status' IS DISTINCT FROM 'activated' THEN
      RAISE EXCEPTION 'Rollback fixture did not reach the successful activation path: %',v_result;
    END IF;
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='intentional rollback probe';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    NULL;
  END;
  IF (SELECT game_state FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM v_state
     OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id=v_id)
     OR (SELECT status FROM public.player_economy_migration_snapshots
         WHERE telegram_id=v_id AND source_hash=v_source_hash) IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'Activation rollback left player/control state changed or damaged the reviewed snapshot';
  END IF;
  v_result := public.economy_activate_legacy_profile(v_id,v_source_hash,v_candidate_hash,v_dryrun_date);
  IF v_result ->> 'status' IS DISTINCT FROM 'activated'
     OR v_result ->> 'ok' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Legacy activation failed: %',v_result;
  END IF;
  SELECT game_state INTO v_after FROM public.player_state WHERE telegram_id=v_id;
  SELECT revision INTO v_revision FROM public.player_economy_control WHERE telegram_id=v_id;
  SELECT source_hash INTO v_source_hash FROM public.player_economy_migration_snapshots
    WHERE telegram_id=v_id AND source_state=v_state AND status='activated';
  IF v_source_hash IS NULL OR v_after ->> 'balance' <> '1234'
     OR v_after ->> 'score' <> '1234' OR v_after ->> 'lifetimeDumplings' <> '500'
     OR v_after ->> 'batches' <> '8' OR v_after -> 'activeBatches' IS DISTINCT FROM v_expected_batches
     OR v_after #>> '{legacyExtension,keep}' <> 'untouched'
     OR (SELECT server_mode FROM public.player_economy_control WHERE telegram_id=v_id) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Activation lost source data, timers, backup, or server_mode';
  END IF;
  IF (SELECT count(*) FROM public.player_economy_migration_snapshots WHERE telegram_id=v_id) <> 1 THEN
    RAISE EXCEPTION 'Activation created duplicate source snapshots';
  END IF;
  v_result := public.economy_activate_legacy_profile(v_id,v_source_hash,v_candidate_hash,v_dryrun_date);
  IF v_result ->> 'status' IS DISTINCT FROM 'already_active'
     OR (SELECT revision FROM public.player_economy_control WHERE telegram_id=v_id) IS DISTINCT FROM v_revision THEN
    RAISE EXCEPTION 'Repeated activation changed the revision or was not idempotent: %',v_result;
  END IF;

  -- Legacy load must not reinterpret an activated legacy profile as a new
  -- player, and an old same-day automatic-reward marker must not be paid again.
  v_result := public.economy_load_visit(v_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT game_state -> 'achievements' @> '["first-visit"]'::jsonb
         FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'Activated old profile was treated as a new player: %',v_result;
  END IF;
  SELECT (game_state ->> 'balance')::bigint, game_state
    INTO v_balance,v_after FROM public.player_state WHERE telegram_id=v_id;
  IF v_balance <> 1234
     OR NOT (v_after -> 'streakRewardClaims' @> jsonb_build_array(v_today::text || ':0:1')) THEN
    RAISE EXCEPTION 'Legacy same-day reward marker was not preserved without payment';
  END IF;
  v_claim_result := public.economy_claim_streak(v_id,'33333333-3333-4333-8333-333333333333');
  IF v_claim_result #>> '{operation,result,error}' IS DISTINCT FROM 'streak_already_claimed'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 1234 THEN
    RAISE EXCEPTION 'A legacy-paid streak reward became claimable again: %',v_claim_result;
  END IF;

  -- Old whole-state upserts are rejected after activation and cannot replace
  -- canonical balance, purchases, achievements or timers.
  PERFORM pg_catalog.set_config('pelmeni.server_economy_write','',true);
  BEGIN
    INSERT INTO public.player_state(telegram_id,game_state,updated_at)
      VALUES(v_id,jsonb_set(v_after,'{balance}','1'::jsonb,true),clock_timestamp())
      ON CONFLICT (telegram_id) DO UPDATE
        SET game_state=EXCLUDED.game_state, updated_at=EXCLUDED.updated_at;
    RAISE EXCEPTION 'Legacy full-state upsert unexpectedly succeeded';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;
  IF (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 1234
     OR (SELECT game_state -> 'activeBatches' FROM public.player_state WHERE telegram_id=v_id)
        IS DISTINCT FROM v_expected_batches THEN
    RAISE EXCEPTION 'Rejected legacy upsert changed the canonical profile';
  END IF;

  -- The approved points transfer is committed once, with the pre-conversion
  -- JSON retained in the audit snapshot; replayed activation cannot pay twice.
  v_id := 9223372036854770208;
  v_state := jsonb_set(v_fixture_source,'{balance}','100'::jsonb,true);
  v_state := jsonb_set(v_state,'{score}','150'::jsonb,true);
  v_state := jsonb_set(v_state,'{lifetimeDumplings}','300'::jsonb,true);
  v_state := jsonb_set(v_state,'{points}','37'::jsonb,true);
  v_state := jsonb_set(v_state,'{pointsRetired}','false'::jsonb,true);
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  IF v_dry_run ->> 'status' IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'Deterministic legacy points profile was not dry-run ready: %',v_dry_run;
  END IF;
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'activated'
     OR (SELECT game_state ->> 'balance' FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM '137'
     OR (SELECT game_state ->> 'points' FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM '0'
     OR (SELECT source_state ->> 'points' FROM public.player_economy_migration_snapshots
         WHERE telegram_id=v_id AND status='activated') IS DISTINCT FROM '37' THEN
    RAISE EXCEPTION 'Legacy points activation failed to preserve value/source snapshot: %',v_result;
  END IF;
  v_revision := (SELECT revision FROM public.player_economy_control WHERE telegram_id=v_id);
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'already_active'
     OR (SELECT game_state ->> 'balance' FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM '137'
     OR (SELECT revision FROM public.player_economy_control WHERE telegram_id=v_id) IS DISTINCT FROM v_revision THEN
    RAISE EXCEPTION 'Repeated activation replayed the points transfer: %',v_result;
  END IF;

  v_state := jsonb_set(jsonb_set(jsonb_set(v_after,'{dailyDate}',to_jsonb(v_yesterday::text),true),
    '{taskDay}',to_jsonb(v_yesterday::text),true),'{taskClaimedOn}',to_jsonb(v_today::text),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
      @> '["current_cook_claim_conflicts_with_expired_daily_state"]'::jsonb) THEN
    RAISE EXCEPTION 'Current-day taskClaimedOn marker was discarded by old-day rollover: %',v_assessment;
  END IF;

  -- Long-inactive accounts keep permanent progress and best streak. Normal
  -- visit processing resets only the current streak according to UTC rules;
  -- the activation itself grants nothing.
  v_id := 9223372036854770204;
  v_state := jsonb_set(v_after,'{activeBatches}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{balance}','42'::jsonb,true);
  v_state := jsonb_set(v_state,'{dailyDate}',to_jsonb((v_today-30)::text),true);
  v_state := jsonb_set(v_state,'{taskDay}',to_jsonb((v_today-30)::text),true);
  v_state := jsonb_set(v_state,'{loginRewardDate}',to_jsonb((v_today-30)::text),true);
  v_state := jsonb_set(v_state,'{taskClaimedOn}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakCurrent}','7'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakBest}','9'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakLastVisitDate}',to_jsonb((v_today-30)::text),true);
  v_state := jsonb_set(v_state,'{streakRunStartedDate}',to_jsonb((v_today-36)::text),true);
  v_state := jsonb_set(v_state,'{streakRewardClaims}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{achievements}',
    CASE WHEN COALESCE(v_state -> 'achievements','[]'::jsonb) @> '["first-start"]'::jsonb
      THEN COALESCE(v_state -> 'achievements','[]'::jsonb)
      ELSE COALESCE(v_state -> 'achievements','[]'::jsonb) || '["first-start"]'::jsonb END,true);
  v_state := jsonb_set(v_state,'{achievementClaims}','["first-start"]'::jsonb,true);
  v_state := jsonb_set(v_state,'{levelClaims}','[2]'::jsonb,true);
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'activated'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 42
     OR (SELECT game_state -> 'achievementClaims' FROM public.player_state WHERE telegram_id=v_id)
        IS DISTINCT FROM '["first-start"]'::jsonb
     OR (SELECT game_state -> 'levelClaims' FROM public.player_state WHERE telegram_id=v_id)
        IS DISTINCT FROM '[2]'::jsonb THEN
    RAISE EXCEPTION 'Long-inactive account did not activate without receiving a payout: %',v_result;
  END IF;
  v_result := public.economy_load_visit(v_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT (game_state ->> 'streakCurrent')::integer FROM public.player_state WHERE telegram_id=v_id) <> 1
     OR (SELECT (game_state ->> 'streakBest')::integer FROM public.player_state WHERE telegram_id=v_id) <> 9
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 42
     OR (SELECT game_state -> 'achievementClaims' FROM public.player_state WHERE telegram_id=v_id)
        IS DISTINCT FROM '["first-start"]'::jsonb
     OR (SELECT game_state -> 'levelClaims' FROM public.player_state WHERE telegram_id=v_id)
        IS DISTINCT FROM '[2]'::jsonb THEN
    RAISE EXCEPTION 'Inactive profile visit did not preserve best streak/progress or reset current streak safely: %',v_result;
  END IF;

  -- Current-day partial task objects can only be activated when the legacy
  -- cook marker safely closes the missing/incomplete slot. Missing slots are
  -- filled inertly; no reward is credited by preparation.
  v_id := 9223372036854770201;
  v_state := jsonb_build_object(
    'balance',77,'score',0,'points',0,'pointsRetired',true,'batches',0,
    'startedAt',NULL,'endsAt',NULL,'batchDurationMs',NULL,'activeBatches','[]'::jsonb,
    'upgrades','[]'::jsonb,'equipped','[]'::jsonb,
    'upgradeLevels',jsonb_build_object('good-stove',0,'large-pot',0,'grandma-recipe',0),
    'taskDay',v_today::text,'taskBatches',1,'lifetimeDumplings',0,
    'taskClaimedOn',v_today::text,'taskBalanceRewardVersion',1,'referralCode',NULL,
    'dailyDate',v_today::text,'dailyTaskVariant',v_variant,
    'dailyTasks',jsonb_build_object('upgrade',jsonb_build_object('progress',0,'claimed',false)),
    'loginRewardDate',v_today::text,'firstLoginNoReward',false,
    'streakCurrent',1,'streakBest',1,'streakLastVisitDate',v_today::text,
    'streakRunStartedDate',v_today::text,'streakRewardClaims',jsonb_build_array(v_today::text||':0:0'),
    'taskPotsUsed','[]'::jsonb,'potCollections',jsonb_build_object('1',0,'2',0),
    'achievements','[]'::jsonb,'achievementClaims','[]'::jsonb,'levelClaims','[]'::jsonb,
    'joinedAt','2026-01-01T00:00:00Z','lastBatchReward',NULL,'lastBatchAt',NULL,'schemaVersion',6
  );
  v_state := v_state - 'dailyTasks';
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'upgrade',jsonb_build_object('progress',0,'claimed',false)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR v_assessment #>> '{candidateState,dailyTasks,cook,claimed}' IS DISTINCT FROM 'true'
     OR v_assessment #>> '{candidateState,dailyTasks,cook,progress}' IS DISTINCT FROM '0'
     OR v_assessment #>> '{candidateState,balance}' IS DISTINCT FROM '77' THEN
    RAISE EXCEPTION 'Partial dailyTasks or taskClaimedOn compatibility failed: %',v_assessment;
  END IF;

  -- Same-day collection evidence must not be silently normalized away when
  -- its task progress contradicts the saved collection marker/reward.
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'login',jsonb_build_object('progress',1,'claimed',true),
    'cook',jsonb_build_object('progress',1,'claimed',true),
    'upgrade',jsonb_build_object('progress',0,'claimed',false),
    'collect',jsonb_build_object('progress',0,'claimed',false),
    'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
    'collect-two',jsonb_build_object('progress',0,'claimed',false),
    'two-pots',jsonb_build_object('progress',0,'claimed',false)),true);
  v_state := jsonb_set(v_state,'{lastBatchAt}',to_jsonb(clock_timestamp()::text),true);
  v_state := jsonb_set(v_state,'{lastBatchReward}',jsonb_build_object('dumplings',5),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["daily_task_state_conflict:collect_progress"]'::jsonb) THEN
    RAISE EXCEPTION 'Contradictory same-day collection evidence was not held for review: %',v_assessment;
  END IF;

  -- Having used both pots is evidence for the two-pots task. A contradictory
  -- explicit zero-progress, unclaimed slot is review-only rather than reset.
  v_state := jsonb_set(v_state,'{lastBatchAt}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{lastBatchReward}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{taskPotsUsed}','[1,2]'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["daily_task_state_conflict:two_pots_progress"]'::jsonb) THEN
    RAISE EXCEPTION 'Contradictory both-pot task evidence was not held for review: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{dailyTasks}',(v_state -> 'dailyTasks') - 'two-pots',true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["daily_task_state_ambiguous:two_pots_claim_history_missing"]'::jsonb) THEN
    RAISE EXCEPTION 'Missing both-pot claim history was not routed to manual review: %',v_assessment;
  END IF;

  -- Restore the clean partial-task fixture used for the stale-approval test.
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'upgrade',jsonb_build_object('progress',0,'claimed',false)),true);
  v_state := jsonb_set(v_state,'{taskPotsUsed}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{lastBatchAt}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{lastBatchReward}','null'::jsonb,true);

  -- A legacy single-pot timer has no stable batch ID or slot. Even when its
  -- timestamps are valid, do not synthesize a collectible batch during cutover.
  v_state := v_state - 'activeBatches';
  v_state := jsonb_set(v_state,'{startedAt}',to_jsonb(v_now_ms-1000),true);
  v_state := jsonb_set(v_state,'{endsAt}',to_jsonb(v_now_ms+1000),true);
  v_state := jsonb_set(v_state,'{batchDurationMs}','2000'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["legacy_batch_identity_missing_requires_review"]'::jsonb) THEN
    RAISE EXCEPTION 'Legacy timer without a stable batch identity was not held for review: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{activeBatches}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{startedAt}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{endsAt}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{batchDurationMs}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{dailyDate}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{taskDay}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{taskClaimedOn}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{activeBatches}',jsonb_build_array(jsonb_build_object(
    'id','started-today','pot',1,'startedAt',v_now_ms,
    'endsAt',v_now_ms+60000,'durationMs',60000)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["current_day_activity_conflicts_with_expired_daily_state"]'::jsonb) THEN
    RAISE EXCEPTION 'Current-day batch activity was erased by stale daily rollover: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{dailyDate}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{taskDay}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{taskClaimedOn}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{activeBatches}','[]'::jsonb,true);

  -- A dry-run approval expires at UTC rollover and is rejected if the source
  -- profile changes before activation. Neither rejection creates control data.
  v_id := 9223372036854770205;
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  IF v_dry_run ->> 'status' IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'Dry-run source-change fixture is unexpectedly ambiguous: %',v_dry_run;
  END IF;
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date - 1);
  IF v_result ->> 'error' IS DISTINCT FROM 'dry_run_expired'
     OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id=v_id) THEN
    RAISE EXCEPTION 'An expired dry-run was accepted or changed control metadata: %',v_result;
  END IF;
  UPDATE public.player_state SET game_state=jsonb_set(game_state,'{balance}','78'::jsonb,true)
    WHERE telegram_id=v_id;
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'error' IS DISTINCT FROM 'source_changed_after_dry_run'
     OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id=v_id)
     OR (SELECT game_state ->> 'balance' FROM public.player_state WHERE telegram_id=v_id) <> '78' THEN
    RAISE EXCEPTION 'Changed source was not rejected without writes: %',v_result;
  END IF;
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'activated'
     OR (SELECT game_state ->> 'balance' FROM public.player_state WHERE telegram_id=v_id) <> '78' THEN
    RAISE EXCEPTION 'A fresh dry-run could not safely activate the changed source: %',v_result;
  END IF;

  -- Missing claim ledgers are ambiguous even when the unlocked-achievement
  -- array is empty: other saved progress can make old rewards claimable.
  v_state := jsonb_set(v_fixture_source,'{achievements}','[]'::jsonb,true) - 'achievementClaims';
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["ambiguous_achievement_claim_history"]'::jsonb) THEN
    RAISE EXCEPTION 'Missing achievementClaims was treated as an empty payout history: %',v_assessment;
  END IF;

  -- A missing level ledger is ambiguous if normalized score can come from
  -- saved balance or lifetime earnings, even when the raw score is below 500.
  v_state := jsonb_set(v_fixture_source,'{levelClaims}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{achievementClaims}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{achievements}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{score}','100'::jsonb,true);
  v_state := jsonb_set(v_state,'{balance}','500'::jsonb,true) - 'levelClaims';
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["ambiguous_level_claim_history"]'::jsonb) THEN
    RAISE EXCEPTION 'Missing levelClaims ignored normalized balance-derived score: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{balance}','0'::jsonb,true);
  v_state := jsonb_set(v_state,'{lifetimeDumplings}','500'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["ambiguous_level_claim_history"]'::jsonb) THEN
    RAISE EXCEPTION 'Missing levelClaims ignored lifetime-derived normalized score: %',v_assessment;
  END IF;

  -- Ambiguous claim history, stale/missing same-day variants, malformed daily JSON,
  -- expired timers and malformed timers remain review-only and are not edited.
  v_id := 9223372036854770202;
  v_state := jsonb_build_object(
    'balance',10,'score',0,'points',0,'pointsRetired',true,'batches',0,
    'startedAt',NULL,'endsAt',NULL,'batchDurationMs',NULL,'activeBatches','[]'::jsonb,
    'upgrades','[]'::jsonb,'equipped','[]'::jsonb,
    'upgradeLevels',jsonb_build_object('good-stove',0,'large-pot',0,'grandma-recipe',0),
    'taskDay',v_today::text,'taskBatches',0,'lifetimeDumplings',0,'levelClaims','[]'::jsonb,
    'taskClaimedOn',NULL,'taskBalanceRewardVersion',1,'referralCode',NULL,
    'dailyDate',v_today::text,'dailyTaskVariant','classic','dailyTasks','{}'::jsonb,
    'loginRewardDate',NULL,'firstLoginNoReward',false,'streakCurrent',0,'streakBest',0,
    'streakLastVisitDate',NULL,'streakRunStartedDate',NULL,'streakRewardClaims','[]'::jsonb,
    'taskPotsUsed','[]'::jsonb,'potCollections',jsonb_build_object('1',0,'2',0),
    'achievements','[]'::jsonb,'achievementClaims','[]'::jsonb,
    'joinedAt',NULL,'lastBatchReward',NULL,'lastBatchAt',NULL,'schemaVersion',6
  );
  v_state := jsonb_set(v_state,'{dailyTaskVariant}',to_jsonb(
    CASE v_variant WHEN 'classic' THEN 'batch-focus' WHEN 'batch-focus' THEN 'kitchen-rhythm' ELSE 'classic' END),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state - 'dailyTaskVariant',v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["daily_task_variant_ambiguous_for_today"]'::jsonb) THEN
    RAISE EXCEPTION 'Missing current-day variant was not routed to review: %',v_assessment;
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["daily_task_variant_ambiguous_for_today"]'::jsonb) THEN
    RAISE EXCEPTION 'Stale current-day variant was not routed to review: %',v_assessment;
  END IF;

  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'manual_review_required'
     OR (SELECT game_state FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM v_state
     OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id=v_id)
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 10 THEN
    RAISE EXCEPTION 'Ambiguous profile was rewritten or activated: %',v_result;
  END IF;

  -- A complete canonical empty profile can retain first-visit eligibility.
  -- The visit unlocks first-visit, but neither activation nor load pays dumplings.
  v_id := 9223372036854770206;
  v_state := jsonb_build_object(
    'balance',0,'score',0,'points',0,'pointsRetired',true,'batches',0,
    'startedAt',NULL,'endsAt',NULL,'batchDurationMs',NULL,'activeBatches','[]'::jsonb,
    'upgrades','[]'::jsonb,'equipped','[]'::jsonb,
    'upgradeLevels',jsonb_build_object('good-stove',0,'large-pot',0,'grandma-recipe',0),
    'taskDay',v_today::text,'taskBatches',0,'lifetimeDumplings',0,'levelClaims','[]'::jsonb,
    'taskClaimedOn',NULL,'taskBalanceRewardVersion',1,'referralCode',NULL,
    'dailyDate',v_today::text,'dailyTaskVariant',v_variant,
    'dailyTasks',jsonb_build_object(
      'login',jsonb_build_object('progress',0,'claimed',false),
      'cook',jsonb_build_object('progress',0,'claimed',false),
      'upgrade',jsonb_build_object('progress',0,'claimed',false),
      'collect',jsonb_build_object('progress',0,'claimed',false),
      'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
      'collect-two',jsonb_build_object('progress',0,'claimed',false),
      'two-pots',jsonb_build_object('progress',0,'claimed',false)),
    'loginRewardDate',NULL,'firstLoginNoReward',false,
    'streakCurrent',0,'streakBest',0,'streakLastVisitDate',NULL,'streakRunStartedDate',NULL,
    'streakRewardClaims','[]'::jsonb,'taskPotsUsed','[]'::jsonb,
    'potCollections',jsonb_build_object('1',0,'2',0),
    'achievements','[]'::jsonb,'achievementClaims','[]'::jsonb,
    'joinedAt',NULL,'lastBatchReward',NULL,'lastBatchAt',NULL,'schemaVersion',6
  );
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  IF v_dry_run ->> 'status' IS DISTINCT FROM 'ready'
     OR v_dry_run ->> 'firstVisitEligible' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Canonical new profile did not retain reliable first-visit eligibility: %',v_dry_run;
  END IF;
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'activated'
     OR v_result ->> 'firstVisitEligible' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'First-visit eligible profile did not activate: %',v_result;
  END IF;
  v_result := public.economy_load_visit(v_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT game_state -> 'achievements' @> '["first-visit"]'::jsonb
         FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM TRUE
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 0 THEN
    RAISE EXCEPTION 'First visit was not recorded without an automatic reward: %',v_result;
  END IF;

  -- A first-visit candidate requires the complete seven-slot dailyTasks
  -- object and only the client-defined progress/claimed keys in each slot.
  -- A proven returning profile may still safely fill a missing inert slot.
  v_state := jsonb_build_object(
    'balance',0,'score',0,'points',0,'pointsRetired',true,'batches',0,
    'startedAt',NULL,'endsAt',NULL,'batchDurationMs',NULL,'activeBatches','[]'::jsonb,
    'upgrades','[]'::jsonb,'equipped','[]'::jsonb,
    'upgradeLevels',jsonb_build_object('good-stove',0,'large-pot',0,'grandma-recipe',0),
    'taskDay',v_today::text,'taskBatches',0,'lifetimeDumplings',0,'levelClaims','[]'::jsonb,
    'taskClaimedOn',NULL,'taskBalanceRewardVersion',1,'referralCode',NULL,
    'dailyDate',v_today::text,'dailyTaskVariant',v_variant,
    'dailyTasks',jsonb_build_object(
      'login',jsonb_build_object('progress',0,'claimed',false),
      'cook',jsonb_build_object('progress',0,'claimed',false),
      'upgrade',jsonb_build_object('progress',0,'claimed',false),
      'collect',jsonb_build_object('progress',0,'claimed',false),
      'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
      'collect-two',jsonb_build_object('progress',0,'claimed',false),
      'two-pots',jsonb_build_object('progress',0,'claimed',false)),
    'loginRewardDate',NULL,'firstLoginNoReward',false,
    'streakCurrent',0,'streakBest',0,'streakLastVisitDate',NULL,'streakRunStartedDate',NULL,
    'streakRewardClaims','[]'::jsonb,'taskPotsUsed','[]'::jsonb,
    'potCollections',jsonb_build_object('1',0,'2',0),
    'achievements','[]'::jsonb,'achievementClaims','[]'::jsonb,
    'joinedAt',NULL,'lastBatchReward',NULL,'lastBatchAt',NULL,'schemaVersion',6
  );
  IF public._pelmeni_is_first_visit(v_state) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Complete canonical dailyTasks state was not classified as a first visit';
  END IF;
  v_state := jsonb_set(v_state,'{dailyTasks}',(v_state -> 'dailyTasks') - 'collect-two',true);
  IF public._pelmeni_is_first_visit(v_state) IS NOT NULL THEN
    RAISE EXCEPTION 'A missing dailyTasks slot was classified as a new player';
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["first_visit_state_ambiguous"]'::jsonb) THEN
    RAISE EXCEPTION 'A partial empty dailyTasks object did not require review: %',v_assessment;
  END IF;

  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_set(
    jsonb_build_object(
      'login',jsonb_build_object('progress',0,'claimed',false),
      'cook',jsonb_build_object('progress',0,'claimed',false),
      'upgrade',jsonb_build_object('progress',0,'claimed',false),
      'collect',jsonb_build_object('progress',0,'claimed',false),
      'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
      'collect-two',jsonb_build_object('progress',0,'claimed',false),
      'two-pots',jsonb_build_object('progress',0,'claimed',false)),
    '{cook,unexpected}',to_jsonb('preserve-me'::text),true),true);
  IF public._pelmeni_is_first_visit(v_state) IS NOT NULL THEN
    RAISE EXCEPTION 'An unknown nested dailyTasks property was classified as a new player';
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["unknown_daily_task_property:cook"]'::jsonb) THEN
    RAISE EXCEPTION 'Unknown daily task property was not preserved for manual review: %',v_assessment;
  END IF;

  v_state := jsonb_set(v_state,'{balance}','10'::jsonb,true);
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'login',jsonb_build_object('progress',0,'claimed',false),
    'cook',jsonb_build_object('progress',0,'claimed',false),
    'upgrade',jsonb_build_object('progress',0,'claimed',false),
    'collect',jsonb_build_object('progress',0,'claimed',false),
    'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
    'two-pots',jsonb_build_object('progress',0,'claimed',false)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR v_assessment #>> '{candidateState,balance}' IS DISTINCT FROM '10'
     OR v_assessment #> '{candidateState,dailyTasks,collect-two}'
       IS DISTINCT FROM '{"progress": 0, "claimed": false}'::jsonb THEN
    RAISE EXCEPTION 'A confirmed old profile did not safely restore an absent inert task slot: %',v_assessment;
  END IF;

  -- Well-formed current-client markers are preserved. Exact duplicates are
  -- semantically inert and normalize like the client's Set, without paying.
  v_state := jsonb_set(v_state,'{balance}','0'::jsonb,true);
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'login',jsonb_build_object('progress',0,'claimed',false),
    'cook',jsonb_build_object('progress',0,'claimed',false),
    'upgrade',jsonb_build_object('progress',0,'claimed',false),
    'collect',jsonb_build_object('progress',0,'claimed',false),
    'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
    'collect-two',jsonb_build_object('progress',0,'claimed',false),
    'two-pots',jsonb_build_object('progress',0,'claimed',false)),true);
  v_state := jsonb_set(v_state,'{loginRewardDate}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{streakRewardClaims}',jsonb_build_array(
    v_yesterday::text||':0:0',v_yesterday::text||':0:0',
    v_yesterday::text||':0:1',v_yesterday::text||':0:1',
    v_yesterday::text||':2:3'),true);
  IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE
     OR public._pelmeni_is_first_visit(v_state) IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'Valid streak markers or duplicate markers were rejected or classified as new';
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR jsonb_array_length(v_assessment #> '{candidateState,streakRewardClaims}') <> 3
     OR v_assessment #> '{candidateState,streakRewardClaims}'
       IS DISTINCT FROM jsonb_build_array(v_yesterday::text||':0:0',v_yesterday::text||':0:1',v_yesterday::text||':2:3')
     OR v_assessment #>> '{candidateState,balance}' IS DISTINCT FROM '0' THEN
    RAISE EXCEPTION 'Valid duplicated streak markers were not safely deduplicated without payout: %',v_assessment;
  END IF;

  -- Duplicate copies of today's claim key still block the actual payout RPC;
  -- preflight deduplication must never turn a claimed day into an unpaid one.
  v_id := 9223372036854770212;
  v_state := jsonb_set(v_state,'{loginRewardDate}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{streakCurrent}','2'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakBest}','2'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakLastVisitDate}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{streakRunStartedDate}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{streakRewardClaims}',jsonb_build_array(
    v_today::text||':0:1',v_today::text||':0:1'),true);
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id,revision,server_mode,state_schema_version)
    VALUES(v_id,0,true,6);
  v_result := public.economy_claim_streak(v_id,'99999999-9999-4999-8999-999999999996');
  IF v_result #>> '{operation,result,error}' IS DISTINCT FROM 'streak_already_claimed'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 0
     OR (SELECT game_state -> 'streakRewardClaims' FROM public.player_state WHERE telegram_id=v_id)
       IS DISTINCT FROM jsonb_build_array(v_today::text||':0:1',v_today::text||':0:1') THEN
    RAISE EXCEPTION 'Duplicate today''s claim markers allowed a second streak reward: %',v_result;
  END IF;

  -- Invalid date/marker syntax combined with loginRewardDate is ambiguous:
  -- never discard it and infer whether an old payout happened.
  v_state := jsonb_set(v_state,'{streakRewardClaims}',jsonb_build_array(v_today::text||':x:1'),true);
  IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM FALSE
     OR public._pelmeni_is_first_visit(v_state) IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid streak marker key format was accepted or classified as a first visit';
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'Invalid marker format did not require manual review: %',v_assessment;
  END IF;

  v_state := jsonb_set(v_state,'{loginRewardDate}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{streakRewardClaims}',jsonb_build_array(
    '2026-02-30:0:1'),true);
  IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM FALSE
     OR public._pelmeni_is_first_visit(v_state) IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid streak marker date was accepted or classified as a first visit';
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
       @> '["first_visit_state_ambiguous"]'::jsonb) THEN
    RAISE EXCEPTION 'Malformed marker together with loginRewardDate was not routed to review: %',v_assessment;
  END IF;

  -- Activation rollover must preserve the source firstLoginNoReward exception
  -- when loginRewardDate already equals today. load_visit then sees the saved
  -- source flag, records only the visit marker, and leaves the manual claim open.
  v_id := 9223372036854770211;
  v_state := v_fixture_source;
  v_state := jsonb_set(v_state,'{dailyDate}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{taskDay}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{dailyTaskVariant}',to_jsonb(
    public._pelmeni_daily_task_variant(v_yesterday)),true);
  v_state := jsonb_set(v_state,'{taskClaimedOn}','null'::jsonb,true);
  v_state := jsonb_set(v_state,'{loginRewardDate}',to_jsonb(v_today::text),true);
  v_state := jsonb_set(v_state,'{firstLoginNoReward}','true'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakCurrent}','1'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakBest}','4'::jsonb,true);
  v_state := jsonb_set(v_state,'{streakLastVisitDate}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{streakRunStartedDate}',to_jsonb(v_yesterday::text),true);
  v_state := jsonb_set(v_state,'{streakRewardClaims}','[]'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb
     OR v_assessment #>> '{candidateState,firstLoginNoReward}' IS DISTINCT FROM 'true'
     OR v_assessment #>> '{candidateState,loginRewardDate}' IS DISTINCT FROM v_today::text THEN
    RAISE EXCEPTION 'Activation preparation erased the first-login exception before load_visit: %',v_assessment;
  END IF;
  INSERT INTO public.player_state(telegram_id,game_state,updated_at)
    VALUES(v_id,v_state,clock_timestamp());
  v_dry_run := public.economy_assess_legacy_profile(v_id);
  IF v_dry_run ->> 'status' IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'firstLoginNoReward rollover profile was not dry-run ready: %',v_dry_run;
  END IF;
  v_result := public.economy_activate_legacy_profile(v_id,v_dry_run ->> 'sourceHash',
    v_dry_run ->> 'candidateHash',(v_dry_run ->> 'dryRunUtcDate')::date);
  IF v_result ->> 'status' IS DISTINCT FROM 'activated'
     OR (SELECT game_state ->> 'firstLoginNoReward' FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM 'true'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 1234 THEN
    RAISE EXCEPTION 'Activation changed the source exception or balance: %',v_result;
  END IF;
  v_result := public.economy_load_visit(v_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT game_state -> 'streakRewardClaims' @> jsonb_build_array(v_today::text || ':0:0')
         FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM TRUE
     OR (SELECT game_state -> 'streakRewardClaims' @> jsonb_build_array(v_today::text || ':0:1')
         FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM FALSE
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 1234 THEN
    RAISE EXCEPTION 'Post-activation load_visit closed or paid the manual streak claim: %',v_result;
  END IF;
  v_result := public.economy_claim_streak(v_id,'99999999-9999-4999-8999-999999999995');
  IF v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR v_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '2'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state WHERE telegram_id=v_id) <> 1236 THEN
    RAISE EXCEPTION 'Manual streak claim failed after compatibility activation: %',v_result;
  END IF;

  v_id := 9223372036854770203;
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'cook',jsonb_build_object('progress','bad','claimed',false)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'Malformed daily task progress was not rejected';
  END IF;

  v_state := jsonb_set(v_state,'{activeBatches}',jsonb_build_array(jsonb_build_object(
    'id','expired-pot-one','pot',1,'startedAt',v_now_ms-100000,
    'endsAt',v_now_ms-50000,'durationMs',50000)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
      @> '["expired_active_batch_requires_review"]'::jsonb) THEN
    RAISE EXCEPTION 'Expired active batch was not explicitly held for review: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{activeBatches}',jsonb_build_array(jsonb_build_object(
    'id','mismatched-pot-one','pot',1,'startedAt',v_now_ms-100000,
    'endsAt',v_now_ms+50000,'durationMs',50000)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
      @> '["active_batch_duration_mismatch_requires_review"]'::jsonb) THEN
    RAISE EXCEPTION 'Mismatched saved timer was not explicitly held for review: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{activeBatches}',jsonb_build_array(jsonb_build_object(
    'id','malformed-pot-one','pot',1,'startedAt','bad','endsAt',v_now_ms+50000)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF NOT (COALESCE(v_assessment -> 'reasons','[]'::jsonb)
      @> '["invalid_active_batch_duration"]'::jsonb) THEN
    RAISE EXCEPTION 'Malformed active batch timer was not held for review: %',v_assessment;
  END IF;

  -- Isolate the unowned-pot case from the malformed-task case above and from
  -- the shared fixture's second-pot ownership. Keep the same legacy profile,
  -- but remove every ownership marker for pot 2 and restore valid stale-day
  -- task data. The batch predates today's UTC boundary, remains active, and
  -- has internally consistent timestamps so only pot ownership is under test.
  v_state := jsonb_set(v_state,'{dailyTasks}',jsonb_build_object(
    'login',jsonb_build_object('progress',0,'claimed',false),
    'cook',jsonb_build_object('progress',0,'claimed',false),
    'upgrade',jsonb_build_object('progress',0,'claimed',false),
    'collect',jsonb_build_object('progress',0,'claimed',false),
    'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
    'collect-two',jsonb_build_object('progress',0,'claimed',false),
    'two-pots',jsonb_build_object('progress',0,'claimed',false)),true);
  v_state := jsonb_set(v_state,'{upgrades}',(v_state -> 'upgrades') - 'second-pot',true);
  v_state := jsonb_set(v_state,'{equipped}',(v_state -> 'equipped') - 'second-pot',true);
  v_state := jsonb_set(v_state,'{upgradeLevels,second-pot}','0'::jsonb,true);
  v_state := jsonb_set(v_state,'{potCollections,2}','0'::jsonb,true);
  v_state := jsonb_set(v_state,'{taskPotsUsed}','[]'::jsonb,true);
  v_state := jsonb_set(v_state,'{activeBatches}',jsonb_build_array(jsonb_build_object(
    'id','unowned-pot-two','pot',2,'startedAt',v_today_start_ms-1000,
    'endsAt',v_now_ms+60000,'durationMs',v_now_ms+61000-v_today_start_ms)),true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb
     OR v_assessment -> 'reasons' IS DISTINCT FROM
       '["batch_uses_unowned_pot_requires_review"]'::jsonb THEN
    RAISE EXCEPTION 'Batch in an unowned pot was not held for review: %',v_assessment;
  END IF;
  v_state := jsonb_set(v_state,'{activeBatches}','[]'::jsonb,true);

  -- Missing claim ledgers are not treated as proof of no prior payout.
  v_state := jsonb_set(v_state,'{dailyTaskVariant}',to_jsonb(v_variant),true);
  v_state := jsonb_set(v_state,'{achievements}','["first-visit"]'::jsonb,true);
  v_state := v_state - 'achievementClaims';
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'Missing achievement claim history with an unlocked achievement was accepted';
  END IF;
  v_state := jsonb_set(v_state,'{achievements}','[]'::jsonb,true) - 'levelClaims';
  v_state := jsonb_set(v_state,'{score}','500'::jsonb,true);
  v_assessment := public._pelmeni_prepare_legacy_state(v_state,v_today);
  IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'Missing level claim history after reaching a claim threshold was accepted';
  END IF;

  -- Ensure assessment itself has no side effect on any source profile.
  -- SQL NULL game_state cannot produce a valid fingerprint/snapshot. Exercise
  -- the assessment guard only when the actual table permits such a row;
  -- otherwise the schema constraint itself rules out this input.
  SELECT is_nullable INTO v_game_state_nullable
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='player_state' AND column_name='game_state';
  IF v_game_state_nullable = 'YES' THEN
    v_id := 9223372036854770207;
    INSERT INTO public.player_state(telegram_id,game_state,updated_at)
      VALUES(v_id,NULL,clock_timestamp());
    v_expected_profile_count := v_expected_profile_count + 1;
    v_dry_run := public.economy_assess_legacy_profile(v_id);
    IF v_dry_run ->> 'status' IS DISTINCT FROM 'manual_review_required'
       OR NOT (COALESCE(v_dry_run -> 'reasons','[]'::jsonb) @> '["legacy_state_not_object"]'::jsonb)
       OR (SELECT game_state FROM public.player_state WHERE telegram_id=v_id) IS NOT NULL
       OR EXISTS (SELECT 1 FROM public.player_economy_migration_snapshots WHERE telegram_id=v_id) THEN
      RAISE EXCEPTION 'SQL NULL game_state was not kept untouched for manual review: %',v_dry_run;
    END IF;
  ELSE
    v_assessment := public._pelmeni_prepare_legacy_state(NULL,v_today);
    IF v_assessment -> 'ok' IS DISTINCT FROM 'false'::jsonb THEN
      RAISE EXCEPTION 'SQL NULL state was not rejected by the compatibility helper: %',v_assessment;
    END IF;
  END IF;

  -- JSON null and scalar JSONB values are storable in jsonb columns. Assessment
  -- must report them for review, not throw while collecting unknown object keys.
  FOR v_id, v_state IN
    SELECT 9223372036854770209::bigint, 'null'::jsonb
    UNION ALL
    SELECT 9223372036854770210::bigint, '"corrupt-scalar"'::jsonb
  LOOP
    INSERT INTO public.player_state(telegram_id,game_state,updated_at)
      VALUES(v_id,v_state,clock_timestamp());
    v_dry_run := public.economy_assess_legacy_profile(v_id);
    IF v_dry_run ->> 'status' IS DISTINCT FROM 'manual_review_required'
       OR NOT (COALESCE(v_dry_run -> 'reasons','[]'::jsonb) @> '["game_state_not_object"]'::jsonb)
       OR (SELECT game_state FROM public.player_state WHERE telegram_id=v_id) IS DISTINCT FROM v_state
       OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id=v_id) THEN
      RAISE EXCEPTION 'Non-object game_state was not safely reported for review: %',v_dry_run;
    END IF;
    v_expected_profile_count := v_expected_profile_count + 1;
  END LOOP;

  IF (SELECT count(*) FROM public.player_state WHERE telegram_id BETWEEN 9223372036854770200 AND 9223372036854770212) <> v_expected_profile_count THEN
    RAISE EXCEPTION 'Unexpected fixture count: expected %, actual %',v_expected_profile_count,
      (SELECT count(*) FROM public.player_state WHERE telegram_id BETWEEN 9223372036854770200 AND 9223372036854770212);
  END IF;
END
$test$;

ROLLBACK;

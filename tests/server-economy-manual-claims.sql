-- Regression test for manual streak/task/achievement claims.
-- Run ONLY in a disposable PostgreSQL/Supabase database after applying the
-- local server-economy migration. The transaction is rolled back at the end.
BEGIN;
SET LOCAL ROLE service_role;

DO $test$
DECLARE
  v_today text := (clock_timestamp() AT TIME ZONE 'UTC')::date::text;
  v_today_variant text;
  v_yesterday_variant text;
  v_variant_candidate text;
  v_day_tasks jsonb := jsonb_build_object(
    'login', jsonb_build_object('progress', 0, 'claimed', false),
    'cook', jsonb_build_object('progress', 1, 'claimed', false),
    'upgrade', jsonb_build_object('progress', 0, 'claimed', false),
    'collect', jsonb_build_object('progress', 0, 'claimed', false),
    'collect-dumplings', jsonb_build_object('progress', 0, 'claimed', false),
    'collect-two', jsonb_build_object('progress', 0, 'claimed', false),
    'two-pots', jsonb_build_object('progress', 0, 'claimed', false)
  );
  v_state jsonb;
  v_current_state jsonb;
  v_result jsonb;
  v_balance bigint;
  v_score bigint;
  v_lifetime bigint;
  v_claims jsonb;
  v_revision bigint;
  v_state_key_count integer;
  v_batches jsonb;
  v_started_at bigint;
  v_ends_at bigint;
  v_duration_ms bigint;
  v_first_id bigint := 9223372036854770001;
  v_returning_id bigint := 9223372036854770002;
  v_legacy_paid_id bigint := 9223372036854770003;
  v_current_format_id bigint := 9223372036854770004;
  v_rollover_id bigint := 9223372036854770005;
  v_variant_mismatch_id bigint := 9223372036854770006;
  v_no_legacy_payout_id bigint := 9223372036854770007;
  v_legacy_payout_marker_id bigint := 9223372036854770008;
  v_no_legacy_payout_rollover_id bigint := 9223372036854770009;
  v_batch_start bigint;
  v_batch_end bigint;
  v_daily_tasks_after jsonb;
  v_variant_after text;
  v_login_reward_date_after text;
  v_variant_index integer;
  v_variant_name text;
  v_variant_profile_id bigint;
  v_variant_goal integer;
  v_variant_result jsonb;
  v_variant_policy_state jsonb;
  v_variant_incomplete_state jsonb;
  v_variant_complete_state jsonb;
  v_variant_claimed_state jsonb;
  v_variant_policy jsonb;
  v_policy_task text;
  v_policy_reward bigint;
  v_retry uuid := '11111111-1111-4111-8111-111111111111';
BEGIN
  -- Mirrors dailyTaskVariantForDate(): UTC epoch-day modulo the three ordered
  -- variant IDs (classic, batch-focus, kitchen-rhythm).
  v_today_variant := CASE mod((v_today::date - DATE '1970-01-01'), 3)
    WHEN 0 THEN 'classic' WHEN 1 THEN 'batch-focus' ELSE 'kitchen-rhythm' END;
  v_day_tasks := jsonb_set(v_day_tasks, '{cook,progress}',
    to_jsonb(CASE WHEN v_today_variant = 'batch-focus' THEN 2 ELSE 1 END), true);
  v_yesterday_variant := CASE mod((v_today::date - DATE '1970-01-02'), 3)
    WHEN 0 THEN 'classic' WHEN 1 THEN 'batch-focus' ELSE 'kitchen-rhythm' END;

  IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id IN
      (v_first_id, v_returning_id, v_legacy_paid_id, v_current_format_id, v_rollover_id,
       v_variant_mismatch_id, v_no_legacy_payout_id, v_legacy_payout_marker_id,
       v_no_legacy_payout_rollover_id, 9223372036854770100, 9223372036854770101,
       9223372036854770102, 9223372036854770103)) THEN
    RAISE EXCEPTION 'Manual-claim test fixture IDs already exist; choose new synthetic IDs';
  END IF;

  -- Canonical first-visit profile. Loading may record the visit and unlock the
  -- welcome achievement, but must not award any dumplings.
  v_state := jsonb_build_object(
    'balance', 0, 'score', 0, 'points', 0, 'pointsRetired', true, 'batches', 0,
    'startedAt', NULL, 'endsAt', NULL, 'batchDurationMs', NULL,
    'activeBatches', '[]'::jsonb, 'upgrades', '[]'::jsonb, 'equipped', '[]'::jsonb,
    'upgradeLevels', jsonb_build_object('good-stove',0,'large-pot',0,'grandma-recipe',0),
    'taskDay', v_today, 'taskBatches', 0, 'lifetimeDumplings', 0,
    'levelClaims', '[]'::jsonb, 'taskClaimedOn', NULL, 'taskBalanceRewardVersion', 1,
    'referralCode', NULL, 'dailyDate', v_today, 'dailyTasks',
      jsonb_build_object(
        'login', jsonb_build_object('progress',0,'claimed',false),
        'cook', jsonb_build_object('progress',0,'claimed',false),
        'upgrade', jsonb_build_object('progress',0,'claimed',false),
        'collect', jsonb_build_object('progress',0,'claimed',false),
        'collect-dumplings', jsonb_build_object('progress',0,'claimed',false),
        'collect-two', jsonb_build_object('progress',0,'claimed',false),
        'two-pots', jsonb_build_object('progress',0,'claimed',false)),
    'dailyTaskVariant', v_today_variant, 'loginRewardDate', NULL, 'firstLoginNoReward', false,
    'streakCurrent', 0, 'streakBest', 0, 'streakLastVisitDate', NULL,
    'streakRunStartedDate', NULL, 'streakRewardClaims', '[]'::jsonb,
    'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1',0,'2',0),
    'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
    'joinedAt', NULL, 'lastBatchReward', NULL, 'lastBatchAt', NULL, 'schemaVersion', 6
  );
  IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Current serializer-shaped profile failed state validation';
  END IF;
  FOREACH v_variant_candidate IN ARRAY ARRAY['classic', 'batch-focus', 'kitchen-rhythm'] LOOP
    IF public._pelmeni_state_shape_is_valid(
         jsonb_set(v_state, '{dailyTaskVariant}', to_jsonb(v_variant_candidate), true)) IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Valid dailyTaskVariant % was rejected', v_variant_candidate;
    END IF;
  END LOOP;
  IF public._pelmeni_state_shape_is_valid(
       jsonb_set(v_state, '{dailyTaskVariant}', '"future-variant"'::jsonb, true)) IS DISTINCT FROM FALSE
     OR public._pelmeni_state_shape_is_valid(
       jsonb_set(v_state, '{dailyTaskVariant}', '1'::jsonb, true)) IS DISTINCT FROM FALSE
     OR public._pelmeni_state_shape_is_valid(
       jsonb_set(v_state, '{achievementClaims}', '["not-an-achievement"]'::jsonb, true)) IS DISTINCT FROM FALSE
     OR public._pelmeni_state_shape_is_valid(
       jsonb_set(v_state, '{achievementClaims}', '[1]'::jsonb, true)) IS DISTINCT FROM FALSE
     OR public._pelmeni_state_shape_is_valid(
       jsonb_set(v_state, '{achievementClaims}', '["first-visit"]'::jsonb, true)) IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'Malformed/unknown/unlocked-claim field values were accepted';
  END IF;
  IF public._pelmeni_state_shape_is_valid(
       jsonb_set(jsonb_set(v_state, '{achievements}', '["first-visit"]'::jsonb, true),
                 '{achievementClaims}', '["first-visit"]'::jsonb, true)) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Valid unlocked achievement claim was rejected';
  END IF;
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_first_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_first_id, 0, true, 6);

  v_result := public.economy_load_visit(v_first_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'First current-format load_visit failed: %', v_result;
  END IF;
  SELECT (game_state ->> 'balance')::bigint,
         (game_state ->> 'score')::bigint,
         (game_state ->> 'lifetimeDumplings')::bigint
    INTO v_balance, v_score, v_lifetime
  FROM public.player_state WHERE telegram_id = v_first_id;
  IF v_balance <> 0 OR v_score <> 0 OR v_lifetime <> 0 THEN
    RAISE EXCEPTION 'First load_visit unexpectedly paid a reward';
  END IF;
  IF (SELECT game_state -> 'achievements' @> '["first-visit"]'::jsonb
      FROM public.player_state WHERE telegram_id = v_first_id) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'First-visit achievement was not unlocked';
  END IF;

  v_result := public.economy_claim_achievement(v_first_id, v_retry, 'first-visit');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR v_result #>> '{operation,status}' <> 'applied' THEN
    RAISE EXCEPTION 'First-visit achievement claim did not apply: %', v_result;
  END IF;
  v_result := public.economy_claim_achievement(v_first_id, v_retry, 'first-visit');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR v_result #>> '{operation,status}' <> 'applied' THEN
    RAISE EXCEPTION 'Identical request retry did not replay its original receipt: %', v_result;
  END IF;
  v_result := public.economy_claim_achievement(v_first_id,
    '22222222-2222-4222-8222-222222222222', 'first-visit');
  IF v_result #>> '{operation,result,error}' <> 'achievement_already_claimed' THEN
    RAISE EXCEPTION 'Achievement was claimable a second time: %', v_result;
  END IF;
  SELECT (game_state ->> 'balance')::bigint,
         (game_state ->> 'score')::bigint,
         (game_state ->> 'lifetimeDumplings')::bigint,
         game_state -> 'achievementClaims',
         revision
    INTO v_balance, v_score, v_lifetime, v_claims, v_revision
  FROM public.player_state AS p
  JOIN public.player_economy_control AS c USING (telegram_id)
  WHERE p.telegram_id = v_first_id;
  IF v_balance <> 5 OR v_score <> 5 OR v_lifetime <> 0
     OR v_claims <> '["first-visit"]'::jsonb OR v_revision <> 2 THEN
    RAISE EXCEPTION 'Achievement payout fields are incorrect';
  END IF;

  -- Separate regression fixture built with the current serializer's complete
  -- key set, including dailyTaskVariant and achievementClaims. It must load,
  -- unlock first-visit, and allow exactly the explicit 5-dumpling claim.
  SELECT count(*) INTO v_state_key_count FROM jsonb_object_keys(v_state);
  IF v_state_key_count <> 37
     OR NOT (v_state ?& ARRAY[
       'balance', 'score', 'points', 'pointsRetired', 'batches', 'startedAt', 'endsAt', 'batchDurationMs',
       'activeBatches', 'upgrades', 'equipped', 'upgradeLevels', 'taskDay', 'taskBatches',
       'lifetimeDumplings', 'levelClaims', 'taskClaimedOn', 'taskBalanceRewardVersion', 'referralCode',
       'dailyDate', 'dailyTasks', 'dailyTaskVariant', 'loginRewardDate', 'firstLoginNoReward',
       'streakCurrent', 'streakBest', 'streakLastVisitDate', 'streakRunStartedDate', 'streakRewardClaims',
       'taskPotsUsed', 'potCollections', 'achievements', 'achievementClaims', 'joinedAt',
       'lastBatchReward', 'lastBatchAt', 'schemaVersion'
     ]) THEN
    RAISE EXCEPTION 'Current-format fixture no longer matches all 37 fields from serializeState()';
  END IF;
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_current_format_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_current_format_id, 0, true, 6);
  v_result := public.economy_load_visit(v_current_format_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Current-format regression load_visit failed: %', v_result;
  END IF;
  IF (SELECT game_state -> 'achievements' @> '["first-visit"]'::jsonb
      FROM public.player_state WHERE telegram_id = v_current_format_id) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Current-format profile did not unlock first-visit';
  END IF;
  SELECT (game_state ->> 'balance')::bigint INTO v_balance
  FROM public.player_state WHERE telegram_id = v_current_format_id;
  IF v_balance <> 0 THEN RAISE EXCEPTION 'Current-format load_visit paid automatically'; END IF;
  v_result := public.economy_claim_achievement(v_current_format_id,
    '88888888-8888-4888-8888-888888888888', 'first-visit');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR v_result #>> '{operation,status}' <> 'applied'
     OR v_result #>> '{operation,result,dumplings}' <> '5' THEN
    RAISE EXCEPTION 'Current-format first-visit claim failed: %', v_result;
  END IF;

  -- A valid but wrong variant value cannot override the server's UTC schedule.
  v_current_state := v_state;
  v_state := jsonb_set(v_current_state, '{dailyTaskVariant}', to_jsonb(
    CASE v_today_variant WHEN 'classic' THEN 'batch-focus'
      WHEN 'batch-focus' THEN 'kitchen-rhythm' ELSE 'classic' END), true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_variant_mismatch_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_variant_mismatch_id, 0, true, 6);
  v_result := public.economy_load_visit(v_variant_mismatch_id);
  IF v_result ->> 'error' IS DISTINCT FROM 'daily_task_variant_stale' THEN
    RAISE EXCEPTION 'load_visit accepted a client-selected non-UTC variant: %', v_result;
  END IF;
  v_result := public.economy_start_batch(v_variant_mismatch_id,
    'eeeeeeee-0000-4000-8000-000000000001', 1);
  IF v_result ->> 'error' IS DISTINCT FROM 'daily_task_variant_stale' THEN
    RAISE EXCEPTION 'Economy command accepted a non-UTC variant: %', v_result;
  END IF;
  SELECT p.game_state, c.revision INTO v_state, v_revision
  FROM public.player_state AS p JOIN public.player_economy_control AS c USING (telegram_id)
  WHERE p.telegram_id = v_variant_mismatch_id;
  IF v_state IS DISTINCT FROM jsonb_set(v_current_state, '{dailyTaskVariant}', to_jsonb(
       CASE v_today_variant WHEN 'classic' THEN 'batch-focus'
         WHEN 'batch-focus' THEN 'kitchen-rhythm' ELSE 'classic' END), true)
     OR v_revision IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'Rejected non-UTC variant request modified state or revision';
  END IF;

  -- UTC rollover mirrors app.js: reset all seven serialized daily task slots,
  -- select the UTC-date variant, and preserve today's already-paid login marker.
  v_state := jsonb_set(v_current_state, '{dailyDate}', to_jsonb((v_today::date - 1)::text), true);
  v_state := jsonb_set(v_state, '{taskDay}', to_jsonb((v_today::date - 1)::text), true);
  v_state := jsonb_set(v_state, '{dailyTaskVariant}', to_jsonb(v_yesterday_variant), true);
  v_state := jsonb_set(v_state, '{dailyTasks,cook,progress}', '9'::jsonb, true);
  v_state := jsonb_set(v_state, '{dailyTasks,collect,progress}', '5'::jsonb, true);
  v_state := jsonb_set(v_state, '{dailyTasks,collect-two,progress}', '2'::jsonb, true);
  v_state := jsonb_set(v_state, '{loginRewardDate}', to_jsonb(v_today), true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_rollover_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_rollover_id, 0, true, 6);
  v_result := public.economy_load_visit(v_rollover_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'UTC rollover load_visit failed: %', v_result;
  END IF;
  SELECT p.game_state -> 'dailyTasks', p.game_state ->> 'dailyTaskVariant',
         p.game_state ->> 'loginRewardDate', (p.game_state ->> 'balance')::bigint
    INTO v_daily_tasks_after, v_variant_after, v_login_reward_date_after, v_balance
  FROM public.player_state AS p WHERE p.telegram_id = v_rollover_id;
  IF v_daily_tasks_after -> 'cook' IS DISTINCT FROM '{"progress": 0, "claimed": false}'::jsonb
     OR v_daily_tasks_after -> 'collect' IS DISTINCT FROM '{"progress": 0, "claimed": false}'::jsonb
     OR v_daily_tasks_after -> 'collect-two' IS DISTINCT FROM '{"progress": 0, "claimed": false}'::jsonb
     OR v_variant_after IS DISTINCT FROM v_today_variant
     OR v_login_reward_date_after IS DISTINCT FROM v_today
     OR v_balance IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'UTC rollover did not reset tasks/variant safely or changed the paid-login marker';
  END IF;
  v_result := public.economy_claim_task(v_rollover_id,
    'd0000000-0000-4000-8000-000000000001', 'cook');
  IF v_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
    RAISE EXCEPTION 'Yesterday task progress remained claimable after UTC rollover: %', v_result;
  END IF;

  -- Test the exact shared policy function for all variants on every run. The
  -- RPCs correctly reject a variant that is not today's server-selected UTC
  -- variant, so full transaction scenarios below execute for today's variant;
  -- rerun this script across the three-day rotation for all three end-to-end.
  FOR v_variant_index IN 0..2 LOOP
    v_variant_name := CASE v_variant_index
      WHEN 0 THEN 'classic' WHEN 1 THEN 'batch-focus' ELSE 'kitchen-rhythm' END;
    v_variant_goal := CASE WHEN v_variant_name = 'batch-focus' THEN 2 ELSE 1 END;
    IF public._pelmeni_daily_task_variant(DATE '1970-01-01' + v_variant_index) IS DISTINCT FROM v_variant_name THEN
      RAISE EXCEPTION 'UTC variant helper disagrees with the client order at index %', v_variant_index;
    END IF;
    v_variant_policy_state := jsonb_build_object('dailyTaskVariant', v_variant_name,
      'dailyTasks', jsonb_build_object(
        'cook', jsonb_build_object('progress',1,'claimed',false),
        'collect', jsonb_build_object('progress',2,'claimed',false),
        'collect-dumplings', jsonb_build_object('progress',30,'claimed',false),
        'collect-two', jsonb_build_object('progress',1,'claimed',false),
        'upgrade', jsonb_build_object('progress',1,'claimed',false),
        'two-pots', jsonb_build_object('progress',1,'claimed',false)));
    v_variant_incomplete_state := jsonb_build_object('dailyTaskVariant', v_variant_name,
      'dailyTasks', jsonb_build_object(
        'cook', jsonb_build_object('progress',0,'claimed',false),
        'collect', jsonb_build_object('progress',0,'claimed',false),
        'collect-dumplings', jsonb_build_object('progress',0,'claimed',false),
        'collect-two', jsonb_build_object('progress',0,'claimed',false),
        'upgrade', jsonb_build_object('progress',0,'claimed',false),
        'two-pots', jsonb_build_object('progress',0,'claimed',false)));
    v_variant_complete_state := jsonb_set(v_variant_policy_state,
      '{dailyTasks,cook,progress}', to_jsonb(v_variant_goal), true);
    v_variant_complete_state := jsonb_set(v_variant_complete_state,
      '{dailyTasks,collect-two,progress}', '2'::jsonb, true);
    v_variant_policy := public._pelmeni_daily_task_policy(v_variant_policy_state, 'cook');
    IF (v_variant_policy ->> 'goal')::integer IS DISTINCT FROM v_variant_goal
       OR (v_variant_policy ->> 'progress')::integer IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION '% cook policy goal/progress mismatch: %', v_variant_name, v_variant_policy;
    END IF;
    v_variant_policy := public._pelmeni_daily_task_policy(v_variant_policy_state, 'collect');
    IF (v_variant_policy ->> 'goal')::integer IS DISTINCT FROM (CASE WHEN v_variant_name = 'batch-focus' THEN 2 ELSE 1 END)
       OR (v_variant_policy ->> 'progress')::integer IS DISTINCT FROM (CASE WHEN v_variant_name = 'kitchen-rhythm' THEN 1 ELSE 2 END) THEN
      RAISE EXCEPTION '% collection policy goal/progress mismatch: %', v_variant_name, v_variant_policy;
    END IF;
    v_variant_policy := public._pelmeni_daily_task_policy(v_variant_policy_state, 'collect-dumplings');
    IF (v_variant_policy ->> 'goal')::integer IS DISTINCT FROM (CASE WHEN v_variant_name = 'kitchen-rhythm' THEN 2 ELSE 30 END)
       OR (v_variant_policy ->> 'progress')::integer IS DISTINCT FROM (CASE WHEN v_variant_name = 'kitchen-rhythm' THEN 1 ELSE 30 END) THEN
      RAISE EXCEPTION '% dumpling policy goal/progress mismatch: %', v_variant_name, v_variant_policy;
    END IF;
    IF public._pelmeni_daily_task_policy(v_variant_policy_state, 'collect-two') IS NOT NULL THEN
      RAISE EXCEPTION 'Internal collect-two counter unexpectedly became a claimable task';
    END IF;
    FOREACH v_policy_task IN ARRAY ARRAY['cook', 'collect', 'collect-dumplings', 'upgrade', 'two-pots'] LOOP
      v_variant_policy := public._pelmeni_daily_task_policy(v_variant_incomplete_state, v_policy_task);
      IF v_variant_policy ->> 'status' IS DISTINCT FROM 'task_not_complete' THEN
        RAISE EXCEPTION '% % task was not rejected while incomplete: %', v_variant_name, v_policy_task, v_variant_policy;
      END IF;
      v_variant_policy := public._pelmeni_daily_task_policy(v_variant_complete_state, v_policy_task);
      v_policy_reward := CASE v_policy_task
        WHEN 'cook' THEN 10 WHEN 'collect' THEN 5 WHEN 'collect-dumplings' THEN 10
        WHEN 'upgrade' THEN 15 ELSE 5 END;
      IF v_variant_policy ->> 'status' IS DISTINCT FROM 'applied'
         OR v_variant_policy ->> 'reward' IS DISTINCT FROM v_policy_reward::text THEN
        RAISE EXCEPTION '% % task did not complete with its existing reward: %', v_variant_name, v_policy_task, v_variant_policy;
      END IF;
      v_variant_claimed_state := jsonb_set(v_variant_complete_state,
        ARRAY['dailyTasks', v_policy_task, 'claimed'], 'true'::jsonb, true);
      v_variant_policy := public._pelmeni_daily_task_policy(v_variant_claimed_state, v_policy_task);
      IF v_variant_policy ->> 'status' IS DISTINCT FROM 'task_already_claimed' THEN
        RAISE EXCEPTION '% % reward was not protected from a repeated claim: %', v_variant_name, v_policy_task, v_variant_policy;
      END IF;
    END LOOP;

    IF v_variant_name <> v_today_variant THEN CONTINUE; END IF;

    -- Ready batches are synthetic trusted fixtures; all progress changes under
    -- test are then generated only by economy_collect_batch/start_batch RPCs.
    v_variant_profile_id := 9223372036854770100 + v_variant_index;
    IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = v_variant_profile_id) THEN
      RAISE EXCEPTION 'Daily-variant fixture id % already exists', v_variant_profile_id;
    END IF;

    v_batch_start := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint - 120000;
    v_batch_end := v_batch_start + 60000;
    v_state := jsonb_build_object(
      'balance', 0, 'score', 0, 'points', 0, 'pointsRetired', true, 'batches', 0,
      'startedAt', v_batch_start, 'endsAt', v_batch_end, 'batchDurationMs', 60000,
      'activeBatches', jsonb_build_array(
        jsonb_build_object('id','ready-pot-one','pot',1,'startedAt',v_batch_start,'endsAt',v_batch_end,'durationMs',60000),
        jsonb_build_object('id','ready-pot-two','pot',2,'startedAt',v_batch_start,'endsAt',v_batch_end,'durationMs',60000)),
      'upgrades', jsonb_build_array('second-pot','herb-pot','wooden-spoon'),
      'equipped', jsonb_build_array('second-pot','herb-pot','wooden-spoon'),
      'upgradeLevels', jsonb_build_object('good-stove',0,'large-pot',10,'grandma-recipe',10),
      'taskDay', v_today, 'taskBatches', 0, 'lifetimeDumplings', 0,
      'levelClaims', '[]'::jsonb, 'taskClaimedOn', NULL, 'taskBalanceRewardVersion', 1,
      'referralCode', NULL, 'dailyDate', v_today,
      'dailyTasks', jsonb_build_object(
        'login', jsonb_build_object('progress',0,'claimed',false),
        'cook', jsonb_build_object('progress',v_variant_goal - 1,'claimed',false),
        'upgrade', jsonb_build_object('progress',0,'claimed',false),
        'collect', jsonb_build_object('progress',0,'claimed',false),
        'collect-dumplings', jsonb_build_object('progress',0,'claimed',false),
        'collect-two', jsonb_build_object('progress',0,'claimed',false),
        'two-pots', jsonb_build_object('progress',0,'claimed',false)),
      'dailyTaskVariant', v_variant_name, 'loginRewardDate', NULL, 'firstLoginNoReward', false,
      'streakCurrent', 1, 'streakBest', 1, 'streakLastVisitDate', v_today,
      'streakRunStartedDate', v_today, 'streakRewardClaims', jsonb_build_array(v_today || ':0:0'),
      'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1',0,'2',0),
      'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
      'joinedAt', clock_timestamp(), 'lastBatchReward', NULL, 'lastBatchAt', NULL, 'schemaVersion', 6
    );
    IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Variant fixture for % failed shape validation', v_variant_name;
    END IF;
    INSERT INTO public.player_state(telegram_id, game_state, updated_at)
    VALUES (v_variant_profile_id, v_state, clock_timestamp());
    INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
    VALUES (v_variant_profile_id, 0, true, 6);

    -- No reward may be claimed from client-supplied or partial progress.
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000001', 'cook');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
      RAISE EXCEPTION '% cook task was claimable before a server start: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000002', 'collect');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
      RAISE EXCEPTION '% collect task was claimable before a server collection: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000003', 'collect-dumplings');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
      RAISE EXCEPTION '% dumpling task was claimable before a server collection: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000018', 'collect-two');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'unknown_task' THEN
      RAISE EXCEPTION 'Internal collect-two counter was directly claimable: %', v_variant_result;
    END IF;

    v_variant_result := public.economy_collect_batch(v_variant_profile_id,
      'a0000000-0000-4000-8000-000000000001', 'ready-pot-one');
    IF v_variant_result ->> 'ok' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION '% first pot collection failed: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000004', 'collect');
    IF v_variant_name = 'classic' THEN
      IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
         OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '5' THEN
        RAISE EXCEPTION 'Classic collect goal did not complete after one batch: %', v_variant_result;
      END IF;
    ELSIF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
      RAISE EXCEPTION '% collect goal completed too early after one batch: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000005', 'collect-dumplings');
    IF v_variant_name IN ('classic', 'batch-focus') THEN
      IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
         OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '10' THEN
        RAISE EXCEPTION '% amount goal did not complete at 30 dumplings: %', v_variant_name, v_variant_result;
      END IF;
    ELSIF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
      RAISE EXCEPTION 'Kitchen-rhythm two-batch goal completed after one collection: %', v_variant_result;
    END IF;

    v_variant_result := public.economy_collect_batch(v_variant_profile_id,
      'a0000000-0000-4000-8000-000000000002', 'ready-pot-two');
    IF v_variant_result ->> 'ok' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION '% second pot collection failed: %', v_variant_name, v_variant_result;
    END IF;

    v_variant_result := public.economy_start_batch(v_variant_profile_id,
      'a0000000-0000-4000-8000-000000000003', 1);
    IF v_variant_result ->> 'ok' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION '% first server start failed: %', v_variant_name, v_variant_result;
    END IF;
    IF v_variant_name <> 'classic' THEN
      v_variant_result := public.economy_claim_task(v_variant_profile_id,
        'b0000000-0000-4000-8000-000000000006', 'collect');
      IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
         OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '5' THEN
        RAISE EXCEPTION '% collection task did not complete after its variant goal: %', v_variant_name, v_variant_result;
      END IF;
    END IF;

    IF v_variant_name = 'classic' THEN
      v_variant_result := public.economy_claim_task(v_variant_profile_id,
        'b0000000-0000-4000-8000-000000000007', 'collect');
      IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
        RAISE EXCEPTION 'Classic collect reward could be claimed twice: %', v_variant_result;
      END IF;
    ELSIF v_variant_name = 'batch-focus' THEN
      v_variant_result := public.economy_claim_task(v_variant_profile_id,
        'b0000000-0000-4000-8000-000000000008', 'collect');
      IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
        RAISE EXCEPTION 'Batch-focus collect reward could be claimed twice: %', v_variant_result;
      END IF;
    END IF;

    IF v_variant_name = 'kitchen-rhythm' THEN
      v_variant_result := public.economy_claim_task(v_variant_profile_id,
        'b0000000-0000-4000-8000-000000000009', 'collect-dumplings');
      IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
         OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '10' THEN
        RAISE EXCEPTION 'Kitchen-rhythm collect-two goal did not complete after two batches: %', v_variant_result;
      END IF;
      v_variant_result := public.economy_claim_task(v_variant_profile_id,
        'b0000000-0000-4000-8000-000000000019', 'collect');
      IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
        RAISE EXCEPTION 'Kitchen-rhythm collect reward could be claimed twice: %', v_variant_result;
      END IF;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000017', 'collect-dumplings');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
      RAISE EXCEPTION '% dumpling reward was claimable twice: %', v_variant_name, v_variant_result;
    END IF;

    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000010', 'cook');
    IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
       OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '10' THEN
      RAISE EXCEPTION '% cook goal did not reach its variant target: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000011', 'cook');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
      RAISE EXCEPTION '% cook reward was claimable twice: %', v_variant_name, v_variant_result;
    END IF;

    v_variant_result := public.economy_purchase_decoration(v_variant_profile_id,
      'c0000000-0000-4000-8000-000000000001', 'blue-tile');
    IF v_variant_result ->> 'ok' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION '% upgrade action could not create server-verified task progress: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000012', 'upgrade');
    IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
       OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '15' THEN
      RAISE EXCEPTION '% upgrade task did not award 15: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000013', 'upgrade');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
      RAISE EXCEPTION '% upgrade reward was claimable twice: %', v_variant_name, v_variant_result;
    END IF;

    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000014', 'two-pots');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_not_complete' THEN
      RAISE EXCEPTION '% both-pot task completed before using both burners: %', v_variant_name, v_variant_result;
    END IF;
    -- Each profile starts in pot 1 above; a second start in pot 2 completes
    -- this optional task independent of variant.
    v_variant_result := public.economy_start_batch(v_variant_profile_id,
      'a0000000-0000-4000-8000-000000000004', 2);
    IF v_variant_result ->> 'ok' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION '% second burner start failed: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000015', 'two-pots');
    IF v_variant_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
       OR v_variant_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '5' THEN
      RAISE EXCEPTION '% both-pot task did not complete after using both burners: %', v_variant_name, v_variant_result;
    END IF;
    v_variant_result := public.economy_claim_task(v_variant_profile_id,
      'b0000000-0000-4000-8000-000000000016', 'two-pots');
    IF v_variant_result #>> '{operation,result,error}' IS DISTINCT FROM 'task_already_claimed' THEN
      RAISE EXCEPTION '% both-pot reward was claimable twice: %', v_variant_name, v_variant_result;
    END IF;
  END LOOP;

  -- Returning player with a completed cook task and today's visit marker. A
  -- load records the visit but does not pay the streak. Both rewards need an
  -- explicit command, and neither can be paid twice.
  v_batch_start := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint - 60000;
  v_batch_end := v_batch_start + 43200000;
  v_state := jsonb_build_object(
    'balance', 0, 'score', 0, 'points', 0, 'pointsRetired', true, 'batches', 0,
    'startedAt', v_batch_start, 'endsAt', v_batch_end, 'batchDurationMs', 43200000,
    'activeBatches', jsonb_build_array(jsonb_build_object(
      'id', 'preserved-active-batch', 'pot', 1, 'startedAt', v_batch_start,
      'endsAt', v_batch_end, 'durationMs', 43200000)),
    'upgrades', '[]'::jsonb, 'equipped', '[]'::jsonb,
    'upgradeLevels', jsonb_build_object('good-stove',0,'large-pot',0,'grandma-recipe',0),
    'taskDay', v_today, 'taskBatches', 1, 'lifetimeDumplings', 0,
    'levelClaims', '[]'::jsonb, 'taskClaimedOn', NULL, 'taskBalanceRewardVersion', 1,
    'referralCode', NULL, 'dailyDate', v_today, 'dailyTasks', v_day_tasks,
    'dailyTaskVariant', v_today_variant, 'loginRewardDate', NULL, 'firstLoginNoReward', false,
    'streakCurrent', 1, 'streakBest', 1, 'streakLastVisitDate', v_today,
    'streakRunStartedDate', v_today, 'streakRewardClaims', jsonb_build_array(v_today || ':0:0'),
    'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1',0,'2',0),
    'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
    'joinedAt', clock_timestamp(), 'lastBatchReward', NULL, 'lastBatchAt', NULL, 'schemaVersion', 6
  );
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_returning_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_returning_id, 0, true, 6);

  v_result := public.economy_load_visit(v_returning_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Returning-player load_visit failed: %', v_result;
  END IF;
  SELECT game_state -> 'activeBatches',
         (game_state ->> 'startedAt')::bigint,
         (game_state ->> 'endsAt')::bigint,
         (game_state ->> 'batchDurationMs')::bigint
    INTO v_batches, v_started_at, v_ends_at, v_duration_ms
  FROM public.player_state WHERE telegram_id = v_returning_id;
  IF v_batches <> jsonb_build_array(jsonb_build_object(
       'id', 'preserved-active-batch', 'pot', 1, 'startedAt', v_batch_start,
       'endsAt', v_batch_end, 'durationMs', 43200000))
     OR v_started_at <> v_batch_start OR v_ends_at <> v_batch_end
     OR v_duration_ms <> 43200000 THEN
    RAISE EXCEPTION 'load_visit changed the saved active batch or timer';
  END IF;
  SELECT (game_state ->> 'balance')::bigint,
         (game_state ->> 'score')::bigint,
         (game_state ->> 'lifetimeDumplings')::bigint
    INTO v_balance, v_score, v_lifetime
  FROM public.player_state WHERE telegram_id = v_returning_id;
  IF v_balance <> 0 OR v_score <> 0 OR v_lifetime <> 0 THEN
    RAISE EXCEPTION 'Returning load_visit unexpectedly paid a streak reward';
  END IF;

  v_result := public.economy_claim_streak(v_returning_id,
    '33333333-3333-4333-8333-333333333333');
  IF v_result #>> '{operation,status}' <> 'applied'
     OR v_result #>> '{operation,result,dumplings}' <> '1' THEN
    RAISE EXCEPTION 'Manual streak claim did not award day-one amount: %', v_result;
  END IF;
  v_result := public.economy_claim_streak(v_returning_id,
    '44444444-4444-4444-8444-444444444444');
  IF v_result #>> '{operation,result,error}' <> 'streak_already_claimed' THEN
    RAISE EXCEPTION 'Streak reward was claimable a second time: %', v_result;
  END IF;

  v_result := public.economy_claim_task(v_returning_id,
    '55555555-5555-4555-8555-555555555555', 'cook');
  IF v_result #>> '{operation,status}' <> 'applied'
     OR v_result #>> '{operation,result,dumplings}' <> '10' THEN
    RAISE EXCEPTION 'Manual cook-task claim did not award 10: %', v_result;
  END IF;
  v_result := public.economy_claim_task(v_returning_id,
    '66666666-6666-4666-8666-666666666666', 'cook');
  IF v_result #>> '{operation,result,error}' <> 'task_already_claimed' THEN
    RAISE EXCEPTION 'Daily task reward was claimable a second time: %', v_result;
  END IF;

  SELECT (game_state ->> 'balance')::bigint,
         (game_state ->> 'score')::bigint,
         (game_state ->> 'lifetimeDumplings')::bigint
    INTO v_balance, v_score, v_lifetime
  FROM public.player_state WHERE telegram_id = v_returning_id;
  IF v_balance <> 11 OR v_score <> 11 OR v_lifetime <> 11 THEN
    RAISE EXCEPTION 'Streak/task rewards were not applied exactly once';
  END IF;

  -- Legacy compatibility: before manual claims, loginRewardDate=today meant
  -- the automatic reward had already been paid. The first server visit must
  -- convert that legacy evidence to a claim marker without paying again.
  v_state := jsonb_set(v_state, '{loginRewardDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{streakCurrent}', '2'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakLastVisitDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{streakRewardClaims}', '[]'::jsonb, true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_legacy_paid_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_legacy_paid_id, 0, true, 6);

  v_result := public.economy_load_visit(v_legacy_paid_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Legacy paid-reward load_visit failed: %', v_result;
  END IF;
  SELECT (game_state ->> 'balance')::bigint,
         game_state -> 'streakRewardClaims'
    INTO v_balance, v_claims
  FROM public.player_state WHERE telegram_id = v_legacy_paid_id;
  IF v_balance <> 0 OR NOT (v_claims @> jsonb_build_array(v_today || ':0:1')) THEN
    RAISE EXCEPTION 'Legacy already-paid streak reward was not safely preserved';
  END IF;
  v_result := public.economy_claim_streak(v_legacy_paid_id,
    '77777777-7777-4777-8777-777777777777');
  IF v_result #>> '{operation,result,error}' <> 'streak_already_claimed' THEN
    RAISE EXCEPTION 'Legacy already-paid streak reward became claimable again: %', v_result;
  END IF;

  -- firstLoginNoReward=true is the legacy exception: loginRewardDate alone
  -- must not consume the manual claim. The visit and claim RPCs are both
  -- exercised, including same-request replay and a later visit.
  v_state := jsonb_set(v_state, '{activeBatches}', '[]'::jsonb, true);
  v_state := jsonb_set(v_state, '{startedAt}', 'null'::jsonb, true);
  v_state := jsonb_set(v_state, '{endsAt}', 'null'::jsonb, true);
  v_state := jsonb_set(v_state, '{batchDurationMs}', 'null'::jsonb, true);
  v_state := jsonb_set(v_state, '{balance}', '0'::jsonb, true);
  v_state := jsonb_set(v_state, '{score}', '0'::jsonb, true);
  v_state := jsonb_set(v_state, '{lifetimeDumplings}', '0'::jsonb, true);
  v_state := jsonb_set(v_state, '{loginRewardDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{firstLoginNoReward}', 'true'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakCurrent}', '2'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakBest}', '2'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakLastVisitDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{streakRunStartedDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{dailyDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{taskDay}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{dailyTaskVariant}', to_jsonb(v_today_variant), true);
  v_state := jsonb_set(v_state, '{taskClaimedOn}', 'null'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakRewardClaims}', '[]'::jsonb, true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_no_legacy_payout_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_no_legacy_payout_id, 0, true, 6);

  v_result := public.economy_load_visit(v_no_legacy_payout_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT game_state -> 'streakRewardClaims' @> jsonb_build_array(v_today || ':0:1')
         FROM public.player_state WHERE telegram_id = v_no_legacy_payout_id) IS DISTINCT FROM FALSE
     OR (SELECT game_state -> 'streakRewardClaims' @> jsonb_build_array(v_today || ':0:0')
         FROM public.player_state WHERE telegram_id = v_no_legacy_payout_id) IS DISTINCT FROM TRUE
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_id) <> 0 THEN
    RAISE EXCEPTION 'firstLoginNoReward=true was incorrectly treated as an already-paid streak reward: %',v_result;
  END IF;
  v_result := public.economy_load_visit(v_no_legacy_payout_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_id) <> 0
     OR (SELECT jsonb_array_length(game_state -> 'streakRewardClaims') FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_id) <> 1 THEN
    RAISE EXCEPTION 'Repeated load_visit duplicated or paid the first-login exception marker';
  END IF;
  v_result := public.economy_claim_streak(v_no_legacy_payout_id,
    '99999999-9999-4999-8999-999999999991');
  IF v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR v_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'Manual streak claim was not available after firstLoginNoReward=true: %',v_result;
  END IF;
  v_result := public.economy_claim_streak(v_no_legacy_payout_id,
    '99999999-9999-4999-8999-999999999991');
  IF v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR v_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'Same request retry did not replay the original streak receipt: %',v_result;
  END IF;
  PERFORM public.economy_load_visit(v_no_legacy_payout_id);
  v_result := public.economy_claim_streak(v_no_legacy_payout_id,
    '99999999-9999-4999-8999-999999999992');
  SELECT (game_state ->> 'balance')::bigint, game_state -> 'streakRewardClaims'
    INTO v_balance, v_claims FROM public.player_state WHERE telegram_id = v_no_legacy_payout_id;
  IF v_result #>> '{operation,result,error}' IS DISTINCT FROM 'streak_already_claimed'
     OR v_balance <> 2
     OR (SELECT (game_state ->> 'score')::bigint FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_id) <> 2
     OR (SELECT (game_state ->> 'lifetimeDumplings')::bigint FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_id) <> 2
     OR jsonb_array_length(v_claims) <> 2 THEN
    RAISE EXCEPTION 'Repeated visit/claim changed reward totals or claim markers: %',v_result;
  END IF;

  -- With firstLoginNoReward=false, the same legacy date is trusted as proof
  -- that the old automatic payment already happened.
  v_state := jsonb_set(v_state, '{balance}', '0'::jsonb, true);
  v_state := jsonb_set(v_state, '{score}', '0'::jsonb, true);
  v_state := jsonb_set(v_state, '{lifetimeDumplings}', '0'::jsonb, true);
  v_state := jsonb_set(v_state, '{firstLoginNoReward}', 'false'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakCurrent}', '2'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakRewardClaims}', '[]'::jsonb, true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_legacy_payout_marker_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_legacy_payout_marker_id, 0, true, 6);
  v_result := public.economy_load_visit(v_legacy_payout_marker_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT game_state -> 'streakRewardClaims' @> jsonb_build_array(v_today || ':0:1')
         FROM public.player_state WHERE telegram_id = v_legacy_payout_marker_id) IS DISTINCT FROM TRUE
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state
         WHERE telegram_id = v_legacy_payout_marker_id) <> 0 THEN
    RAISE EXCEPTION 'firstLoginNoReward=false did not preserve the legacy paid marker: %',v_result;
  END IF;
  v_result := public.economy_claim_streak(v_legacy_payout_marker_id,
    '99999999-9999-4999-8999-999999999993');
  IF v_result #>> '{operation,result,error}' IS DISTINCT FROM 'streak_already_claimed'
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state
         WHERE telegram_id = v_legacy_payout_marker_id) <> 0 THEN
    RAISE EXCEPTION 'Legacy already-paid streak reward was claimable with firstLoginNoReward=false: %',v_result;
  END IF;

  -- Even if loginRewardDate already names today, a true source exception must
  -- survive daily rollover long enough to allow this day's manual claim.
  v_state := jsonb_set(v_state, '{firstLoginNoReward}', 'true'::jsonb, true);
  v_state := jsonb_set(v_state, '{dailyDate}', to_jsonb((v_today::date - 1)::text), true);
  v_state := jsonb_set(v_state, '{taskDay}', to_jsonb((v_today::date - 1)::text), true);
  v_state := jsonb_set(v_state, '{dailyTaskVariant}', to_jsonb(v_yesterday_variant), true);
  v_state := jsonb_set(v_state, '{taskClaimedOn}', 'null'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakCurrent}', '1'::jsonb, true);
  v_state := jsonb_set(v_state, '{streakLastVisitDate}', to_jsonb((v_today::date - 1)::text), true);
  v_state := jsonb_set(v_state, '{streakRunStartedDate}', to_jsonb((v_today::date - 1)::text), true);
  v_state := jsonb_set(v_state, '{streakRewardClaims}', '[]'::jsonb, true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (v_no_legacy_payout_rollover_id, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (v_no_legacy_payout_rollover_id, 0, true, 6);
  v_result := public.economy_load_visit(v_no_legacy_payout_rollover_id);
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR (SELECT game_state ->> 'dailyDate' FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_rollover_id) IS DISTINCT FROM v_today
     OR (SELECT game_state ->> 'dailyTaskVariant' FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_rollover_id) IS DISTINCT FROM v_today_variant
     OR (SELECT game_state ->> 'firstLoginNoReward' FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_rollover_id) IS DISTINCT FROM 'false'
     OR (SELECT game_state -> 'streakRewardClaims' @> jsonb_build_array(v_today || ':0:1')
         FROM public.player_state WHERE telegram_id = v_no_legacy_payout_rollover_id) IS DISTINCT FROM FALSE
     OR (SELECT (game_state ->> 'balance')::bigint FROM public.player_state
         WHERE telegram_id = v_no_legacy_payout_rollover_id) <> 0 THEN
    RAISE EXCEPTION 'UTC rollover lost firstLoginNoReward exception or paid a reward: %',v_result;
  END IF;
  v_result := public.economy_claim_streak(v_no_legacy_payout_rollover_id,
    '99999999-9999-4999-8999-999999999994');
  IF v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR v_result #>> '{operation,result,dumplings}' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'UTC rollover did not leave the streak reward manually claimable: %',v_result;
  END IF;

  -- A visit marker alone must not make the reward claimable while daily state
  -- still points to a future UTC date.
  v_state := jsonb_set(v_state, '{balance}', '7'::jsonb, true);
  v_state := jsonb_set(v_state, '{score}', '7'::jsonb, true);
  v_state := jsonb_set(v_state, '{lifetimeDumplings}', '7'::jsonb, true);
  v_state := jsonb_set(v_state, '{dailyDate}', to_jsonb((v_today::date + 1)::text), true);
  v_state := jsonb_set(v_state, '{taskDay}', to_jsonb((v_today::date + 1)::text), true);
  v_state := jsonb_set(v_state, '{streakLastVisitDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{streakCurrent}', '2'::jsonb, true);
  v_state := jsonb_set(v_state, '{loginRewardDate}', to_jsonb(v_today), true);
  v_state := jsonb_set(v_state, '{streakRewardClaims}', '[]'::jsonb, true);
  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (9223372036854770103, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (9223372036854770103, 0, true, 6);

  v_result := public.economy_claim_streak(9223372036854770103,
    '99999999-9999-4999-8999-999999999995');
  SELECT (game_state ->> 'balance')::bigint,
         (game_state ->> 'score')::bigint,
         (game_state ->> 'lifetimeDumplings')::bigint,
         game_state -> 'streakRewardClaims'
    INTO v_balance, v_score, v_lifetime, v_claims
  FROM public.player_state WHERE telegram_id = 9223372036854770103;
  IF v_result #>> '{operation,result,error}' IS DISTINCT FROM 'daily_state_stale'
     OR v_balance <> 7 OR v_score <> 7 OR v_lifetime <> 7
     OR v_claims IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'Streak reward was claimable with stale dailyDate or changed player state: %', v_result;
  END IF;
END
$test$;

ROLLBACK;

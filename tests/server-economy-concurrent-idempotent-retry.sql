-- Phase-driven fixture for run-server-economy-concurrent-idempotent-retry.sh.
-- Uses one fixed synthetic profile and a marker-guarded cleanup. The test
-- requires committed concurrent sessions, so cleanup is explicit, not ROLLBACK.
\set ON_ERROR_STOP on
SET ROLE service_role;
SELECT pg_catalog.set_config('pelmeni.concurrent_idempotent_retry_phase', :'phase', false);

DO $test$
DECLARE
  c_phase text := current_setting('pelmeni.concurrent_idempotent_retry_phase');
  c_id constant bigint := 9223372036854769871;
  c_request constant uuid := 'b1000000-0000-4000-8000-000000000001';
  c_marker constant text := 'pelmeni-local-idempotent-retry-test-v1';
  v_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_variant text;
  v_state jsonb;
  v_expected_state jsonb;
  v_control_revision bigint;
  v_server_mode boolean;
  v_schema_version integer;
  v_request_count integer;
  v_receipt jsonb;
  v_expected_hash text;
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Run this local test as service_role';
  END IF;

  IF c_phase = 'setup' THEN
    IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_requests WHERE telegram_id = c_id) THEN
      RAISE EXCEPTION 'Synthetic fixture ID already exists; inspect it before running this test';
    END IF;

    v_variant := public._pelmeni_daily_task_variant(v_today);
    v_state := jsonb_build_object(
      'balance', 1000, 'score', 37, 'points', 37, 'pointsRetired', true, 'batches', 0,
      'startedAt', NULL, 'endsAt', NULL, 'batchDurationMs', NULL,
      'activeBatches', '[]'::jsonb, 'upgrades', '[]'::jsonb, 'equipped', '[]'::jsonb,
      'upgradeLevels', jsonb_build_object('good-stove', 0, 'large-pot', 0, 'grandma-recipe', 0),
      'taskDay', v_today::text, 'taskBatches', 0, 'lifetimeDumplings', 81,
      'levelClaims', '[]'::jsonb, 'taskClaimedOn', NULL, 'taskBalanceRewardVersion', 1,
      'referralCode', NULL, 'dailyDate', v_today::text,
      'dailyTasks', jsonb_build_object(
        'login', jsonb_build_object('progress', 0, 'claimed', false),
        'cook', jsonb_build_object('progress', 0, 'claimed', false),
        'upgrade', jsonb_build_object('progress', 0, 'claimed', false),
        'collect', jsonb_build_object('progress', 0, 'claimed', false),
        'collect-dumplings', jsonb_build_object('progress', 0, 'claimed', false),
        'collect-two', jsonb_build_object('progress', 0, 'claimed', false),
        'two-pots', jsonb_build_object('progress', 0, 'claimed', false)),
      'dailyTaskVariant', v_variant, 'loginRewardDate', NULL, 'firstLoginNoReward', false,
      'streakCurrent', 0, 'streakBest', 0, 'streakLastVisitDate', NULL,
      'streakRunStartedDate', NULL, 'streakRewardClaims', '[]'::jsonb,
      'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1', 0, '2', 0),
      'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
      'joinedAt', NULL, 'lastBatchReward', NULL, 'lastBatchAt', NULL,
      'schemaVersion', 6, 'concurrentIdempotentRetryFixture', c_marker);

    IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Synthetic current-format game_state failed validation';
    END IF;
    INSERT INTO public.player_state(telegram_id, game_state, updated_at)
      VALUES (c_id, v_state, clock_timestamp());
    INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
      VALUES (c_id, 0, true, 6);

  ELSIF c_phase = 'verify' THEN
    SELECT game_state INTO v_state
    FROM public.player_state
    WHERE telegram_id = c_id
      AND game_state ->> 'concurrentIdempotentRetryFixture' = c_marker;
    IF NOT FOUND THEN RAISE EXCEPTION 'Marked synthetic fixture is missing'; END IF;
    IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM (v_state ->> 'dailyDate')::date THEN
      RAISE EXCEPTION 'UTC date changed during idempotent concurrent retry test; rerun outside UTC midnight';
    END IF;

    SELECT revision, server_mode, state_schema_version
      INTO v_control_revision, v_server_mode, v_schema_version
    FROM public.player_economy_control WHERE telegram_id = c_id;
    SELECT count(*)::integer INTO v_request_count
    FROM public.player_economy_requests WHERE telegram_id = c_id;
    SELECT to_jsonb(r) INTO v_receipt
    FROM public.player_economy_requests AS r
    WHERE telegram_id = c_id AND request_id = c_request;
    v_expected_hash := md5(jsonb_build_object('action', 'purchase_upgrade',
      'params', jsonb_build_object('upgradeId', 'good-stove'))::text);

    IF v_request_count <> 1 OR v_receipt IS NULL THEN
      RAISE EXCEPTION 'Expected exactly one receipt for the shared request ID; found %', v_request_count;
    END IF;
    IF v_receipt ->> 'telegram_id' IS DISTINCT FROM c_id::text
       OR v_receipt ->> 'request_id' IS DISTINCT FROM c_request::text
       OR v_receipt ->> 'action' IS DISTINCT FROM 'purchase_upgrade'
       OR v_receipt -> 'request_args' IS DISTINCT FROM jsonb_build_object('upgradeId', 'good-stove')
       OR v_receipt ->> 'request_hash' IS DISTINCT FROM v_expected_hash
       OR v_receipt -> 'outcome' IS DISTINCT FROM
          jsonb_build_object('status', 'applied', 'upgradeId', 'good-stove', 'level', 1, 'cost', 15) THEN
      RAISE EXCEPTION 'Stored receipt does not match the one applied purchase: %', v_receipt;
    END IF;

    v_variant := public._pelmeni_daily_task_variant(v_today);
    v_expected_state := jsonb_build_object(
      'balance', 1000, 'score', 37, 'points', 37, 'pointsRetired', true, 'batches', 0,
      'startedAt', NULL, 'endsAt', NULL, 'batchDurationMs', NULL,
      'activeBatches', '[]'::jsonb, 'upgrades', '[]'::jsonb, 'equipped', '[]'::jsonb,
      'upgradeLevels', jsonb_build_object('good-stove', 0, 'large-pot', 0, 'grandma-recipe', 0),
      'taskDay', v_today::text, 'taskBatches', 0, 'lifetimeDumplings', 81,
      'levelClaims', '[]'::jsonb, 'taskClaimedOn', NULL, 'taskBalanceRewardVersion', 1,
      'referralCode', NULL, 'dailyDate', v_today::text,
      'dailyTasks', jsonb_build_object(
        'login', jsonb_build_object('progress', 0, 'claimed', false),
        'cook', jsonb_build_object('progress', 0, 'claimed', false),
        'upgrade', jsonb_build_object('progress', 0, 'claimed', false),
        'collect', jsonb_build_object('progress', 0, 'claimed', false),
        'collect-dumplings', jsonb_build_object('progress', 0, 'claimed', false),
        'collect-two', jsonb_build_object('progress', 0, 'claimed', false),
        'two-pots', jsonb_build_object('progress', 0, 'claimed', false)),
      'dailyTaskVariant', v_variant, 'loginRewardDate', NULL, 'firstLoginNoReward', false,
      'streakCurrent', 0, 'streakBest', 0, 'streakLastVisitDate', NULL,
      'streakRunStartedDate', NULL, 'streakRewardClaims', '[]'::jsonb,
      'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1', 0, '2', 0),
      'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
      'joinedAt', NULL, 'lastBatchReward', NULL, 'lastBatchAt', NULL,
      'schemaVersion', 6, 'concurrentIdempotentRetryFixture', c_marker);
    v_expected_state := jsonb_set(v_expected_state, '{balance}', '985'::jsonb, true);
    v_expected_state := jsonb_set(v_expected_state, '{upgradeLevels,good-stove}', '1'::jsonb, true);
    v_expected_state := jsonb_set(v_expected_state, '{dailyTasks}',
      public._pelmeni_task_progress(v_expected_state -> 'dailyTasks', 'upgrade', 1), true);
    v_expected_state := public._pelmeni_refresh_achievements(v_expected_state);

    IF v_state IS DISTINCT FROM v_expected_state
       OR v_control_revision IS DISTINCT FROM 1
       OR v_server_mode IS DISTINCT FROM TRUE
       OR v_schema_version IS DISTINCT FROM 6
       OR (v_state ->> 'balance')::bigint IS DISTINCT FROM 985
       OR (v_state ->> 'score')::bigint IS DISTINCT FROM 37
       OR (v_state ->> 'lifetimeDumplings')::bigint IS DISTINCT FROM 81
       OR (v_state ->> 'batches')::bigint IS DISTINCT FROM 0
       OR v_state -> 'activeBatches' IS DISTINCT FROM '[]'::jsonb
       OR v_state -> 'upgrades' IS DISTINCT FROM '[]'::jsonb
       OR v_state -> 'equipped' IS DISTINCT FROM '[]'::jsonb
       OR v_state #>> '{upgradeLevels,good-stove}' IS DISTINCT FROM '1'
       OR v_state #>> '{dailyTasks,upgrade,progress}' IS DISTINCT FROM '1' THEN
      RAISE EXCEPTION 'Persisted state or revision changed by other than one upgrade: state %, revision %',
        v_state, v_control_revision;
    END IF;

  ELSIF c_phase = 'cleanup' THEN
    IF NOT EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id
      AND game_state ->> 'concurrentIdempotentRetryFixture' = c_marker) THEN
      RAISE EXCEPTION 'Cleanup refused: synthetic fixture marker is absent';
    END IF;
    IF EXISTS (SELECT 1 FROM public.player_economy_requests
      WHERE telegram_id = c_id AND request_id <> c_request) THEN
      RAISE EXCEPTION 'Cleanup refused: unexpected request rows exist for synthetic profile';
    END IF;
    DELETE FROM public.player_economy_requests
      WHERE telegram_id = c_id AND request_id = c_request;
    DELETE FROM public.player_economy_control WHERE telegram_id = c_id;
    DELETE FROM public.player_state WHERE telegram_id = c_id
      AND game_state ->> 'concurrentIdempotentRetryFixture' = c_marker;
    IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_requests WHERE telegram_id = c_id) THEN
      RAISE EXCEPTION 'Synthetic fixture cleanup was incomplete or found unexpected request rows';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown test phase: %', c_phase;
  END IF;
END
$test$;

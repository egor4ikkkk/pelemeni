-- Phase-driven fixture for tests/run-server-economy-concurrent-collect.sh.
-- This file is intentionally run only against the local Supabase PostgreSQL
-- listener on 127.0.0.1:54322. All mutations use one reserved synthetic ID;
-- setup refuses to overwrite any pre-existing row and cleanup checks a marker.
\set ON_ERROR_STOP on
SET ROLE service_role;
SELECT pg_catalog.set_config('pelmeni.concurrent_collect_phase', :'phase', false);

DO $test$
DECLARE
  c_phase text := current_setting('pelmeni.concurrent_collect_phase');
  c_id constant bigint := 9223372036854769901;
  c_batch constant text := 'concurrent-collect-one-batch';
  c_request_a constant uuid := 'f1f1f1f1-1111-4111-8111-111111111111';
  c_request_b constant uuid := 'f2f2f2f2-2222-4222-8222-222222222222';
  v_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_now_ms bigint := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  v_state jsonb;
  v_batch_result jsonb;
  v_a jsonb;
  v_b jsonb;
  v_reward bigint;
  v_balance bigint;
  v_score bigint;
  v_batches bigint;
  v_lifetime bigint;
  v_revision bigint;
  v_active jsonb;
  v_requests integer;
  v_pot_collections jsonb;
  v_action_a text;
  v_action_b text;
  v_args_a jsonb;
  v_args_b jsonb;
  v_hash_a text;
  v_hash_b text;
  v_request_id_a uuid;
  v_request_id_b uuid;
  v_expected_hash text;
  v_alias_started jsonb;
  v_alias_ends jsonb;
  v_alias_duration jsonb;
  v_upgrades jsonb;
  v_equipped jsonb;
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Run this local test as service_role';
  END IF;

  IF c_phase = 'setup' THEN
    IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_requests WHERE telegram_id = c_id) THEN
      RAISE EXCEPTION 'Synthetic fixture ID already exists; inspect it before cleanup';
    END IF;

    v_state := jsonb_build_object(
      'balance', 0, 'score', 0, 'points', 0, 'pointsRetired', true, 'batches', 0,
      'startedAt', v_now_ms - 120000, 'endsAt', v_now_ms - 60000, 'batchDurationMs', 60000,
      'activeBatches', jsonb_build_array(jsonb_build_object(
        'id', c_batch, 'pot', 1, 'startedAt', v_now_ms - 120000,
        'endsAt', v_now_ms - 60000, 'durationMs', 60000)),
      'upgrades', '[]'::jsonb, 'equipped', '[]'::jsonb,
      'upgradeLevels', jsonb_build_object('good-stove', 0, 'large-pot', 0, 'grandma-recipe', 0),
      'taskDay', v_today::text, 'taskBatches', 0, 'lifetimeDumplings', 0,
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
      'dailyTaskVariant', public._pelmeni_daily_task_variant(v_today),
      'loginRewardDate', NULL, 'firstLoginNoReward', false,
      'streakCurrent', 0, 'streakBest', 0, 'streakLastVisitDate', NULL,
      'streakRunStartedDate', NULL, 'streakRewardClaims', '[]'::jsonb,
      'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1', 0, '2', 0),
      'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
      'joinedAt', NULL, 'lastBatchReward', NULL, 'lastBatchAt', NULL, 'schemaVersion', 6,
      'concurrentCollectFixture', 'pelmeni-local-concurrency-test-v1');

    IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Synthetic current-format game_state failed validation';
    END IF;
    INSERT INTO public.player_state(telegram_id, game_state, updated_at)
      VALUES (c_id, v_state, clock_timestamp());
    INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
      VALUES (c_id, 40, true, 6);

  ELSIF c_phase = 'verify' THEN
    SELECT game_state -> 'activeBatches',
           (game_state ->> 'balance')::bigint,
           (game_state ->> 'score')::bigint,
           (game_state ->> 'batches')::bigint,
           (game_state ->> 'lifetimeDumplings')::bigint,
           game_state -> 'potCollections',
           game_state -> 'upgrades',
           game_state -> 'equipped'
      INTO v_active, v_balance, v_score, v_batches, v_lifetime, v_pot_collections,
           v_upgrades, v_equipped
    FROM public.player_state
    WHERE telegram_id = c_id
      AND game_state ->> 'concurrentCollectFixture' = 'pelmeni-local-concurrency-test-v1';
    IF NOT FOUND THEN RAISE EXCEPTION 'Marked synthetic fixture is missing'; END IF;

    SELECT revision INTO v_revision FROM public.player_economy_control WHERE telegram_id = c_id;
    SELECT count(*)::integer INTO v_requests FROM public.player_economy_requests
    WHERE telegram_id = c_id;
    SELECT request_id, action, request_args, request_hash, outcome
      INTO v_request_id_a, v_action_a, v_args_a, v_hash_a, v_a
    FROM public.player_economy_requests
    WHERE telegram_id = c_id AND request_id = c_request_a;
    SELECT request_id, action, request_args, request_hash, outcome
      INTO v_request_id_b, v_action_b, v_args_b, v_hash_b, v_b
    FROM public.player_economy_requests
    WHERE telegram_id = c_id AND request_id = c_request_b;
    v_expected_hash := md5(jsonb_build_object('action', 'collect_batch',
      'params', jsonb_build_object('batchId', c_batch))::text);
    SELECT game_state -> 'startedAt', game_state -> 'endsAt', game_state -> 'batchDurationMs'
      INTO v_alias_started, v_alias_ends, v_alias_duration
    FROM public.player_state WHERE telegram_id = c_id;

    IF v_requests <> 2 THEN
      RAISE EXCEPTION 'Expected two receipts, found %', v_requests;
    END IF;
    IF v_request_id_a IS DISTINCT FROM c_request_a
       OR v_request_id_b IS DISTINCT FROM c_request_b
       OR v_action_a IS DISTINCT FROM 'collect_batch'
       OR v_action_b IS DISTINCT FROM 'collect_batch'
       OR v_args_a IS DISTINCT FROM jsonb_build_object('batchId', c_batch)
       OR v_args_b IS DISTINCT FROM jsonb_build_object('batchId', c_batch)
       OR v_hash_a IS DISTINCT FROM v_expected_hash
       OR v_hash_b IS DISTINCT FROM v_expected_hash THEN
      RAISE EXCEPTION 'Stored request identities, actions, args, or hashes differ: A %, %, %; B %, %, %',
        v_action_a, v_args_a, v_hash_a, v_action_b, v_args_b, v_hash_b;
    END IF;
    IF v_a IS NULL OR v_b IS NULL THEN
      RAISE EXCEPTION 'One of the two request receipts is missing';
    END IF;
    IF (v_a ->> 'status') IS DISTINCT FROM 'applied'
       OR v_a ->> 'batchId' IS DISTINCT FROM c_batch THEN
      RAISE EXCEPTION 'Connection A did not collect the fixture batch: %', v_a;
    END IF;
    IF (v_b ->> 'status') IS DISTINCT FROM 'rejected'
       OR v_b ->> 'error' IS DISTINCT FROM 'batch_not_found' THEN
      RAISE EXCEPTION 'Connection B did not receive the expected duplicate-collect rejection: %', v_b;
    END IF;
    v_reward := (v_a ->> 'dumplings')::bigint;
    IF v_reward < 10 OR v_reward > 15
       OR v_balance <> v_reward OR v_score <> v_reward OR v_lifetime <> v_reward
       OR v_batches <> 1 OR v_revision <> 41
       OR v_active IS DISTINCT FROM '[]'::jsonb
       OR v_pot_collections IS DISTINCT FROM '{"1":1,"2":0}'::jsonb
       OR v_pot_collections ->> '2' IS DISTINCT FROM '0'
       OR v_upgrades IS DISTINCT FROM '[]'::jsonb
       OR v_equipped IS DISTINCT FROM '[]'::jsonb
       OR v_alias_started IS DISTINCT FROM 'null'::jsonb
       OR v_alias_ends IS DISTINCT FROM 'null'::jsonb
       OR v_alias_duration IS DISTINCT FROM 'null'::jsonb THEN
      RAISE EXCEPTION 'Final economy state does not show exactly one collection: reward %, balance %, score %, batches %, lifetime %, revision %, active %, pots %',
        v_reward, v_balance, v_score, v_batches, v_lifetime, v_revision, v_active, v_pot_collections;
    END IF;

  ELSIF c_phase = 'cleanup' THEN
    IF NOT EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id
      AND game_state ->> 'concurrentCollectFixture' = 'pelmeni-local-concurrency-test-v1') THEN
      RAISE EXCEPTION 'Cleanup refused: fixture marker is absent';
    END IF;
    DELETE FROM public.player_economy_requests WHERE telegram_id = c_id;
    DELETE FROM public.player_economy_control WHERE telegram_id = c_id;
    DELETE FROM public.player_state WHERE telegram_id = c_id
      AND game_state ->> 'concurrentCollectFixture' = 'pelmeni-local-concurrency-test-v1';
    IF EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_control WHERE telegram_id = c_id)
       OR EXISTS (SELECT 1 FROM public.player_economy_requests WHERE telegram_id = c_id) THEN
      RAISE EXCEPTION 'Synthetic fixture cleanup was incomplete';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown test phase: %', c_phase;
  END IF;
END
$test$;

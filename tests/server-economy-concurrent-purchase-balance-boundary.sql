-- Phase-driven fixture for run-server-economy-concurrent-purchase-balance-boundary.sh.
-- This test requires committed concurrent sessions; cleanup is explicit and
-- refuses to remove rows unless the synthetic marker matches.
\set ON_ERROR_STOP on
SET ROLE service_role;
SELECT pg_catalog.set_config('pelmeni.concurrent_purchase_boundary_phase', :'phase', false);

DO $test$
DECLARE
  c_phase constant text := current_setting('pelmeni.concurrent_purchase_boundary_phase');
  c_id constant bigint := 9223372036854769861;
  c_request_a constant uuid := 'c1000000-0000-4000-8000-000000000001';
  c_request_b constant uuid := 'c2000000-0000-4000-8000-000000000002';
  c_marker constant text := 'pelmeni-local-purchase-boundary-v1';
  v_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_variant text;
  v_state jsonb;
  v_expected_state jsonb;
  v_revision bigint;
  v_server_mode boolean;
  v_schema_version integer;
  v_receipt_count integer;
  v_receipt_a jsonb;
  v_receipt_b jsonb;
  v_expected_hash_a text;
  v_expected_hash_b text;
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
      'balance', 75, 'score', 37, 'points', 37, 'pointsRetired', true, 'batches', 0,
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
      'schemaVersion', 6, 'concurrentPurchaseBoundaryFixture', c_marker);

    -- Both level-1 purchases are individually affordable from this exact
    -- starting state; together they cost 90, while the profile has 75.
    IF (v_state ->> 'balance')::bigint < 75
       OR (v_state #>> '{upgradeLevels,good-stove}')::integer <> 0
       OR (v_state #>> '{upgradeLevels,large-pot}')::integer <> 0 THEN
      RAISE EXCEPTION 'Fixture does not make both first-level upgrades individually purchasable';
    END IF;
    IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Synthetic current-format game_state failed validation';
    END IF;
    INSERT INTO public.player_state(telegram_id, game_state, updated_at)
      VALUES (c_id, v_state, clock_timestamp());
    INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
      VALUES (c_id, 0, true, 6);

  ELSIF c_phase = 'verify' THEN
    IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
      RAISE EXCEPTION 'UTC date changed during purchase boundary test; rerun outside UTC midnight';
    END IF;
    SELECT game_state INTO v_state
    FROM public.player_state
    WHERE telegram_id = c_id
      AND game_state ->> 'concurrentPurchaseBoundaryFixture' = c_marker;
    IF NOT FOUND THEN RAISE EXCEPTION 'Marked synthetic fixture is missing'; END IF;

    SELECT revision, server_mode, state_schema_version
      INTO v_revision, v_server_mode, v_schema_version
    FROM public.player_economy_control WHERE telegram_id = c_id;
    SELECT count(*)::integer INTO v_receipt_count
    FROM public.player_economy_requests WHERE telegram_id = c_id;
    SELECT to_jsonb(r) INTO v_receipt_a
    FROM public.player_economy_requests AS r
    WHERE telegram_id = c_id AND request_id = c_request_a;
    SELECT to_jsonb(r) INTO v_receipt_b
    FROM public.player_economy_requests AS r
    WHERE telegram_id = c_id AND request_id = c_request_b;

    v_expected_hash_a := md5(jsonb_build_object('action', 'purchase_upgrade',
      'params', jsonb_build_object('upgradeId', 'good-stove'))::text);
    v_expected_hash_b := md5(jsonb_build_object('action', 'purchase_upgrade',
      'params', jsonb_build_object('upgradeId', 'large-pot'))::text);

    IF v_receipt_count <> 2 OR v_receipt_a IS NULL OR v_receipt_b IS NULL THEN
      RAISE EXCEPTION 'Expected exactly two purchase receipts, found %', v_receipt_count;
    END IF;
    IF v_receipt_a ->> 'telegram_id' IS DISTINCT FROM c_id::text
       OR v_receipt_a ->> 'request_id' IS DISTINCT FROM c_request_a::text
       OR v_receipt_a ->> 'action' IS DISTINCT FROM 'purchase_upgrade'
       OR v_receipt_a -> 'request_args' IS DISTINCT FROM jsonb_build_object('upgradeId', 'good-stove')
       OR v_receipt_a ->> 'request_hash' IS DISTINCT FROM v_expected_hash_a
       OR v_receipt_a -> 'outcome' IS DISTINCT FROM
          jsonb_build_object('status', 'applied', 'upgradeId', 'good-stove', 'level', 1, 'cost', 15) THEN
      RAISE EXCEPTION 'A receipt does not record exactly one good-stove purchase: %', v_receipt_a;
    END IF;
    IF v_receipt_b ->> 'telegram_id' IS DISTINCT FROM c_id::text
       OR v_receipt_b ->> 'request_id' IS DISTINCT FROM c_request_b::text
       OR v_receipt_b ->> 'action' IS DISTINCT FROM 'purchase_upgrade'
       OR v_receipt_b -> 'request_args' IS DISTINCT FROM jsonb_build_object('upgradeId', 'large-pot')
       OR v_receipt_b ->> 'request_hash' IS DISTINCT FROM v_expected_hash_b
       OR v_receipt_b -> 'outcome' IS DISTINCT FROM
          jsonb_build_object('status', 'rejected', 'error', 'insufficient_balance', 'cost', 75) THEN
      RAISE EXCEPTION 'B receipt did not preserve insufficient_balance with cost 75: %', v_receipt_b;
    END IF;

    v_expected_state := jsonb_build_object(
      'balance', 75, 'score', 37, 'points', 37, 'pointsRetired', true, 'batches', 0,
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
      'dailyTaskVariant', public._pelmeni_daily_task_variant(v_today),
      'loginRewardDate', NULL, 'firstLoginNoReward', false,
      'streakCurrent', 0, 'streakBest', 0, 'streakLastVisitDate', NULL,
      'streakRunStartedDate', NULL, 'streakRewardClaims', '[]'::jsonb,
      'taskPotsUsed', '[]'::jsonb, 'potCollections', jsonb_build_object('1', 0, '2', 0),
      'achievements', '[]'::jsonb, 'achievementClaims', '[]'::jsonb,
      'joinedAt', NULL, 'lastBatchReward', NULL, 'lastBatchAt', NULL,
      'schemaVersion', 6, 'concurrentPurchaseBoundaryFixture', c_marker);
    v_expected_state := jsonb_set(v_expected_state, '{balance}', '60'::jsonb, true);
    v_expected_state := jsonb_set(v_expected_state, '{upgradeLevels,good-stove}', '1'::jsonb, true);
    v_expected_state := jsonb_set(v_expected_state, '{dailyTasks}',
      public._pelmeni_task_progress(v_expected_state -> 'dailyTasks', 'upgrade', 1), true);
    v_expected_state := public._pelmeni_refresh_achievements(v_expected_state);

    IF v_state IS DISTINCT FROM v_expected_state
       OR v_revision IS DISTINCT FROM 1
       OR v_server_mode IS DISTINCT FROM TRUE
       OR v_schema_version IS DISTINCT FROM 6
       OR (v_state ->> 'balance')::bigint IS DISTINCT FROM 60
       OR (v_state ->> 'score')::bigint IS DISTINCT FROM 37
       OR (v_state ->> 'lifetimeDumplings')::bigint IS DISTINCT FROM 81
       OR (v_state ->> 'batches')::bigint IS DISTINCT FROM 0
       OR v_state -> 'activeBatches' IS DISTINCT FROM '[]'::jsonb
       OR v_state -> 'upgrades' IS DISTINCT FROM '[]'::jsonb
       OR v_state -> 'equipped' IS DISTINCT FROM '[]'::jsonb
       OR v_state #>> '{upgradeLevels,good-stove}' IS DISTINCT FROM '1'
       OR v_state #>> '{upgradeLevels,large-pot}' IS DISTINCT FROM '0'
       OR (v_state ->> 'balance')::bigint < 0 THEN
      RAISE EXCEPTION 'State does not show exactly one 15-pelmeni purchase: state %, revision %',
        v_state, v_revision;
    END IF;

  ELSIF c_phase = 'cleanup' THEN
    IF NOT EXISTS (SELECT 1 FROM public.player_state WHERE telegram_id = c_id
      AND game_state ->> 'concurrentPurchaseBoundaryFixture' = c_marker) THEN
      RAISE EXCEPTION 'Cleanup refused: synthetic fixture marker is absent';
    END IF;
    IF EXISTS (SELECT 1 FROM public.player_economy_requests
      WHERE telegram_id = c_id AND request_id NOT IN (c_request_a, c_request_b)) THEN
      RAISE EXCEPTION 'Cleanup refused: unexpected request rows exist for synthetic profile';
    END IF;
    DELETE FROM public.player_economy_requests
      WHERE telegram_id = c_id AND request_id IN (c_request_a, c_request_b);
    DELETE FROM public.player_economy_control WHERE telegram_id = c_id;
    DELETE FROM public.player_state WHERE telegram_id = c_id
      AND game_state ->> 'concurrentPurchaseBoundaryFixture' = c_marker;
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

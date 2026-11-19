-- Idempotency conflict regression test for server economy RPCs.
-- Run only in a disposable PostgreSQL/Supabase database after applying the
-- local server-economy migration. All fixtures are synthetic and rolled back.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE service_role;

DO $test$
DECLARE
  c_id_args constant bigint := 9223372036854769001;
  c_id_action constant bigint := 9223372036854769002;
  c_id_player_a constant bigint := 9223372036854769003;
  c_id_player_b constant bigint := 9223372036854769004;
  c_request_args constant uuid := 'a1000000-0000-4000-8000-000000000001';
  c_request_action constant uuid := 'a2000000-0000-4000-8000-000000000002';
  c_shared_request constant uuid := 'a3000000-0000-4000-8000-000000000003';
  v_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_variant text;
  v_state jsonb;
  v_expected_state jsonb;
  v_result jsonb;
  v_before_state jsonb;
  v_after_state jsonb;
  v_before_revision bigint;
  v_after_revision bigint;
  v_before_updated_at timestamptz;
  v_after_updated_at timestamptz;
  v_receipt_before jsonb;
  v_receipt_after jsonb;
  v_expected_hash text;
  v_receipt_count integer;
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Run this test as service_role in a disposable database';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.player_state
    WHERE telegram_id IN (c_id_args, c_id_action, c_id_player_a, c_id_player_b)
  ) OR EXISTS (
    SELECT 1 FROM public.player_economy_control
    WHERE telegram_id IN (c_id_args, c_id_action, c_id_player_a, c_id_player_b)
  ) OR EXISTS (
    SELECT 1 FROM public.player_economy_requests
    WHERE telegram_id IN (c_id_args, c_id_action, c_id_player_a, c_id_player_b)
  ) THEN
    RAISE EXCEPTION 'A fixed synthetic profile ID already exists; inspect before running this test';
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
    'joinedAt', NULL, 'lastBatchReward', NULL, 'lastBatchAt', NULL, 'schemaVersion', 6);

  IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Synthetic current-format game_state failed validation';
  END IF;

  INSERT INTO public.player_state(telegram_id, game_state, updated_at)
  VALUES (c_id_args, v_state, clock_timestamp()),
         (c_id_action, v_state, clock_timestamp()),
         (c_id_player_a, v_state, clock_timestamp()),
         (c_id_player_b, v_state, clock_timestamp());
  INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
  VALUES (c_id_args, 0, true, 6), (c_id_action, 0, true, 6),
         (c_id_player_a, 0, true, 6), (c_id_player_b, 0, true, 6);

  -- 1. Same player and UUID, different arguments.
  IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'UTC date changed during idempotency test; rerun outside UTC midnight';
  END IF;
  v_result := public.economy_purchase_upgrade(c_id_args, c_request_args, 'good-stove');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR jsonb_typeof(v_result -> 'ok') IS DISTINCT FROM 'boolean'
     OR v_result #>> '{operation,requestId}' IS DISTINCT FROM c_request_args::text
     OR jsonb_typeof(v_result #> '{operation,requestId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result -> 'operation') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,status}') IS DISTINCT FROM 'string'
     OR v_result #>> '{operation,result,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,result}') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,result,upgradeId}' IS DISTINCT FROM 'good-stove'
     OR jsonb_typeof(v_result #> '{operation,result,upgradeId}') IS DISTINCT FROM 'string'
     OR v_result #>> '{operation,result,level}' IS DISTINCT FROM '1'
     OR jsonb_typeof(v_result #> '{operation,result,level}') IS DISTINCT FROM 'number'
     OR v_result #>> '{operation,result,cost}' IS DISTINCT FROM '15'
     OR jsonb_typeof(v_result #> '{operation,result,cost}') IS DISTINCT FROM 'number'
     OR jsonb_typeof(v_result -> 'state') IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_result -> 'revision') IS DISTINCT FROM 'number' THEN
    RAISE EXCEPTION 'Initial good-stove purchase did not apply as expected: %', v_result;
  END IF;
  SELECT p.game_state, c.revision, p.updated_at
    INTO v_before_state, v_before_revision, v_before_updated_at
  FROM public.player_state AS p
  JOIN public.player_economy_control AS c USING (telegram_id)
  WHERE p.telegram_id = c_id_args;
  SELECT to_jsonb(r) INTO v_receipt_before
  FROM public.player_economy_requests AS r
  WHERE r.telegram_id = c_id_args AND r.request_id = c_request_args;
  IF v_receipt_before IS NULL THEN
    RAISE EXCEPTION 'Initial request receipt was not stored';
  END IF;
  v_expected_hash := md5(jsonb_build_object('action', 'purchase_upgrade',
    'params', jsonb_build_object('upgradeId', 'good-stove'))::text);
  IF v_before_revision <> 1
     OR (v_before_state ->> 'balance')::bigint <> 985
     OR (v_before_state ->> 'score')::bigint <> 37
     OR (v_before_state ->> 'lifetimeDumplings')::bigint <> 81
     OR v_receipt_before ->> 'action' IS DISTINCT FROM 'purchase_upgrade'
     OR v_receipt_before ->> 'telegram_id' IS DISTINCT FROM c_id_args::text
     OR v_receipt_before ->> 'request_id' IS DISTINCT FROM c_request_args::text
     OR v_receipt_before -> 'request_args' IS DISTINCT FROM jsonb_build_object('upgradeId', 'good-stove')
     OR v_receipt_before ->> 'request_hash' IS DISTINCT FROM v_expected_hash
     OR jsonb_typeof(v_receipt_before -> 'outcome') IS DISTINCT FROM 'object'
     OR v_receipt_before #>> '{outcome,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'Initial upgrade state or stored receipt fields are incorrect';
  END IF;

  IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'UTC date changed during idempotency test; rerun outside UTC midnight';
  END IF;
  v_result := public.economy_purchase_upgrade(c_id_args, c_request_args, 'large-pot');
  IF v_result ->> 'ok' IS DISTINCT FROM 'false'
     OR jsonb_typeof(v_result -> 'ok') IS DISTINCT FROM 'boolean'
     OR v_result ->> 'error' IS DISTINCT FROM 'idempotency_conflict'
     OR jsonb_typeof(v_result -> 'error') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result -> 'state') IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_result -> 'revision') IS DISTINCT FROM 'number'
     OR v_result ? 'operation' THEN
    RAISE EXCEPTION 'Changed arguments did not return idempotency_conflict: %', v_result;
  END IF;
  SELECT p.game_state, c.revision, p.updated_at
    INTO v_after_state, v_after_revision, v_after_updated_at
  FROM public.player_state AS p
  JOIN public.player_economy_control AS c USING (telegram_id)
  WHERE p.telegram_id = c_id_args;
  SELECT to_jsonb(r) INTO v_receipt_after
  FROM public.player_economy_requests AS r
  WHERE r.telegram_id = c_id_args AND r.request_id = c_request_args;
  IF v_after_state IS DISTINCT FROM v_before_state
     OR v_after_revision IS DISTINCT FROM v_before_revision
     OR v_after_updated_at IS DISTINCT FROM v_before_updated_at
     OR v_receipt_after IS DISTINCT FROM v_receipt_before
     OR (v_after_state ->> 'balance')::bigint <> 985
     OR (v_after_state ->> 'score')::bigint <> 37
     OR (v_after_state ->> 'lifetimeDumplings')::bigint <> 81 THEN
    RAISE EXCEPTION 'Changed-argument conflict modified state, revision, timestamp, or original receipt';
  END IF;

  -- 2. Same player and UUID, different RPC/action.
  IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'UTC date changed during idempotency test; rerun outside UTC midnight';
  END IF;
  v_result := public.economy_purchase_decoration(c_id_action, c_request_action, 'herb-pot');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR jsonb_typeof(v_result -> 'ok') IS DISTINCT FROM 'boolean'
     OR v_result #>> '{operation,requestId}' IS DISTINCT FROM c_request_action::text
     OR jsonb_typeof(v_result #> '{operation,requestId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result -> 'operation') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,status}') IS DISTINCT FROM 'string'
     OR v_result #>> '{operation,result,status}' IS DISTINCT FROM 'applied'
     OR v_result #>> '{operation,result,decorationId}' IS DISTINCT FROM 'herb-pot'
     OR jsonb_typeof(v_result #> '{operation,result,decorationId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result #> '{operation,result}') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,result,cost}' IS DISTINCT FROM '100'
     OR jsonb_typeof(v_result #> '{operation,result,cost}') IS DISTINCT FROM 'number'
     OR jsonb_typeof(v_result -> 'state') IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_result -> 'revision') IS DISTINCT FROM 'number' THEN
    RAISE EXCEPTION 'Initial herb-pot purchase did not apply as expected: %', v_result;
  END IF;
  SELECT p.game_state, c.revision, p.updated_at
    INTO v_before_state, v_before_revision, v_before_updated_at
  FROM public.player_state AS p
  JOIN public.player_economy_control AS c USING (telegram_id)
  WHERE p.telegram_id = c_id_action;
  SELECT to_jsonb(r) INTO v_receipt_before
  FROM public.player_economy_requests AS r
  WHERE r.telegram_id = c_id_action AND r.request_id = c_request_action;
  IF v_receipt_before IS NULL THEN
    RAISE EXCEPTION 'Initial decoration receipt was not stored';
  END IF;
  v_expected_hash := md5(jsonb_build_object('action', 'purchase_decoration',
    'params', jsonb_build_object('decorationId', 'herb-pot'))::text);
  IF v_before_revision <> 1
     OR (v_before_state ->> 'balance')::bigint <> 900
     OR (v_before_state ->> 'score')::bigint <> 37
     OR (v_before_state ->> 'lifetimeDumplings')::bigint <> 81
     OR v_receipt_before ->> 'action' IS DISTINCT FROM 'purchase_decoration'
     OR v_receipt_before ->> 'telegram_id' IS DISTINCT FROM c_id_action::text
     OR v_receipt_before ->> 'request_id' IS DISTINCT FROM c_request_action::text
     OR v_receipt_before -> 'request_args' IS DISTINCT FROM jsonb_build_object('decorationId', 'herb-pot')
     OR v_receipt_before ->> 'request_hash' IS DISTINCT FROM v_expected_hash
     OR jsonb_typeof(v_receipt_before -> 'outcome') IS DISTINCT FROM 'object'
     OR v_receipt_before #>> '{outcome,status}' IS DISTINCT FROM 'applied' THEN
    RAISE EXCEPTION 'Initial decoration state or stored receipt fields are incorrect';
  END IF;

  IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'UTC date changed during idempotency test; rerun outside UTC midnight';
  END IF;
  v_result := public.economy_purchase_upgrade(c_id_action, c_request_action, 'good-stove');
  IF v_result ->> 'ok' IS DISTINCT FROM 'false'
     OR jsonb_typeof(v_result -> 'ok') IS DISTINCT FROM 'boolean'
     OR v_result ->> 'error' IS DISTINCT FROM 'idempotency_conflict'
     OR jsonb_typeof(v_result -> 'error') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result -> 'state') IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_result -> 'revision') IS DISTINCT FROM 'number'
     OR v_result ? 'operation' THEN
    RAISE EXCEPTION 'Changed RPC action did not return idempotency_conflict: %', v_result;
  END IF;
  SELECT p.game_state, c.revision, p.updated_at
    INTO v_after_state, v_after_revision, v_after_updated_at
  FROM public.player_state AS p
  JOIN public.player_economy_control AS c USING (telegram_id)
  WHERE p.telegram_id = c_id_action;
  SELECT to_jsonb(r) INTO v_receipt_after
  FROM public.player_economy_requests AS r
  WHERE r.telegram_id = c_id_action AND r.request_id = c_request_action;
  IF v_after_state IS DISTINCT FROM v_before_state
     OR v_after_revision IS DISTINCT FROM v_before_revision
     OR v_after_updated_at IS DISTINCT FROM v_before_updated_at
     OR v_receipt_after IS DISTINCT FROM v_receipt_before
     OR (v_after_state ->> 'balance')::bigint <> 900
     OR (v_after_state ->> 'score')::bigint <> 37
     OR (v_after_state ->> 'lifetimeDumplings')::bigint <> 81 THEN
    RAISE EXCEPTION 'Changed-action conflict modified state, revision, timestamp, or original receipt';
  END IF;

  -- 3. The same UUID is independently scoped by telegram_id.
  IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'UTC date changed during idempotency test; rerun outside UTC midnight';
  END IF;
  v_result := public.economy_purchase_upgrade(c_id_player_a, c_shared_request, 'good-stove');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR jsonb_typeof(v_result -> 'ok') IS DISTINCT FROM 'boolean'
     OR v_result #>> '{operation,requestId}' IS DISTINCT FROM c_shared_request::text
     OR jsonb_typeof(v_result #> '{operation,requestId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result -> 'operation') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,status}') IS DISTINCT FROM 'string'
     OR v_result #>> '{operation,result,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,result,cost}') IS DISTINCT FROM 'number'
     OR v_result #>> '{operation,result,upgradeId}' IS DISTINCT FROM 'good-stove'
     OR jsonb_typeof(v_result #> '{operation,result,upgradeId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result #> '{operation,result}') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,result,cost}' IS DISTINCT FROM '15' THEN
    RAISE EXCEPTION 'Player A could not use shared UUID independently: %', v_result;
  END IF;
  IF (clock_timestamp() AT TIME ZONE 'UTC')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'UTC date changed during idempotency test; rerun outside UTC midnight';
  END IF;
  v_result := public.economy_purchase_upgrade(c_id_player_b, c_shared_request, 'good-stove');
  IF v_result ->> 'ok' IS DISTINCT FROM 'true'
     OR jsonb_typeof(v_result -> 'ok') IS DISTINCT FROM 'boolean'
     OR v_result #>> '{operation,requestId}' IS DISTINCT FROM c_shared_request::text
     OR jsonb_typeof(v_result #> '{operation,requestId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result -> 'operation') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,status}') IS DISTINCT FROM 'string'
     OR v_result #>> '{operation,result,status}' IS DISTINCT FROM 'applied'
     OR jsonb_typeof(v_result #> '{operation,result,cost}') IS DISTINCT FROM 'number'
     OR v_result #>> '{operation,result,upgradeId}' IS DISTINCT FROM 'good-stove'
     OR jsonb_typeof(v_result #> '{operation,result,upgradeId}') IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_result #> '{operation,result}') IS DISTINCT FROM 'object'
     OR v_result #>> '{operation,result,cost}' IS DISTINCT FROM '15' THEN
    RAISE EXCEPTION 'Player B could not use shared UUID independently: %', v_result;
  END IF;

  SELECT count(*)::integer INTO v_receipt_count
  FROM public.player_economy_requests
  WHERE request_id = c_shared_request
    AND telegram_id IN (c_id_player_a, c_id_player_b);
  v_expected_hash := md5(jsonb_build_object('action', 'purchase_upgrade',
    'params', jsonb_build_object('upgradeId', 'good-stove'))::text);
  IF v_receipt_count <> 2
     OR (SELECT count(*) FROM public.player_economy_requests
         WHERE telegram_id = c_id_player_a AND request_id = c_shared_request
           AND action = 'purchase_upgrade'
           AND request_args = jsonb_build_object('upgradeId', 'good-stove')
           AND request_hash = v_expected_hash
           AND outcome ->> 'status' = 'applied') <> 1
     OR (SELECT count(*) FROM public.player_economy_requests
         WHERE telegram_id = c_id_player_b AND request_id = c_shared_request
           AND action = 'purchase_upgrade'
           AND request_args = jsonb_build_object('upgradeId', 'good-stove')
           AND request_hash = v_expected_hash
           AND outcome ->> 'status' = 'applied') <> 1 THEN
    RAISE EXCEPTION 'Shared UUID did not create two correctly scoped independent receipts';
  END IF;

  v_expected_state := jsonb_set(v_state, '{balance}', '985'::jsonb, true);
  v_expected_state := jsonb_set(v_expected_state, '{upgradeLevels,good-stove}', '1'::jsonb, true);
  v_expected_state := jsonb_set(v_expected_state, '{dailyTasks}',
    public._pelmeni_task_progress(v_expected_state -> 'dailyTasks', 'upgrade', 1), true);
  v_expected_state := public._pelmeni_refresh_achievements(v_expected_state);
  FOR v_result IN
    SELECT jsonb_build_object(
      'telegram_id', p.telegram_id,
      'gameState', p.game_state,
      'balance', p.game_state ->> 'balance',
      'score', p.game_state ->> 'score',
      'lifetimeDumplings', p.game_state ->> 'lifetimeDumplings',
      'goodStove', p.game_state #>> '{upgradeLevels,good-stove}',
      'revision', c.revision)
    FROM public.player_state AS p
    JOIN public.player_economy_control AS c USING (telegram_id)
    WHERE p.telegram_id IN (c_id_player_a, c_id_player_b)
    ORDER BY p.telegram_id
  LOOP
    IF v_result -> 'gameState' IS DISTINCT FROM v_expected_state
       OR v_result ->> 'balance' IS DISTINCT FROM '985'
       OR v_result ->> 'score' IS DISTINCT FROM '37'
       OR v_result ->> 'lifetimeDumplings' IS DISTINCT FROM '81'
       OR v_result ->> 'goodStove' IS DISTINCT FROM '1'
       OR v_result ->> 'revision' IS DISTINCT FROM '1' THEN
      RAISE EXCEPTION 'Shared UUID changed player state by an unexpected amount: %', v_result;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM public.player_state
      WHERE telegram_id IN (c_id_player_a, c_id_player_b)) <> 2 THEN
    RAISE EXCEPTION 'Expected both independent synthetic profiles after shared-UUID operations';
  END IF;
END
$test$;

ROLLBACK;

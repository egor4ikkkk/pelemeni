-- Pelmeni Clicker server economy — PREPARED, NOT APPLIED.
--
-- Preconditions that must be confirmed in Supabase before this file is run:
--   1. public.player_state has exactly the expected key/data columns and a
--      unique key on telegram_id (checked below; this migration aborts otherwise).
--   2. The Supabase role `service_role` exists and is the role used by
--      ctx.supabaseAdmin. The migration aborts if it does not exist.
--   3. This draft intentionally does not activate or rewrite any player rows.
--      Existing profiles have no row in player_economy_control and therefore
--      all commands return profile_not_enabled until a separately reviewed cutover.
--   4. No legacy save/import path is changed here. Deploying this migration alone
--      does not change its response contract. A database trigger below rejects
--      legacy full-state writes for server-mode profiles atomically.
--
-- Applying the migration itself does not rewrite player_state rows. The
-- explicit, hash-approved per-profile activation may apply only the documented
-- compatibility candidate while retaining a complete source snapshot.
-- Economic RPCs currently support only game_state.schemaVersion = 6. The
-- control row must explicitly declare the same version; this migration does
-- not assign a version to old profiles.

DO $preflight$
DECLARE
  v_table regclass := to_regclass('public.player_state');
  v_service_role oid := to_regrole('service_role');
  v_columns text[];
  v_signature text;
BEGIN
  IF v_table IS NULL THEN
    RAISE EXCEPTION 'Preflight failed: public.player_state does not exist';
  END IF;

  SELECT array_agg(format('%s:%s', column_name, data_type) ORDER BY ordinal_position)
    INTO v_columns
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'player_state';

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'player_state'
      AND column_name = 'telegram_id' AND data_type = 'bigint'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'player_state'
      AND column_name = 'game_state' AND data_type = 'jsonb'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'player_state'
      AND column_name = 'updated_at' AND data_type = 'timestamp with time zone'
  ) THEN
    RAISE EXCEPTION 'Preflight failed: expected columns telegram_id bigint, game_state jsonb, updated_at timestamptz; found %', v_columns;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
    WHERE c.conrelid = v_table
      AND c.contype IN ('p', 'u')
      AND cardinality(c.conkey) = 1
      AND a.attname = 'telegram_id'
  ) THEN
    RAISE EXCEPTION 'Preflight failed: telegram_id must have a single-column PRIMARY KEY or UNIQUE constraint';
  END IF;

  IF v_service_role IS NULL THEN
    RAISE EXCEPTION 'Preflight failed: Supabase role service_role is absent; confirm the actual trusted database role before using this draft';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role' AND rolbypassrls) THEN
    RAISE EXCEPTION 'Preflight failed: service_role must bypass RLS for these invoker-security RPCs; confirm the actual server role and policies';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_roles r
    WHERE r.rolname <> 'service_role'
      -- PostgREST's authenticator is the trusted gateway that sets request roles;
      -- it is not an application role or a credential exposed to Mini App clients.
      AND r.rolname <> 'authenticator'
      -- These exact Supabase-managed identities are not application roles.
      -- Keep each exception tied to its observed role attributes; do not exempt
      -- arbitrary NOLOGIN or BYPASSRLS members of service_role.
      AND NOT (
        (r.rolname = 'postgres'
         AND r.rolcanlogin
         AND r.rolinherit
         AND r.rolbypassrls)
        OR (r.rolname = 'supabase_realtime_admin'
            AND NOT r.rolcanlogin
            AND NOT r.rolinherit
            AND NOT r.rolbypassrls)
        OR (r.rolname = 'supabase_storage_admin'
            AND r.rolcanlogin
            AND NOT r.rolinherit
            AND NOT r.rolbypassrls)
      )
      AND NOT r.rolsuper
      AND pg_has_role(r.oid, v_service_role, 'MEMBER')
  ) THEN
    RAISE EXCEPTION 'Preflight failed: a non-gateway non-superuser role can assume service_role; remove or review role membership before enabling the legacy-save guard';
  END IF;

  IF NOT has_table_privilege('service_role', v_table, 'SELECT')
     OR NOT has_table_privilege('service_role', v_table, 'UPDATE')
     OR NOT has_table_privilege('service_role', v_table, 'INSERT') THEN
    RAISE EXCEPTION 'Preflight failed: service_role needs SELECT, INSERT, and UPDATE on public.player_state for the current upsert and invoker-security RPCs';
  END IF;

  IF to_regclass('public.player_economy_control') IS NOT NULL
     OR to_regclass('public.player_economy_requests') IS NOT NULL
     OR to_regclass('public.player_economy_migration_snapshots') IS NOT NULL THEN
    RAISE EXCEPTION 'Preflight failed: one or both economy metadata tables already exist; inspect their definitions before adapting this migration';
  END IF;

  FOREACH v_signature IN ARRAY ARRAY[
    'public._pelmeni_task_progress(jsonb,text,bigint)',
    'public._pelmeni_daily_task_variant(date)',
    'public._pelmeni_daily_task_policy(jsonb,text)',
    'public._pelmeni_add_dumplings(jsonb,bigint,boolean)',
    'public._pelmeni_refresh_achievements(jsonb)',
    'public._pelmeni_state_shape_is_valid(jsonb)',
    'public._pelmeni_finish_request(bigint,uuid,text,jsonb,bigint,jsonb,jsonb)',
    'public._pelmeni_apply_economy_command(bigint,uuid,text,jsonb)',
    'public._pelmeni_valid_utc_day(text)',
    'public._pelmeni_guard_legacy_save()',
    'public._pelmeni_is_first_visit(jsonb)',
    'public._pelmeni_prepare_legacy_state(jsonb,date)',
    'public.economy_assess_legacy_profile(bigint)',
    'public.economy_activate_legacy_profile(bigint)',
    'public.economy_activate_legacy_profile(bigint,text,text,date)',
    'public.economy_load_visit(bigint)',
    'public.economy_start_batch(bigint,uuid,integer)',
    'public.economy_collect_batch(bigint,uuid,text)',
    'public.economy_purchase_upgrade(bigint,uuid,text)',
    'public.economy_purchase_decoration(bigint,uuid,text)',
    'public.economy_set_decoration_equipped(bigint,uuid,text,boolean)',
    'public.economy_claim_task(bigint,uuid,text)',
    'public.economy_claim_streak(bigint,uuid)',
    'public.economy_claim_achievement(bigint,uuid,text)',
    'public.economy_claim_level(bigint,uuid,integer)'
  ] LOOP
    IF to_regprocedure(v_signature) IS NOT NULL THEN
      RAISE EXCEPTION 'Preflight failed: function % already exists; inspect it before adapting this migration', v_signature;
    END IF;
  END LOOP;
END
$preflight$;

DO $trigger_preflight$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = to_regclass('public.player_state')
      AND tgname = 'pelmeni_guard_server_mode_writes'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Preflight failed: trigger pelmeni_guard_server_mode_writes already exists; inspect it before adapting this migration';
  END IF;
END
$trigger_preflight$;

-- These tables contain control metadata only; they are not populated for
-- existing players by this migration.
CREATE TABLE IF NOT EXISTS public.player_economy_control (
  telegram_id bigint PRIMARY KEY,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  server_mode boolean NOT NULL DEFAULT false,
  state_schema_version integer NOT NULL DEFAULT 1 CHECK (state_schema_version > 0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.player_economy_requests (
  telegram_id bigint NOT NULL,
  request_id uuid NOT NULL,
  action text NOT NULL,
  request_hash text NOT NULL,
  request_args jsonb NOT NULL,
  outcome jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (telegram_id, request_id)
);

-- Immutable source snapshots make legacy activation reviewable and repeatable.
CREATE TABLE IF NOT EXISTS public.player_economy_migration_snapshots (
  telegram_id bigint NOT NULL,
  source_hash text NOT NULL,
  source_state jsonb NOT NULL,
  prepared_state jsonb,
  status text NOT NULL CHECK (status IN ('review', 'ready', 'activated')),
  review_reasons text[] NOT NULL DEFAULT ARRAY[]::text[],
  dry_run_utc_date date,
  first_visit_eligible boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  activated_at timestamptz,
  PRIMARY KEY (telegram_id, source_hash)
);

ALTER TABLE public.player_economy_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_economy_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_economy_migration_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.player_economy_control FROM PUBLIC;
REVOKE ALL ON public.player_economy_requests FROM PUBLIC;
REVOKE ALL ON public.player_economy_migration_snapshots FROM PUBLIC;

-- Block the existing Edge Function's whole-state upsert after a profile is
-- enabled. Economy RPCs set a transaction-local marker only after taking the
-- same player_state -> control-row locks; old save requests do not set it.
-- Custom GUCs can be set by ordinary SQL callers, so the marker alone is not
-- authority: the trigger also requires current_user to be service_role.
-- This trigger adds no columns and is compatible with the checked key/data
-- columns, but it cannot distinguish trusted server code from another caller
-- using the service_role. Keep that key server-only. Edge Function changes are
-- still required for canonical load, command routing, and a useful 409 response.
-- The compatibility activation RPC below locks player_state first and the
-- control row second, then switches server_mode as its final database change.
CREATE OR REPLACE FUNCTION public._pelmeni_guard_legacy_save()
RETURNS trigger
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog
SET row_security = off
AS $fn$
DECLARE
  v_server_mode boolean := false;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.telegram_id IS DISTINCT FROM NEW.telegram_id THEN
      RAISE EXCEPTION 'Changing player_state.telegram_id is not allowed' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- The player_state row is already locked by UPDATE; take the metadata lock
    -- second, matching economy RPCs and avoiding a lock-order inversion.
    SELECT server_mode INTO v_server_mode
    FROM public.player_economy_control
    WHERE telegram_id = NEW.telegram_id
    FOR UPDATE;
  ELSE
    -- INSERT runs before ON CONFLICT has locked an existing player row. Do not
    -- lock control here: if the insert becomes an upsert, its UPDATE trigger
    -- rechecks under the consistent player_state -> control lock order.
    SELECT server_mode INTO v_server_mode
    FROM public.player_economy_control
    WHERE telegram_id = NEW.telegram_id;
  END IF;

  IF COALESCE(v_server_mode, false)
     AND NOT (current_user = 'service_role'
              AND current_setting('pelmeni.server_economy_write', true) IS NOT DISTINCT FROM 'allowed') THEN
    RAISE EXCEPTION 'Legacy full-state writes are disabled for server-managed profiles'
      USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END
$fn$;

CREATE TRIGGER pelmeni_guard_server_mode_writes
BEFORE INSERT OR UPDATE ON public.player_state
FOR EACH ROW EXECUTE FUNCTION public._pelmeni_guard_legacy_save();

CREATE OR REPLACE FUNCTION public._pelmeni_valid_utc_day(p_day text)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_day date;
BEGIN
  IF p_day IS NULL OR p_day !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RETURN false;
  END IF;
  v_day := p_day::date;
  RETURN v_day::text = p_day;
EXCEPTION WHEN others THEN
  RETURN false;
END
$fn$;

-- Internal helpers use the ordinary invoker context. The Edge Function must
-- call them only with its server-side admin client, after verifying initData.
CREATE OR REPLACE FUNCTION public._pelmeni_task_progress(
  p_tasks jsonb, p_task_id text, p_increment bigint
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_task jsonb := COALESCE(p_tasks -> p_task_id, '{"progress":0,"claimed":false}'::jsonb);
  v_progress bigint := LEAST(1000000, GREATEST(0, COALESCE((v_task ->> 'progress')::bigint, 0)) + p_increment);
BEGIN
  RETURN jsonb_set(
    COALESCE(p_tasks, '{}'::jsonb), ARRAY[p_task_id],
    jsonb_build_object('progress', v_progress, 'claimed', COALESCE((v_task ->> 'claimed')::boolean, false)), true
  );
END
$fn$;

-- Keep the UTC rotation identical to dailyTaskVariantForDate() in game-rules.js.
CREATE OR REPLACE FUNCTION public._pelmeni_daily_task_variant(p_day date)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SECURITY INVOKER
SET search_path = pg_catalog
AS $fn$
  SELECT CASE mod(p_day - DATE '1970-01-01', 3)
    WHEN 0 THEN 'classic' WHEN 1 THEN 'batch-focus' ELSE 'kitchen-rhythm' END;
$fn$;

-- Shared daily-task target/progress projection, also called by claim_task.
-- Progress comes only from server-updated dailyTasks; the client passes an ID,
-- never a target, progress amount, reward, or task variant.
CREATE OR REPLACE FUNCTION public._pelmeni_daily_task_policy(p_state jsonb, p_task_id text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $fn$
DECLARE
  v_variant text := p_state ->> 'dailyTaskVariant';
  v_progress bigint;
  v_goal bigint;
  v_cook_text text;
  v_collect_text text;
  v_internal_text text;
  v_claimed boolean;
  v_reward bigint;
BEGIN
  v_goal := CASE
    WHEN p_task_id IN ('cook', 'collect') AND v_variant = 'batch-focus' THEN 2
    WHEN p_task_id = 'collect-dumplings' AND v_variant = 'kitchen-rhythm' THEN 2
    WHEN p_task_id = 'collect-dumplings' THEN 30
    WHEN p_task_id IN ('cook', 'collect', 'upgrade', 'two-pots') THEN 1
    ELSE NULL
  END;
  IF v_goal IS NULL OR COALESCE(v_variant NOT IN ('classic', 'batch-focus', 'kitchen-rhythm'), true) THEN
    RETURN NULL;
  END IF;

  IF p_task_id = 'collect' AND v_variant = 'kitchen-rhythm' THEN
    v_cook_text := COALESCE(p_state #>> '{dailyTasks,cook,progress}', '0');
    v_collect_text := COALESCE(p_state #>> '{dailyTasks,collect,progress}', '0');
    IF v_cook_text !~ '^(0|[1-9][0-9]*)$' OR length(v_cook_text) > 19
       OR v_collect_text !~ '^(0|[1-9][0-9]*)$' OR length(v_collect_text) > 19 THEN
      RETURN NULL;
    END IF;
    v_progress := LEAST(1000000, LEAST(v_cook_text::numeric, v_collect_text::numeric))::bigint;
  ELSIF p_task_id = 'collect-dumplings' AND v_variant = 'kitchen-rhythm' THEN
    v_internal_text := COALESCE(p_state #>> '{dailyTasks,collect-two,progress}', '0');
    IF v_internal_text !~ '^(0|[1-9][0-9]*)$' OR length(v_internal_text) > 19 THEN
      RETURN NULL;
    END IF;
    v_progress := LEAST(1000000, v_internal_text::numeric)::bigint;
  ELSE
    v_internal_text := COALESCE(p_state #>> ARRAY['dailyTasks', p_task_id, 'progress'], '0');
    IF v_internal_text !~ '^(0|[1-9][0-9]*)$' OR length(v_internal_text) > 19 THEN
      RETURN NULL;
    END IF;
    v_progress := LEAST(1000000, v_internal_text::numeric)::bigint;
  END IF;

  v_claimed := COALESCE(
    p_state #> ARRAY['dailyTasks', p_task_id, 'claimed'] = 'true'::jsonb,
    false);
  v_reward := CASE p_task_id
    WHEN 'cook' THEN 10 WHEN 'collect' THEN 5 WHEN 'collect-dumplings' THEN 10
    WHEN 'upgrade' THEN 15 WHEN 'two-pots' THEN 5 ELSE NULL END;
  RETURN jsonb_build_object(
    'goal', v_goal,
    'progress', v_progress,
    'claimed', v_claimed,
    'reward', v_reward,
    'status', CASE WHEN v_claimed THEN 'task_already_claimed'
      WHEN v_progress < v_goal THEN 'task_not_complete' ELSE 'applied' END);
END
$fn$;

CREATE OR REPLACE FUNCTION public._pelmeni_add_dumplings(
  p_state jsonb, p_amount bigint, p_count_lifetime boolean
) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
  SELECT jsonb_set(
    jsonb_set(
      CASE WHEN p_count_lifetime THEN
        jsonb_set(p_state, '{lifetimeDumplings}', to_jsonb(COALESCE((p_state ->> 'lifetimeDumplings')::bigint, 0) + p_amount), true)
      ELSE p_state END,
      '{balance}', to_jsonb(COALESCE((p_state ->> 'balance')::bigint, 0) + p_amount), true
    ),
    '{score}', to_jsonb(COALESCE((p_state ->> 'score')::bigint, 0) + p_amount), true
  )
$fn$;

-- Mirror the current client's automatic unlocks, but never pay an achievement
-- here. Claims remain an explicit player command.
CREATE OR REPLACE FUNCTION public._pelmeni_refresh_achievements(p_state jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_achievements jsonb := COALESCE(p_state -> 'achievements', '[]'::jsonb);
  v_levels jsonb := COALESCE(p_state -> 'upgradeLevels', '{}'::jsonb);
  v_upgrades jsonb := COALESCE(p_state -> 'upgrades', '[]'::jsonb);
  v_batches jsonb := COALESCE(p_state -> 'activeBatches', '[]'::jsonb);
  v_collections jsonb := COALESCE(p_state -> 'potCollections', '{"1":0,"2":0}'::jsonb);
  v_started bigint := COALESCE((p_state ->> 'batches')::bigint, 0) + jsonb_array_length(v_batches);
  v_batch_count bigint := COALESCE((p_state ->> 'batches')::bigint, 0);
  v_lifetime bigint := COALESCE((p_state ->> 'lifetimeDumplings')::bigint, 0);
  v_total_upgrades bigint := COALESCE((v_levels ->> 'good-stove')::bigint, 0)
    + COALESCE((v_levels ->> 'large-pot')::bigint, 0)
    + COALESCE((v_levels ->> 'grandma-recipe')::bigint, 0)
    + jsonb_array_length(v_upgrades);
  v_kitchen_level bigint := 1 + floor((
    COALESCE((v_levels ->> 'good-stove')::bigint, 0)
    + COALESCE((v_levels ->> 'large-pot')::bigint, 0)
    + COALESCE((v_levels ->> 'grandma-recipe')::bigint, 0)
  )::numeric / 2)::bigint;
  v_streak_best bigint := COALESCE((p_state ->> 'streakBest')::bigint, 0);
  v_id text;
  v_met boolean;
BEGIN
  FOREACH v_id IN ARRAY ARRAY[
    'first-visit','first-start','first-batch','first-upgrade',
    'dumpling-100','dumpling-500','dumpling-thousand','dumpling-5000','dumpling-10000',
    'starts-ten','starts-fifty','five-batches','ten-batches','twenty-five-batches','fifty-batches',
    'upgrade-five','upgrade-ten','second-pot','three-decorations','master-kitchen','both-burners',
    'streak-three','streak-seven','streak-fourteen','streak-thirty'
  ] LOOP
    v_met := CASE v_id
      WHEN 'first-visit' THEN v_achievements @> '["first-visit"]'::jsonb
      WHEN 'first-start' THEN v_started >= 1
      WHEN 'first-batch' THEN v_batch_count >= 1
      WHEN 'first-upgrade' THEN v_total_upgrades >= 1
      WHEN 'dumpling-100' THEN v_lifetime >= 100
      WHEN 'dumpling-500' THEN v_lifetime >= 500
      WHEN 'dumpling-thousand' THEN v_lifetime >= 1000
      WHEN 'dumpling-5000' THEN v_lifetime >= 5000
      WHEN 'dumpling-10000' THEN v_lifetime >= 10000
      WHEN 'starts-ten' THEN v_started >= 10
      WHEN 'starts-fifty' THEN v_started >= 50
      WHEN 'five-batches' THEN v_batch_count >= 5
      WHEN 'ten-batches' THEN v_batch_count >= 10
      WHEN 'twenty-five-batches' THEN v_batch_count >= 25
      WHEN 'fifty-batches' THEN v_batch_count >= 50
      WHEN 'upgrade-five' THEN v_total_upgrades >= 5
      WHEN 'upgrade-ten' THEN v_total_upgrades >= 10
      WHEN 'second-pot' THEN v_upgrades @> '["second-pot"]'::jsonb
      WHEN 'three-decorations' THEN
        v_upgrades @> '["herb-pot"]'::jsonb
        AND v_upgrades @> '["blue-tile"]'::jsonb
        AND v_upgrades @> '["wooden-spoon"]'::jsonb
      WHEN 'master-kitchen' THEN v_kitchen_level >= 6
      WHEN 'both-burners' THEN COALESCE((v_collections ->> '1')::bigint, 0) > 0
        AND COALESCE((v_collections ->> '2')::bigint, 0) > 0
      WHEN 'streak-three' THEN v_streak_best >= 3
      WHEN 'streak-seven' THEN v_streak_best >= 7
      WHEN 'streak-fourteen' THEN v_streak_best >= 14
      WHEN 'streak-thirty' THEN v_streak_best >= 30
      ELSE false
    END;
    IF v_met AND NOT (v_achievements @> jsonb_build_array(v_id)) THEN
      v_achievements := v_achievements || jsonb_build_array(v_id);
    END IF;
  END LOOP;
  RETURN jsonb_set(p_state, '{achievements}', v_achievements, true);
END
$fn$;

-- Reject malformed persisted JSON before an economy operation can interpret it.
-- This is validation only: it never repairs or normalizes a saved profile.
CREATE OR REPLACE FUNCTION public._pelmeni_state_shape_is_valid(p_state jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_key text;
  v_expected_type text;
  v_text text;
  v_value jsonb;
  v_batch jsonb;
  v_task jsonb;
  v_id text;
  v_pot integer;
  v_started numeric;
  v_ends numeric;
  v_duration numeric;
  v_pot_one_count integer := 0;
  v_pot_two_count integer := 0;
  v_ids text[] := ARRAY[]::text[];
  v_claim_ids text[] := ARRAY[]::text[];
  v_pots integer[] := ARRAY[]::integer[];
  v_limit bigint := 9223372036854775807;
BEGIN
  IF jsonb_typeof(p_state) IS DISTINCT FROM 'object' THEN RETURN false; END IF;

  FOR v_key, v_expected_type IN
    SELECT * FROM (VALUES
      ('upgradeLevels', 'object'), ('upgrades', 'array'), ('equipped', 'array'),
      ('activeBatches', 'array'), ('dailyTasks', 'object'), ('levelClaims', 'array'),
      ('achievements', 'array'), ('achievementClaims', 'array'), ('streakRewardClaims', 'array'),
      ('taskPotsUsed', 'array'), ('potCollections', 'object')
    ) AS expected(key, json_type)
  LOOP
    IF p_state ? v_key AND jsonb_typeof(p_state -> v_key) IS DISTINCT FROM v_expected_type THEN
      RETURN false;
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY ARRAY['balance', 'score', 'points', 'lifetimeDumplings', 'batches', 'taskBatches', 'streakCurrent', 'streakBest', 'taskBalanceRewardVersion', 'schemaVersion'] LOOP
    IF p_state ? v_key THEN
      v_value := p_state -> v_key;
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^(0|[1-9][0-9]*)$'
         OR length(v_text) > 19 THEN
        RETURN false;
      END IF;
      IF v_text::numeric > v_limit
         OR (v_key IN ('streakCurrent', 'streakBest') AND v_text::numeric > 1000000000)
         OR (v_key = 'taskBalanceRewardVersion' AND v_text::numeric <> 1)
         OR (v_key = 'schemaVersion' AND v_text::numeric <> 6) THEN
        RETURN false;
      END IF;
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY ARRAY['good-stove', 'large-pot', 'grandma-recipe'] LOOP
    IF COALESCE(p_state -> 'upgradeLevels', '{}'::jsonb) ? v_key THEN
      v_value := p_state -> 'upgradeLevels' -> v_key;
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 2 THEN
        RETURN false;
      END IF;
      IF v_text::integer > 10 THEN
        RETURN false;
      END IF;
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY ARRAY['upgrades', 'equipped', 'achievements', 'achievementClaims', 'streakRewardClaims'] LOOP
    IF p_state ? v_key THEN
      FOR v_value IN SELECT value FROM jsonb_array_elements(p_state -> v_key) AS item(value) LOOP
        IF jsonb_typeof(v_value) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- The client keeps only date:visit-kind:claim-kind markers whose date is a
  -- real UTC day. Do not silently discard malformed server history during
  -- activation: it could conceal whether today's reward was already claimed.
  -- Duplicate valid markers are harmless and are deduplicated in the reviewed
  -- legacy candidate below, matching normalizeStreakRewardClaims().
  IF p_state ? 'streakRewardClaims' THEN
    FOR v_value IN
      SELECT value FROM jsonb_array_elements(p_state -> 'streakRewardClaims') AS item(value)
    LOOP
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'string'
         OR v_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9]+:[0-9]+$'
         OR NOT public._pelmeni_valid_utc_day(split_part(v_text, ':', 1)) THEN
        RETURN false;
      END IF;
    END LOOP;
  END IF;

  -- Match normalizeState(): claims contain only real, already-unlocked reward
  -- IDs, omit the client's non-claimable score-1000 marker, and are unique.
  IF p_state ? 'achievementClaims' THEN
    FOR v_value IN SELECT value FROM jsonb_array_elements(p_state -> 'achievementClaims') AS item(value) LOOP
      v_id := v_value #>> '{}';
      IF v_id NOT IN (
        'first-visit','first-start','first-batch','first-upgrade',
        'dumpling-100','dumpling-500','dumpling-thousand','dumpling-5000','dumpling-10000',
        'starts-ten','starts-fifty','five-batches','ten-batches','twenty-five-batches','fifty-batches',
        'upgrade-five','upgrade-ten','second-pot','three-decorations','master-kitchen','both-burners',
        'streak-three','streak-seven','streak-fourteen','streak-thirty'
      ) OR v_id = ANY(v_claim_ids)
        OR COALESCE(p_state -> 'achievements' @> jsonb_build_array(v_id), false) IS DISTINCT FROM TRUE THEN
        RETURN false;
      END IF;
      v_claim_ids := array_append(v_claim_ids, v_id);
    END LOOP;
  END IF;

  IF p_state ? 'dailyTasks' THEN
    FOR v_key, v_task IN SELECT key, value FROM jsonb_each(p_state -> 'dailyTasks') AS item(key, value) LOOP
      IF v_key NOT IN ('login', 'cook', 'upgrade', 'collect', 'collect-dumplings', 'collect-two', 'two-pots') THEN
        RETURN false;
      END IF;
      IF jsonb_typeof(v_task) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
      IF NOT (v_task ? 'progress') OR NOT (v_task ? 'claimed') THEN RETURN false; END IF;
      IF v_task ? 'progress' THEN
        v_value := v_task -> 'progress';
        v_text := v_value #>> '{}';
        IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
           OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 7 THEN
          RETURN false;
        END IF;
        IF v_text::integer > 1000000 THEN
          RETURN false;
        END IF;
      END IF;
      IF v_task ? 'claimed' AND jsonb_typeof(v_task -> 'claimed') IS DISTINCT FROM 'boolean' THEN
        RETURN false;
      END IF;
    END LOOP;
  END IF;

  IF p_state ? 'activeBatches' THEN
    FOR v_batch IN SELECT value FROM jsonb_array_elements(p_state -> 'activeBatches') AS item(value) LOOP
      IF jsonb_typeof(v_batch) IS DISTINCT FROM 'object'
         OR jsonb_typeof(v_batch -> 'id') IS DISTINCT FROM 'string'
         OR (v_batch ->> 'id') !~ '^[A-Za-z0-9_-]{1,64}$'
         OR jsonb_typeof(v_batch -> 'pot') IS DISTINCT FROM 'number'
         OR (v_batch ->> 'pot') !~ '^[12]$' THEN
        RETURN false;
      END IF;
      v_id := v_batch ->> 'id';
      v_pot := (v_batch ->> 'pot')::integer;
      IF v_id = ANY(v_ids) OR v_pot = ANY(v_pots) THEN RETURN false; END IF;

      FOREACH v_key IN ARRAY ARRAY['startedAt', 'endsAt', 'durationMs'] LOOP
        v_value := v_batch -> v_key;
        v_text := v_value #>> '{}';
        IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
           OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
          RETURN false;
        END IF;
        IF v_text::numeric > v_limit THEN
          RETURN false;
        END IF;
      END LOOP;
      v_started := (v_batch ->> 'startedAt')::numeric;
      v_ends := (v_batch ->> 'endsAt')::numeric;
      v_duration := (v_batch ->> 'durationMs')::numeric;
      IF v_duration <= 0 OR v_ends <= v_started THEN RETURN false; END IF;

      v_ids := array_append(v_ids, v_id);
      v_pots := array_append(v_pots, v_pot);
    END LOOP;
  END IF;

  IF p_state ? 'taskPotsUsed' THEN
    FOR v_value IN SELECT value FROM jsonb_array_elements(p_state -> 'taskPotsUsed') AS item(value) LOOP
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number' OR v_value #>> '{}' NOT IN ('1', '2') THEN
        RETURN false;
      END IF;
      IF v_value #>> '{}' = '1' THEN v_pot_one_count := v_pot_one_count + 1; END IF;
      IF v_value #>> '{}' = '2' THEN v_pot_two_count := v_pot_two_count + 1; END IF;
    END LOOP;
    IF jsonb_array_length(p_state -> 'taskPotsUsed') > 2
       OR v_pot_one_count > 1 OR v_pot_two_count > 1 THEN
      RETURN false;
    END IF;
  END IF;

  IF p_state ? 'levelClaims' THEN
    FOR v_value IN SELECT value FROM jsonb_array_elements(p_state -> 'levelClaims') AS item(value) LOOP
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^([2-9]|10)$' THEN
        RETURN false;
      END IF;
    END LOOP;
  END IF;

  IF p_state ? 'potCollections' THEN
    FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_state -> 'potCollections') AS item(key, value) LOOP
      IF v_key NOT IN ('1', '2') THEN RETURN false; END IF;
      IF v_key IN ('1', '2') THEN
        v_text := v_value #>> '{}';
        IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
           OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 7 THEN
          RETURN false;
        END IF;
        IF v_text::integer > 1000000 THEN
          RETURN false;
        END IF;
      END IF;
    END LOOP;
  END IF;

  -- These scalar fields are consumed by economic RPCs or first-visit
  -- classification. Reject malformed values before any downstream cast.
  FOREACH v_key IN ARRAY ARRAY['taskDay', 'dailyDate', 'loginRewardDate', 'taskClaimedOn', 'streakLastVisitDate', 'streakRunStartedDate'] LOOP
    IF p_state ? v_key AND p_state -> v_key IS DISTINCT FROM 'null'::jsonb THEN
      IF jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'string'
         OR NOT public._pelmeni_valid_utc_day(p_state ->> v_key) THEN RETURN false; END IF;
    END IF;
  END LOOP;

  -- `dailyTaskVariant` is serialized by the current client. Null is a valid
  -- legacy/stale-day value, but only the three current identifiers are valid
  -- strings. This is validation only; no variant is inferred or rewritten.
  IF p_state ? 'dailyTaskVariant'
     AND p_state -> 'dailyTaskVariant' IS DISTINCT FROM 'null'::jsonb
     AND (jsonb_typeof(p_state -> 'dailyTaskVariant') IS DISTINCT FROM 'string'
          OR p_state ->> 'dailyTaskVariant' NOT IN ('classic', 'batch-focus', 'kitchen-rhythm')) THEN
    RETURN false;
  END IF;
  FOREACH v_key IN ARRAY ARRAY['pointsRetired', 'firstLoginNoReward'] LOOP
    IF p_state ? v_key AND jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'boolean' THEN RETURN false; END IF;
  END LOOP;
  FOREACH v_key IN ARRAY ARRAY['loginRewardDate', 'taskClaimedOn', 'referralCode', 'joinedAt', 'lastBatchAt', 'lastBatchReward', 'schemaVersion'] LOOP
    IF p_state ? v_key AND p_state -> v_key IS DISTINCT FROM 'null'::jsonb THEN
      IF v_key IN ('loginRewardDate', 'taskClaimedOn') AND jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
      IF v_key = 'referralCode' AND (jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'string' OR (p_state ->> v_key) !~ '^PC-[A-Z0-9]{6}$') THEN RETURN false; END IF;
      IF v_key IN ('joinedAt', 'lastBatchAt') AND jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
      IF v_key = 'lastBatchReward' THEN
        IF jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'object'
           OR NOT ((p_state -> v_key) ? 'dumplings')
           OR jsonb_typeof(p_state #> ARRAY[v_key, 'dumplings']) IS DISTINCT FROM 'number'
           OR (p_state #>> ARRAY[v_key, 'dumplings']) !~ '^(0|[1-9][0-9]*)$'
           OR length(p_state #>> ARRAY[v_key, 'dumplings']) > 19
           OR (p_state #>> ARRAY[v_key, 'dumplings'])::numeric > v_limit THEN
          RETURN false;
        END IF;
      END IF;
      IF v_key = 'schemaVersion' AND (jsonb_typeof(p_state -> v_key) IS DISTINCT FROM 'number' OR (p_state ->> v_key) !~ '^[0-9]+$') THEN RETURN false; END IF;
    END IF;
  END LOOP;

  RETURN true;
EXCEPTION WHEN others THEN
  -- Never let malformed persisted JSON escape validation as a SQL exception.
  RETURN false;
END
$fn$;

-- Produce a schema-6 candidate preserving balances except for the exact legacy
-- points transfer already defined by normalizeState(). Purchases, lifetime
-- statistics, achievements, claim history, and valid batch timestamps remain
-- protected. A nonempty reasons array means manual review is required.
CREATE OR REPLACE FUNCTION public._pelmeni_prepare_legacy_state(p_state jsonb, p_today date)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_state jsonb := p_state;
  v_daily_probe jsonb := jsonb_build_object('schemaVersion', 6);
  v_tasks jsonb;
  v_task jsonb;
  v_batch jsonb;
  v_batches jsonb := '[]'::jsonb;
  v_id text;
  v_key text;
  v_text text;
  v_claims jsonb;
  v_variant text;
  v_expected_variant text;
  v_daily_day date;
  v_task_day date;
  v_first_visit boolean;
  v_last_batch_date date;
  v_last_batch_text text;
  v_owned jsonb;
  v_equipped jsonb;
  v_legacy_level jsonb;
  v_started numeric;
  v_ends numeric;
  v_duration numeric;
  v_legacy_points numeric;
  v_legacy_balance numeric;
  v_legacy_score numeric;
  v_legacy_lifetime numeric;
  v_points_retired boolean;
  v_legacy_points_state_valid boolean := false;
  v_effective_score numeric;
  v_legacy_probe jsonb;
  v_today_ms numeric;
  v_today_start_ms numeric;
  v_current_day_batch boolean := false;
  v_blockers text[] := ARRAY[]::text[];
  v_task_ids text[] := ARRAY['login','cook','upgrade','collect','collect-dumplings','collect-two','two-pots'];
BEGIN
  IF jsonb_typeof(v_state) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reasons', jsonb_build_array('game_state_not_object'));
  END IF;

  IF p_today IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reasons', jsonb_build_array('server_date_missing'));
  END IF;

  -- Schema 6 is supported. A missing version may be added only after the
  -- supported state fields have passed validation; an explicit other version
  -- requires a separate migration and is never relabelled.
  IF v_state ? 'schemaVersion'
     AND (jsonb_typeof(v_state -> 'schemaVersion') IS DISTINCT FROM 'number'
          OR v_state ->> 'schemaVersion' IS DISTINCT FROM '6') THEN
    v_blockers := array_append(v_blockers, 'unsupported_schema_version');
  END IF;

  -- Fields that carry irreversible economic history must be present. In
  -- particular, absent claim ledgers are not interpreted as proof of unpaid
  -- rewards. Empty achievement/level histories are safe only where the saved
  -- state proves no such reward could previously have been unlocked.
  FOREACH v_key IN ARRAY ARRAY[
    'balance','score','batches','upgradeLevels','upgrades','equipped',
    'taskDay','taskBatches','lifetimeDumplings','taskClaimedOn','taskBalanceRewardVersion',
    'referralCode','dailyDate','loginRewardDate','firstLoginNoReward','streakCurrent','streakBest',
    'streakLastVisitDate','streakRunStartedDate','streakRewardClaims','taskPotsUsed','potCollections',
    'achievements','joinedAt','lastBatchReward','lastBatchAt'
  ] LOOP
    IF NOT (v_state ? v_key) THEN
      v_blockers := array_append(v_blockers, 'missing_' || v_key);
    END IF;
  END LOOP;

  -- Classify the untouched source before applying any deterministic legacy
  -- field conversion. In particular, pointsRetired=false is never evidence of
  -- a fresh profile, even if its currently visible counters happen to be zero.
  v_first_visit := public._pelmeni_is_first_visit(v_state);
  IF v_first_visit IS NULL THEN
    v_blockers := array_append(v_blockers, 'first_visit_state_ambiguous');
  ELSE
    -- Identical valid streak markers carry no extra history. Match the
    -- client's Set-based normalization while retaining the first occurrence
    -- and every distinct marker. The original source JSON remains in the
    -- immutable migration snapshot for rollback/audit.
    SELECT COALESCE(jsonb_agg(to_jsonb(markers.marker) ORDER BY markers.first_position), '[]'::jsonb)
      INTO v_claims
    FROM (
      SELECT marker, min(ordinality) AS first_position
      FROM jsonb_array_elements_text(v_state -> 'streakRewardClaims')
        WITH ORDINALITY AS claims(marker, ordinality)
      GROUP BY marker
    ) AS markers;
    IF v_claims IS DISTINCT FROM v_state -> 'streakRewardClaims' THEN
      v_state := jsonb_set(v_state, '{streakRewardClaims}', v_claims, true);
    END IF;
  END IF;

  -- Match normalizeState()'s deterministic retirement of the legacy points
  -- field. This is a one-time value transfer, not a reward: the original JSON
  -- is kept in the source snapshot and the candidate is hash-approved before
  -- activation. Invalid/missing source counters stay review-only.
  v_legacy_probe := jsonb_build_object(
    'balance',v_state -> 'balance','score',v_state -> 'score',
    'lifetimeDumplings',v_state -> 'lifetimeDumplings',
    'pointsRetired',COALESCE(v_state -> 'pointsRetired','false'::jsonb));
  IF v_state ? 'points' THEN
    v_legacy_probe := v_legacy_probe || jsonb_build_object('points',v_state -> 'points');
  END IF;
  v_legacy_points_state_valid := public._pelmeni_state_shape_is_valid(v_legacy_probe) IS TRUE;
  IF NOT v_legacy_points_state_valid THEN
    v_blockers := array_append(v_blockers, 'legacy_points_state_invalid');
  ELSE
    v_points_retired := COALESCE((v_state -> 'pointsRetired') = 'true'::jsonb, false);
    v_legacy_balance := (v_state ->> 'balance')::numeric;
    v_legacy_score := (v_state ->> 'score')::numeric;
    v_legacy_lifetime := (v_state ->> 'lifetimeDumplings')::numeric;
    v_effective_score := GREATEST(v_legacy_score, v_legacy_lifetime, v_legacy_balance);
    IF NOT v_points_retired THEN
      IF v_state ? 'points' THEN
        v_legacy_points := (v_state ->> 'points')::numeric;
      ELSE
        -- This fallback mirrors normalizeState() for pre-points saves.
        v_legacy_points := v_legacy_score;
      END IF;
      IF v_legacy_balance + v_legacy_points > 9223372036854775807 THEN
        v_blockers := array_append(v_blockers, 'legacy_points_balance_overflow');
      ELSE
        v_state := jsonb_set(v_state, '{balance}', to_jsonb(v_legacy_balance + v_legacy_points), true);
        v_state := jsonb_set(v_state, '{score}', to_jsonb(GREATEST(v_legacy_score, v_legacy_lifetime, v_legacy_balance)), true);
        v_state := jsonb_set(v_state, '{points}', '0'::jsonb, true);
        v_state := jsonb_set(v_state, '{pointsRetired}', 'true'::jsonb, true);
      END IF;
    ELSE
      -- normalizeState() also reconciles score on already-retired saves; do
      -- not leave the server candidate behind the client's displayed score.
      v_state := jsonb_set(v_state, '{score}', to_jsonb(GREATEST(v_legacy_score, v_legacy_lifetime, v_legacy_balance)), true);
      v_state := jsonb_set(v_state, '{points}', '0'::jsonb, true);
    END IF;
  END IF;

  -- Validate timestamps before rollover or classification can hide them.
  FOREACH v_key IN ARRAY ARRAY['joinedAt','lastBatchAt'] LOOP
    IF v_state -> v_key IS DISTINCT FROM 'null'::jsonb THEN
      IF jsonb_typeof(v_state -> v_key) IS DISTINCT FROM 'string' THEN
        v_blockers := array_append(v_blockers, 'invalid_' || v_key);
      ELSE
        BEGIN
          v_last_batch_text := v_state ->> v_key;
          PERFORM v_last_batch_text::timestamptz;
          IF v_key = 'lastBatchAt' THEN
            v_last_batch_date := (v_last_batch_text::timestamptz AT TIME ZONE 'UTC')::date;
          END IF;
        EXCEPTION WHEN others THEN
          v_blockers := array_append(v_blockers, 'invalid_' || v_key);
        END;
      END IF;
    END IF;
  END LOOP;

  -- Validate fields that a UTC rollover may replace before touching them.
  -- Otherwise a malformed old-day claim marker or task payload could be
  -- silently erased by the rollover and misclassified as a clean profile.
  FOREACH v_key IN ARRAY ARRAY[
    'dailyTasks','dailyTaskVariant','dailyDate','taskDay','taskBatches',
    'taskClaimedOn','taskBalanceRewardVersion','taskPotsUsed','firstLoginNoReward'
  ] LOOP
    IF v_state ? v_key THEN
      v_daily_probe := v_daily_probe || jsonb_build_object(v_key, v_state -> v_key);
    END IF;
  END LOOP;
  IF public._pelmeni_state_shape_is_valid(v_daily_probe) IS DISTINCT FROM TRUE THEN
    v_blockers := array_append(v_blockers, 'malformed_daily_legacy_state');
  END IF;

  IF v_first_visit IS TRUE AND (v_state ->> 'dailyDate' IS DISTINCT FROM p_today::text
      OR v_state ->> 'taskDay' IS DISTINCT FROM p_today::text) THEN
    -- An empty-looking old profile with no trustworthy visit marker cannot be
    -- distinguished from a stale first-visit snapshot; never promote it.
    v_blockers := array_append(v_blockers, 'first_visit_state_ambiguous');
  END IF;

  IF NOT (v_state ? 'achievementClaims') THEN
    IF jsonb_typeof(v_state -> 'achievements') IS DISTINCT FROM 'array' THEN
      v_blockers := array_append(v_blockers, 'ambiguous_achievement_claim_history');
    ELSIF jsonb_array_length(v_state -> 'achievements') > 0 THEN
      v_blockers := array_append(v_blockers, 'ambiguous_achievement_claim_history');
    ELSIF v_first_visit IS DISTINCT FROM TRUE THEN
      -- An empty unlock list alone does not prove that old awards were never
      -- claimable (for example, an older client may not have refreshed them).
      -- Only a provably fresh canonical profile can safely start with no claims.
      v_blockers := array_append(v_blockers, 'ambiguous_achievement_claim_history');
    ELSE
      v_state := jsonb_set(v_state, '{achievementClaims}', '[]'::jsonb, true);
    END IF;
  END IF;
  IF NOT (v_state ? 'levelClaims') THEN
    IF NOT v_legacy_points_state_valid OR v_effective_score IS NULL THEN
      v_blockers := array_append(v_blockers, 'ambiguous_level_claim_history');
    ELSIF v_effective_score >= 500 THEN
      -- normalizeState() exposes max(score, lifetimeDumplings, balance) as
      -- score. Any of these may make a level reward claimable; missing history
      -- cannot safely be interpreted as an empty claim ledger.
      v_blockers := array_append(v_blockers, 'ambiguous_level_claim_history');
    ELSE
      v_state := jsonb_set(v_state, '{levelClaims}', '[]'::jsonb, true);
    END IF;
  END IF;

  -- Unknown daily task IDs are not silently discarded by rollover. They make
  -- the profile review-only until a migration explicitly understands them.
  IF v_state ? 'dailyTasks' THEN
    IF jsonb_typeof(v_state -> 'dailyTasks') IS DISTINCT FROM 'object' THEN
      v_blockers := array_append(v_blockers, 'invalid_daily_tasks_type');
    ELSE
      FOR v_key IN SELECT key FROM jsonb_object_keys(v_state -> 'dailyTasks') AS tasks(key) LOOP
        IF NOT (v_key = ANY(v_task_ids)) THEN
          v_blockers := array_append(v_blockers, 'unknown_daily_task_id:' || v_key);
        ELSIF jsonb_typeof(v_state #> ARRAY['dailyTasks', v_key]) = 'object'
          AND EXISTS (
            SELECT 1
            FROM jsonb_object_keys(v_state #> ARRAY['dailyTasks', v_key]) AS properties(key)
            WHERE key NOT IN ('progress', 'claimed')
          ) THEN
          -- Unknown task-slot fields may carry state whose meaning this
          -- migration cannot preserve or reconcile safely.
          v_blockers := array_append(v_blockers, 'unknown_daily_task_property:' || v_key);
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- Legacy single-batch aliases do not carry a stable batch ID or an explicit
  -- pot slot. Their timestamps cannot safely be turned into a server batch;
  -- preserve the source and require review rather than inventing identity.
  IF NOT (v_state ? 'activeBatches') THEN
    IF v_state -> 'startedAt' IS DISTINCT FROM 'null'::jsonb
       OR v_state -> 'endsAt' IS DISTINCT FROM 'null'::jsonb THEN
      IF jsonb_typeof(v_state -> 'startedAt') IS DISTINCT FROM 'number'
         OR jsonb_typeof(v_state -> 'endsAt') IS DISTINCT FROM 'number'
         OR (v_state ->> 'startedAt') !~ '^(0|[1-9][0-9]*)$'
         OR (v_state ->> 'endsAt') !~ '^(0|[1-9][0-9]*)$' THEN
        v_blockers := array_append(v_blockers, 'invalid_legacy_batch_timestamps');
      ELSE
        v_started := (v_state ->> 'startedAt')::numeric;
        v_ends := (v_state ->> 'endsAt')::numeric;
        IF v_ends <= v_started THEN
          v_blockers := array_append(v_blockers, 'invalid_legacy_batch_timestamps');
        ELSE
          IF v_state -> 'batchDurationMs' IS DISTINCT FROM 'null'::jsonb THEN
            IF jsonb_typeof(v_state -> 'batchDurationMs') IS DISTINCT FROM 'number'
               OR COALESCE((v_state ->> 'batchDurationMs') ~ '^(0|[1-9][0-9]*)$', false) IS DISTINCT FROM TRUE THEN
              v_blockers := array_append(v_blockers, 'invalid_legacy_batch_duration');
            ELSIF (v_state ->> 'batchDurationMs')::numeric <= 0 THEN
              v_blockers := array_append(v_blockers, 'invalid_legacy_batch_duration');
            ELSE
              v_duration := (v_state ->> 'batchDurationMs')::numeric;
            END IF;
          ELSE
            v_duration := v_ends - v_started;
          END IF;
          IF v_duration IS NULL OR v_duration > 9223372036854775807 THEN
            v_blockers := array_append(v_blockers, 'invalid_legacy_batch_duration');
          ELSE
            v_blockers := array_append(v_blockers, 'legacy_batch_identity_missing_requires_review');
          END IF;
        END IF;
      END IF;
    ELSE
      IF v_state -> 'batchDurationMs' IS DISTINCT FROM 'null'::jsonb THEN
        v_blockers := array_append(v_blockers, 'legacy_batch_state_inconsistent_requires_review');
      ELSE
        v_state := jsonb_set(v_state, '{activeBatches}', '[]'::jsonb, true);
      END IF;
    END IF;
  ELSIF jsonb_typeof(v_state -> 'activeBatches') = 'array' THEN
    FOR v_batch IN SELECT value FROM jsonb_array_elements(v_state -> 'activeBatches') AS item(value) LOOP
      IF jsonb_typeof(v_batch) IS DISTINCT FROM 'object' THEN
        v_blockers := array_append(v_blockers, 'invalid_active_batch');
        EXIT;
      END IF;
      IF NOT (v_batch ? 'durationMs') THEN
        IF jsonb_typeof(v_batch -> 'startedAt') IS DISTINCT FROM 'number'
           OR jsonb_typeof(v_batch -> 'endsAt') IS DISTINCT FROM 'number'
           OR (v_batch ->> 'startedAt') !~ '^(0|[1-9][0-9]*)$'
           OR (v_batch ->> 'endsAt') !~ '^(0|[1-9][0-9]*)$' THEN
          v_blockers := array_append(v_blockers, 'invalid_active_batch_duration');
          EXIT;
        END IF;
        v_started := (v_batch ->> 'startedAt')::numeric;
        v_ends := (v_batch ->> 'endsAt')::numeric;
        v_duration := v_ends - v_started;
        IF v_duration <= 0 OR v_duration > 9223372036854775807 THEN
          v_blockers := array_append(v_blockers, 'invalid_active_batch_duration');
          EXIT;
        END IF;
        v_batch := jsonb_set(v_batch, '{durationMs}', to_jsonb(v_duration), true);
      END IF;
      v_batches := v_batches || jsonb_build_array(v_batch);
    END LOOP;
    IF NOT ('invalid_active_batch' = ANY(v_blockers)
            OR 'invalid_active_batch_duration' = ANY(v_blockers)) THEN
      v_state := jsonb_set(v_state, '{activeBatches}', v_batches, true);
    END IF;
  ELSE
    v_blockers := array_append(v_blockers, 'invalid_active_batches_type');
  END IF;

  -- The legacy second-pot level was converted to owned/equipped decoration by
  -- normalizeState(). Mirror that exact compatibility rule without dropping its
  -- old level field or any other item IDs.
  IF jsonb_typeof(v_state -> 'upgradeLevels') = 'object'
     AND v_state -> 'upgradeLevels' ? 'second-pot' THEN
    v_legacy_level := v_state #> '{upgradeLevels,second-pot}';
    IF jsonb_typeof(v_legacy_level) IS DISTINCT FROM 'number'
       OR v_legacy_level #>> '{}' !~ '^(0|[1-9][0-9]*)$' THEN
      v_blockers := array_append(v_blockers, 'invalid_legacy_second_pot_level');
    ELSIF (v_legacy_level #>> '{}')::numeric > 0 THEN
      v_owned := COALESCE(v_state -> 'upgrades', '[]'::jsonb);
      v_equipped := COALESCE(v_state -> 'equipped', '[]'::jsonb);
      IF NOT (v_owned @> '["second-pot"]'::jsonb) THEN
        v_state := jsonb_set(v_state, '{upgrades}', v_owned || '["second-pot"]'::jsonb, true);
        v_state := jsonb_set(v_state, '{equipped}', v_equipped || '["second-pot"]'::jsonb, true);
      END IF;
    END IF;
  END IF;

  IF jsonb_typeof(v_state -> 'activeBatches') = 'array' THEN
    FOR v_batch IN SELECT value FROM jsonb_array_elements(v_state -> 'activeBatches') AS item(value) LOOP
      IF jsonb_typeof(v_batch) = 'object'
         AND jsonb_typeof(v_batch -> 'pot') = 'number'
         AND v_batch ->> 'pot' = '2'
         AND NOT COALESCE(v_state -> 'upgrades' @> '["second-pot"]'::jsonb, false) THEN
        v_blockers := array_append(v_blockers, 'batch_uses_unowned_pot_requires_review');
      END IF;
    END LOOP;
  END IF;

  -- A batch started today is evidence of current-day activity even if the
  -- persisted daily aliases still point at yesterday; do not erase its task
  -- progress by rolling the daily object forward automatically.
  v_today_start_ms := extract(epoch FROM (p_today::timestamp AT TIME ZONE 'UTC')) * 1000;
  IF jsonb_typeof(v_state -> 'activeBatches') = 'array' THEN
    FOR v_batch IN SELECT value FROM jsonb_array_elements(v_state -> 'activeBatches') AS item(value) LOOP
      IF jsonb_typeof(v_batch) = 'object'
         AND jsonb_typeof(v_batch -> 'startedAt') = 'number' THEN
        v_text := v_batch ->> 'startedAt';
        IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false) AND length(v_text) <= 19 THEN
          IF v_text::numeric >= v_today_start_ms THEN
            v_current_day_batch := true;
          END IF;
        END IF;
      END IF;
    END LOOP;
  END IF;

  -- Resolve missing date aliases only when the other is a valid UTC date.
  IF v_state -> 'dailyDate' IS DISTINCT FROM 'null'::jsonb
     AND (jsonb_typeof(v_state -> 'dailyDate') IS DISTINCT FROM 'string'
          OR NOT public._pelmeni_valid_utc_day(v_state ->> 'dailyDate')) THEN
    v_blockers := array_append(v_blockers, 'invalid_daily_date');
  END IF;
  IF v_state -> 'taskDay' IS DISTINCT FROM 'null'::jsonb
     AND (jsonb_typeof(v_state -> 'taskDay') IS DISTINCT FROM 'string'
          OR NOT public._pelmeni_valid_utc_day(v_state ->> 'taskDay')) THEN
    v_blockers := array_append(v_blockers, 'invalid_task_day');
  END IF;
  IF v_state -> 'dailyDate' = 'null'::jsonb
     AND public._pelmeni_valid_utc_day(v_state ->> 'taskDay') THEN
    v_state := jsonb_set(v_state, '{dailyDate}', v_state -> 'taskDay', true);
  ELSIF v_state -> 'taskDay' = 'null'::jsonb
     AND public._pelmeni_valid_utc_day(v_state ->> 'dailyDate') THEN
    v_state := jsonb_set(v_state, '{taskDay}', v_state -> 'dailyDate', true);
  END IF;
  IF NOT public._pelmeni_valid_utc_day(v_state ->> 'dailyDate')
     OR NOT public._pelmeni_valid_utc_day(v_state ->> 'taskDay') THEN
    v_blockers := array_append(v_blockers, 'daily_date_unknown');
  ELSE
    v_daily_day := (v_state ->> 'dailyDate')::date;
    v_task_day := (v_state ->> 'taskDay')::date;
    IF v_daily_day > p_today OR v_task_day > p_today THEN
      v_blockers := array_append(v_blockers, 'daily_date_in_future');
    ELSIF (v_daily_day = p_today) <> (v_task_day = p_today) THEN
      v_blockers := array_append(v_blockers, 'conflicting_current_daily_dates');
    ELSIF v_state ->> 'taskClaimedOn' = p_today::text
       AND (v_daily_day < p_today OR v_task_day < p_today) THEN
      -- A current-day cook claim marker conflicts with expired daily aliases.
      -- Do not roll it away: keep the source profile for manual review.
      v_blockers := array_append(v_blockers, 'current_cook_claim_conflicts_with_expired_daily_state');
    ELSIF v_daily_day < p_today AND v_task_day < p_today
       AND (v_last_batch_date = p_today OR v_current_day_batch) THEN
      v_blockers := array_append(v_blockers, 'current_day_activity_conflicts_with_expired_daily_state');
    ELSIF v_daily_day < p_today AND v_task_day < p_today THEN
      -- Only expired daily state is discarded. Permanent fields, rewards, and
      -- batch times are left untouched. A past/unknown variant is irrelevant.
      v_state := jsonb_set(v_state, '{dailyDate}', to_jsonb(p_today::text), true);
      v_state := jsonb_set(v_state, '{taskDay}', to_jsonb(p_today::text), true);
      v_state := jsonb_set(v_state, '{dailyTaskVariant}',
        to_jsonb(public._pelmeni_daily_task_variant(p_today)), true);
      v_state := jsonb_set(v_state, '{dailyTasks}', jsonb_build_object(
        'login',jsonb_build_object('progress',0,'claimed',false),
        'cook',jsonb_build_object('progress',0,'claimed',false),
        'upgrade',jsonb_build_object('progress',0,'claimed',false),
        'collect',jsonb_build_object('progress',0,'claimed',false),
        'collect-dumplings',jsonb_build_object('progress',0,'claimed',false),
        'collect-two',jsonb_build_object('progress',0,'claimed',false),
        'two-pots',jsonb_build_object('progress',0,'claimed',false)), true);
      v_state := jsonb_set(v_state, '{taskBatches}', '0'::jsonb, true);
      v_state := jsonb_set(v_state, '{taskClaimedOn}', 'null'::jsonb, true);
      v_state := jsonb_set(v_state, '{taskPotsUsed}', '[]'::jsonb, true);
      -- Keep the source exception through activation when loginRewardDate is
      -- already today. economy_load_visit() must see it before its own visit
      -- rollover decides whether the legacy automatic reward was paid.
      IF v_state ->> 'loginRewardDate' IS DISTINCT FROM p_today::text THEN
        v_state := jsonb_set(v_state, '{firstLoginNoReward}', 'false'::jsonb, true);
      END IF;
    ELSE
      v_expected_variant := public._pelmeni_daily_task_variant(p_today);
      v_variant := v_state ->> 'dailyTaskVariant';
      IF v_variant IS DISTINCT FROM v_expected_variant THEN
        v_blockers := array_append(v_blockers, 'daily_task_variant_ambiguous_for_today');
      END IF;
      IF v_state ? 'dailyTasks' AND jsonb_typeof(v_state -> 'dailyTasks') IS DISTINCT FROM 'object' THEN
        v_blockers := array_append(v_blockers, 'invalid_daily_tasks_type');
      ELSE
        v_tasks := COALESCE(v_state -> 'dailyTasks', '{}'::jsonb);
        IF NOT (v_tasks ? 'cook')
           AND v_state ->> 'taskClaimedOn' IS DISTINCT FROM p_today::text THEN
          v_text := v_state ->> 'taskBatches';
          IF jsonb_typeof(v_state -> 'taskBatches') = 'number'
             AND COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false)
             AND length(v_text) <= 19 THEN
            IF v_text::numeric > 0 THEN
              v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:cook_progress_missing');
            END IF;
          END IF;
          IF jsonb_typeof(v_state -> 'activeBatches') = 'array' THEN
            IF jsonb_array_length(v_state -> 'activeBatches') > 0 THEN
              v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:cook_progress_missing');
            END IF;
          END IF;
        END IF;
        IF NOT (v_tasks ? 'upgrade') THEN
          IF jsonb_typeof(v_state -> 'upgrades') = 'array' THEN
            IF jsonb_array_length(v_state -> 'upgrades') > 0 THEN
              v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:upgrade_progress_missing');
            END IF;
          END IF;
          IF COALESCE((v_state #>> '{upgradeLevels,good-stove}') ~ '^[1-9]', false)
             OR COALESCE((v_state #>> '{upgradeLevels,large-pot}') ~ '^[1-9]', false)
             OR COALESCE((v_state #>> '{upgradeLevels,grandma-recipe}') ~ '^[1-9]', false)
             OR COALESCE((v_state #>> '{upgradeLevels,second-pot}') ~ '^[1-9]', false) THEN
            v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:upgrade_progress_missing');
          END IF;
        END IF;
        IF v_last_batch_date = p_today THEN
          IF NOT (v_tasks ? 'collect') OR NOT (v_tasks ? 'collect-dumplings')
             OR NOT (v_tasks ? 'collect-two') THEN
            v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:collection_progress_missing');
          ELSE
            v_text := v_tasks #>> '{collect,progress}';
            IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false) AND length(v_text) <= 19 THEN
              IF v_text::numeric < 1 THEN
                v_blockers := array_append(v_blockers, 'daily_task_state_conflict:collect_progress');
              END IF;
            ELSE
              v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:collect_progress');
            END IF;

            v_text := v_tasks #>> '{collect-two,progress}';
            IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false) AND length(v_text) <= 19 THEN
              IF v_text::numeric < 1 THEN
                v_blockers := array_append(v_blockers, 'daily_task_state_conflict:collect_two_progress');
              END IF;
            ELSE
              v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:collect_two_progress');
            END IF;

            v_text := v_tasks #>> '{collect-dumplings,progress}';
            v_id := v_state #>> '{lastBatchReward,dumplings}';
            IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false) AND length(v_text) <= 19
               AND COALESCE(v_id ~ '^(0|[1-9][0-9]*)$', false) AND length(v_id) <= 19 THEN
              IF v_text::numeric < v_id::numeric THEN
                v_blockers := array_append(v_blockers, 'daily_task_state_conflict:collect_dumplings_progress');
              END IF;
            ELSE
              v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:collect_dumplings_progress');
            END IF;
          END IF;
        END IF;
        IF COALESCE(v_state -> 'taskPotsUsed' @> '[1,2]'::jsonb, false) THEN
          IF NOT (v_tasks ? 'two-pots') THEN
            v_blockers := array_append(v_blockers, 'daily_task_state_ambiguous:two_pots_claim_history_missing');
          ELSE
            v_text := v_tasks #>> '{two-pots,progress}';
            IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false) THEN
              IF v_text::numeric = 0 THEN
                v_blockers := array_append(v_blockers, 'daily_task_state_conflict:two_pots_progress');
              END IF;
            END IF;
          END IF;
        END IF;
        FOR v_key IN SELECT key FROM jsonb_object_keys(v_tasks) AS tasks(key) LOOP
          IF NOT (v_key = ANY(v_task_ids)) THEN
            v_blockers := array_append(v_blockers, 'unknown_daily_task_id:' || v_key);
          END IF;
        END LOOP;
        FOREACH v_id IN ARRAY v_task_ids LOOP
          IF NOT (v_tasks ? v_id) THEN
            v_tasks := jsonb_set(v_tasks, ARRAY[v_id],
              jsonb_build_object('progress',0,'claimed',false), true);
          END IF;
        END LOOP;
        IF v_state ->> 'taskClaimedOn' = p_today::text THEN
          v_task := COALESCE(v_tasks -> 'cook', jsonb_build_object('progress',0,'claimed',false));
          IF jsonb_typeof(v_task) = 'object' THEN
            v_task := jsonb_set(v_task, '{claimed}', 'true'::jsonb, true);
            v_tasks := jsonb_set(v_tasks, '{cook}', v_task, true);
          END IF;
        END IF;
        v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
      END IF;
    END IF;
  END IF;

  IF NOT (v_state ? 'schemaVersion') AND cardinality(v_blockers) = 0 THEN
    v_state := jsonb_set(v_state, '{schemaVersion}', '6'::jsonb, true);
  END IF;
  IF cardinality(v_blockers) = 0
     AND public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE THEN
    v_blockers := array_append(v_blockers, 'normalized_state_shape_invalid');
  END IF;

  -- An elapsed or internally inconsistent legacy timer cannot prove when the
  -- batch began. Keep it byte-for-byte in the candidate, but require review so
  -- activation cannot make it immediately collectible.
  v_today_ms := floor(extract(epoch FROM clock_timestamp()) * 1000)::numeric;
  IF jsonb_typeof(v_state -> 'activeBatches') = 'array' THEN
    FOR v_batch IN SELECT value FROM jsonb_array_elements(v_state -> 'activeBatches') AS item(value) LOOP
      IF jsonb_typeof(v_batch -> 'endsAt') = 'number' THEN
        v_text := v_batch ->> 'endsAt';
        IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false) THEN
          IF v_text::numeric <= v_today_ms THEN
            v_blockers := array_append(v_blockers, 'expired_active_batch_requires_review');
          END IF;
        END IF;
      END IF;
      IF jsonb_typeof(v_batch -> 'startedAt') = 'number'
         AND jsonb_typeof(v_batch -> 'endsAt') = 'number'
         AND jsonb_typeof(v_batch -> 'durationMs') = 'number' THEN
        v_text := v_batch ->> 'startedAt';
        v_id := v_batch ->> 'endsAt';
        v_variant := v_batch ->> 'durationMs';
        IF COALESCE(v_text ~ '^(0|[1-9][0-9]*)$', false)
           AND COALESCE(v_id ~ '^(0|[1-9][0-9]*)$', false)
           AND COALESCE(v_variant ~ '^(0|[1-9][0-9]*)$', false) THEN
          IF v_id::numeric - v_text::numeric <> v_variant::numeric THEN
            v_blockers := array_append(v_blockers, 'active_batch_duration_mismatch_requires_review');
          END IF;
        END IF;
      END IF;
    END LOOP;
  END IF;

  IF cardinality(v_blockers) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reasons', to_jsonb(v_blockers), 'candidateState', v_state);
  END IF;
  RETURN jsonb_build_object('ok', true, 'reasons', '[]'::jsonb, 'candidateState', v_state);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'reasons', jsonb_build_array('legacy_state_conversion_error'));
END
$fn$;

CREATE OR REPLACE FUNCTION public._pelmeni_finish_request(
  p_telegram_id bigint,
  p_request_id uuid,
  p_action text,
  p_args jsonb,
  p_revision bigint,
  p_state jsonb,
  p_result jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  -- md5 is a compact fingerprint, not an authorization primitive. Exact JSONB
  -- parameters are also stored and compared, so a digest collision cannot
  -- make a different request replay as the original operation.
  v_hash text := md5(jsonb_build_object('action', p_action, 'params', p_args)::text);
BEGIN
  INSERT INTO public.player_economy_requests
    (telegram_id, request_id, action, request_hash, request_args, outcome)
  VALUES
    (p_telegram_id, p_request_id, p_action, v_hash, p_args, p_result);

  RETURN jsonb_build_object(
    'ok', (p_result ->> 'status') = 'applied',
    'operation', jsonb_build_object('requestId', p_request_id, 'status', p_result ->> 'status', 'result', p_result),
    'state', p_state,
    'revision', p_revision,
    'protocolVersion', 1,
    'gameStateSchemaVersion', p_state -> 'schemaVersion'
  );
END
$fn$;

-- One transaction boundary for every command. All wrapper RPCs delegate here;
-- the player_state row lock serializes distinct commands for one profile.
CREATE OR REPLACE FUNCTION public._pelmeni_apply_economy_command(
  p_telegram_id bigint,
  p_request_id uuid,
  p_action text,
  p_args jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_state jsonb;
  v_revision bigint;
  v_server_mode boolean;
  v_control_schema_version integer;
  v_old_action text;
  v_old_hash text;
  v_old_args jsonb;
  v_old_outcome jsonb;
  v_hash text;
  v_result jsonb;
  v_levels jsonb;
  v_equipped jsonb;
  v_owned jsonb;
  v_batches jsonb;
  v_batch jsonb;
  v_clean_batches jsonb;
  v_tasks jsonb;
  v_task jsonb;
  v_task_policy jsonb;
  v_task_id text;
  v_id text;
  v_base bigint;
  v_cost bigint;
  v_level integer;
  v_pot integer;
  v_duration_ms bigint;
  v_now_ms bigint;
  v_end_ms bigint;
  v_reward bigint;
  v_bonus bigint;
  v_threshold bigint;
  v_task_progress bigint;
  v_claims jsonb;
  v_pot_collections jsonb;
  v_primary jsonb;
  v_original_equipped jsonb;
  v_today date;
  v_expected_variant text;
  v_changed boolean := false;
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Economy RPC is restricted to the trusted server role' USING ERRCODE = '42501';
  END IF;
  IF p_telegram_id IS NULL OR p_telegram_id <= 0 OR p_request_id IS NULL
     OR p_action IS NULL OR p_args IS NULL OR jsonb_typeof(p_args) <> 'object' THEN
    RAISE EXCEPTION 'Invalid economy RPC arguments' USING ERRCODE = '22023';
  END IF;

  -- Lock the existing profile; do not create profiles or import client snapshots.
  SELECT game_state INTO v_state
  FROM public.player_state
  WHERE telegram_id = p_telegram_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found');
  END IF;
  IF v_state IS NULL OR jsonb_typeof(v_state) <> 'object' THEN
    RAISE EXCEPTION 'Canonical profile game_state is not a JSON object' USING ERRCODE = '22023';
  END IF;

  SELECT revision, server_mode, state_schema_version
    INTO v_revision, v_server_mode, v_control_schema_version
  FROM public.player_economy_control
  WHERE telegram_id = p_telegram_id
  FOR UPDATE;
  IF NOT FOUND OR NOT v_server_mode THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_enabled');
  END IF;

  IF v_control_schema_version <> 6
     OR jsonb_typeof(v_state -> 'schemaVersion') IS DISTINCT FROM 'number'
     OR (v_state ->> 'schemaVersion') IS DISTINCT FROM v_control_schema_version::text THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_game_state_schema',
      'expectedGameStateSchemaVersion', 6, 'protocolVersion', 1);
  END IF;
  IF NOT public._pelmeni_state_shape_is_valid(v_state) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_game_state_shape',
      'protocolVersion', 1, 'gameStateSchemaVersion', 6);
  END IF;

  -- Evaluate the day only after both profile locks. If the day changed while
  -- this call waited, stale daily state must be refreshed by load/visit before
  -- any command can add progress to yesterday's tasks. Check receipts first so
  -- a successful retry remains replayable after midnight.
  v_today := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_expected_variant := public._pelmeni_daily_task_variant(v_today);

  -- The full JSONB comparison below is authoritative; md5 is only a compact
  -- indexable fingerprint and is not relied on for authorization.
  v_hash := md5(jsonb_build_object('action', p_action, 'params', p_args)::text);
  SELECT action, request_hash, request_args, outcome
    INTO v_old_action, v_old_hash, v_old_args, v_old_outcome
  FROM public.player_economy_requests
  WHERE telegram_id = p_telegram_id AND request_id = p_request_id;
  IF FOUND THEN
    IF v_old_action <> p_action OR v_old_hash <> v_hash OR v_old_args <> p_args THEN
      RETURN jsonb_build_object('ok', false, 'error', 'idempotency_conflict', 'state', v_state, 'revision', v_revision,
        'protocolVersion', 1, 'gameStateSchemaVersion', v_state -> 'schemaVersion');
    END IF;
    RETURN jsonb_build_object(
      'ok', (v_old_outcome ->> 'status') = 'applied',
      'operation', jsonb_build_object('requestId', p_request_id, 'status', v_old_outcome ->> 'status', 'result', v_old_outcome),
      'state', v_state, 'revision', v_revision,
      'protocolVersion', 1, 'gameStateSchemaVersion', v_state -> 'schemaVersion'
    );
  END IF;

  IF (v_state ->> 'dailyDate') IS DISTINCT FROM v_today::text
     OR (v_state ->> 'taskDay') IS DISTINCT FROM v_today::text THEN
    RETURN jsonb_build_object('ok', false, 'error', 'daily_state_stale',
      'protocolVersion', 1, 'gameStateSchemaVersion', 6);
  END IF;
  IF (v_state ->> 'dailyTaskVariant') IS DISTINCT FROM v_expected_variant THEN
    RETURN jsonb_build_object('ok', false, 'error', 'daily_task_variant_stale',
      'protocolVersion', 1, 'gameStateSchemaVersion', 6);
  END IF;

  -- Refresh unlocked status from server-owned state before evaluating an
  -- explicit achievement claim. This helper never changes balances.
  v_state := public._pelmeni_refresh_achievements(v_state);

  v_levels := COALESCE(v_state -> 'upgradeLevels', '{}'::jsonb);
  v_equipped := COALESCE(v_state -> 'equipped', '[]'::jsonb);
  v_owned := COALESCE(v_state -> 'upgrades', '[]'::jsonb);
  v_batches := COALESCE(v_state -> 'activeBatches', '[]'::jsonb);
  v_tasks := COALESCE(v_state -> 'dailyTasks', '{}'::jsonb);

  IF p_action = 'start_batch' THEN
    IF p_args ->> 'pot' IS NULL OR jsonb_typeof(p_args -> 'pot') <> 'number' OR (p_args ->> 'pot') !~ '^[12]$' THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'invalid_pot');
    ELSE
      v_pot := (p_args ->> 'pot')::integer;
      IF v_pot = 2 AND NOT (v_equipped ? 'second-pot') THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'second_pot_not_equipped');
      ELSIF EXISTS (SELECT 1 FROM jsonb_array_elements(v_batches) AS x(value) WHERE (x.value ->> 'pot')::integer = v_pot) THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'pot_already_cooking');
      ELSE
        v_level := LEAST(10, GREATEST(0, COALESCE((v_levels ->> 'good-stove')::integer, 0)));
        v_base := GREATEST(21600000, round(43200000 * (1 - LEAST(0.5, v_level * 0.05)))::bigint);
        v_duration_ms := v_base;
        v_now_ms := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
        v_end_ms := v_now_ms + v_duration_ms;
        v_batch := jsonb_build_object('id', p_request_id::text, 'pot', v_pot,
          'startedAt', v_now_ms, 'endsAt', v_end_ms, 'durationMs', v_duration_ms);
        SELECT COALESCE(jsonb_agg(x.value ORDER BY (x.value ->> 'pot')::integer), '[]'::jsonb)
          INTO v_batches
        FROM jsonb_array_elements(v_batches || jsonb_build_array(v_batch)) AS x(value);
        v_state := jsonb_set(v_state, '{activeBatches}', v_batches, true);
        v_primary := NULL;
        SELECT x.value INTO v_primary FROM jsonb_array_elements(v_batches) AS x(value)
          ORDER BY CASE WHEN (x.value ->> 'pot')::integer = 1 THEN 0 ELSE 1 END LIMIT 1;
        v_state := jsonb_set(v_state, '{startedAt}', COALESCE(v_primary -> 'startedAt', 'null'::jsonb), true);
        v_state := jsonb_set(v_state, '{endsAt}', COALESCE(v_primary -> 'endsAt', 'null'::jsonb), true);
        v_state := jsonb_set(v_state, '{batchDurationMs}', COALESCE(v_primary -> 'durationMs', 'null'::jsonb), true);
        v_tasks := public._pelmeni_task_progress(v_tasks, 'cook', 1);
        v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
        IF v_equipped ? 'second-pot' THEN
          v_state := jsonb_set(v_state, '{taskPotsUsed}',
            (SELECT COALESCE(jsonb_agg(to_jsonb(pot) ORDER BY pot), '[]'::jsonb)
             FROM (SELECT DISTINCT value::integer AS pot
                   FROM jsonb_array_elements_text(COALESCE(v_state -> 'taskPotsUsed', '[]'::jsonb))
                   UNION SELECT v_pot) pots), true);
          IF (v_state -> 'taskPotsUsed') @> '[1]'::jsonb AND (v_state -> 'taskPotsUsed') @> '[2]'::jsonb THEN
            v_tasks := public._pelmeni_task_progress(v_tasks, 'two-pots', 1);
            v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
          END IF;
        END IF;
        v_result := jsonb_build_object('status', 'applied', 'batchId', p_request_id, 'pot', v_pot,
          'startedAt', v_now_ms, 'endsAt', v_end_ms, 'durationMs', v_duration_ms);
        v_changed := true;
      END IF;
    END IF;

  ELSIF p_action = 'collect_batch' THEN
    v_id := p_args ->> 'batchId';
    SELECT x.value INTO v_batch FROM jsonb_array_elements(v_batches) AS x(value) WHERE x.value ->> 'id' = v_id LIMIT 1;
    IF v_id IS NULL OR v_batch IS NULL THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'batch_not_found');
    ELSE
      v_now_ms := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
      IF v_now_ms < (v_batch ->> 'endsAt')::bigint THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'batch_not_ready');
      ELSE
        v_pot := (v_batch ->> 'pot')::integer;
        v_base := 10 + floor(random() * 6)::bigint;
        v_level := LEAST(10, GREATEST(0, COALESCE((v_levels ->> 'grandma-recipe')::integer, 0)));
        v_bonus := CASE WHEN v_equipped ? 'herb-pot' THEN 2 ELSE 0 END
                 + CASE WHEN v_equipped ? 'wooden-spoon' THEN 3 ELSE 0 END;
        v_reward := round(v_base * (1 + v_level * 0.05))::bigint
                  + LEAST(10, GREATEST(0, COALESCE((v_levels ->> 'large-pot')::integer, 0))) + v_bonus;
        SELECT COALESCE(jsonb_agg(x.value ORDER BY (x.value ->> 'pot')::integer), '[]'::jsonb)
          INTO v_clean_batches
        FROM jsonb_array_elements(v_batches) AS x(value) WHERE x.value ->> 'id' <> v_id;
        v_state := public._pelmeni_add_dumplings(v_state, v_reward, true);
        v_state := jsonb_set(v_state, '{activeBatches}', v_clean_batches, true);
        v_state := jsonb_set(v_state, '{batches}', to_jsonb(COALESCE((v_state ->> 'batches')::bigint, 0) + 1), true);
        v_state := jsonb_set(v_state, '{taskBatches}', to_jsonb(COALESCE((v_state ->> 'taskBatches')::bigint, 0) + 1), true);
        v_tasks := public._pelmeni_task_progress(v_tasks, 'collect', 1);
        v_tasks := public._pelmeni_task_progress(v_tasks, 'collect-dumplings', v_reward);
        v_tasks := public._pelmeni_task_progress(v_tasks, 'collect-two', 1);
        v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
        v_pot_collections := COALESCE(v_state -> 'potCollections', '{"1":0,"2":0}'::jsonb);
        v_state := jsonb_set(v_state, ARRAY['potCollections', v_pot::text],
          to_jsonb(LEAST(1000000, COALESCE((v_pot_collections ->> v_pot::text)::bigint, 0) + 1)), true);
        v_state := jsonb_set(v_state, '{lastBatchReward}', jsonb_build_object('dumplings', v_reward), true);
        v_state := jsonb_set(v_state, '{lastBatchAt}', to_jsonb(clock_timestamp()), true);
        -- The legacy single-batch aliases always describe the remaining
        -- primary batch (pot 1 first), never the batch just collected.
        v_primary := NULL;
        SELECT x.value INTO v_primary FROM jsonb_array_elements(v_clean_batches) AS x(value)
          ORDER BY CASE WHEN (x.value ->> 'pot')::integer = 1 THEN 0 ELSE 1 END LIMIT 1;
        v_state := jsonb_set(v_state, '{startedAt}', COALESCE(v_primary -> 'startedAt', 'null'::jsonb), true);
        v_state := jsonb_set(v_state, '{endsAt}', COALESCE(v_primary -> 'endsAt', 'null'::jsonb), true);
        v_state := jsonb_set(v_state, '{batchDurationMs}', COALESCE(v_primary -> 'durationMs', 'null'::jsonb), true);
        v_result := jsonb_build_object('status', 'applied', 'batchId', v_id, 'pot', v_pot, 'dumplings', v_reward);
        v_changed := true;
      END IF;
    END IF;

  ELSIF p_action = 'purchase_upgrade' THEN
    v_id := p_args ->> 'upgradeId';
    v_base := CASE v_id WHEN 'good-stove' THEN 15 WHEN 'large-pot' THEN 75 WHEN 'grandma-recipe' THEN 100 ELSE NULL END;
    IF v_base IS NULL THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'unknown_upgrade');
    ELSIF jsonb_typeof(v_levels) <> 'object' THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'invalid_upgrade_level');
    ELSE
      v_level := NULL;
      IF v_levels ? v_id THEN
        IF jsonb_typeof(v_levels -> v_id) = 'number' THEN
          IF (v_levels ->> v_id) ~ '^(0|[1-9][0-9]*)$' THEN
            IF (v_levels ->> v_id)::numeric <= 10 THEN
              v_level := (v_levels ->> v_id)::integer;
            END IF;
          END IF;
        END IF;
      ELSE
        v_level := 0;
      END IF;
      IF v_level IS NULL THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'invalid_upgrade_level');
      ELSE
        IF v_level >= 10 THEN
          v_result := jsonb_build_object('status', 'rejected', 'error', 'upgrade_max_level');
        ELSE
          v_cost := CASE v_id
            WHEN 'good-stove' THEN (ARRAY[15,25,40,60,90,130,180,250,350,500]::bigint[])[v_level + 1]
            WHEN 'large-pot' THEN (ARRAY[75,125,200,300,450,650,900,1200,1550,2000]::bigint[])[v_level + 1]
            WHEN 'grandma-recipe' THEN (ARRAY[100,150,250,400,600,900,1250,1750,2300,3000]::bigint[])[v_level + 1]
          END;
          IF COALESCE((v_state ->> 'balance')::bigint, 0) < v_cost THEN
            v_result := jsonb_build_object('status', 'rejected', 'error', 'insufficient_balance', 'cost', v_cost);
          ELSE
            v_state := jsonb_set(v_state, '{balance}', to_jsonb((v_state ->> 'balance')::bigint - v_cost), true);
            v_state := jsonb_set(v_state, ARRAY['upgradeLevels', v_id], to_jsonb(v_level + 1), true);
            v_tasks := public._pelmeni_task_progress(v_tasks, 'upgrade', 1);
            v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
            v_result := jsonb_build_object('status', 'applied', 'upgradeId', v_id, 'level', v_level + 1, 'cost', v_cost);
            v_changed := true;
          END IF;
        END IF;
      END IF;
    END IF;

  ELSIF p_action = 'purchase_decoration' THEN
    v_id := p_args ->> 'decorationId';
    v_cost := CASE v_id WHEN 'herb-pot' THEN 100 WHEN 'blue-tile' THEN 50 WHEN 'wooden-spoon' THEN 200 WHEN 'second-pot' THEN 1500 ELSE NULL END;
    IF v_cost IS NULL THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'unknown_decoration');
    ELSIF v_owned ? v_id THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'already_owned');
    ELSIF COALESCE((v_state ->> 'balance')::bigint, 0) < v_cost THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'insufficient_balance', 'cost', v_cost);
    ELSE
      v_state := jsonb_set(v_state, '{balance}', to_jsonb((v_state ->> 'balance')::bigint - v_cost), true);
      v_state := jsonb_set(v_state, '{upgrades}', v_owned || jsonb_build_array(v_id), true);
      v_state := jsonb_set(v_state, '{equipped}', v_equipped || jsonb_build_array(v_id), true);
      v_tasks := public._pelmeni_task_progress(v_tasks, 'upgrade', 1);
      v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
      v_result := jsonb_build_object('status', 'applied', 'decorationId', v_id, 'cost', v_cost);
      v_changed := true;
    END IF;

  ELSIF p_action = 'set_decoration_equipped' THEN
    v_id := p_args ->> 'decorationId';
    IF COALESCE(v_id, '') NOT IN ('herb-pot', 'blue-tile', 'wooden-spoon', 'second-pot') THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'unknown_decoration');
    ELSIF p_args -> 'equipped' IS NULL OR jsonb_typeof(p_args -> 'equipped') <> 'boolean' THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'invalid_equipped_value');
    ELSIF NOT (v_owned ? v_id) THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'not_owned');
    ELSE
      v_original_equipped := v_equipped;
      IF (p_args ->> 'equipped')::boolean THEN
        IF NOT (v_equipped ? v_id) THEN v_equipped := v_equipped || jsonb_build_array(v_id); END IF;
      ELSE
        SELECT COALESCE(jsonb_agg(x.value ORDER BY x.ordinality), '[]'::jsonb) INTO v_equipped
        FROM jsonb_array_elements(v_equipped) WITH ORDINALITY AS x(value, ordinality)
        WHERE x.value #>> '{}' <> v_id;
      END IF;
      IF v_equipped IS DISTINCT FROM v_original_equipped THEN
        v_state := jsonb_set(v_state, '{equipped}', v_equipped, true);
        v_changed := true;
      END IF;
      v_result := jsonb_build_object('status', 'applied', 'decorationId', v_id, 'equipped', (p_args ->> 'equipped')::boolean);
    END IF;

  ELSIF p_action = 'claim_streak' THEN
    v_id := v_today::text || ':0:1';
    v_claims := COALESCE(v_state -> 'streakRewardClaims', '[]'::jsonb);
    IF (v_state ->> 'dailyDate') IS DISTINCT FROM v_today::text THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'daily_state_stale');
    ELSIF (v_state ->> 'streakLastVisitDate') IS DISTINCT FROM v_today::text THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'streak_not_visited_today');
    ELSIF v_claims @> jsonb_build_array(v_id) THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'streak_already_claimed');
    ELSE
      v_reward := LEAST(10, floor(COALESCE((v_state ->> 'streakCurrent')::numeric, 1) / 2)::bigint + 1);
      v_state := jsonb_set(v_state, '{streakRewardClaims}', v_claims || jsonb_build_array(v_id), true);
      v_state := jsonb_set(v_state, '{loginRewardDate}', to_jsonb(v_today::text), true);
      v_state := public._pelmeni_add_dumplings(v_state, v_reward, true);
      v_result := jsonb_build_object('status', 'applied', 'dumplings', v_reward, 'claimDate', v_today::text);
      v_changed := true;
    END IF;

  ELSIF p_action = 'claim_achievement' THEN
    v_id := p_args ->> 'achievementId';
    v_reward := CASE v_id
      WHEN 'first-visit' THEN 5 WHEN 'first-start' THEN 5 WHEN 'first-batch' THEN 10 WHEN 'first-upgrade' THEN 10
      WHEN 'dumpling-100' THEN 5 WHEN 'dumpling-500' THEN 10 WHEN 'dumpling-thousand' THEN 20
      WHEN 'dumpling-5000' THEN 50 WHEN 'dumpling-10000' THEN 100
      WHEN 'starts-ten' THEN 5 WHEN 'starts-fifty' THEN 15 WHEN 'five-batches' THEN 5
      WHEN 'ten-batches' THEN 10 WHEN 'twenty-five-batches' THEN 15 WHEN 'fifty-batches' THEN 25
      WHEN 'upgrade-five' THEN 10 WHEN 'upgrade-ten' THEN 20 WHEN 'second-pot' THEN 25
      WHEN 'three-decorations' THEN 15 WHEN 'master-kitchen' THEN 15 WHEN 'both-burners' THEN 15
      WHEN 'streak-three' THEN 10 WHEN 'streak-seven' THEN 20 WHEN 'streak-fourteen' THEN 40
      WHEN 'streak-thirty' THEN 100 ELSE NULL END;
    v_claims := COALESCE(v_state -> 'achievementClaims', '[]'::jsonb);
    IF v_reward IS NULL THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'unknown_achievement');
    ELSIF NOT (COALESCE(v_state -> 'achievements', '[]'::jsonb) @> jsonb_build_array(v_id)) THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'achievement_not_unlocked');
    ELSIF v_claims @> jsonb_build_array(v_id) THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'achievement_already_claimed');
    ELSE
      v_state := jsonb_set(v_state, '{achievementClaims}', v_claims || jsonb_build_array(v_id), true);
      -- Matches app.js claimAchievement(): balance and score increase, while
      -- lifetimeDumplings does not count achievement payouts.
      v_state := public._pelmeni_add_dumplings(v_state, v_reward, false);
      v_result := jsonb_build_object('status', 'applied', 'achievementId', v_id, 'dumplings', v_reward);
      v_changed := true;
    END IF;

  ELSIF p_action = 'claim_task' THEN
    v_task_id := p_args ->> 'taskId';
    IF COALESCE(v_task_id, '') NOT IN ('cook', 'collect', 'collect-dumplings', 'upgrade', 'two-pots') THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'unknown_task');
    ELSIF (v_state ->> 'taskDay')::date IS DISTINCT FROM v_today THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'daily_state_stale');
    ELSE
      v_task := COALESCE(v_tasks -> v_task_id, '{"progress":0,"claimed":false}'::jsonb);
      v_task_policy := public._pelmeni_daily_task_policy(v_state, v_task_id);
      v_reward := (v_task_policy ->> 'reward')::bigint;
      v_threshold := COALESCE((v_task_policy ->> 'goal')::bigint, 9223372036854775807);
      v_task_progress := COALESCE((v_task_policy ->> 'progress')::bigint, 0);
      IF v_task_policy IS NULL THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'invalid_daily_task_state');
      ELSIF v_task_policy ->> 'status' = 'task_already_claimed' THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'task_already_claimed');
      ELSIF v_task_policy ->> 'status' = 'task_not_complete' THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'task_not_complete',
          'progress', v_task_progress, 'goal', v_threshold);
      ELSE
        v_tasks := jsonb_set(v_tasks, ARRAY[v_task_id],
          jsonb_build_object('progress', COALESCE((v_task ->> 'progress')::bigint, 0), 'claimed', true), true);
        v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);
        v_state := public._pelmeni_add_dumplings(v_state, v_reward, true);
        IF v_task_id = 'cook' THEN
          v_state := jsonb_set(v_state, '{taskClaimedOn}', to_jsonb(v_today::text), true);
          v_state := jsonb_set(v_state, '{taskBalanceRewardVersion}', '1'::jsonb, true);
        END IF;
        v_result := jsonb_build_object('status', 'applied', 'taskId', v_task_id, 'dumplings', v_reward);
        v_changed := true;
      END IF;
    END IF;

  ELSIF p_action = 'claim_level' THEN
    IF p_args ->> 'level' IS NULL OR jsonb_typeof(p_args -> 'level') <> 'number' OR (p_args ->> 'level') !~ '^([2-9]|10)$' THEN
      v_result := jsonb_build_object('status', 'rejected', 'error', 'invalid_level');
    ELSE
      v_level := (p_args ->> 'level')::integer;
      v_threshold := (ARRAY[0,500,1000,1500,2000,3000,4000,5500,7500,10000])[v_level];
      v_claims := COALESCE(v_state -> 'levelClaims', '[]'::jsonb);
      IF v_claims @> jsonb_build_array(v_level) THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'level_already_claimed');
      ELSIF COALESCE((v_state ->> 'score')::bigint, 0) < v_threshold THEN
        v_result := jsonb_build_object('status', 'rejected', 'error', 'level_threshold_not_met');
      ELSE
        v_reward := 10 + GREATEST(0, v_level - 2) * 5;
        v_state := jsonb_set(v_state, '{levelClaims}', v_claims || jsonb_build_array(v_level), true);
        v_state := public._pelmeni_add_dumplings(v_state, v_reward, false);
        v_result := jsonb_build_object('status', 'applied', 'level', v_level, 'dumplings', v_reward);
        v_changed := true;
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown economy operation: %', p_action USING ERRCODE = '22023';
  END IF;

  IF v_changed THEN
    v_state := public._pelmeni_refresh_achievements(v_state);
    v_revision := v_revision + 1;
    PERFORM pg_catalog.set_config('pelmeni.server_economy_write', 'allowed', true);
    UPDATE public.player_state
       SET game_state = v_state, updated_at = clock_timestamp()
     WHERE telegram_id = p_telegram_id;
    UPDATE public.player_economy_control
       SET revision = v_revision, updated_at = clock_timestamp()
     WHERE telegram_id = p_telegram_id;
  END IF;

  RETURN public._pelmeni_finish_request(p_telegram_id, p_request_id, p_action, p_args, v_revision, v_state, v_result);
END
$fn$;

CREATE OR REPLACE FUNCTION public._pelmeni_is_first_visit(p_state jsonb)
RETURNS boolean
LANGUAGE plpgsql STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_value jsonb;
  v_task jsonb;
  v_key text;
  v_task_id text;
  v_text text;
  v_number numeric;
  v_expected_keys text[] := ARRAY[
    'balance', 'score', 'points', 'pointsRetired', 'batches', 'startedAt', 'endsAt', 'batchDurationMs',
    'activeBatches', 'upgrades', 'equipped', 'upgradeLevels', 'taskDay', 'taskBatches',
    'lifetimeDumplings', 'levelClaims', 'taskClaimedOn', 'taskBalanceRewardVersion', 'referralCode',
    'dailyDate', 'dailyTasks', 'dailyTaskVariant', 'loginRewardDate', 'firstLoginNoReward', 'streakCurrent', 'streakBest',
    'streakLastVisitDate', 'streakRunStartedDate', 'streakRewardClaims', 'taskPotsUsed',
    'potCollections', 'achievements', 'achievementClaims', 'joinedAt', 'lastBatchReward', 'lastBatchAt', 'schemaVersion'
  ];
BEGIN
  -- NULL means “cannot safely classify”. The caller must stop without applying
  -- either the first-visit no-reward path or the returning-player daily reward.
  -- A first visit is true only for a complete, canonical, empty schema-6 state.
  IF jsonb_typeof(p_state) IS DISTINCT FROM 'object'
     OR public._pelmeni_state_shape_is_valid(p_state) IS DISTINCT FROM TRUE THEN
    RETURN NULL;
  END IF;

  -- Detect positive progress first, including fields the old predicate ignored.
  FOREACH v_key IN ARRAY ARRAY[
    'balance', 'score', 'lifetimeDumplings', 'batches', 'taskBatches', 'streakCurrent', 'streakBest', 'points'
  ] LOOP
    IF p_state ? v_key THEN
      v_value := p_state -> v_key;
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
        RETURN NULL;
      END IF;
      IF v_text::numeric > 0 THEN RETURN false; END IF;
    END IF;
  END LOOP;

  IF p_state ? 'pointsRetired' THEN
    IF jsonb_typeof(p_state -> 'pointsRetired') IS DISTINCT FROM 'boolean' THEN RETURN NULL; END IF;
    IF p_state -> 'pointsRetired' IS DISTINCT FROM 'true'::jsonb THEN RETURN NULL; END IF;
  END IF;
  IF p_state ? 'level' THEN
    v_value := p_state -> 'level';
    v_text := v_value #>> '{}';
    IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
       OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
      RETURN NULL;
    END IF;
    IF v_text::numeric > 1 THEN RETURN false; END IF;
    -- `level` is not part of the current serialized schema; even level 1 is
    -- an unrecognized legacy snapshot and cannot prove a fresh account.
    RETURN NULL;
  END IF;

  IF p_state ? 'upgradeLevels' THEN
    FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_state -> 'upgradeLevels') AS item(key, value) LOOP
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
        RETURN NULL;
      END IF;
      v_number := v_text::numeric;
      IF v_number > 0 THEN RETURN false; END IF;
    END LOOP;
  END IF;

  FOREACH v_key IN ARRAY ARRAY[
    'upgrades', 'equipped', 'activeBatches', 'levelClaims', 'achievements',
    'streakRewardClaims', 'taskPotsUsed'
  ] LOOP
    IF p_state ? v_key AND jsonb_array_length(p_state -> v_key) > 0 THEN RETURN false; END IF;
  END LOOP;

  IF p_state ? 'dailyTasks' THEN
    FOR v_task_id, v_task IN SELECT key, value FROM jsonb_each(p_state -> 'dailyTasks') AS item(key, value) LOOP
      IF COALESCE((v_task ->> 'progress')::numeric, 0) > 0
         OR COALESCE((v_task ->> 'claimed')::boolean, false) THEN
        RETURN false;
      END IF;
    END LOOP;
  END IF;

  -- A fresh current-format profile always has a recognized daily variant and
  -- an empty claim list. A null/unknown variant is ambiguous and must not be
  -- treated as proof of a first visit.
  IF p_state -> 'dailyTaskVariant' IS NULL
     OR jsonb_typeof(p_state -> 'dailyTaskVariant') IS DISTINCT FROM 'string'
     OR p_state ->> 'dailyTaskVariant' NOT IN ('classic', 'batch-focus', 'kitchen-rhythm') THEN
    RETURN NULL;
  END IF;

  IF p_state ? 'potCollections' THEN
    FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_state -> 'potCollections') AS item(key, value) LOOP
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
        RETURN NULL;
      END IF;
      IF v_text::numeric > 0 THEN RETURN false; END IF;
    END LOOP;
  END IF;

  IF p_state -> 'joinedAt' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_state -> 'joinedAt') = 'string' THEN
      v_text := p_state ->> 'joinedAt';
      IF v_text = '' THEN RETURN NULL; END IF;
      BEGIN
        PERFORM v_text::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN NULL;
      END;
      RETURN false;
    END IF;
    RETURN NULL;
  END IF;
  IF p_state -> 'loginRewardDate' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_state -> 'loginRewardDate') = 'string'
       AND public._pelmeni_valid_utc_day(p_state ->> 'loginRewardDate') THEN
      RETURN false;
    END IF;
    RETURN NULL;
  END IF;
  IF p_state -> 'taskClaimedOn' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_state -> 'taskClaimedOn') = 'string'
       AND public._pelmeni_valid_utc_day(p_state ->> 'taskClaimedOn') THEN
      RETURN false;
    END IF;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_state -> 'firstLoginNoReward') IS DISTINCT FROM 'boolean' THEN RETURN NULL; END IF;
  IF p_state -> 'firstLoginNoReward' IS DISTINCT FROM 'false'::jsonb THEN RETURN false; END IF;
  IF p_state ? 'taskBalanceRewardVersion' THEN
    v_value := p_state -> 'taskBalanceRewardVersion';
    v_text := v_value #>> '{}';
    IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
       OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
      RETURN NULL;
    END IF;
    IF v_text::numeric <> 1 THEN RETURN NULL; END IF;
  END IF;
  IF p_state -> 'referralCode' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_state -> 'referralCode') = 'string'
       AND (p_state ->> 'referralCode') ~ '^PC-[A-Z0-9]{6}$' THEN
      RETURN false;
    END IF;
    RETURN NULL;
  END IF;
  FOREACH v_key IN ARRAY ARRAY['streakLastVisitDate', 'streakRunStartedDate'] LOOP
    IF p_state -> v_key IS DISTINCT FROM 'null'::jsonb THEN
      IF jsonb_typeof(p_state -> v_key) = 'string'
         AND public._pelmeni_valid_utc_day(p_state ->> v_key) THEN
        RETURN false;
      END IF;
      RETURN NULL;
    END IF;
  END LOOP;
  FOREACH v_key IN ARRAY ARRAY['startedAt', 'endsAt', 'batchDurationMs'] LOOP
    IF p_state -> v_key IS DISTINCT FROM 'null'::jsonb THEN
      v_value := p_state -> v_key;
      v_text := v_value #>> '{}';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'number'
         OR v_text !~ '^(0|[1-9][0-9]*)$' OR length(v_text) > 19 THEN
        RETURN NULL;
      END IF;
      RETURN false;
    END IF;
  END LOOP;
  IF p_state -> 'lastBatchReward' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_state -> 'lastBatchReward') = 'object'
       AND jsonb_typeof(p_state #> '{lastBatchReward,dumplings}') = 'number'
       AND (p_state #>> '{lastBatchReward,dumplings}') ~ '^(0|[1-9][0-9]*)$' THEN
      RETURN false;
    END IF;
    RETURN NULL;
  END IF;
  IF p_state -> 'lastBatchAt' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_state -> 'lastBatchAt') = 'string' THEN
      BEGIN
        PERFORM (p_state ->> 'lastBatchAt')::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN NULL;
      END;
      RETURN false;
    END IF;
    RETURN NULL;
  END IF;
  IF p_state -> 'dailyDate' IS NULL OR p_state -> 'taskDay' IS NULL
     OR jsonb_typeof(p_state -> 'dailyDate') IS DISTINCT FROM 'string'
     OR jsonb_typeof(p_state -> 'taskDay') IS DISTINCT FROM 'string'
     OR NOT public._pelmeni_valid_utc_day(p_state ->> 'dailyDate')
     OR NOT public._pelmeni_valid_utc_day(p_state ->> 'taskDay')
     OR p_state ->> 'dailyDate' IS DISTINCT FROM p_state ->> 'taskDay' THEN
    RETURN NULL;
  END IF;

  -- A fresh state is canonical only when every serialized task slot exists
  -- and contains exactly the two client-defined fields. This check is after
  -- reliable progress/visit markers above, so an old profile with a partial
  -- task object can still be classified as old and safely completed by the
  -- legacy preparation path.
  FOREACH v_task_id IN ARRAY ARRAY[
    'login', 'cook', 'upgrade', 'collect', 'collect-dumplings', 'collect-two', 'two-pots'
  ] LOOP
    IF NOT (p_state -> 'dailyTasks' ? v_task_id) THEN RETURN NULL; END IF;
    v_task := p_state #> ARRAY['dailyTasks', v_task_id];
    IF jsonb_typeof(v_task) IS DISTINCT FROM 'object'
       OR NOT (v_task ?& ARRAY['progress', 'claimed'])
       OR (v_task - 'progress' - 'claimed') IS DISTINCT FROM '{}'::jsonb THEN
      RETURN NULL;
    END IF;
  END LOOP;

  -- Current normalized state always has these keys. Missing/extra fields or a
  -- partially populated legacy snapshot are ambiguous, not proof of a new user.
  FOREACH v_key IN ARRAY v_expected_keys LOOP
    IF NOT (p_state ? v_key) THEN RETURN NULL; END IF;
  END LOOP;
  FOR v_key IN SELECT jsonb_object_keys(p_state) LOOP
    IF NOT (v_key = ANY(v_expected_keys)) THEN RETURN NULL; END IF;
  END LOOP;

  IF p_state -> 'schemaVersion' IS DISTINCT FROM '6'::jsonb
     OR p_state -> 'balance' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'score' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'points' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'pointsRetired' IS DISTINCT FROM 'true'::jsonb
     OR p_state -> 'batches' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'lifetimeDumplings' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'taskBatches' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'streakCurrent' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'streakBest' IS DISTINCT FROM '0'::jsonb
     OR p_state -> 'taskBalanceRewardVersion' IS DISTINCT FROM '1'::jsonb
     OR p_state -> 'upgradeLevels' IS DISTINCT FROM '{"good-stove":0,"large-pot":0,"grandma-recipe":0}'::jsonb
     OR p_state -> 'dailyTasks' IS DISTINCT FROM jsonb_build_object(
       'login', jsonb_build_object('progress', 0, 'claimed', false),
       'cook', jsonb_build_object('progress', 0, 'claimed', false),
       'upgrade', jsonb_build_object('progress', 0, 'claimed', false),
       'collect', jsonb_build_object('progress', 0, 'claimed', false),
       'collect-dumplings', jsonb_build_object('progress', 0, 'claimed', false),
       'collect-two', jsonb_build_object('progress', 0, 'claimed', false),
       'two-pots', jsonb_build_object('progress', 0, 'claimed', false))
     OR p_state -> 'potCollections' IS DISTINCT FROM '{"1":0,"2":0}'::jsonb
     OR p_state -> 'upgrades' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'equipped' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'activeBatches' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'levelClaims' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'achievements' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'achievementClaims' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'streakRewardClaims' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'taskPotsUsed' IS DISTINCT FROM '[]'::jsonb
     OR p_state -> 'startedAt' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'endsAt' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'batchDurationMs' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'streakLastVisitDate' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'streakRunStartedDate' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'referralCode' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'lastBatchReward' IS DISTINCT FROM 'null'::jsonb
     OR p_state -> 'lastBatchAt' IS DISTINCT FROM 'null'::jsonb THEN
    RETURN NULL;
  END IF;

  RETURN true;
END
$fn$;

-- Dry-run report. It writes only an immutable source/candidate audit row;
-- player_state, balance, control mode and revision remain untouched. Activation
-- repeats all checks while holding the profile and control locks.
CREATE OR REPLACE FUNCTION public.economy_assess_legacy_profile(p_telegram_id bigint)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_state jsonb;
  v_assessment jsonb;
  v_candidate jsonb;
  v_source_hash text;
  v_candidate_hash text;
  v_snapshot_status text;
  v_first_visit_eligible boolean;
  v_reasons text[];
  v_unknown_keys jsonb;
  v_rows integer;
  v_today date;
  v_known_keys text[] := ARRAY[
    'balance','score','points','pointsRetired','batches','startedAt','endsAt','batchDurationMs',
    'activeBatches','upgrades','equipped','upgradeLevels','taskDay','taskBatches',
    'lifetimeDumplings','levelClaims','taskClaimedOn','taskBalanceRewardVersion','referralCode',
    'dailyDate','dailyTasks','dailyTaskVariant','loginRewardDate','firstLoginNoReward',
    'streakCurrent','streakBest','streakLastVisitDate','streakRunStartedDate','streakRewardClaims',
    'taskPotsUsed','potCollections','achievements','achievementClaims','joinedAt',
    'lastBatchReward','lastBatchAt','schemaVersion'
  ];
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Legacy profile assessment is restricted to the trusted server role' USING ERRCODE = '42501';
  END IF;
  IF p_telegram_id IS NULL OR p_telegram_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required', 'reasons', jsonb_build_array('invalid_telegram_id'));
  END IF;
  SELECT game_state INTO v_state FROM public.player_state WHERE telegram_id = p_telegram_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required', 'reasons', jsonb_build_array('profile_not_found'));
  END IF;
  IF v_state IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'reasons', jsonb_build_array('legacy_state_not_object'));
  END IF;
  IF EXISTS (SELECT 1 FROM public.player_economy_control
      WHERE telegram_id = p_telegram_id AND server_mode = true) THEN
    RETURN jsonb_build_object('ok', true, 'status', 'already_active');
  END IF;
  v_today := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_assessment := public._pelmeni_prepare_legacy_state(v_state, v_today);
  v_first_visit_eligible := public._pelmeni_is_first_visit(v_state) IS TRUE;
  v_candidate := v_assessment -> 'candidateState';
  v_source_hash := md5(v_state::text);
  v_candidate_hash := CASE WHEN v_assessment ? 'candidateState'
    THEN md5(v_candidate::text) ELSE NULL END;
  v_snapshot_status := CASE WHEN v_assessment -> 'ok' = 'true'::jsonb THEN 'ready' ELSE 'review' END;
  SELECT ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_assessment -> 'reasons', '[]'::jsonb)))
    INTO v_reasons;
  SELECT COALESCE(jsonb_agg(key ORDER BY key), '[]'::jsonb) INTO v_unknown_keys
  FROM jsonb_object_keys(
    CASE WHEN jsonb_typeof(v_state) = 'object' THEN v_state ELSE '{}'::jsonb END
  ) AS field(key)
  WHERE NOT (key = ANY(v_known_keys));

  -- Persist only migration audit metadata. The original player_state, balance,
  -- control row and revision remain untouched during dry-run. The source row
  -- is immutable; a hash collision or an already activated snapshot fails closed.
  INSERT INTO public.player_economy_migration_snapshots
    (telegram_id,source_hash,source_state,prepared_state,status,review_reasons,dry_run_utc_date,first_visit_eligible)
  VALUES
    (p_telegram_id,v_source_hash,v_state,v_candidate,v_snapshot_status,
     COALESCE(v_reasons,ARRAY[]::text[]),v_today,v_first_visit_eligible)
  ON CONFLICT (telegram_id,source_hash) DO UPDATE
    SET prepared_state = EXCLUDED.prepared_state,
        status = EXCLUDED.status,
        review_reasons = EXCLUDED.review_reasons,
        dry_run_utc_date = EXCLUDED.dry_run_utc_date,
        first_visit_eligible = EXCLUDED.first_visit_eligible,
        updated_at = clock_timestamp()
    WHERE public.player_economy_migration_snapshots.source_state = EXCLUDED.source_state
      AND public.player_economy_migration_snapshots.status <> 'activated';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'reasons', jsonb_build_array('source_fingerprint_conflict_or_activated_snapshot'));
  END IF;

  RETURN jsonb_build_object(
    'ok', v_assessment -> 'ok',
    'status', CASE WHEN v_assessment -> 'ok' = 'true'::jsonb THEN 'ready' ELSE 'manual_review_required' END,
    'reasons', COALESCE(v_assessment -> 'reasons', '[]'::jsonb),
    'sourceHash', v_source_hash,
    'candidateHash', v_candidate_hash,
    'dryRunUtcDate', v_today,
    'preservedUnknownTopLevelKeys', v_unknown_keys,
    'firstVisitEligible', v_first_visit_eligible,
    'candidateState', v_candidate
  );
END
$fn$;

-- Activate only the exact dry-run result approved by the operator. The caller
-- must pass all three dry-run fingerprints; activation recomputes them after
-- locking the source profile and refuses stale or changed input without writes.
CREATE OR REPLACE FUNCTION public.economy_activate_legacy_profile(
  p_telegram_id bigint,
  p_approved_source_hash text,
  p_approved_candidate_hash text,
  p_approved_utc_date date
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_source jsonb;
  v_prepared jsonb;
  v_candidate jsonb;
  v_assessment jsonb;
  v_hash text;
  v_candidate_hash text;
  v_saved_source jsonb;
  v_saved_candidate jsonb;
  v_saved_status text;
  v_saved_reasons text[];
  v_saved_day date;
  v_saved_first_visit boolean;
  v_revision bigint;
  v_server_mode boolean;
  v_today date;
  v_control_found boolean;
  v_snapshot_found boolean;
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Legacy profile activation is restricted to the trusted server role' USING ERRCODE = '42501';
  END IF;
  IF p_telegram_id IS NULL OR p_telegram_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required', 'reasons', jsonb_build_array('invalid_telegram_id'));
  END IF;

  -- This lock order is shared with economy RPCs and the legacy-save trigger.
  SELECT game_state INTO v_source FROM public.player_state
  WHERE telegram_id = p_telegram_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required', 'reasons', jsonb_build_array('profile_not_found'));
  END IF;
  SELECT revision, server_mode INTO v_revision, v_server_mode
  FROM public.player_economy_control WHERE telegram_id = p_telegram_id FOR UPDATE;
  v_control_found := FOUND;
  IF v_control_found AND v_server_mode THEN
    RETURN jsonb_build_object('ok', true, 'status', 'already_active', 'revision', v_revision);
  END IF;

  -- Do not create control/snapshot rows for an expired or incomplete dry run.
  -- Every return below this point remains read-only until all approval checks pass.
  v_today := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  IF p_approved_source_hash IS NULL OR p_approved_candidate_hash IS NULL
     OR p_approved_source_hash !~ '^[0-9a-f]{32}$'
     OR p_approved_candidate_hash !~ '^[0-9a-f]{32}$'
     OR p_approved_utc_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'dry_run_approval_required', 'reasons', jsonb_build_array('dry_run_approval_required'));
  END IF;
  IF p_approved_utc_date IS DISTINCT FROM v_today THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'dry_run_expired', 'reasons', jsonb_build_array('dry_run_expired'), 'dryRunUtcDate', v_today);
  END IF;

  v_hash := md5(v_source::text);
  IF p_approved_source_hash IS DISTINCT FROM v_hash THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'source_changed_after_dry_run', 'reasons', jsonb_build_array('source_changed_after_dry_run'),
      'sourceHash', v_hash, 'dryRunUtcDate', v_today);
  END IF;
  v_assessment := public._pelmeni_prepare_legacy_state(v_source, v_today);
  v_candidate := v_assessment -> 'candidateState';
  v_candidate_hash := CASE WHEN v_assessment ? 'candidateState'
    THEN md5((v_assessment -> 'candidateState')::text) ELSE NULL END;
  IF p_approved_candidate_hash IS DISTINCT FROM v_candidate_hash THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'candidate_changed_after_dry_run', 'reasons', jsonb_build_array('candidate_changed_after_dry_run'),
      'sourceHash', v_hash, 'candidateHash', v_candidate_hash, 'dryRunUtcDate', v_today);
  END IF;
  IF v_assessment -> 'ok' IS DISTINCT FROM 'true'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'sourceHash', v_hash, 'candidateHash', v_candidate_hash, 'dryRunUtcDate', v_today,
      'reasons', COALESCE(v_assessment -> 'reasons', jsonb_build_array('legacy_state_corrupted')));
  END IF;

  -- Activation is permitted only for the ready, exact dry-run row. This also
  -- detects source edits, candidate changes, and a dry run from another UTC day.
  SELECT source_state, prepared_state, status, dry_run_utc_date, review_reasons, first_visit_eligible
    INTO v_saved_source, v_saved_candidate, v_saved_status, v_saved_day, v_saved_reasons, v_saved_first_visit
  FROM public.player_economy_migration_snapshots
  WHERE telegram_id = p_telegram_id AND source_hash = v_hash FOR UPDATE;
  v_snapshot_found := FOUND;
  IF NOT v_snapshot_found THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'dry_run_not_recorded', 'reasons', jsonb_build_array('dry_run_not_recorded'));
  END IF;
  IF v_snapshot_found AND v_saved_source IS DISTINCT FROM v_source THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'source_fingerprint_conflict', 'reasons', jsonb_build_array('source_fingerprint_conflict'));
  END IF;
  IF v_saved_day IS DISTINCT FROM p_approved_utc_date THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'dry_run_expired', 'reasons', jsonb_build_array('dry_run_expired'));
  END IF;
  IF v_saved_status = 'review' THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'sourceHash',v_hash,'candidateHash',v_candidate_hash,'dryRunUtcDate',v_today,
      'reasons',to_jsonb(COALESCE(v_saved_reasons,ARRAY['legacy_state_corrupted']::text[])));
  END IF;
  IF v_saved_status <> 'ready' THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'activation_snapshot_not_ready', 'reasons', jsonb_build_array('activation_snapshot_not_ready'));
  END IF;
  IF v_saved_candidate IS DISTINCT FROM v_candidate THEN
    RETURN jsonb_build_object('ok', false, 'status', 'manual_review_required',
      'error', 'candidate_changed_after_dry_run', 'reasons', jsonb_build_array('candidate_changed_after_dry_run'));
  END IF;

  IF NOT v_control_found THEN
    INSERT INTO public.player_economy_control(telegram_id, revision, server_mode, state_schema_version)
    VALUES (p_telegram_id, 0, false, 6);
    SELECT revision, server_mode INTO v_revision, v_server_mode
    FROM public.player_economy_control WHERE telegram_id = p_telegram_id FOR UPDATE;
  END IF;

  UPDATE public.player_economy_migration_snapshots
     SET prepared_state = v_candidate,
         status = 'ready', dry_run_utc_date = v_today,
         review_reasons = ARRAY[]::text[],
         updated_at = clock_timestamp()
   WHERE telegram_id = p_telegram_id AND source_hash = v_hash;

  IF v_candidate IS DISTINCT FROM v_source THEN
    UPDATE public.player_state SET game_state = v_candidate, updated_at = clock_timestamp()
    WHERE telegram_id = p_telegram_id;
  END IF;
  UPDATE public.player_economy_control
     SET revision = COALESCE(v_revision, 0) + 1,
         state_schema_version = 6,
         updated_at = clock_timestamp()
   WHERE telegram_id = p_telegram_id;
  UPDATE public.player_economy_migration_snapshots
     SET status = 'activated', review_reasons = ARRAY[]::text[],
         updated_at = clock_timestamp(), activated_at = clock_timestamp()
   WHERE telegram_id = p_telegram_id AND source_hash = v_hash;
  -- Must remain the final database mutation: any waiting legacy upsert then
  -- observes server_mode=true in its trigger and is rejected.
  UPDATE public.player_economy_control SET server_mode = true, updated_at = clock_timestamp()
  WHERE telegram_id = p_telegram_id;

  RETURN jsonb_build_object('ok', true, 'status', 'activated', 'sourceHash', v_hash,
    'candidateHash', v_candidate_hash, 'dryRunUtcDate', v_today,
    'firstVisitEligible', v_saved_first_visit,
    'revision', COALESCE(v_revision, 0) + 1, 'state', v_candidate);
END
$fn$;

-- Daily visit records eligibility and unlocks achievements only. Any dumpling
-- reward requires an explicit claim RPC. It never imports browser/localStorage.
CREATE OR REPLACE FUNCTION public.economy_load_visit(p_telegram_id bigint)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_state jsonb;
  v_original jsonb;
  v_revision bigint;
  v_server_mode boolean;
  v_control_schema_version integer;
  v_today date;
  v_expected_variant text;
  v_daily_date text;
  v_daily_date_value date;
  v_daily_date_valid boolean;
  v_last_visit_text text;
  v_last_visit date;
  v_streak_current bigint;
  v_streak_best bigint;
  v_next_streak bigint;
  v_day_delta integer;
  v_first_visit boolean;
  v_has_activation_snapshot boolean := false;
  v_snapshot_first_visit boolean := false;
  v_previous_login_reward_date text;
  v_previous_first_login_no_reward boolean;
  v_previous_claims jsonb;
  v_task_id text;
  v_tasks jsonb;
  v_task jsonb;
  v_task_ids text[] := ARRAY['login','cook','upgrade','collect','collect-dumplings','collect-two','two-pots'];
  v_changed boolean := false;
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION 'Economy RPC is restricted to the trusted server role' USING ERRCODE = '42501';
  END IF;
  IF p_telegram_id IS NULL OR p_telegram_id <= 0 THEN
    RAISE EXCEPTION 'Invalid Telegram profile id' USING ERRCODE = '22023';
  END IF;

  -- Use the same lock order as economy commands and the legacy-save trigger.
  SELECT game_state INTO v_state
  FROM public.player_state WHERE telegram_id = p_telegram_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found', 'protocolVersion', 1);
  END IF;
  IF v_state IS NULL OR jsonb_typeof(v_state) <> 'object' THEN
    RAISE EXCEPTION 'Canonical profile game_state is not a JSON object' USING ERRCODE = '22023';
  END IF;
  SELECT revision, server_mode, state_schema_version
    INTO v_revision, v_server_mode, v_control_schema_version
  FROM public.player_economy_control WHERE telegram_id = p_telegram_id FOR UPDATE;
  IF NOT FOUND OR NOT v_server_mode THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_enabled', 'protocolVersion', 1);
  END IF;
  IF v_control_schema_version <> 6
     OR jsonb_typeof(v_state -> 'schemaVersion') IS DISTINCT FROM 'number'
     OR (v_state ->> 'schemaVersion') IS DISTINCT FROM v_control_schema_version::text THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_game_state_schema',
      'expectedGameStateSchemaVersion', 6, 'protocolVersion', 1);
  END IF;
  IF public._pelmeni_state_shape_is_valid(v_state) IS DISTINCT FROM TRUE
     OR COALESCE(jsonb_typeof(v_state -> 'dailyTasks'), 'missing') <> 'object'
     OR (v_state ? 'achievements' AND jsonb_typeof(v_state -> 'achievements') <> 'array') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_game_state_shape',
      'protocolVersion', 1, 'gameStateSchemaVersion', 6);
  END IF;
  v_original := v_state;
  v_previous_login_reward_date := v_state ->> 'loginRewardDate';
  -- Preserve this legacy exception before UTC rollover can reset the field.
  -- A same-day login marker is not proof of payment when this was true.
  v_previous_first_login_no_reward := CASE
    WHEN jsonb_typeof(v_state -> 'firstLoginNoReward') = 'boolean'
      THEN (v_state ->> 'firstLoginNoReward')::boolean
    ELSE NULL
  END;
  v_previous_claims := COALESCE(v_state -> 'streakRewardClaims', '[]'::jsonb);

  -- Compute the UTC date after obtaining both locks so a long lock wait across
  -- midnight is evaluated against the server day at the serialized visit.
  v_today := (clock_timestamp() AT TIME ZONE 'UTC')::date;
  v_expected_variant := public._pelmeni_daily_task_variant(v_today);
  SELECT first_visit_eligible INTO v_snapshot_first_visit
  FROM public.player_economy_migration_snapshots
  WHERE telegram_id = p_telegram_id AND status = 'activated'
  ORDER BY activated_at DESC NULLS LAST LIMIT 1;
  v_has_activation_snapshot := FOUND;
  -- Activation preserves a first-visit classification only when the exact
  -- source snapshot proved it. Existing/ambiguous profiles are never made new.
  v_first_visit := CASE WHEN v_has_activation_snapshot THEN v_snapshot_first_visit
    ELSE public._pelmeni_is_first_visit(v_state) END;
  IF v_first_visit IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'first_visit_state_ambiguous',
      'protocolVersion', 1, 'gameStateSchemaVersion', 6);
  END IF;
  v_daily_date := v_state ->> 'dailyDate';
  v_daily_date_valid := public._pelmeni_valid_utc_day(v_daily_date);
  IF v_daily_date_valid THEN v_daily_date_value := v_daily_date::date; END IF;
  -- Match the current client clock-skew guard: a device/game date in the
  -- future is not rolled backward and does not earn another daily reward.
  IF v_daily_date_valid AND v_daily_date_value > v_today THEN
    IF COALESCE(NULLIF(v_state ->> 'joinedAt', ''), '') = '' THEN
      v_state := jsonb_set(v_state, '{joinedAt}', to_jsonb(clock_timestamp()), true);
    END IF;
  ELSE
    IF v_daily_date_valid AND v_daily_date_value = v_today
       AND (v_state ->> 'dailyTaskVariant') IS DISTINCT FROM v_expected_variant THEN
      RETURN jsonb_build_object('ok', false, 'error', 'daily_task_variant_stale',
        'protocolVersion', 1, 'gameStateSchemaVersion', 6);
    END IF;
    v_last_visit_text := v_state ->> 'streakLastVisitDate';
    v_streak_current := CASE WHEN COALESCE(v_state ->> 'streakCurrent', '') ~ '^[0-9]+$'
      THEN LEAST((v_state ->> 'streakCurrent')::bigint, 1000000000) ELSE 0 END;
    v_streak_best := CASE WHEN COALESCE(v_state ->> 'streakBest', '') ~ '^[0-9]+$'
      THEN LEAST((v_state ->> 'streakBest')::bigint, 1000000000) ELSE v_streak_current END;
    v_streak_best := GREATEST(v_streak_best, v_streak_current);

    IF NOT public._pelmeni_valid_utc_day(v_last_visit_text) THEN
      v_next_streak := 1;
      v_streak_best := GREATEST(v_streak_best, 1);
      v_state := jsonb_set(v_state, '{streakLastVisitDate}', to_jsonb(v_today::text), true);
      v_state := jsonb_set(v_state, '{streakCurrent}', to_jsonb(v_next_streak), true);
      v_state := jsonb_set(v_state, '{streakBest}', to_jsonb(v_streak_best), true);
      v_state := jsonb_set(v_state, '{streakRunStartedDate}', to_jsonb(v_today::text), true);
    ELSE
      v_last_visit := v_last_visit_text::date;
      v_day_delta := v_today - v_last_visit;
      IF v_day_delta = 0 THEN
        v_next_streak := GREATEST(v_streak_current, 1);
      ELSIF v_day_delta < 0 THEN
        v_next_streak := v_streak_current;
      ELSIF v_day_delta = 1 THEN
        v_next_streak := v_streak_current + 1;
      ELSE
        v_next_streak := 1;
      END IF;
      IF v_day_delta > 0 THEN
        v_state := jsonb_set(v_state, '{streakLastVisitDate}', to_jsonb(v_today::text), true);
        v_streak_best := GREATEST(v_streak_best, v_next_streak);
        v_state := jsonb_set(v_state, '{streakCurrent}', to_jsonb(v_next_streak), true);
        v_state := jsonb_set(v_state, '{streakBest}', to_jsonb(v_streak_best), true);
        IF v_day_delta > 1 THEN
          v_state := jsonb_set(v_state, '{streakRunStartedDate}', to_jsonb(v_today::text), true);
        END IF;
      ELSIF v_day_delta = 0 AND v_streak_current = 0 THEN
        v_state := jsonb_set(v_state, '{streakCurrent}', to_jsonb(1), true);
      END IF;
      IF COALESCE(NULLIF(v_state ->> 'streakRunStartedDate', ''), '') = '' THEN
        v_state := jsonb_set(v_state, '{streakRunStartedDate}', to_jsonb(v_last_visit_text), true);
      END IF;
    END IF;

    IF NOT v_daily_date_valid OR v_daily_date_value <> v_today
       OR (v_state ->> 'taskDay') IS DISTINCT FROM v_today::text THEN
      -- Keep loginRewardDate intact: it can already equal today even when
      -- dailyDate/taskDay need a rollover, and clearing it would pay twice.
      v_state := jsonb_set(v_state, '{dailyDate}', to_jsonb(v_today::text), true);
      v_state := jsonb_set(v_state, '{dailyTasks}', jsonb_build_object(
        'login', jsonb_build_object('progress', 0, 'claimed', false),
        'cook', jsonb_build_object('progress', 0, 'claimed', false),
        'upgrade', jsonb_build_object('progress', 0, 'claimed', false),
        'collect', jsonb_build_object('progress', 0, 'claimed', false),
        'collect-dumplings', jsonb_build_object('progress', 0, 'claimed', false),
        'collect-two', jsonb_build_object('progress', 0, 'claimed', false),
        'two-pots', jsonb_build_object('progress', 0, 'claimed', false)), true);
      v_state := jsonb_set(v_state, '{dailyTaskVariant}', to_jsonb(v_expected_variant), true);
      v_state := jsonb_set(v_state, '{firstLoginNoReward}', 'false'::jsonb, true);
      v_state := jsonb_set(v_state, '{taskDay}', to_jsonb(v_today::text), true);
      v_state := jsonb_set(v_state, '{taskBatches}', '0'::jsonb, true);
      v_state := jsonb_set(v_state, '{taskClaimedOn}', 'null'::jsonb, true);
      v_state := jsonb_set(v_state, '{taskPotsUsed}', '[]'::jsonb, true);
    END IF;

    -- Complete partial dailyTasks objects with inert slots. The legacy cook
    -- claim marker is authoritative for duplicate prevention, including when
    -- the cook slot was absent or had a false claimed flag.
    v_tasks := COALESCE(v_state -> 'dailyTasks', '{}'::jsonb);
    FOREACH v_task_id IN ARRAY v_task_ids LOOP
      IF NOT (v_tasks ? v_task_id) THEN
        v_tasks := jsonb_set(v_tasks, ARRAY[v_task_id],
          jsonb_build_object('progress', 0, 'claimed', false), true);
      END IF;
    END LOOP;
    IF v_state ->> 'taskClaimedOn' = v_today::text THEN
      v_task := jsonb_set(COALESCE(v_tasks -> 'cook',
        jsonb_build_object('progress', 0, 'claimed', false)), '{claimed}', 'true'::jsonb, true);
      v_tasks := jsonb_set(v_tasks, '{cook}', v_task, true);
    END IF;
    v_state := jsonb_set(v_state, '{dailyTasks}', v_tasks, true);

    IF v_state ->> 'loginRewardDate' IS DISTINCT FROM v_today::text THEN
      IF v_first_visit THEN
        v_state := jsonb_set(v_state, '{firstLoginNoReward}', 'false'::jsonb, true);
        IF NOT COALESCE(v_state -> 'achievements', '[]'::jsonb) @> '["first-visit"]'::jsonb THEN
          v_state := jsonb_set(v_state, '{achievements}',
            COALESCE(v_state -> 'achievements', '[]'::jsonb) || '["first-visit"]'::jsonb, true);
        END IF;
      END IF;
      -- A visit records streak eligibility, but the player must explicitly
      -- invoke economy_claim_streak to receive the daily reward.
      v_state := jsonb_set(v_state, '{loginRewardDate}', to_jsonb(v_today::text), true);
    END IF;

    -- Legacy clients used loginRewardDate as proof that the automatic reward
    -- had already been paid. Before adding the new visit marker, preserve that
    -- meaning as a claim marker so rollout cannot make today's reward
    -- claimable a second time. This only records the legacy claim; it never
    -- grants dumplings. firstLoginNoReward is the legacy exception.
    IF v_previous_login_reward_date IS NOT DISTINCT FROM v_today::text
      AND v_previous_first_login_no_reward IS FALSE
      AND NOT v_previous_claims
        @> jsonb_build_array(v_today::text || ':0:0')
      AND NOT v_previous_claims
        @> jsonb_build_array(v_today::text || ':0:1') THEN
      v_state := jsonb_set(v_state, '{streakRewardClaims}',
        COALESCE(v_state -> 'streakRewardClaims', '[]'::jsonb)
          || jsonb_build_array(v_today::text || ':0:1'), true);
    END IF;

    IF NOT COALESCE(v_state -> 'streakRewardClaims', '[]'::jsonb)
      @> jsonb_build_array(v_today::text || ':0:0') THEN
      v_state := jsonb_set(v_state, '{streakRewardClaims}',
        COALESCE(v_state -> 'streakRewardClaims', '[]'::jsonb)
          || jsonb_build_array(v_today::text || ':0:0'), true);
    END IF;

    v_state := jsonb_set(v_state, '{dailyTasks,login}',
      jsonb_build_object('progress', 1, 'claimed', true), true);
    IF COALESCE(NULLIF(v_state ->> 'joinedAt', ''), '') = '' THEN
      v_state := jsonb_set(v_state, '{joinedAt}', to_jsonb(clock_timestamp()), true);
    END IF;
  END IF;

  v_state := public._pelmeni_refresh_achievements(v_state);
  v_changed := v_state IS DISTINCT FROM v_original;
  IF v_changed THEN
    v_revision := v_revision + 1;
    PERFORM pg_catalog.set_config('pelmeni.server_economy_write', 'allowed', true);
    UPDATE public.player_state SET game_state = v_state, updated_at = clock_timestamp()
    WHERE telegram_id = p_telegram_id;
    UPDATE public.player_economy_control SET revision = v_revision, updated_at = clock_timestamp()
    WHERE telegram_id = p_telegram_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'state', v_state, 'revision', v_revision,
    'protocolVersion', 1, 'gameStateSchemaVersion', v_state -> 'schemaVersion');
END
$fn$;

-- Explicit RPC surface. Telegram ID is supplied only by the trusted Edge
-- Function after initData verification; it is not an accepted client field.
CREATE OR REPLACE FUNCTION public.economy_start_batch(p_telegram_id bigint, p_request_id uuid, p_pot integer)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'start_batch', jsonb_build_object('pot', p_pot)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_collect_batch(p_telegram_id bigint, p_request_id uuid, p_batch_id text)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'collect_batch', jsonb_build_object('batchId', p_batch_id)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_purchase_upgrade(p_telegram_id bigint, p_request_id uuid, p_upgrade_id text)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'purchase_upgrade', jsonb_build_object('upgradeId', p_upgrade_id)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_purchase_decoration(p_telegram_id bigint, p_request_id uuid, p_decoration_id text)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'purchase_decoration', jsonb_build_object('decorationId', p_decoration_id)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_set_decoration_equipped(p_telegram_id bigint, p_request_id uuid, p_decoration_id text, p_equipped boolean)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'set_decoration_equipped', jsonb_build_object('decorationId', p_decoration_id, 'equipped', p_equipped)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_claim_task(p_telegram_id bigint, p_request_id uuid, p_task_id text)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'claim_task', jsonb_build_object('taskId', p_task_id)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_claim_streak(p_telegram_id bigint, p_request_id uuid)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'claim_streak', '{}'::jsonb) $fn$;

CREATE OR REPLACE FUNCTION public.economy_claim_achievement(p_telegram_id bigint, p_request_id uuid, p_achievement_id text)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'claim_achievement', jsonb_build_object('achievementId', p_achievement_id)) $fn$;

CREATE OR REPLACE FUNCTION public.economy_claim_level(p_telegram_id bigint, p_request_id uuid, p_level integer)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$ SELECT public._pelmeni_apply_economy_command(p_telegram_id, p_request_id, 'claim_level', jsonb_build_object('level', p_level)) $fn$;

-- Remove default PUBLIC execution, then grant only to the server role.
REVOKE ALL ON FUNCTION public._pelmeni_task_progress(jsonb, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_daily_task_variant(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_daily_task_policy(jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_add_dumplings(jsonb, bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_refresh_achievements(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_state_shape_is_valid(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_finish_request(bigint, uuid, text, jsonb, bigint, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_apply_economy_command(bigint, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_valid_utc_day(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_is_first_visit(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_prepare_legacy_state(jsonb, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pelmeni_guard_legacy_save() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_assess_legacy_profile(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_activate_legacy_profile(bigint,text,text,date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_load_visit(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_start_batch(bigint, uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_collect_batch(bigint, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_purchase_upgrade(bigint, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_purchase_decoration(bigint, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_set_decoration_equipped(bigint, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_claim_task(bigint, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_claim_streak(bigint, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_claim_achievement(bigint, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.economy_claim_level(bigint, uuid, integer) FROM PUBLIC;

DO $grants$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON public.player_economy_control, public.player_economy_requests,
      public.player_economy_migration_snapshots FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_task_progress(jsonb, text, bigint) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_daily_task_variant(date) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_daily_task_policy(jsonb, text) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_add_dumplings(jsonb, bigint, boolean) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_refresh_achievements(jsonb) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_state_shape_is_valid(jsonb) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_finish_request(bigint, uuid, text, jsonb, bigint, jsonb, jsonb) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_apply_economy_command(bigint, uuid, text, jsonb) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_valid_utc_day(text) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_is_first_visit(jsonb) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_prepare_legacy_state(jsonb, date) FROM anon;
    REVOKE ALL ON FUNCTION public._pelmeni_guard_legacy_save() FROM anon;
    REVOKE ALL ON FUNCTION public.economy_assess_legacy_profile(bigint) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_activate_legacy_profile(bigint,text,text,date) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_load_visit(bigint) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_start_batch(bigint, uuid, integer) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_collect_batch(bigint, uuid, text) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_purchase_upgrade(bigint, uuid, text) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_purchase_decoration(bigint, uuid, text) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_set_decoration_equipped(bigint, uuid, text, boolean) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_claim_task(bigint, uuid, text) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_claim_streak(bigint, uuid) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_claim_achievement(bigint, uuid, text) FROM anon;
    REVOKE ALL ON FUNCTION public.economy_claim_level(bigint, uuid, integer) FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON public.player_economy_control, public.player_economy_requests,
      public.player_economy_migration_snapshots FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_task_progress(jsonb, text, bigint) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_daily_task_variant(date) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_daily_task_policy(jsonb, text) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_add_dumplings(jsonb, bigint, boolean) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_refresh_achievements(jsonb) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_state_shape_is_valid(jsonb) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_finish_request(bigint, uuid, text, jsonb, bigint, jsonb, jsonb) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_apply_economy_command(bigint, uuid, text, jsonb) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_valid_utc_day(text) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_is_first_visit(jsonb) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_prepare_legacy_state(jsonb, date) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pelmeni_guard_legacy_save() FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_assess_legacy_profile(bigint) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_activate_legacy_profile(bigint,text,text,date) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_load_visit(bigint) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_start_batch(bigint, uuid, integer) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_collect_batch(bigint, uuid, text) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_purchase_upgrade(bigint, uuid, text) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_purchase_decoration(bigint, uuid, text) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_set_decoration_equipped(bigint, uuid, text, boolean) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_claim_task(bigint, uuid, text) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_claim_streak(bigint, uuid) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_claim_achievement(bigint, uuid, text) FROM authenticated;
    REVOKE ALL ON FUNCTION public.economy_claim_level(bigint, uuid, integer) FROM authenticated;
  END IF;
  GRANT SELECT, INSERT, UPDATE ON public.player_economy_control TO service_role;
  GRANT SELECT, INSERT ON public.player_economy_requests TO service_role;
  GRANT SELECT, INSERT, UPDATE ON public.player_economy_migration_snapshots TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_task_progress(jsonb, text, bigint) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_daily_task_variant(date) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_daily_task_policy(jsonb, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_add_dumplings(jsonb, bigint, boolean) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_refresh_achievements(jsonb) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_state_shape_is_valid(jsonb) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_finish_request(bigint, uuid, text, jsonb, bigint, jsonb, jsonb) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_apply_economy_command(bigint, uuid, text, jsonb) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_valid_utc_day(text) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_is_first_visit(jsonb) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_prepare_legacy_state(jsonb, date) TO service_role;
  GRANT EXECUTE ON FUNCTION public._pelmeni_guard_legacy_save() TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_assess_legacy_profile(bigint) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_activate_legacy_profile(bigint,text,text,date) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_load_visit(bigint) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_start_batch(bigint, uuid, integer) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_collect_batch(bigint, uuid, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_purchase_upgrade(bigint, uuid, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_purchase_decoration(bigint, uuid, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_set_decoration_equipped(bigint, uuid, text, boolean) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_claim_task(bigint, uuid, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_claim_streak(bigint, uuid) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_claim_achievement(bigint, uuid, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public.economy_claim_level(bigint, uuid, integer) TO service_role;
END
$grants$;

#!/bin/sh
set -eu

# Uses only the named local Supabase container and its PostgreSQL Unix socket.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SQL_FILE="$ROOT_DIR/tests/server-economy-concurrent-idempotent-retry.sql"

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'docker is required; no database connection was attempted.' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'python3 is required; no database connection was attempted.' >&2
  exit 2
fi

exec python3 - "$SQL_FILE" <<'PY'
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

SQL_FILE = pathlib.Path(sys.argv[1]).resolve()
CONTAINER, USER, DATABASE = "supabase_db_supabase-local-test", "postgres", "postgres"
FIXTURE_ID = "9223372036854769871"
REQUEST_ID = "b1000000-0000-4000-8000-000000000001"
APP_A, APP_B = "pelmeni_idem_retry_a", "pelmeni_idem_retry_b"
FIXTURE_CREATED = False
WORKERS_STARTED = False
CHILDREN = []
TEMP_DIR = None

def psql_base():
    # Fixed container, socket directory, port, role, and database. Empty
    # PGPASSWORD plus -w prohibit use of a stored/password credential or prompt.
    return ["docker", "exec", "-i", "--env", "PGPASSWORD=", CONTAINER,
            "psql", "-X", "-q", "-A", "-t", "-h", "/var/run/postgresql",
            "-p", "5432", "-U", USER, "-d", DATABASE, "-w",
            "-v", "ON_ERROR_STOP=1"]

def run_psql(args, *, timeout=8, capture=False, stdin_text=None):
    if stdin_text is None:
        stdin_text = ""
    return subprocess.run(psql_base() + args, input=stdin_text, text=True,
                          capture_output=capture, timeout=timeout, check=True)

def observe(query, *, timeout=3):
    return run_psql(["-c", query], timeout=timeout, capture=True).stdout.strip()

def wait_for(query, deadline_seconds, description):
    deadline = time.monotonic() + deadline_seconds
    last_error = ""
    while time.monotonic() < deadline:
        try:
            value = observe(query)
            if value:
                return value
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            last_error = str(exc)
        time.sleep(0.1)
    detail = f" Last observer error: {last_error}" if last_error else ""
    raise TimeoutError(f"Timed out waiting for {description}.{detail}")

def start_worker(sql_path, log_path):
    global WORKERS_STARTED
    log = open(log_path, "w+", encoding="utf-8")
    sql_input = open(sql_path, "rb")
    proc = subprocess.Popen(psql_base(), stdin=sql_input,
                            stdout=log, stderr=subprocess.STDOUT)
    proc._pelmeni_sql_input = sql_input
    CHILDREN.append((proc, log))
    WORKERS_STARTED = True
    return proc

def terminate_child(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)

def handle_termination(signum, _frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, handle_termination)
signal.signal(signal.SIGHUP, handle_termination)

def finish_workers(timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if all(proc.poll() is not None for proc, _ in CHILDREN):
            break
        time.sleep(0.1)
    else:
        raise TimeoutError(f"PostgreSQL worker exceeded {timeout_seconds}s; terminating sessions")
    failures = []
    for proc, log in CHILDREN:
        log.flush()
        if proc.returncode != 0:
            log.seek(0)
            failures.append(log.read())
    if failures:
        raise RuntimeError("A concurrent psql session failed:\n" + "\n".join(failures))

def terminate_test_sessions():
    # Terminate only the two named test backends, closing open transactions
    # even if terminating a docker exec client did not stop its server process.
    query = f"""SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE application_name IN ('{APP_A}', '{APP_B}')
        AND pid <> pg_backend_pid()"""
    try:
        run_psql(["-c", query], timeout=5, capture=True)
    except Exception as exc:
        print(f"WARNING: could not terminate named test backends: {exc}", file=sys.stderr)

def extract_rpc_result(log_path):
    found = []
    for line in log_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("RPC_RESULT:"):
            found.append(json.loads(line[len("RPC_RESULT:"):]))
    if len(found) != 1:
        raise RuntimeError(f"Expected one RPC_RESULT line in {log_path.name}, found {len(found)}")
    return found[0]

def assert_rpc_response(response, label):
    operation = response.get("operation")
    if (response.get("ok") is not True
            or not isinstance(operation, dict)
            or operation.get("requestId") != REQUEST_ID
            or operation.get("status") != "applied"
            or operation.get("result") != {
                "status": "applied", "upgradeId": "good-stove", "level": 1, "cost": 15
            }
            or not isinstance(response.get("state"), dict)
            or response.get("revision") != 1
            or response.get("protocolVersion") != 1
            or response.get("gameStateSchemaVersion") != 6):
        raise RuntimeError(f"Unexpected {label} RPC response: {response!r}")

def cleanup_fixture():
    global FIXTURE_CREATED
    if not FIXTURE_CREATED:
        return
    try:
        run_psql(["-v", "phase=cleanup"], timeout=8,
                 stdin_text=SQL_FILE.read_text(encoding="utf-8"))
        FIXTURE_CREATED = False
        print("Guarded cleanup removed only the marked synthetic fixture.")
    except Exception as exc:
        print(f"WARNING: automatic guarded cleanup failed: {exc}", file=sys.stderr)
        print("Manual local cleanup command:", file=sys.stderr)
        print(f"docker exec -i --env PGPASSWORD= {CONTAINER} psql -X -q -h /var/run/postgresql -p 5432 \\", file=sys.stderr)
        print(f"  -U postgres -d postgres -w -v ON_ERROR_STOP=1 -v phase=cleanup < '{SQL_FILE}'", file=sys.stderr)
        raise

try:
    if not SQL_FILE.is_file():
        raise FileNotFoundError(f"SQL scenario not found: {SQL_FILE}")

    if os.environ.get("DOCKER_HOST"):
        raise RuntimeError("Refusing DOCKER_HOST override; select a local Unix-socket Docker context")
    docker_endpoint = subprocess.run(
        ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
        text=True, capture_output=True, timeout=5, check=True).stdout.strip()
    if not docker_endpoint.startswith("unix://"):
        raise RuntimeError(f"Refusing non-local Docker endpoint: {docker_endpoint!r}")
    print(f"Confirmed local Docker Unix-socket endpoint: {docker_endpoint}.")

    docker_check = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}|{{.State.Health.Status}}", CONTAINER],
        text=True, capture_output=True, timeout=5, check=True)
    if docker_check.stdout.strip() != "true|healthy":
        raise RuntimeError(f"Refusing container that is not running and healthy: {docker_check.stdout.strip()!r}")
    print(f"Confirmed local container {CONTAINER} is running and healthy.")

    identity = observe(
        "SELECT current_database() || '|' || current_setting('server_version_num')",
        timeout=5)
    parts = identity.split("|")
    if len(parts) != 2 or parts[0] != DATABASE:
        raise RuntimeError(f"Refusing unexpected database identity: {identity!r}")
    try:
        server_version_num = int(parts[1])
    except ValueError as exc:
        raise RuntimeError(f"Invalid PostgreSQL version response: {identity!r}") from exc
    if not 170000 <= server_version_num < 180000:
        raise RuntimeError(f"Expected local PostgreSQL 17, got server_version_num={server_version_num}")
    print(f"Pinned local socket target {CONTAINER}:/var/run/postgresql:5432/{DATABASE}; PostgreSQL {server_version_num}.")

    run_psql(["-v", "phase=setup"], timeout=8,
             stdin_text=SQL_FILE.read_text(encoding="utf-8"))
    FIXTURE_CREATED = True

    TEMP_DIR = tempfile.TemporaryDirectory(prefix="pelmeni-concurrent-idem-retry-")
    work = pathlib.Path(TEMP_DIR.name)
    sql_a = work / "session-a.sql"
    sql_b = work / "session-b.sql"
    date_guard = f"""DO $guard$
DECLARE v_saved_day date;
BEGIN
  SELECT (game_state ->> 'dailyDate')::date INTO v_saved_day
  FROM public.player_state
  WHERE telegram_id = {FIXTURE_ID}
    AND game_state ->> 'concurrentIdempotentRetryFixture' = 'pelmeni-local-idempotent-retry-test-v1';
  IF v_saved_day IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'UTC')::date THEN
    RAISE EXCEPTION 'UTC date changed during idempotent concurrent retry test; rerun outside UTC midnight';
  END IF;
END
$guard$;
"""
    shared_prefix = "\\set ON_ERROR_STOP on\nSET ROLE service_role;\n"
    sql_a.write_text(shared_prefix + f"""SET application_name = '{APP_A}';
SET statement_timeout = '25000ms';
SET lock_timeout = '5000ms';
BEGIN;
SELECT 1 FROM public.player_state WHERE telegram_id = {FIXTURE_ID} FOR UPDATE;
SELECT pg_sleep(8);
{date_guard}
SELECT 'RPC_RESULT:' || public.economy_purchase_upgrade({FIXTURE_ID}, '{REQUEST_ID}', 'good-stove')::text;
COMMIT;
""", encoding="utf-8")
    sql_b.write_text(shared_prefix + f"""SET application_name = '{APP_B}';
SET statement_timeout = '30000ms';
SET lock_timeout = '20000ms';
BEGIN;
{date_guard}
SELECT 'RPC_RESULT:' || public.economy_purchase_upgrade({FIXTURE_ID}, '{REQUEST_ID}', 'good-stove')::text;
COMMIT;
""", encoding="utf-8")

    proc_a = start_worker(sql_a, work / "session-a.log")
    a_pid_text = wait_for(
        f"SELECT pid::text FROM pg_stat_activity WHERE application_name = '{APP_A}' "
        "AND state = 'active' AND query ILIKE '%pg_sleep(8)%'",
        10, "session A holding the profile row lock")
    a_pids = a_pid_text.splitlines()
    if len(a_pids) != 1 or not a_pids[0].isdigit():
        raise RuntimeError(f"Expected one PostgreSQL backend PID for A, got {a_pid_text!r}")
    a_backend_pid = int(a_pids[0])

    proc_b = start_worker(sql_b, work / "session-b.log")
    blocker_query = f"""
      SELECT b.pid::text || '|' || a.pid::text
      FROM pg_stat_activity AS b
      JOIN pg_stat_activity AS a ON a.pid = ANY(pg_blocking_pids(b.pid))
      WHERE b.application_name = '{APP_B}'
        AND b.wait_event_type = 'Lock'
        AND a.application_name = '{APP_A}'
    """
    blocker = wait_for(blocker_query, 6,
                       "session B blocked specifically by session A on a PostgreSQL lock")
    blocker_rows = blocker.splitlines()
    if len(blocker_rows) != 1 or "|" not in blocker_rows[0]:
        raise RuntimeError(f"Unexpected blocker PID result: {blocker!r}")
    b_pid_text, a_pid_text = blocker_rows[0].split("|", 1)
    if not b_pid_text.isdigit() or not a_pid_text.isdigit():
        raise RuntimeError(f"Invalid PostgreSQL backend PIDs: {blocker_rows[0]!r}")
    b_backend_pid, observed_a_pid = int(b_pid_text), int(a_pid_text)
    if observed_a_pid != a_backend_pid or b_backend_pid == a_backend_pid:
        raise RuntimeError(f"B was not blocked by the observed distinct A backend: {blocker_rows[0]}")
    print(f"Confirmed PostgreSQL lock wait: B pid={b_backend_pid} blocked by A pid={a_backend_pid}.")

    finish_workers(35)
    for proc, log in CHILDREN:
        proc._pelmeni_sql_input.close()
        log.close()
    CHILDREN.clear()

    result_a = extract_rpc_result(work / "session-a.log")
    result_b = extract_rpc_result(work / "session-b.log")
    assert_rpc_response(result_a, "A")
    assert_rpc_response(result_b, "B")
    if result_a != result_b:
        raise RuntimeError(f"Concurrent retry responses differ: A={result_a!r}, B={result_b!r}")
    print("Both independent RPC calls returned the same applied receipt and state.")

    run_psql(["-v", "phase=verify"], timeout=8,
             stdin_text=SQL_FILE.read_text(encoding="utf-8"))
    print("PASS: one purchase, one receipt, one revision increment, and exact persisted state verified.")
finally:
    for proc, log in CHILDREN:
        terminate_child(proc)
        try:
            proc._pelmeni_sql_input.close()
        except Exception:
            pass
        try:
            log.close()
        except Exception:
            pass
    CHILDREN.clear()
    if WORKERS_STARTED:
        terminate_test_sessions()
    try:
        cleanup_fixture()
    finally:
        if TEMP_DIR is not None:
            TEMP_DIR.cleanup()
PY

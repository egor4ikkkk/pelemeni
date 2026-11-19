#!/bin/sh
set -eu

# The embedded runner uses only the named local Supabase container and its
# PostgreSQL Unix socket; it does not require a host-installed psql.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SQL_FILE="$ROOT_DIR/tests/server-economy-concurrent-collect.sql"

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'docker is required; no database connection was attempted.' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'python3 is required; no database connection was attempted.' >&2
  exit 2
fi

exec python3 - "$SQL_FILE" <<'PY'
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

SQL_FILE = pathlib.Path(sys.argv[1]).resolve()
CONTAINER, USER, DATABASE = "supabase_db_supabase-local-test", "postgres", "postgres"
FIXTURE_ID = "9223372036854769901"
APP_A, APP_B = "pelmeni_collect_test_a", "pelmeni_collect_test_b"
REQUEST_A = "f1f1f1f1-1111-4111-8111-111111111111"
REQUEST_B = "f2f2f2f2-2222-4222-8222-222222222222"
FIXTURE_CREATED = False
CHILDREN = []
TEMP_DIR = None
WORKERS_STARTED = False

def psql_base():
    # Explicit Unix-socket directory and -w keep this inside the named
    # container and prevent a password prompt or TCP fallback.
    return ["docker", "exec", "-i", "--env", "PGPASSWORD=", CONTAINER, "psql", "-X", "-q",
            "-h", "/var/run/postgresql", "-p", "5432", "-U", USER, "-d", DATABASE,
            "-w", "-v", "ON_ERROR_STOP=1"]

def run_psql(args, *, timeout=8, capture=False, stdin_text=None):
    if stdin_text is None:
        stdin_text = ""
    return subprocess.run(psql_base() + args, input=stdin_text, text=True,
                          capture_output=capture, timeout=timeout, check=True)

def terminate_child(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)

def observe(query, *, timeout=3):
    result = run_psql(["-A", "-t", "-c", query], timeout=timeout, capture=True)
    return result.stdout.strip()

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
    log = open(log_path, "w", encoding="utf-8")
    sql_input = open(sql_path, "rb")
    proc = subprocess.Popen(psql_base(), stdin=sql_input,
                            stdout=log, stderr=subprocess.STDOUT)
    proc._pelmeni_sql_input = sql_input
    CHILDREN.append((proc, log))
    WORKERS_STARTED = True
    return proc

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
        raise TimeoutError(f"PostgreSQL worker exceeded {timeout_seconds}s; terminating connections")
    failures = []
    for proc, log in CHILDREN:
        log.flush()
        if proc.returncode != 0:
            log.seek(0)
            failures.append(log.read())
    if failures:
        raise RuntimeError("A concurrent psql session failed:\n" + "\n".join(failures))

def terminate_test_sessions():
    # Killing a docker CLI process alone is not guaranteed to kill the exec
    # process in the container. Terminate only the two uniquely named test
    # backends so PostgreSQL closes their sessions and rolls back open txns.
    query = """SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE application_name IN ('pelmeni_collect_test_a', 'pelmeni_collect_test_b')
        AND pid <> pg_backend_pid()"""
    try:
        run_psql(["-A", "-t", "-c", query], timeout=5, capture=True)
    except Exception as exc:
        print(f"WARNING: could not terminate named test backends: {exc}", file=sys.stderr)

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
        print(f"WARNING: automatic cleanup failed: {exc}", file=sys.stderr)
        print("Manual guarded cleanup command:", file=sys.stderr)
        print(f"docker exec -i {CONTAINER} psql -X -h /var/run/postgresql -p 5432 \\", file=sys.stderr)
        print(f"  -U postgres -d postgres -w -v ON_ERROR_STOP=1 -v phase=cleanup < '{SQL_FILE}'", file=sys.stderr)
        raise

try:
    if not SQL_FILE.is_file():
        raise FileNotFoundError(f"SQL scenario not found: {SQL_FILE}")

    docker_check = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}|{{.State.Health.Status}}", CONTAINER],
        text=True, capture_output=True, timeout=5, check=True)
    if docker_check.stdout.strip() != "true|healthy":
        raise RuntimeError(f"Refusing container that is not running and healthy: {docker_check.stdout.strip()!r}")
    print(f"Confirmed local container {CONTAINER} is running and healthy.")

    # The fixed container name plus explicit in-container Unix socket, port,
    # user, and database prevent remote/TCP destinations. No password is read
    # or passed; -w forbids an interactive password prompt.
    target = observe(
        "SELECT current_database() || '|' || current_setting('server_version_num')",
        timeout=5,
    )
    parts = target.split("|")
    if len(parts) != 2 or parts[0] != DATABASE:
        raise RuntimeError(f"Refusing unexpected database identity: {target!r}")
    try:
        server_version_num = int(parts[1])
    except ValueError as exc:
        raise RuntimeError(f"Invalid PostgreSQL version response: {target!r}") from exc
    if not 170000 <= server_version_num < 180000:
        raise RuntimeError(f"Expected local PostgreSQL 17, got server_version_num={server_version_num}")
    print(f"Pinned local socket target: {CONTAINER}:/var/run/postgresql:5432/{DATABASE}; server_version_num={server_version_num}.")

    run_psql(["-v", "phase=setup"], timeout=8,
             stdin_text=SQL_FILE.read_text(encoding="utf-8"))
    FIXTURE_CREATED = True

    TEMP_DIR = tempfile.TemporaryDirectory(prefix="pelmeni-concurrent-collect-")
    work = pathlib.Path(TEMP_DIR.name)
    sql_a = work / "session-a.sql"
    sql_b = work / "session-b.sql"
    sql_a.write_text(f"""\\set ON_ERROR_STOP on
SET ROLE service_role;
SET application_name = '{APP_A}';
SET statement_timeout = '15000ms';
SET lock_timeout = '5000ms';
BEGIN;
SELECT 1 FROM public.player_state WHERE telegram_id = {FIXTURE_ID} FOR UPDATE;
SELECT pg_sleep(8);
SELECT public.economy_collect_batch({FIXTURE_ID}, '{REQUEST_A}', 'concurrent-collect-one-batch');
COMMIT;
""", encoding="utf-8")
    sql_b.write_text(f"""\\set ON_ERROR_STOP on
SET ROLE service_role;
SET application_name = '{APP_B}';
SET statement_timeout = '20000ms';
SET lock_timeout = '15000ms';
BEGIN;
SELECT public.economy_collect_batch({FIXTURE_ID}, '{REQUEST_B}', 'concurrent-collect-one-batch');
COMMIT;
""", encoding="utf-8")

    proc_a = start_worker(sql_a, work / "session-a.log")
    a_sleep_query = (
        f"SELECT 1 FROM pg_stat_activity WHERE application_name = '{APP_A}' "
        "AND state = 'active' AND query ILIKE '%pg_sleep(8)%'"
    )
    wait_for(a_sleep_query, 10, "session A holding the player row lock")

    proc_b = start_worker(sql_b, work / "session-b.log")
    exact_blocker_query = f"""
      SELECT b.pid::text || '|' || a.pid::text
      FROM pg_stat_activity AS b
      JOIN pg_stat_activity AS a ON a.pid = ANY(pg_blocking_pids(b.pid))
      WHERE b.application_name = '{APP_B}'
        AND b.wait_event_type = 'Lock'
        AND a.application_name = '{APP_A}'
    """
    blocker = wait_for(exact_blocker_query, 5,
                       "session B blocked specifically by session A on a PostgreSQL lock")
    b_pid, a_pid = blocker.split("|")
    if int(a_pid) == int(b_pid):
        raise RuntimeError(f"Unexpected blocker/session PIDs: {blocker}")
    print(f"Confirmed lock contention: B pid={b_pid} is blocked by A pid={a_pid} ({APP_A}).")

    finish_workers(25)
    for proc, log in CHILDREN:
        proc._pelmeni_sql_input.close()
        log.close()
    CHILDREN.clear()
    print("RPC responses from both independent PostgreSQL sessions:")
    print((work / "session-a.log").read_text(encoding="utf-8"))
    print((work / "session-b.log").read_text(encoding="utf-8"))

    run_psql(["-v", "phase=verify"], timeout=8,
             stdin_text=SQL_FILE.read_text(encoding="utf-8"))
    print("PASS: receipt identities and outcomes, one payout, one revision increment, both-pot state, and timers verified.")
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

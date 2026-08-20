#!/usr/bin/env bash
# diagnose-webserver-bug.sh
# Detects the "api/ragflow_server.py not restarted after infinity 120s timeout" bug.
#
# Usage:
#   ./diagnose-webserver-bug.sh [ragflow-container]
#
# Default container name: docker-ragflow-cpu-1
# Override with: ./diagnose-webserver-bug.sh my-ragflow-container
#
# Exit codes:
#   0  Healthy (frontend backend reachable, main process running)
#   1  Broken (one or more checks failed)
#   2  Could not run checks (container not running, no docker, etc.)

set -u

CONTAINER="${1:-docker-ragflow-cpu-1}"
API_PORT="${API_PORT:-9380}"
FRONTEND_PORT="${FRONTEND_PORT:-80}"

# ANSI colors (only when stdout is a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
hdr()  { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"; }

# --- preconditions ---
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found in PATH"; exit 2
fi
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "container '$CONTAINER' not found"; docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null; exit 2
fi

# --- run checks, accumulate failures ---
FAILED=0

hdr "1. container is running"
STATE=$(docker inspect --format='{{.State.Running}}' "$CONTAINER")
if [ "$STATE" = "true" ]; then
  ok "$CONTAINER is running"
else
  fail "$CONTAINER is not running (state=$STATE)"
  exit 2
fi

hdr "2. main API server is alive on port $API_PORT"
# 1) Inside the container, look for the python process
MAIN_PID=""
if docker exec "$CONTAINER" bash -c "ps -ef | grep -v grep | grep -q 'api/ragflow_server.py'"; then
  MAIN_PID=$(docker exec "$CONTAINER" bash -c "ps -ef | grep -v grep | grep 'api/ragflow_server.py' | awk '{print \$2}' | head -1")
  ok "python3 api/ragflow_server.py is running (PID $MAIN_PID)"
  MAIN_RUNNING=1
else
  fail "python3 api/ragflow_server.py is NOT running inside the container"
  warn "admin_server.py, task_executor.py, sync_data_source.py may still be running, but the main API on port $API_PORT is down"
  FAILED=1
  MAIN_RUNNING=0
fi

# 2) Inside the container, was the entrypoint loop wrapper alive?
# Detect a <defunct> bash as evidence the wrapper exited.
DEFUNCT=$(docker exec "$CONTAINER" bash -c "ps -ef | awk '\$8 ~ /<defunct>/' | wc -l" 2>/dev/null | tr -d ' \r\n')
if [ "${DEFUNCT:-0}" -gt 0 ]; then
  fail "$DEFUNCT <defunct> process(es) found (entrypoint subshell likely exited)"
  FAILED=1
else
  ok "no <defunct> bash processes"
fi

# 3) Local HTTP check
if command -v curl >/dev/null 2>&1; then
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$API_PORT/" 2>/dev/null)
  HTTP="${HTTP:-000}"
  if [ "$HTTP" = "000" ]; then
    fail "http://127.0.0.1:$API_PORT/ is unreachable (HTTP 000 = connection refused)"
    FAILED=1
  else
    ok "http://127.0.0.1:$API_PORT/ responded (HTTP $HTTP)"
  fi
else
  warn "curl not available, skipping local HTTP check"
fi

hdr "3. entrypoint loop log evidence"
# "RAGFlow python server started." is printed AFTER the python exits, by the loop wrapper.
# A healthy setup restarts the dead python, so this message should appear at least once.
LOGS=$(docker logs "$CONTAINER" 2>&1 || true)
ATTEMPTS=$(printf '%s' "$LOGS" | grep -c 'Attempt to start RAGFlow python server' || true)
STARTED=$(printf '%s' "$LOGS" | grep -c 'RAGFlow python server started' || true)
UNHEALTHY=$(printf '%s' "$LOGS" | grep -c 'Infinity .* is unhealthy in 120s' || true)
SERVER_READY=$(printf '%s' "$LOGS" | grep -c 'RAGFlow server is ready' || true)

printf '  attempts to start main server: %s\n' "$ATTEMPTS"
printf '  "RAGFlow python server started." (post-crash) markers: %s\n' "$STARTED"
printf '  "Infinity is unhealthy in 120s" errors: %s\n' "$UNHEALTHY"
printf '  "RAGFlow server is ready" messages: %s\n' "$SERVER_READY"

if [ "$MAIN_RUNNING" -eq 0 ] && [ "$ATTEMPTS" -ge 1 ] && [ "$STARTED" -eq 0 ] && [ "$UNHEALTHY" -ge 1 ]; then
  fail "entrypoint loop died after first crash: $ATTEMPTS attempt(s), $STARTED post-crash marker(s), $UNHEALTHY infinity timeout(s)"
  warn "the main API server's while-true loop did not restart the python process"
  FAILED=1
elif [ "$MAIN_RUNNING" -eq 1 ] && [ "$ATTEMPTS" -ge 1 ] && [ "$STARTED" -eq 0 ] && [ "$UNHEALTHY" -ge 1 ]; then
  warn "historical evidence of the bug (loop died once, then container was restarted)"
  warn "if this is a fresh user-reported bug, ask them to re-run the script after a clean restart"
elif [ "$SERVER_READY" -ge 1 ]; then
  ok "main server has reported 'RAGFlow server is ready'"
else
  warn "main server has not yet reported 'RAGFlow server is ready' (still initializing)"
fi

hdr "4. nginx is serving the frontend on port $FRONTEND_PORT"
if command -v curl >/dev/null 2>&1; then
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$FRONTEND_PORT/" 2>/dev/null)
  HTTP="${HTTP:-000}"
  if [ "$HTTP" = "200" ]; then
    ok "frontend served HTTP 200 (frontend up, but this does not imply backend health)"
  else
    warn "frontend returned HTTP $HTTP on port $FRONTEND_PORT"
  fi
fi

# --- summary ---
hdr "summary"
if [ "$FAILED" -eq 0 ]; then
  printf '%sHEALTHY%s — main API server is running and reachable.\n' "$GREEN" "$RESET"
  exit 0
else
  printf '%sBROKEN%s — main API server is missing. Symptoms match the bug:\n' "$RED" "$RESET"
  printf '  - infinity timed out at 120s on cold start\n'
  printf '  - api/ragflow_server.py crashed once\n'
  printf '  - entrypoint.sh while-true loop wrapper exited instead of retrying\n'
  printf '  - nginx still serves the frontend on port %s, but the API on port %s is unreachable\n' "$FRONTEND_PORT" "$API_PORT"
  printf '\n'
  printf 'Suggested recovery:\n'
  printf '  %sdocker restart %s%s\n' "$BOLD" "$CONTAINER" "$RESET"
  printf '\n'
  exit 1
fi

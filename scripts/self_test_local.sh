#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG_BIN="${ZIG:-}"
if [[ -z "$ZIG_BIN" ]]; then
  if [[ -x "$ROOT/../zig-x86_64-linux-0.16.0/zig" ]]; then
    ZIG_BIN="$ROOT/../zig-x86_64-linux-0.16.0/zig"
  else
    ZIG_BIN="zig"
  fi
fi

ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/../zig-cache-global}"
EXAMPLE_PORT="${SWS_EXAMPLE_PORT:-9090}"
BENCH_PORT="${SWS_BENCH_PORT:-19090}"
SERVER_PID=""

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'self_test_local.sh must run on Linux because sws depends on io_uring.\n' >&2
  exit 1
fi

require_cmd curl
require_cmd ss

log "environment"
uname -a || true
printf 'cpu cores: '
nproc || true
if command -v free >/dev/null 2>&1; then
  free -h || true
fi
printf 'ulimit -n: %s\n' "$(ulimit -n)"
sysctl fs.nr_open net.core.somaxconn net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse 2>/dev/null || true

# 修改原因：没有独立压测机时，先记录本机 fd/端口限制，避免把环境瓶颈误判成框架瓶颈。
nofile="$(ulimit -n)"
if [[ "$nofile" =~ ^[0-9]+$ ]] && (( nofile < 4096 )); then
  printf '\nwarning: ulimit -n is %s; this is fine for smoke tests, but too low for large connection tests.\n' "$nofile"
fi

if ss -ltnp 2>/dev/null | grep -E ":(${EXAMPLE_PORT}|${BENCH_PORT})\\b" >/dev/null; then
  printf '\nport %s or %s is already in use; stop the old sws/im-bench process first.\n' "$EXAMPLE_PORT" "$BENCH_PORT" >&2
  ss -ltnp 2>/dev/null | grep -E ":(${EXAMPLE_PORT}|${BENCH_PORT})\\b" >&2 || true
  exit 1
fi

log "zig build"
"$ZIG_BIN" build --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"

log "zig build test"
"$ZIG_BIN" build test --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"

log "curl smoke test"
server_log="$(mktemp "${TMPDIR:-/tmp}/sws-example.XXXXXX.log")"
body_file="$(mktemp "${TMPDIR:-/tmp}/sws-body.XXXXXX")"
headers_file="$(mktemp "${TMPDIR:-/tmp}/sws-headers.XXXXXX")"
./zig-out/bin/sws >"$server_log" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 30); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    printf 'sws example exited early. log follows:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
  if curl -fsS --max-time 2 -D "$headers_file" "http://127.0.0.1:${EXAMPLE_PORT}/hello" -o "$body_file" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if ! grep -q 'Hello from worker' "$body_file"; then
  printf 'unexpected /hello response:\n' >&2
  cat "$headers_file" >&2 || true
  cat "$body_file" >&2 || true
  printf '\nserver log:\n' >&2
  cat "$server_log" >&2 || true
  exit 1
fi

cat "$headers_file"
cat "$body_file"
printf '\n'
cleanup
SERVER_PID=""

log "local benchmark"
"$ZIG_BIN" build run-im-bench --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"

log "summary"
printf 'self-test passed on this server.\n'
printf 'note: this validates correctness and small local load only; client and server share the same machine.\n'

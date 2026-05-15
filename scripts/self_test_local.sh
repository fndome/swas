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

curl_expect() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local data="${4:-}"

  : >"$headers_file"
  : >"$body_file"
  if [[ -n "$data" ]]; then
    curl -fsS --max-time 3 -X "$method" -H 'Connection: close' -H 'Content-Type: application/json' --data "$data" \
      -D "$headers_file" "http://127.0.0.1:${EXAMPLE_PORT}${path}" -o "$body_file"
  else
    # 修改原因：方法矩阵会连续打开多条 curl 连接，显式关闭连接可避免自测被小连接池容量干扰。
    curl -fsS --max-time 3 -X "$method" -H 'Connection: close' \
      -D "$headers_file" "http://127.0.0.1:${EXAMPLE_PORT}${path}" -o "$body_file"
  fi

  if ! grep -Fq "$expected" "$body_file"; then
    printf 'unexpected %s %s response, expected body fragment %s:\n' "$method" "$path" "$expected" >&2
    cat "$headers_file" >&2 || true
    cat "$body_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
  if ! grep -iq '^Content-Type: application/json' "$headers_file"; then
    printf 'unexpected %s %s content-type:\n' "$method" "$path" >&2
    cat "$headers_file" >&2 || true
    exit 1
  fi
  # 修改原因：给关闭 CQE 一个事件循环周期，避免方法矩阵测试变成短连接回收压力测试。
  sleep 0.1
}

keep_alive_reuse_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-keepalive.XXXXXX")"

  (
    : >"$out_file"
    exec 3<>"/dev/tcp/127.0.0.1/${EXAMPLE_PORT}"
    # 修改原因：同一条 keep-alive 连接先发带 body 的 POST，再发无 body 的 GET，可覆盖 per-request Content-Length 残留问题。
    printf 'POST /missing HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\n{"a":1}' >&3
    read_http_response "$out_file"
    printf 'GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    timeout 3 cat <&3 >>"$out_file" || true
    exec 3<&-
    exec 3>&-
  ) || {
    printf 'failed to run keep-alive reuse request\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  }

  if ! grep -Fq 'Not Found' "$out_file" || ! grep -Fq 'Hello from worker' "$out_file"; then
    printf 'unexpected keep-alive reuse response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

read_http_response() {
  local out_file="$1"
  local content_length=0
  local saw_blank=0
  local line clean

  while IFS= read -r -t 3 line <&3; do
    printf '%s\n' "$line" >>"$out_file"
    clean="${line%$'\r'}"
    if [[ "$clean" =~ ^[Cc]ontent-[Ll]ength:[[:space:]]*([0-9]+) ]]; then
      content_length="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$clean" ]]; then
      saw_blank=1
      break
    fi
  done

  if (( saw_blank == 0 )); then
    return 1
  fi
  if (( content_length > 0 )); then
    dd bs=1 count="$content_length" <&3 >>"$out_file" 2>/dev/null
    printf '\n' >>"$out_file"
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
require_cmd timeout

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
  if curl -fsS --max-time 2 -H 'Connection: close' -D "$headers_file" "http://127.0.0.1:${EXAMPLE_PORT}/hello" -o "$body_file" 2>/dev/null; then
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

log "HTTP method JSON tests"
# 修改原因：覆盖 GET/POST/PUT/PATCH/DELETE，避免只测 GET 冒烟时漏掉 body 读取和方法路由问题。
curl_expect GET /http-method '"method":"GET"'
curl_expect DELETE /http-method '"method":"DELETE"'
curl_expect POST /http-method '"body":{"post":true}' '{"post":true}'
curl_expect PUT /http-method '"body":{"put":true}' '{"put":true}'
curl_expect PATCH /http-method '"body":{"patch":true}' '{"patch":true}'

log "keep-alive reuse request test"
keep_alive_reuse_expect

cleanup
SERVER_PID=""

log "local benchmark"
"$ZIG_BIN" build run-im-bench --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"

log "summary"
printf 'self-test passed on this server.\n'
printf 'note: this validates correctness and small local load only; client and server share the same machine.\n'

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
BENCH_OPTIMIZE="${SWS_BENCH_OPTIMIZE:-ReleaseFast}"
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

keep_alive_reuse_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-keepalive.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]

def read_response(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("connection closed before headers")
        data.extend(chunk)
    head, rest = bytes(data).split(b"\r\n\r\n", 1)
    content_length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            content_length = int(line.split(b":", 1)[1].strip())
    while len(rest) < content_length:
        chunk = sock.recv(content_length - len(rest))
        if not chunk:
            raise RuntimeError("connection closed before body")
        rest += chunk
    return head + b"\r\n\r\n" + rest[:content_length]

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：同一条 keep-alive 连接先发带 body 的 POST，再发无 body 的 GET，可覆盖 per-request Content-Length 残留问题。
    sock.sendall(
        b'POST /missing HTTP/1.1\r\n'
        b'Host: localhost\r\n'
        b'Content-Type: application/json\r\n'
        b'Content-Length: 7\r\n'
        b'Connection: keep-alive\r\n'
        b'\r\n'
        b'{"a":1}'
    )
    first = read_response(sock)
    sock.sendall(b'GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
    chunks = [read_response(sock)]
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(first + b"\n" + b"".join(chunks))
PY
  then
    printf 'failed to run keep-alive reuse request\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq 'Not Found' "$out_file" || ! grep -Fq 'Hello from worker' "$out_file"; then
    printf 'unexpected keep-alive reuse response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

split_header_body_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-split-body.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
out_path = sys.argv[2]

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：请求头跨 TCP 分片且 body 另一次到达时，服务端必须保留重组后的完整请求行用于路由。
    sock.sendall(b'POST /htt')
    time.sleep(0.05)
    sock.sendall(
        b'p-method HTTP/1.1\r\n'
        b'Host: localhost\r\n'
        b'Content-Type: application/json\r\n'
        b'Content-Length: 7\r\n'
        b'Connection: close\r\n'
        b'\r\n'
    )
    time.sleep(0.05)
    sock.sendall(b'{"a":1}')
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'split header/body request did not close cleanly:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq '"method":"POST"' "$out_file" || ! grep -Fq '"body":{"a":1}' "$out_file"; then
    printf 'unexpected split header/body response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

pipelined_extra_bytes_close_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-pipeline.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]
payload = (
    b'POST /http-method HTTP/1.1\r\n'
    b'Host: localhost\r\n'
    b'Content-Type: application/json\r\n'
    b'Content-Length: 7\r\n'
    b'Connection: keep-alive\r\n'
    b'\r\n'
    b'{"a":1}'
    b'GET /hello HTTP/1.1\r\n'
    b'Host: localhost\r\n'
    b'Connection: close\r\n'
    b'\r\n'
)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：当前服务端一次只处理一个 HTTP 请求；同一 read buffer 里若带尾随请求，必须关闭连接避免客户端等待被丢弃的第二响应。
    sock.sendall(payload)
    chunks = []
    while True:
        try:
            chunk = sock.recv(4096)
        except TimeoutError:
            sys.exit(2)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'pipelined request did not close after first response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq '"method":"POST"' "$out_file" || ! grep -iq '^Connection: close' "$out_file"; then
    printf 'unexpected pipelined request response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

invalid_content_length_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-bad-cl.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]
payload = (
    b'POST /http-method HTTP/1.1\r\n'
    b'Host: localhost\r\n'
    b'Content-Type: application/json\r\n'
    b'Content-Length: nope\r\n'
    b'Connection: keep-alive\r\n'
    b'\r\n'
    b'{"bad":true}'
)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：非法 Content-Length 必须被协议层拒绝，不能让业务 handler 当成无 body 请求继续处理。
    sock.sendall(payload)
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'invalid Content-Length request did not close cleanly:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq 'HTTP/1.1 400 Bad Request' "$out_file" || ! grep -iq '^Connection: close' "$out_file"; then
    printf 'unexpected invalid Content-Length response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

duplicate_content_length_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-duplicate-cl.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]
payload = (
    b'POST /http-method HTTP/1.1\r\n'
    b'Host: localhost\r\n'
    b'Content-Type: application/json\r\n'
    b'Content-Length: 7\r\n'
    b'Content-Length: 3\r\n'
    b'Connection: keep-alive\r\n'
    b'\r\n'
    b'{"a":1}'
)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：重复 Content-Length 会让 body 边界不唯一，协议层必须拒绝而不是只取第一个值。
    sock.sendall(payload)
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'duplicate Content-Length request did not close cleanly:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq 'HTTP/1.1 400 Bad Request' "$out_file" || ! grep -iq '^Connection: close' "$out_file"; then
    printf 'unexpected duplicate Content-Length response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

malformed_request_line_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-bad-request-line.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]
payload = (
    b'GET /hello\r\n'
    b'Host: localhost\r\n'
    b'Connection: keep-alive\r\n'
    b'\r\n'
)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：请求行缺少 HTTP 版本时必须协议层拒绝，不能被普通 /hello handler 处理成 200。
    sock.sendall(payload)
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'malformed request line did not close cleanly:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq 'HTTP/1.1 400 Bad Request' "$out_file" || ! grep -iq '^Connection: close' "$out_file"; then
    printf 'unexpected malformed request line response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

malformed_header_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-bad-header.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]
payload = (
    b'GET /hello HTTP/1.1\r\n'
    b'Bad Header: nope\r\n'
    b'Host: localhost\r\n'
    b'Connection: keep-alive\r\n'
    b'\r\n'
)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：header 名含空格是畸形 HTTP 头，不能被忽略后让 /hello 正常返回 200。
    sock.sendall(payload)
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'malformed header request did not close cleanly:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq 'HTTP/1.1 400 Bad Request' "$out_file" || ! grep -iq '^Connection: close' "$out_file"; then
    printf 'unexpected malformed header response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

transfer_encoding_expect() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sws-transfer-encoding.XXXXXX")"

  if ! python3 - "$EXAMPLE_PORT" "$out_file" <<'PY'
import socket
import sys

port = int(sys.argv[1])
out_path = sys.argv[2]
payload = (
    b'POST /http-method HTTP/1.1\r\n'
    b'Host: localhost\r\n'
    b'Transfer-Encoding: chunked\r\n'
    b'Connection: keep-alive\r\n'
    b'\r\n'
    b'7\r\n{"a":1}\r\n0\r\n\r\n'
)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    # 修改原因：服务端目前不支持 chunked body，必须在协议层拒绝，避免分块数据污染 keep-alive 后续请求。
    sock.sendall(payload)
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

with open(out_path, "wb") as f:
    f.write(b"".join(chunks))
PY
  then
    printf 'Transfer-Encoding request did not close cleanly:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi

  if ! grep -Fq 'HTTP/1.1 400 Bad Request' "$out_file" || ! grep -iq '^Connection: close' "$out_file"; then
    printf 'unexpected Transfer-Encoding response:\n' >&2
    cat "$out_file" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
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
require_cmd timeout
require_cmd python3

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

log "split header/body request test"
split_header_body_expect

log "pipelined extra bytes close test"
pipelined_extra_bytes_close_expect

log "invalid Content-Length test"
invalid_content_length_expect

log "duplicate Content-Length test"
duplicate_content_length_expect

log "malformed request line test"
malformed_request_line_expect

log "malformed header test"
malformed_header_expect

log "Transfer-Encoding rejection test"
transfer_encoding_expect

cleanup
SERVER_PID=""

log "local benchmark"
# 修改原因：前面的 build/test 保留 Debug 覆盖正确性；benchmark 默认用 ReleaseFast，避免把 Debug 构建开销误读成框架吞吐上限。
"$ZIG_BIN" build -Doptimize="$BENCH_OPTIMIZE" run-im-bench --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"

log "summary"
printf 'self-test passed on this server.\n'
printf 'note: this validates correctness and small local load only; client and server share the same machine.\n'
printf 'benchmark mode: optimize=%s, conns=%s, reqs/conn=%s.\n' "$BENCH_OPTIMIZE" "${SWS_BENCH_CONNS:-50}" "${SWS_BENCH_REQS_PER_CONN:-100}"

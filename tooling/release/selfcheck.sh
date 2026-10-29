#!/usr/bin/env bash
# 上线自检：7 项，全绿才算可以对外发布。
#
#   bash tooling/release/selfcheck.sh https://dl.example.com [安装包文件名]
#
# 不传安装包名时，从 updates/android/latest.json 里取。
# 退出码 0 = 全绿；1 = 有失败项。
set -u

BASE="${1:-}"
PACKAGE="${2:-}"
FAILED=0
PASS=0

line() { printf '%-6s %-34s %s\n' "$1" "$2" "$3"; }
ok()   { PASS=$((PASS + 1)); line "PASS" "$1" "${2:-}"; }
bad()  { FAILED=$((FAILED + 1)); line "FAIL" "$1" "$2"; }
skip() { line "SKIP" "$1" "$2"; }

if [ -z "$BASE" ]; then
  echo "用法：bash selfcheck.sh <https://域名> [安装包文件名]" >&2
  exit 2
fi
BASE="${BASE%/}"

echo "自检目标：$BASE"
echo

# 1. HTTPS（仅临时验证时用 SELFCHECK_LOCAL=1 豁免 http；生产必须 https）
case "$BASE" in
  https://*) ok "HTTPS 传输" "scheme=https" ;;
  http://*)
    if [ "${SELFCHECK_LOCAL:-}" = "1" ]; then
      ok "HTTPS 传输（临时豁免）" "$BASE；客户端正式版只接受 https，此处仅内网/IP 验证"
    else
      bad "HTTPS 传输" "当前是 $BASE；客户端只接受 https（临时验证可加 SELFCHECK_LOCAL=1）"
    fi
    ;;
  *) bad "HTTPS 传输" "当前是 $BASE；客户端只接受 https 下载地址" ;;
esac

# 2. 健康检查
body="$(curl -sS -m 10 "$BASE/health" 2>/dev/null || true)"
case "$body" in
  *'"ok":true'*) ok "健康检查 /health" "200 ok" ;;
  *)             bad "健康检查 /health" "${body:-无响应}" ;;
esac

# 找清单
manifest="$BASE/updates/android/latest.json"
manifest_body="$(curl -sS -m 10 "$manifest" 2>/dev/null || true)"
if [ -z "$PACKAGE" ] && [ -n "$manifest_body" ]; then
  PACKAGE="$(printf '%s' "$manifest_body" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's|.*/||')"
fi
if [ -z "$PACKAGE" ]; then
  bad "安装包定位" "没有传入包名，latest.json 里也取不到"
  echo
  echo "通过 $PASS 项，失败 $FAILED 项"
  exit 1
fi
PACKAGE_URL="$BASE/updates/android/$PACKAGE"

# 3. 匿名下载
headers="$(curl -sS -m 20 -D - -o /dev/null -r 0-99 "$PACKAGE_URL" 2>/dev/null || true)"
status="$(printf '%s' "$headers" | head -1 | awk '{print $2}')"
case "$status" in
  200|206) ok "安装包可匿名下载" "HTTP $status  $(printf '%s' "$headers" | grep -i '^content-length' | tr -d '\r' | head -1)" ;;
  *)       bad "安装包可匿名下载" "HTTP ${status:-无响应}（403 DownloadForbidden 说明还在用 COS 默认域名）" ;;
esac

# 4. Range
if printf '%s' "$headers" | grep -qi '^content-range: bytes 0-99/'; then
  ok "Range 请求" "$(printf '%s' "$headers" | grep -i '^content-range' | tr -d '\r')"
else
  bad "Range 请求" "缺少 content-range: bytes 0-99/…，下载器无法续传"
fi

# 5. ETag / 304
etag="$(printf '%s' "$headers" | grep -i '^etag:' | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//')"
if [ -n "$etag" ]; then
  revalidate="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -H "If-None-Match: $etag" -r 0-99 "$PACKAGE_URL" 2>/dev/null || true)"
  if [ "$revalidate" = "304" ]; then
    ok "ETag 复验" "304（$etag）"
  else
    bad "ETag 复验" "带 If-None-Match 得到 HTTP $revalidate，期望 304"
  fi
else
  bad "ETag 复验" "响应里没有 ETag"
fi

# 6. 防护（根目录 / 异常路径 / 后缀）
#    注意：标准 URL 解析器会把 `..` 归一化掉（%2e%2e 也算），所以穿越探针只断言「不被服务」，
#    真正能被断言的是点文件（.env）与非法后缀。
root_code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
dot_code="$(curl -sS -m 10 --path-as-is -o /dev/null -w '%{http_code}' "$BASE/updates/.env" 2>/dev/null || true)"
trav_code="$(curl -sS -m 10 --path-as-is -o /dev/null -w '%{http_code}' "$BASE/updates/%2e%2e/%2e%2e/etc/passwd" 2>/dev/null || true)"
ext_code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$BASE/updates/android/probe.txt" 2>/dev/null || true)"
if [ "$root_code" = "403" ] && [ "$dot_code" = "400" ] && [ "$ext_code" = "415" ] && [ "$trav_code" != "200" ]; then
  ok "防护（目录/点文件/后缀）" "403 / 400 / 415（穿越探针 $trav_code）"
else
  bad "防护（目录/点文件/后缀）" "根目录=$root_code(期望403) 点文件=$dot_code(期望400) 穿越=$trav_code(不应200) 后缀=$ext_code(期望415)"
fi

# 7. 清单一致性
if [ -z "$manifest_body" ]; then
  bad "清单可读" "$manifest 取不到"
else
  m_sha="$(printf '%s' "$manifest_body" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  m_size="$(printf '%s' "$manifest_body" | sed -n 's/.*"size"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
  r_size="$(printf '%s' "$headers" | grep -i '^content-range' | tr -d '\r' | sed 's|.*/||')"
  if [ -n "$m_sha" ] && [ -n "$m_size" ] && [ "$m_size" = "$r_size" ]; then
    ok "清单与包一致" "size=$m_size sha256=${m_sha%"${m_sha#????????}"}…"
  else
    bad "清单与包一致" "清单 size=${m_size:-空} 服务器 size=${r_size:-空}"
  fi
fi

echo
echo "通过 $PASS 项，失败 $FAILED 项"
[ "$FAILED" -eq 0 ] || exit 1

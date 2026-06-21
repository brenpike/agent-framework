#!/usr/bin/env bash
#
# Script-triple test for the enable-brood-remote engine
# plugin/skills/enable-brood-remote/scripts/rc-brood.sh.
#
# Drives the engine end-to-end against DISPOSABLE throwaway git checkouts (so its
# `git rev-parse --show-toplevel` resolves a tmp root) with a FAKE `tmux` first on PATH so the
# test controls session liveness and captures every `send-keys` payload WITHOUT delivering a
# keystroke anywhere. Mirrors tools/test_seed_hive.sh conventions: hermetic `mktemp -d` workdir,
# EXIT-trap cleanup, tmp HOME, SKIP-clean when jq/git absent, explicit PASS/FAIL counters,
# non-zero exit on any failed assertion. Writes nothing into this repo's tree.
#
# LOCKED INVARIANTS (each a PASS/FAIL case):
#   1. All-alive fan-out: N strains, all sessions alive → one `/rc <slug>` + one Enter per strain,
#      correct sanitized slug per strain, exit 0, summary applied=N.
#   2. Fail-soft on dead session: one strain's session NOT alive → that strain skipped, the OTHER
#      strains still get their send-keys, exit 0, summary shows the skip.
#   3. Pre-flight blocker → ZERO send-keys: (a) bad/empty/traversal brood-id, (b) missing manifest
#      → `blocker:` on stderr, exit 1, send-keys log EMPTY.
#   4. Injection-safety: a hostile strain name (`;`, `$()`, backticks, spaces, slashes) → the bytes
#      sent are ONLY the sanitized `/rc <slug>` literal; no shell metacharacter reaches send-keys and
#      no side-effect file the hostile name tried to create exists.
#   5. Summary correctness: applied/skipped/failed counts match the scenario.
#
# Usage:
#   ./tools/test_rc_brood.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENGINE="$REPO_ROOT/plugin/skills/enable-brood-remote/scripts/rc-brood.sh"
FIXTURES="$REPO_ROOT/tests/brood"

[ -f "$ENGINE" ] || { echo "FAIL: engine missing: $ENGINE" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq is required to run this suite"  >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git is required to run this suite" >&2; exit 0; }

PASS_COUNT=0
FAIL_COUNT=0
pass()   { echo "PASS [$1] $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
failed() { echo "FAIL [$1] $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# assert_eq <case> <expected> <actual> [msg]
assert_eq() {
  local case_name="$1" expected="$2" actual="$3" msg="${4:-}"
  if [ "$expected" = "$actual" ]; then
    pass "$case_name" "${msg:+$msg }(== '$expected')"
  else
    failed "$case_name" "${msg:+$msg }expected '$expected', got '$actual'"
  fi
}

# assert_contains <case> <needle> <haystack> [msg]
assert_contains() {
  local case_name="$1" needle="$2" haystack="$3" msg="${4:-}"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$case_name" "${msg:+$msg }(contains '$needle')"
  else
    failed "$case_name" "${msg:+$msg }missing '$needle'"
  fi
}

# assert_not_contains <case> <needle> <haystack> [msg]
assert_not_contains() {
  local case_name="$1" needle="$2" haystack="$3" msg="${4:-}"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    failed "$case_name" "${msg:+$msg }unexpectedly contains '$needle'"
  else
    pass "$case_name" "${msg:+$msg }(free of '$needle')"
  fi
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-rc-brood.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; return 0; }
trap cleanup EXIT

# ── Fake tmux ───────────────────────────────────────────────────────────────────
# A FAKE `tmux` placed FIRST on PATH so the engine's `tmux has-session` / `tmux send-keys` calls hit
# the fake instead of a real server:
#   has-session -t <s> : exit 0 iff <s> is listed (one per line) in $TMUX_ALIVE_FILE; else exit 1.
#                        This lets each case control which sessions are "alive".
#   send-keys ...      : append the FULL argv (one arg per line, NUL-safe-ish) to $TMUX_SENDKEYS_LOG.
#                        It NEVER actually sends a keystroke — capture only.
#   any other subcmd   : exit 0 (no-op; the engine only uses the two above).
FAKE_BIN="$WORKDIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
# Hermetic tmux stand-in for test_rc_brood.sh. Liveness + send-keys capture only.
sub="${1:-}"
shift || true
case "$sub" in
  has-session)
    # parse `-t <session>`
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target="${2:-}"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ -n "${TMUX_ALIVE_FILE:-}" ] || exit 1
    [ -f "$TMUX_ALIVE_FILE" ]     || exit 1
    if grep -qxF -- "$target" "$TMUX_ALIVE_FILE"; then
      exit 0
    fi
    exit 1
    ;;
  send-keys)
    # Capture the full send-keys invocation verbatim. One record per call, args on their own lines,
    # framed by a SEND-KEYS marker so the test can split records unambiguously.
    {
      printf 'SEND-KEYS-RECORD\n'
      for a in "$@"; do printf 'ARG:%s\n' "$a"; done
      printf 'END-RECORD\n'
    } >> "${TMUX_SENDKEYS_LOG:?TMUX_SENDKEYS_LOG unset}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_TMUX
chmod +x "$FAKE_BIN/tmux"

# new_brood_root <name> <brood_id> <fixture> — materialize a throwaway git checkout under $WORKDIR
# and stage <fixture> at <root>/.hivemind/broods/<brood_id>/manifest.json so the engine's
# `git rev-parse --show-toplevel`-anchored manifest read resolves it there. Prints the root path.
new_brood_root() {
  local name="$1" brood_id="$2" fixture="$3"
  local root="$WORKDIR/$name"
  mkdir -p "$root"
  git -C "$root" init -q
  mkdir -p "$root/.hivemind/broods/$brood_id"
  cp "$fixture" "$root/.hivemind/broods/$brood_id/manifest.json"
  printf '%s' "$root"
}

# run_engine <root> <brood_id> <alive_file> <sendkeys_log> — run the engine inside <root> with the
# fake tmux first on PATH, a tmp HOME, the configured alive-set + send-keys log. Stdout is written to
# <sendkeys_log>.stdout, stderr to <sendkeys_log>.stderr, and the exit code is stored in the global
# RUN_RC. run_engine is NOT invoked through command substitution (a `$()` subshell could not write
# RUN_RC back to the parent shell); callers read RUN_RC and the .stdout file after the call.
RUN_RC=0
run_engine() {
  local root="$1" brood_id="$2" alive_file="$3" sendkeys_log="$4"
  set +e
  (
    cd "$root" \
      && PATH="$FAKE_BIN:$PATH" \
         HOME="$root/fakehome" \
         TMUX_ALIVE_FILE="$alive_file" \
         TMUX_SENDKEYS_LOG="$sendkeys_log" \
         bash "$ENGINE" "$brood_id"
  ) >"${sendkeys_log}.stdout" 2>"${sendkeys_log}.stderr"
  RUN_RC=$?
  set -e
}

# count_records <log> — number of send-keys invocations captured. `grep -c` prints its count AND
# exits 1 on zero matches, so route through a var to keep a single clean integer on stdout.
count_records() {
  local n
  n="$(grep -c '^SEND-KEYS-RECORD$' "$1" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# literal_payloads <log> — for every send-keys call carrying `-l`, echo the LAST ARG (the literal
# text typed, e.g. `/rc <slug>`), one per line. This is the exact byte payload delivered.
literal_payloads() {
  awk '
    /^SEND-KEYS-RECORD$/ { has_l=0; last=""; next }
    /^ARG:-l$/           { has_l=1; next }
    /^ARG:/              { last=substr($0,5); next }
    /^END-RECORD$/       { if (has_l) print last; next }
  ' "$1"
}

# enter_count <log> — number of send-keys calls whose final ARG is the literal `Enter` key event.
enter_count() {
  awk '
    /^SEND-KEYS-RECORD$/ { last=""; next }
    /^ARG:/              { last=substr($0,5); next }
    /^END-RECORD$/       { if (last=="Enter") c++; next }
    END                  { print c+0 }
  ' "$1"
}

# ── Case 1: all-alive fan-out ─────────────────────────────────────────────────────
# 3 strains, all sessions alive → one `/rc <slug>` literal + one Enter per strain, correct slug per
# strain, exit 0, summary applied=3 skipped=0 failed=0.
echo '=== Case 1: all-alive fan-out — one /rc <slug> + Enter per strain, exit 0 ==='
BID1="brood-feedface-0000-4000-8000-000000000001"
ROOT1="$(new_brood_root all-alive "$BID1" "$FIXTURES/rc-manifest-all-alive.json")"
ALIVE1="$WORKDIR/alive1"
LOG1="$WORKDIR/log1"
: > "$LOG1"
printf '%s\n' \
  "$BID1-api" \
  "$BID1-web-ui" \
  "$BID1-db" > "$ALIVE1"
run_engine "$ROOT1" "$BID1" "$ALIVE1" "$LOG1"
OUT1="$(cat "${LOG1}.stdout")"
assert_eq "all-alive:exit" "0" "$RUN_RC" "fan-out completed"
# 3 literal send-keys (the /rc payloads) + 3 Enter = 6 records.
assert_eq "all-alive:record-count" "6" "$(count_records "$LOG1")" "two send-keys per strain"
assert_eq "all-alive:enter-count" "3" "$(enter_count "$LOG1")" "one Enter per strain"
PAYLOADS1="$(literal_payloads "$LOG1")"
assert_contains "all-alive:slug-api"   "/rc api"           "$PAYLOADS1" "api slug"
assert_contains "all-alive:slug-webui" "/rc web-ui"        "$PAYLOADS1" "web-ui slug"
assert_contains "all-alive:slug-db"    "/rc db.migrations" "$PAYLOADS1" "db.migrations slug"
assert_eq "all-alive:literal-payload-count" "3" "$(printf '%s\n' "$PAYLOADS1" | grep -c '^/rc ')" "exactly 3 /rc literals"
assert_contains "all-alive:summary" "3 applied, 0 skipped, 0 failed (of 3 strains)" "$OUT1" "summary counts"
assert_contains "all-alive:applied-api" "applied: api" "$OUT1"

# ── Case 2: fail-soft on dead session ─────────────────────────────────────────────
# Same 3-strain manifest, but the web-ui session is NOT alive → web-ui skipped, api + db.migrations
# still delivered, exit 0, summary applied=2 skipped=1.
echo '=== Case 2: fail-soft — one dead session skipped, others still delivered ==='
ROOT2="$(new_brood_root dead-session "$BID1" "$FIXTURES/rc-manifest-all-alive.json")"
ALIVE2="$WORKDIR/alive2"
LOG2="$WORKDIR/log2"
: > "$LOG2"
# web-ui session intentionally OMITTED → has-session returns failure for it.
printf '%s\n' \
  "$BID1-api" \
  "$BID1-db" > "$ALIVE2"
run_engine "$ROOT2" "$BID1" "$ALIVE2" "$LOG2"
OUT2="$(cat "${LOG2}.stdout")"
assert_eq "dead:exit" "0" "$RUN_RC" "dead session does not abort fan-out"
PAYLOADS2="$(literal_payloads "$LOG2")"
assert_contains "dead:slug-api" "/rc api"           "$PAYLOADS2" "api still delivered"
assert_contains "dead:slug-db"  "/rc db.migrations" "$PAYLOADS2" "db still delivered"
assert_not_contains "dead:no-webui" "/rc web-ui" "$PAYLOADS2" "dead web-ui never delivered"
assert_eq "dead:literal-payload-count" "2" "$(printf '%s\n' "$PAYLOADS2" | grep -c '^/rc ')" "exactly 2 /rc literals (1 skipped)"
assert_eq "dead:enter-count" "2" "$(enter_count "$LOG2")" "one Enter per applied strain"
assert_contains "dead:skip-line" "skipped: web-ui (session not alive:" "$OUT2" "skip disposition line"
assert_contains "dead:summary" "2 applied, 1 skipped, 0 failed (of 3 strains)" "$OUT2" "summary counts"

# ── Case 3a: pre-flight blocker — bad brood-id → ZERO send-keys ───────────────────
# A traversal-shaped brood-id is rejected by the FAIL-CLOSED arg gate BEFORE any manifest read or
# keystroke. blocker on stderr, exit 1, send-keys log EMPTY.
echo '=== Case 3a: bad brood-id (traversal) — blocker, exit 1, zero send-keys ==='
ROOT3A="$(new_brood_root badid "$BID1" "$FIXTURES/rc-manifest-all-alive.json")"
ALIVE3A="$WORKDIR/alive3a"; : > "$ALIVE3A"
LOG3A="$WORKDIR/log3a"; : > "$LOG3A"
run_engine "$ROOT3A" "../../etc/passwd" "$ALIVE3A" "$LOG3A"
assert_eq "badid:exit" "1" "$RUN_RC" "bad brood-id is a pre-flight blocker"
assert_contains "badid:blocker" "blocker:" "$(cat "${LOG3A}.stderr")" "blocker line on stderr"
assert_eq "badid:zero-sendkeys" "0" "$(count_records "$LOG3A")" "no keystroke delivered on pre-flight blocker"

# ── Case 3a': empty brood-id → blocker, zero send-keys ────────────────────────────
echo '=== Case 3a-empty: empty brood-id — blocker, exit 1, zero send-keys ==='
ROOT3AE="$(new_brood_root emptyid "$BID1" "$FIXTURES/rc-manifest-all-alive.json")"
ALIVE3AE="$WORKDIR/alive3ae"; : > "$ALIVE3AE"
LOG3AE="$WORKDIR/log3ae"; : > "$LOG3AE"
run_engine "$ROOT3AE" "" "$ALIVE3AE" "$LOG3AE"
assert_eq "emptyid:exit" "1" "$RUN_RC" "empty brood-id is a pre-flight blocker"
assert_contains "emptyid:blocker" "blocker:" "$(cat "${LOG3AE}.stderr")" "blocker line on stderr"
assert_eq "emptyid:zero-sendkeys" "0" "$(count_records "$LOG3AE")" "no keystroke on empty brood-id"

# ── Case 3b: missing manifest → blocker, exit 1, zero send-keys ───────────────────
# Well-formed brood-id, but no manifest staged under that id → blocker, exit 1, send-keys empty.
echo '=== Case 3b: missing manifest — blocker, exit 1, zero send-keys ==='
ROOT3B="$WORKDIR/no-manifest"
mkdir -p "$ROOT3B"
git -C "$ROOT3B" init -q
ALIVE3B="$WORKDIR/alive3b"; : > "$ALIVE3B"
LOG3B="$WORKDIR/log3b"; : > "$LOG3B"
run_engine "$ROOT3B" "brood-deadbeef-0000-4000-8000-000000000099" "$ALIVE3B" "$LOG3B"
assert_eq "nomanifest:exit" "1" "$RUN_RC" "missing manifest is a pre-flight blocker"
assert_contains "nomanifest:blocker" "brood manifest not found" "$(cat "${LOG3B}.stderr")" "manifest-missing blocker"
assert_eq "nomanifest:zero-sendkeys" "0" "$(count_records "$LOG3B")" "no keystroke when manifest missing"

# ── Case 4: injection-safety ──────────────────────────────────────────────────────
# A hostile strain name carrying `;`, `$()`, backticks, spaces and slashes. The ONLY bytes sent are
# the sanitized `/rc <slug>` literal. No shell metacharacter reaches send-keys; no side-effect file
# the hostile name tried to create exists anywhere.
echo '=== Case 4: injection-safety — only the sanitized /rc <slug> literal is sent ==='
BID4="brood-feedface-0000-4000-8000-000000000002"
ROOT4="$(new_brood_root hostile "$BID4" "$FIXTURES/rc-manifest-hostile-name.json")"
ALIVE4="$WORKDIR/alive4"
LOG4="$WORKDIR/log4"
: > "$LOG4"
printf '%s\n' "$BID4-hostile" > "$ALIVE4"
# The expected slug is the hostile name reduced to [A-Za-z0-9._-]:
#   "abc; touch PWNED $(touch SUBPWN) `touch BTPWN` /etc/x" -> abctouchPWNEDtouchSUBPWNtouchBTPWNetcx
EXPECT_SLUG="abctouchPWNEDtouchSUBPWNtouchBTPWNetcx"
run_engine "$ROOT4" "$BID4" "$ALIVE4" "$LOG4"
OUT4="$(cat "${LOG4}.stdout")"
assert_eq "hostile:exit" "0" "$RUN_RC" "hostile name still completes fan-out"
PAYLOADS4="$(literal_payloads "$LOG4")"
# Exactly ONE literal payload, and it is the sanitized form verbatim.
assert_eq "hostile:literal-count" "1" "$(printf '%s\n' "$PAYLOADS4" | grep -c '^/rc ')" "exactly one /rc literal"
assert_eq "hostile:exact-payload" "/rc $EXPECT_SLUG" "$PAYLOADS4" "sent payload is the sanitized literal only"
# No shell metacharacter from the hostile name survived into the delivered slug. The fixed `/rc `
# command prefix legitimately carries a space and a leading `/`; the SLUG (everything after `/rc `)
# is the only untrusted-derived portion and must be a pure [A-Za-z0-9._-] token. Strip the fixed
# prefix and assert the remaining slug bytes carry none of the hostile metacharacters.
SLUG4="${PAYLOADS4#/rc }"
for meta in ';' '$(' '`' ' ' '/'; do
  if printf '%s' "$SLUG4" | grep -qF -- "$meta"; then
    failed "hostile:no-meta" "metacharacter '$meta' reached the send-keys slug"
  else
    pass "hostile:no-meta" "(slug free of metacharacter '$meta')"
  fi
done
# No side-effect file the hostile name attempted to create exists — search the whole workdir + cwd.
INJECT_HITS="$(find "$WORKDIR" \( -name 'PWNED' -o -name 'SUBPWN' -o -name 'BTPWN' \) 2>/dev/null | head -n 1)"
assert_eq "hostile:no-side-effect" "" "$INJECT_HITS" "no injected file (PWNED/SUBPWN/BTPWN) created"

# ── Case 5: summary correctness already asserted per case above ───────────────────
# Cases 1, 2 assert the exact applied/skipped/failed triple; Case 4 asserts the hostile slug path
# still summarises applied=1. Re-assert the hostile summary explicitly for the failed=0 dimension.
echo '=== Case 5: summary correctness — hostile path applied=1 skipped=0 failed=0 ==='
assert_contains "summary:hostile" "1 applied, 0 skipped, 0 failed (of 1 strains)" "$OUT4" "hostile summary counts"

# ── Tally ─────────────────────────────────────────────────────────────────────────
echo
echo "test_rc_brood: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0

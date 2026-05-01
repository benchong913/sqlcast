#!/usr/bin/env bash
#
# Smoke tests for sqlcast.sh argument handling. Stubs `mysql` via PATH so
# no real database connection is attempted.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SQLCAST="${ROOT_DIR}/sqlcast.sh"

pass=0
fail=0

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n      want substring: %s\n      got: %s\n' \
      "$name" "$needle" "$haystack"
  fi
}

assert_rc() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" -eq "$want" ]]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n      want rc: %s\n      got: %s\n' "$name" "$want" "$got"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n      must not contain: %s\n      got: %s\n' \
      "$name" "$needle" "$haystack"
  fi
}

STUB_DIR="$(mktemp -d -t sqlcast_stub.XXXXXX)"
TEST_MY_CNF="$(mktemp -t sqlcast_mycnf.XXXXXX)"
INPUT_LOG="$(mktemp -t sqlcast_input.XXXXXX)"
export SQLCAST_TEST_INPUT_LOG="$INPUT_LOG"
trap 'rm -rf "$STUB_DIR" "$TEST_MY_CNF" "$INPUT_LOG"' EXIT

cat > "${STUB_DIR}/mysql" <<'STUB'
#!/usr/bin/env bash
echo "STUB mysql: $*"
if [[ -n "${SQLCAST_TEST_INPUT_LOG:-}" ]]; then
  cat >> "$SQLCAST_TEST_INPUT_LOG"
  printf '\n---boundary---\n' >> "$SQLCAST_TEST_INPUT_LOG"
else
  cat >/dev/null
fi
host=""
for arg in "$@"; do
  case "$arg" in --host=*) host="${arg#--host=}" ;; esac
done
case ",${SQLCAST_FAIL_HOSTS:-}," in
  *",${host},"*) exit 1 ;;
esac
# Hosts in SQLCAST_PARTIAL_HOSTS emit N synthetic ERROR lines on stderr
# but still exit 0 — mimics how `mysql --force` continues past failures.
errs="${SQLCAST_PARTIAL_ERRS:-2}"
case ",${SQLCAST_PARTIAL_HOSTS:-}," in
  *",${host},"*)
    i=1
    while [[ "$i" -le "$errs" ]]; do
      printf 'ERROR 1062 (23000) at line %d: stub partial err %d\n' "$i" "$i" >&2
      i=$((i + 1))
    done
    ;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/mysql"
export PATH="${STUB_DIR}:${PATH}"

cat > "$TEST_MY_CNF" <<'CNF'
[client]
user = test
password = test
CNF
export SQLCAST_MY_CNF="$TEST_MY_CNF"
export SQLCAST_COUNTRIES_FILE="${ROOT_DIR}/countries.conf.example"

# 1. Help shows usage.
out="$("$SQLCAST" -h 2>&1)" || true
assert_contains "$out" "Usage:" "help shows usage"

# 2. -e flag is removed and rejected as unknown.
out="$("$SQLCAST" -e "SELECT 1" 2>&1)" || true
assert_contains "$out" "unknown flag: -e" "removed -e flag is unknown"

# 3. Bare SQL string is no longer accepted (treated as a missing file).
out="$("$SQLCAST" "SELECT 1;" 2>&1)" || true
assert_contains "$out" "file not found: SELECT 1;" \
  "bare SQL string is rejected as missing file"

# 4. Piped stdin (no positional) is read and fanned out.
out="$(echo "SELECT 1;" | "$SQLCAST" 2>&1)" || true
assert_contains "$out" "running stdin across:" \
  "piped stdin is read when no positional"

# 5. No positional + empty stdin errors out.
out="$("$SQLCAST" < /dev/null 2>&1)" || true
assert_contains "$out" "no SQL provided" \
  "empty stdin with no positional errors"

# 6. Missing file path errors out.
out="$("$SQLCAST" missing-file.sql 2>&1)" || true
assert_contains "$out" "file not found: missing-file.sql" \
  "missing file errors out"

# 7. Existing file goes through file mode.
tmpdir="$(mktemp -d -t sqlcast_in.XXXXXX)"
tmpfile="${tmpdir}/script.sql"
echo "SELECT 1;" > "$tmpfile"
out="$("$SQLCAST" "$tmpfile" 2>&1)" || true
assert_contains "$out" "running $tmpfile" "existing file goes through file mode"
rm -rf "$tmpdir"

# 8. --only filters countries (paired with stdin SQL).
out="$(echo "SELECT 1" | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "across: us" "--only=us filters to us"

# 9. Unknown country code errors out.
out="$(echo "SELECT 1" | "$SQLCAST" --only=zz 2>&1)" || true
assert_contains "$out" "country not in countries.conf: zz" \
  "unknown country errors"

# 10. Two positionals error out.
out="$("$SQLCAST" a.sql b.sql 2>&1)" || true
assert_contains "$out" "more than one SQL source" \
  "two positionals error out"

# 11. mysql is invoked with --defaults-file pointing at the configured my.cnf.
out="$(echo "SELECT 1" | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "--defaults-file=$TEST_MY_CNF" \
  "mysql receives --defaults-file from SQLCAST_MY_CNF"

# 12. Missing my.cnf errors out.
out="$(SQLCAST_MY_CNF=/nonexistent/my.cnf "$SQLCAST" --only=us < /dev/null 2>&1)" || true
assert_contains "$out" "missing my.cnf" "missing my.cnf errors out"

# 13. Empty --only= value is rejected.
out="$("$SQLCAST" --only= < /dev/null 2>&1)" || true
assert_contains "$out" "--only requires a value" \
  "empty --only value is rejected"

# 14. Duplicate code in --only is rejected.
out="$(echo "SELECT 1" | "$SQLCAST" --only=us,us 2>&1)" || true
assert_contains "$out" "duplicate code in --only: us" \
  "duplicate --only code is rejected"

# 15. Multi-country --only=us,in selects both, in order.
out="$(echo "SELECT 1" | "$SQLCAST" --only=us,in 2>&1)" || true
assert_contains "$out" "across: us in" \
  "--only=us,in selects two countries in order"

# 16. World-readable my.cnf is rejected (the user could leak the password).
BAD_CNF="$(mktemp -t sqlcast_badmycnf.XXXXXX)"
cat > "$BAD_CNF" <<CNF
[client]
user = test
password = test
CNF
chmod 644 "$BAD_CNF"
out="$(SQLCAST_MY_CNF="$BAD_CNF" "$SQLCAST" --only=us < /dev/null 2>&1)" || true
rm -f "$BAD_CNF"
assert_contains "$out" "insecure my.cnf permissions" \
  "world-readable my.cnf is rejected"

# 17. mysql failure is captured: failed summary + exit code 1.
export SQLCAST_FAIL_HOSTS="us-db.example"
out="$(echo "SELECT 1" | "$SQLCAST" --only=us,in 2>&1)"; rc=$?
unset SQLCAST_FAIL_HOSTS
assert_contains "$out" "failed: us" "failure path lists failing country"
assert_contains "$out" "ok:     in" "failure path still lists passing country"
assert_rc "$rc" 1 "exit code 1 when any country fails"

# 18. All-ok run shows failed: (none) and exits 0.
out="$(echo "SELECT 1" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "failed: (none)" "summary shows failed: (none) on success"
assert_rc "$rc" 0 "exit code 0 when all countries succeed"

# --- destructive-SQL guard ---

# 19a. DROP TABLE is refused by default.
out="$(echo "DROP TABLE users;" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "refusing destructive SQL" \
  "DROP TABLE is refused by default"
assert_contains "$out" "DROP TABLE" "guard reports the matched keyword"
assert_rc "$rc" 2 "destructive SQL exits 2"

# 19b. TRUNCATE is refused by default.
out="$(echo "TRUNCATE TABLE users;" | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "refusing destructive SQL" \
  "TRUNCATE TABLE is refused by default"

# 19c. RENAME TABLE is refused by default.
out="$(echo "RENAME TABLE a TO b;" | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "refusing destructive SQL" \
  "RENAME TABLE is refused by default"

# 19d. --allow-destructive lets DROP through.
out="$(echo "DROP TABLE users;" | "$SQLCAST" --allow-destructive --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "--allow-destructive permits DROP TABLE"
assert_rc "$rc" 0 "DROP with --allow-destructive succeeds"

# 19e. SQLCAST_ALLOW_DESTRUCTIVE=1 lets DROP through.
out="$(echo "DROP TABLE users;" | SQLCAST_ALLOW_DESTRUCTIVE=1 "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "SQLCAST_ALLOW_DESTRUCTIVE=1 permits DROP TABLE"
assert_rc "$rc" 0 "DROP with env override succeeds"

# 19f. DROP inside a -- comment must not trip the guard.
out="$(printf -- '-- DROP TABLE users;\nSELECT 1;\n' | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "DROP inside a -- comment is ignored"
assert_rc "$rc" 0 "commented DROP is allowed"

# 19g. DROP inside a string literal must not trip the guard.
out="$(echo "INSERT INTO logs (msg) VALUES ('DROP TABLE users');" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "DROP inside a string literal is ignored"
assert_rc "$rc" 0 "string-literal DROP is allowed"

# 19h. DROP inside an executable conditional comment IS detected
# (MySQL would actually run it, so the guard must look inside).
out="$(echo "/*!50000 DROP TABLE users */;" | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "refusing destructive SQL" \
  "DROP inside /*! ... */ is refused"

# 19i. DELETE without WHERE is refused.
out="$(echo "DELETE FROM users;" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "DELETE without WHERE" \
  "DELETE without WHERE is refused"
assert_rc "$rc" 2 "DELETE without WHERE exits 2"

# 19j. DELETE with WHERE passes the guard.
out="$(echo "DELETE FROM users WHERE id = 1;" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "DELETE with WHERE is allowed"
assert_rc "$rc" 0 "DELETE with WHERE succeeds"

# 19k. UPDATE without WHERE is refused.
out="$(echo "UPDATE users SET active = 0;" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "UPDATE without WHERE" \
  "UPDATE without WHERE is refused"
assert_rc "$rc" 2 "UPDATE without WHERE exits 2"

# 19l. UPDATE with WHERE passes the guard.
out="$(echo "UPDATE users SET active = 0 WHERE id = 1;" | "$SQLCAST" --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "UPDATE with WHERE is allowed"
assert_rc "$rc" 0 "UPDATE with WHERE succeeds"

# 19m. Mixed batch: a safe DELETE followed by an unsafe DELETE is refused
# on the second statement (per-statement scan, not whole-file scan).
out="$(printf 'DELETE FROM a WHERE id=1;\nDELETE FROM b;\n' | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "DELETE without WHERE" \
  "per-statement scan flags second naked DELETE"

# 19n. --allow-destructive lets DELETE without WHERE through.
out="$(echo "DELETE FROM users;" | "$SQLCAST" --allow-destructive --only=us 2>&1)"; rc=$?
assert_contains "$out" "running stdin across: us" \
  "--allow-destructive permits naked DELETE"
assert_rc "$rc" 0 "naked DELETE with --allow-destructive succeeds"

# 19. Interactive multi-line paste: sqlcast reads every pasted line until the
# user presses Enter on a blank line, so multi-statement SQL survives a
# copy-paste into a TTY.
if command -v expect >/dev/null; then
  : > "$INPUT_LOG"
  expect <<EOF >/dev/null
    log_user 0
    set timeout 10
    spawn $SQLCAST --only=us
    expect "SQL>"
    send -- "SELECT 1;\r"
    send -- "SELECT 2;\r"
    send -- "\r"
    expect eof
EOF
  captured="$(cat "$INPUT_LOG")"
  assert_contains "$captured" "SELECT 1;" \
    "interactive paste captures first pasted line"
  assert_contains "$captured" "SELECT 2;" \
    "interactive paste captures subsequent pasted lines"
else
  printf 'skip - expect not installed; multi-line paste test skipped\n'
fi

# --- continue-on-error ---

# 20a. Default mode (no flag) must NOT pass --force to mysql.
out="$(echo "SELECT 1" | "$SQLCAST" --only=us 2>&1)" || true
assert_not_contains "$out" "--force" \
  "default mode does not pass --force to mysql"

# 20b. --continue-on-error passes --force to mysql.
out="$(echo "SELECT 1" | "$SQLCAST" --continue-on-error --only=us 2>&1)"; rc=$?
assert_contains "$out" "--force" \
  "--continue-on-error passes --force to mysql"
assert_rc "$rc" 0 "clean run with --continue-on-error exits 0"

# 20c. SQLCAST_CONTINUE_ON_ERROR=1 acts like the flag.
out="$(echo "SELECT 1" | SQLCAST_CONTINUE_ON_ERROR=1 "$SQLCAST" --only=us 2>&1)"
assert_contains "$out" "--force" \
  "SQLCAST_CONTINUE_ON_ERROR=1 passes --force"

# 20d. Partial host (errors on stderr but exit 0) is classified partial.
export SQLCAST_PARTIAL_HOSTS="us-db.example"
out="$(echo "SELECT 1" | "$SQLCAST" --continue-on-error --only=us,in 2>&1)"; rc=$?
unset SQLCAST_PARTIAL_HOSTS
assert_contains "$out" "partial: us(2)" \
  "partial host shown with error count"
assert_contains "$out" "ok:     in" \
  "non-partial host stays in ok bucket"
assert_contains "$out" "failed: (none)" \
  "partial does not pollute the failed bucket"
assert_rc "$rc" 1 "exit 1 when any host has partial failures"

# 20e. Partial count reflects the number of ERROR lines emitted.
export SQLCAST_PARTIAL_HOSTS="us-db.example"
export SQLCAST_PARTIAL_ERRS=5
out="$(echo "SELECT 1" | "$SQLCAST" --continue-on-error --only=us 2>&1)"; rc=$?
unset SQLCAST_PARTIAL_HOSTS SQLCAST_PARTIAL_ERRS
assert_contains "$out" "partial: us(5)" \
  "partial count tracks ERROR line count"
assert_rc "$rc" 1 "partial-only run exits 1"

# 20f. Clean --continue-on-error run: no partial line, exit 0.
out="$(echo "SELECT 1" | "$SQLCAST" --continue-on-error --only=us 2>&1)"; rc=$?
assert_not_contains "$out" "partial:" \
  "no partial line when no errors emitted"
assert_rc "$rc" 0 "clean continue-on-error run exits 0"

# 20g. Without --continue-on-error, partial-style stderr is not classified
# (the stub still emits ERROR lines, but no --force means they wouldn't
# happen in real life; we just verify default summary stays 2-bucket).
export SQLCAST_PARTIAL_HOSTS="us-db.example"
out="$(echo "SELECT 1" | "$SQLCAST" --only=us 2>&1)"; rc=$?
unset SQLCAST_PARTIAL_HOSTS
assert_not_contains "$out" "partial:" \
  "default mode never produces a partial line"

# 20h. Hard failure still wins over partial classification.
export SQLCAST_FAIL_HOSTS="us-db.example"
out="$(echo "SELECT 1" | "$SQLCAST" --continue-on-error --only=us,in 2>&1)"; rc=$?
unset SQLCAST_FAIL_HOSTS
assert_contains "$out" "failed: us" \
  "rc!=0 host goes to failed even with --continue-on-error"
assert_rc "$rc" 1 "failed host exits 1 under --continue-on-error"

# --- per-host credential override ---

# 21a. mysql receives --defaults-group-suffix=_<code> per host so an
# optional [client_<code>] section in my.cnf can override [client].
out="$(echo "SELECT 1" | "$SQLCAST" --only=us 2>&1)" || true
assert_contains "$out" "--defaults-group-suffix=_us" \
  "mysql receives --defaults-group-suffix=_us when running for us"

# 21b. The suffix tracks the country code, not a fixed value.
out="$(echo "SELECT 1" | "$SQLCAST" --only=in 2>&1)" || true
assert_contains "$out" "--defaults-group-suffix=_in" \
  "mysql receives --defaults-group-suffix=_in when running for in"

# 21c. Multi-country run: each host gets its own suffix.
out="$(echo "SELECT 1" | "$SQLCAST" --only=us,jp 2>&1)" || true
assert_contains "$out" "--defaults-group-suffix=_us" \
  "multi-country run includes _us suffix"
assert_contains "$out" "--defaults-group-suffix=_jp" \
  "multi-country run includes _jp suffix"

# 21d. A countries.conf code that is not a valid MySQL option-group name
# suffix is rejected at parse time so users don't silently lose their
# override (mysql would just ignore an unparseable group name).
BAD_CONF="$(mktemp -t sqlcast_badconf.XXXXXX)"
cat > "$BAD_CONF" <<'EOF'
us/east  us-db.example
EOF
out="$(echo "SELECT 1" | SQLCAST_COUNTRIES_FILE="$BAD_CONF" "$SQLCAST" 2>&1)"; rc=$?
rm -f "$BAD_CONF"
assert_contains "$out" "invalid country code" \
  "country code with illegal chars is rejected"
assert_rc "$rc" 1 "invalid country code exits 1"

# 21e. Codes are also forbidden from starting with a non-alphanumeric — '..',
# '.foo', '-foo' would otherwise sneak into err_file paths under
# --continue-on-error (err_dir/${code}.err), and a leading dash could be
# parsed as a flag if ever reused outside an array boundary.
TRAV_CONF="$(mktemp -t sqlcast_travconf.XXXXXX)"
cat > "$TRAV_CONF" <<'EOF'
..  any-host.example
EOF
out="$(echo "SELECT 1" | SQLCAST_COUNTRIES_FILE="$TRAV_CONF" "$SQLCAST" 2>&1)"; rc=$?
rm -f "$TRAV_CONF"
assert_contains "$out" "invalid country code" \
  "code starting with non-alphanumeric is rejected"
assert_rc "$rc" 1 "leading-dot code exits 1"

printf '\n--- %d passed, %d failed ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

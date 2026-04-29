#!/usr/bin/env bash
#
# sqlcast — fan out SQL across all configured country test DBs.
#
# Reads country routing from countries.conf. Shared user/password live
# in the [client] group of ~/.my.cnf (auto-read by the mysql client).
# Sequential execution, fail-summary at the end.
#
# SQL source:
#   ./sqlcast.sh script.sql   # path to an existing file
#   ./sqlcast.sh              # interactive: paste, blank-line Enter executes
#   ./sqlcast.sh < script.sql # piped/redirected stdin reads the full input

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUNTRIES_FILE="${SQLCAST_COUNTRIES_FILE:-${SCRIPT_DIR}/countries.conf}"
MY_CNF="${SQLCAST_MY_CNF:-${SCRIPT_DIR}/my.cnf}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--only=LIST] [--allow-destructive] [<sql-file>]

If a positional argument is given it must be an existing file. With no
positional, SQL is read from stdin: on a terminal, lines are collected
until a blank Enter (or Ctrl-D); from a pipe or redirect, the whole
input is read.

Options:
  --only=LIST           Comma-separated country codes (default: all)
  --allow-destructive   Permit DROP / TRUNCATE / RENAME TABLE and DELETE / UPDATE
                        without WHERE (all refused by default). Equivalent to
                        SQLCAST_ALLOW_DESTRUCTIVE=1.
  -h, --help            Show this help

Examples:
  $(basename "$0") migrations/v1.sql
  $(basename "$0") --only=us,in migrations/v1.sql
  $(basename "$0")                    # paste SQL, blank Enter to execute
  echo "SELECT VERSION();" | $(basename "$0")
EOF
}

only=""
positional=""
allow_destructive=0
[[ "${SQLCAST_ALLOW_DESTRUCTIVE:-}" == "1" ]] && allow_destructive=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only=*)             only="${1#--only=}"
                          [[ -n "$only" ]] || { echo "--only requires a value" >&2; exit 2; }
                          shift ;;
    --allow-destructive)  allow_destructive=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    -*)                   echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -n "$positional" ]] && { echo "more than one SQL source given" >&2; exit 2; }
      positional="$1"; shift
      ;;
  esac
done

[[ ! -f "$COUNTRIES_FILE" ]] && { echo "missing countries file: $COUNTRIES_FILE (copy from countries.conf.example)" >&2; exit 1; }
[[ ! -f "$MY_CNF" ]]         && { echo "missing my.cnf: $MY_CNF (copy from my.cnf.example, then chmod 600)" >&2; exit 1; }
my_cnf_perms="$(stat -f '%Lp' "$MY_CNF" 2>/dev/null || stat -c '%a' "$MY_CNF" 2>/dev/null || echo '')"
case "$my_cnf_perms" in
  400|600|0400|0600) ;;
  *) echo "insecure my.cnf permissions (${my_cnf_perms:-unknown}); run: chmod 600 $MY_CNF" >&2; exit 1 ;;
esac
# mysql-client (Homebrew) is keg-only and not symlinked into PATH; fall back
# to its canonical install paths so users don't need to edit their shell rc.
if ! command -v mysql >/dev/null; then
  for brew_bin in /opt/homebrew/opt/mysql-client/bin /usr/local/opt/mysql-client/bin; do
    [[ -x "$brew_bin/mysql" ]] && { PATH="$brew_bin:$PATH"; break; }
  done
fi
command -v mysql >/dev/null || {
  echo "mysql client not on PATH" >&2
  echo "  install: brew install mysql-client" >&2
  echo "  then either rerun this script, or add to PATH:" >&2
  echo "    echo 'export PATH=\"/opt/homebrew/opt/mysql-client/bin:\$PATH\"' >> ~/.zshrc" >&2
  exit 1
}

# Resolve SQL source. Both modes end up with $sql_path so the fan-out
# loop can re-read it once per country.
sql_path=""
sql_label=""
cleanup_path=""
trap '[[ -n "$cleanup_path" ]] && rm -f "$cleanup_path"' EXIT

if [[ -n "$positional" ]]; then
  [[ -f "$positional" ]] || { echo "file not found: $positional" >&2; exit 1; }
  sql_path="$positional"
  sql_label="$positional"
else
  cleanup_path="$(mktemp -t sqlcast.XXXXXX)"
  sql_path="$cleanup_path"
  sql_label="stdin"
  if [[ -t 0 ]]; then
    # Interactive: paste multi-line SQL, finish with Enter on a blank line
    # (or Ctrl-D). Reading until a blank line lets a single Enter terminate
    # a paste whose content already ends with a newline.
    printf 'SQL> (paste; press Enter on a blank line or Ctrl-D to execute)\n' >&2
    : > "$sql_path"
    while IFS= read -r line; do
      [[ -z "$line" ]] && break
      printf '%s\n' "$line" >> "$sql_path"
    done
    [[ -s "$sql_path" ]] || { echo "no SQL provided" >&2; exit 2; }
  else
    # Piped / redirected: read the full input.
    cat > "$sql_path"
    [[ -s "$sql_path" ]] || { echo "no SQL provided (empty stdin)" >&2; exit 2; }
  fi
fi

# Guard against accidentally fanning out a destructive DDL to every DB.
# Strip block comments, line comments, and string literals first so a
# "-- DROP TABLE x" comment or 'DROP TABLE x' inside a literal does not
# false-positive. MySQL's executable conditional comments (/*! ... */
# and /*+ ... */) are unwrapped, since their contents are real SQL.
#
# Defined as a function so the heredoc stays out of $( ... ); macOS
# bash 3.2 mis-parses heredocs nested inside command substitution.
_sqlcast_scan_destructive() {
  perl - "$1" <<'PERL'
my $f = shift @ARGV;
open my $fh, '<', $f or die "$f: $!";
local $/;
my $sql = <$fh>;
$sql =~ s{/\*!\d*\s*(.*?)\*/}{ $1 }gs;
$sql =~ s{/\*\+\s*(.*?)\*/}{ $1 }gs;
$sql =~ s{/\*.*?\*/}{ }gs;
$sql =~ s{(?:--[ \t]|\#)[^\n]*}{ }g;
$sql =~ s{'(?:[^'\\]|\\.|'')*'}{ }g;
$sql =~ s{"(?:[^"\\]|\\.|"")*"}{ }g;
my %hits;

# DDL deletions.
while ($sql =~ /\b(DROP\s+(?:TABLE|DATABASE|SCHEMA|INDEX|VIEW|TRIGGER|FUNCTION|PROCEDURE|EVENT|USER|TABLESPACE|SERVER)|TRUNCATE(?:\s+TABLE)?|RENAME\s+TABLE)\b/gis) {
    my $k = uc $1;
    $k =~ s/\s+/ /g;
    $hits{$k} = 1;
}

# DML without WHERE — split on ; per statement. Comments and string
# literals are already stripped, so embedded semicolons don't fool us.
# WHERE appearing only inside a sub-SELECT will pass; that's the
# operator's call. We're a guard, not a parser.
for my $stmt (split /;/, $sql) {
    next unless $stmt =~ /\S/;
    if ($stmt =~ /^\s*DELETE\b/is && $stmt !~ /\bWHERE\b/is) {
        $hits{"DELETE without WHERE"} = 1;
    }
    if ($stmt =~ /^\s*UPDATE\b/is && $stmt !~ /\bWHERE\b/is) {
        $hits{"UPDATE without WHERE"} = 1;
    }
}

print "  $_\n" for sort keys %hits;
PERL
}

if [[ "$allow_destructive" -ne 1 ]]; then
  command -v perl >/dev/null || {
    echo "perl is required for the destructive-SQL check" >&2
    echo "  install perl, or rerun with --allow-destructive" >&2
    exit 1
  }
  forbidden="$(_sqlcast_scan_destructive "$sql_path")"
  if [[ -n "$forbidden" ]]; then
    {
      echo "refusing destructive SQL — found:"
      printf '%s\n' "$forbidden"
      echo "if intentional, rerun with --allow-destructive (or SQLCAST_ALLOW_DESTRUCTIVE=1)"
    } >&2
    exit 2
  fi
fi

# Parse countries.conf.
entries=()
seen_codes=" "
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%%#*}"
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  read -r code host extra <<< "$line"
  [[ -z "$code" || -z "$host" ]]   && { echo "invalid line: $raw" >&2; exit 1; }
  [[ -n "$extra" ]]                && { echo "too many fields: $raw" >&2; exit 1; }
  [[ "$seen_codes" == *" $code "* ]] && { echo "duplicate code in $COUNTRIES_FILE: $code" >&2; exit 1; }
  seen_codes+="$code "
  entries+=("$code|$host")
done < "$COUNTRIES_FILE"

[[ "${#entries[@]}" -eq 0 ]] && { echo "no countries defined in $COUNTRIES_FILE" >&2; exit 1; }

selected=()
if [[ -n "$only" ]]; then
  IFS=',' read -ra requested <<< "$only"
  seen_only=" "
  for r in "${requested[@]}"; do
    [[ -z "$r" ]]                     && { echo "empty country code in --only" >&2; exit 2; }
    [[ "$seen_only" == *" $r "* ]]    && { echo "duplicate code in --only: $r" >&2; exit 2; }
    seen_only+="$r "
    match=""
    for e in "${entries[@]}"; do
      [[ "${e%%|*}" == "$r" ]] && { match="$e"; break; }
    done
    [[ -z "$match" ]] && { echo "country not in countries.conf: $r" >&2; exit 1; }
    selected+=("$match")
  done
else
  selected=("${entries[@]}")
fi

codes_only=()
for e in "${selected[@]}"; do codes_only+=("${e%%|*}"); done
echo "running $sql_label across: ${codes_only[*]}"

ok=()
failed=()
for e in "${selected[@]}"; do
  IFS='|' read -r code host <<< "$e"
  printf '\n=== %s (%s) ===\n' "$code" "$host"
  if mysql --defaults-file="$MY_CNF" --ssl-mode=REQUIRED --host="$host" < "$sql_path"; then
    ok+=("$code")
  else
    failed+=("$code")
  fi
done

printf '\n--- summary ---\n'
printf 'ok:     %s\n' "${ok[*]:-(none)}"
printf 'failed: %s\n' "${failed[*]:-(none)}"
[[ "${#failed[@]}" -gt 0 ]] && exit 1
exit 0

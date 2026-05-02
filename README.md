# sqlcast

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

> Fan out one SQL script to many MySQL hosts — sequentially, with a guard against accidental DROPs.

Run the same SQL across multiple MySQL hosts (typical use case: one test database per country / region) and get a single pass/fail summary at the end. By default refuses `DROP`, `TRUNCATE`, and unbounded `DELETE` / `UPDATE` so a single fat-fingered migration can't sweep every database.

```
$ ./sqlcast.sh migrations/v1.sql
running migrations/v1.sql across: us jp de br in

=== us (us-db.example) ===
=== jp (jp-db.example) ===
=== de (de-db.example) ===
=== br (br-db.example) ===
=== in (in-db.example) ===

--- summary ---
ok:     us jp de br
failed: in
```

## Quick start

Requires the `mysql` client (macOS: `brew install mysql-client` — keg-only, the script auto-fixes `PATH`; Linux: install `mysql-client` / `default-mysql-client` via your package manager).

```bash
git clone <this-repo>
cd sqlcast

cp countries.conf.example countries.conf   # replace hosts with your real ones
cp my.cnf.example my.cnf                   # fill in user / password
chmod 600 my.cnf                           # required — sqlcast refuses to run otherwise

./sqlcast.sh migrations/v1.sql
```

## Usage

```bash
./sqlcast.sh migrations/v1.sql               # run a .sql file
./sqlcast.sh                                 # interactive: paste SQL, blank Enter to execute
echo "SELECT VERSION();" | ./sqlcast.sh      # piped / redirected stdin
./sqlcast.sh --only=us,in migrations/v1.sql  # restrict to specific countries
./sqlcast.sh --allow-destructive drop.sql    # explicitly permit destructive SQL
./sqlcast.sh --continue-on-error seed.sql    # keep running past statement errors
```

The script does not set a default database — your SQL must `USE` one or fully-qualify table names.

| Exit | Meaning |
|---|---|
| `0` | All hosts succeeded |
| `1` | One or more hosts failed or partial |
| `2` | Usage error or destructive SQL refused |

### Continue on error

By default, `mysql` aborts a batch on the first error, leaving earlier statements committed (autocommit) and later ones unrun. For idempotent batch loads (seeding, cleanup, bulk inserts) where you'd rather skip bad rows than abort, pass `--continue-on-error` (or set `SQLCAST_CONTINUE_ON_ERROR=1`). It transparently appends `--force` to the `mysql` invocation. Hosts that emitted any `ERROR` line on stderr are reported in a `partial` bucket with the error count, and the script exits 1 if any host was partial or failed:

```
--- summary ---
ok:     us jp
partial: in(3)
failed: (none)
```

## Configuration

| File | Purpose |
|---|---|
| `countries.conf` | Routing table. One line per host: `<code>  <host>`. `#` comments and blank lines are ignored. `<code>` is what `--only=` accepts. |
| `my.cnf` | Shared credentials. MySQL option-file format; the `[client]` group provides `user` and `password`. |

Both are gitignored — only `*.example` templates are committed.

Environment variables:

| Variable | Description |
|---|---|
| `SQLCAST_COUNTRIES_FILE` | Routing-table path (default `${SCRIPT_DIR}/countries.conf`) |
| `SQLCAST_MY_CNF` | Credentials-file path (default `${SCRIPT_DIR}/my.cnf`) |
| `SQLCAST_ALLOW_DESTRUCTIVE` | Set to `1` to permit destructive SQL (same as `--allow-destructive`) |
| `SQLCAST_CONTINUE_ON_ERROR` | Set to `1` to keep running past errors (same as `--continue-on-error`) |

Connections always include `--ssl-mode=REQUIRED`; the target MySQL must accept TLS.

### Per-host credential override

By default every host authenticates with the shared `[client]` group in `my.cnf`. To give one host a different login, add a `[client_<code>]` section — `<code>` is the country code from `countries.conf`. sqlcast passes `--defaults-group-suffix=_<code>` to `mysql`, so options set in `[client_<code>]` override the same option in `[client]`; anything not set there is inherited. Hosts without a matching section use `[client]` unchanged.

```ini
# my.cnf
[client]
user     = shared_user
password = "shared_password"

[client_us]
password = "us_only_password"   # user inherits from [client]
```

The country code is reused as the option-group suffix and as a path component for per-host error capture, so codes are restricted to `[A-Za-z0-9_.-]` and must begin with an alphanumeric — both validated when `countries.conf` is parsed. A typo'd section name silently falls back to `[client]` — verify with `mysql --defaults-file=my.cnf --defaults-group-suffix=_us --print-defaults` before relying on a new override.

## Destructive-SQL guard

The following statements are refused by default (exit code 2). The scanner strips comments and string literals first, so `DROP` inside a comment or string literal won't false-positive; `/*! … */` and `/*+ … */` blocks are unwrapped before scanning, since MySQL actually executes their contents.

| Category | Refused |
|---|---|
| DDL deletions | `DROP TABLE/DATABASE/SCHEMA/INDEX/VIEW/TRIGGER/FUNCTION/PROCEDURE/EVENT/USER/TABLESPACE/SERVER` |
| Table-level wipe / rename | `TRUNCATE [TABLE]`, `RENAME TABLE` |
| Whole-table DML | `DELETE` / `UPDATE` without `WHERE` (per-statement scan — a single naked statement rejects the whole batch) |

To proceed anyway, pass `--allow-destructive` (or set `SQLCAST_ALLOW_DESTRUCTIVE=1`).

> The guard is a last-resort safety net, not a SQL parser. `ALTER TABLE … DROP COLUMN`, `DELETE … WHERE 1=1`, and outer `DELETE` whose `WHERE` lives only inside a sub-SELECT can still slip through. Review your SQL before running.

## Tests

```bash
./tests/test_sqlcast.sh
```

`mysql` is replaced via a `PATH` stub — no real connections are opened. Includes an interactive-paste regression (requires `expect`; skipped automatically if missing).

## FAQ

**`ERROR 1045 (28000): Access denied` even though the password is correct?**
The MySQL option-file parser treats `#` as the start of an inline comment — if your `my.cnf` `password = ...` line contains `#`, `;`, or whitespace, only the part before `#` is sent for authentication. Double-quote the value:

```ini
[client]
user     = your_user
password = "your#shared!password"
```

## License

MIT — see [LICENSE](LICENSE).

# sqlcast

[English](README.md) | [中文](README.zh.md)

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
chmod 600 my.cnf

./sqlcast.sh migrations/v1.sql
```

## Usage

```bash
./sqlcast.sh migrations/v1.sql               # run a .sql file
./sqlcast.sh                                 # interactive: paste SQL, blank Enter to execute
echo "SELECT VERSION();" | ./sqlcast.sh      # piped / redirected stdin
./sqlcast.sh --only=us,in migrations/v1.sql  # restrict to specific countries
./sqlcast.sh --allow-destructive drop.sql    # explicitly permit destructive SQL
```

The exit code is non-zero if any host fails (CI-friendly). The script does not set a default database — your SQL must `USE` one or fully-qualify table names.

## Configuration

| File | Purpose |
|---|---|
| `countries.conf` | Routing table. One line per host: `<code>  <host>`. `#` comments and blank lines are ignored. `<code>` is what `--only=` accepts. |
| `my.cnf` | Shared credentials. MySQL option-file format; the `[client]` group provides `user` and `password`. |

Both are gitignored — only `*.example` templates are committed.

Environment variables (default to the script's own directory):

| Variable | Default |
|---|---|
| `SQLCAST_COUNTRIES_FILE` | `${SCRIPT_DIR}/countries.conf` |
| `SQLCAST_MY_CNF` | `${SCRIPT_DIR}/my.cnf` |
| `SQLCAST_ALLOW_DESTRUCTIVE` | `1` is equivalent to `--allow-destructive` |

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

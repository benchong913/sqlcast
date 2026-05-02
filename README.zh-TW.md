# sqlcast

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

> Fan out one SQL script to many MySQL hosts — sequentially, with a guard against accidental DROPs.

把同一份 SQL 依序下發到多個 MySQL 主機(典型場景:每個國家一套測試資料庫),最後彙總成功 / 失敗;預設攔截 `DROP` / `TRUNCATE` 以及不帶 `WHERE` 的 `DELETE`、`UPDATE`,避免一份手滑的遷移把所有庫一次掃光。

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

## 快速上手

需要 `mysql` client(macOS:`brew install mysql-client`,屬 keg-only,腳本會自動補 `PATH`;Linux:用發行版套件管理員安裝 `mysql-client` / `default-mysql-client`)。

```bash
git clone <this-repo>
cd sqlcast

cp countries.conf.example countries.conf   # 將 host 替換成真實位址
cp my.cnf.example my.cnf                   # 填入 user / password
chmod 600 my.cnf                           # 必要 —— 權限不對腳本會拒絕執行

./sqlcast.sh migrations/v1.sql
```

## 用法

```bash
./sqlcast.sh migrations/v1.sql               # 執行 .sql 檔
./sqlcast.sh                                 # 互動模式:貼上 SQL,空白行 Enter 即送出
echo "SELECT VERSION();" | ./sqlcast.sh      # 管線 / 重新導向 stdin
./sqlcast.sh --only=us,in migrations/v1.sql  # 只跑指定的國家
./sqlcast.sh --allow-destructive drop.sql    # 顯式放行破壞性 SQL
./sqlcast.sh --continue-on-error seed.sql    # 單條出錯不要中斷後續
```

腳本不會指定預設資料庫,SQL 必須自行 `USE`,或使用完整限定的資料表名稱。

| 退出碼 | 含義 |
|---|---|
| `0` | 所有 host 皆成功 |
| `1` | 有 host 失敗或部分成功(partial) |
| `2` | 用法錯誤,或破壞性 SQL 被攔下 |

### 出錯繼續(continue-on-error)

`mysql` 預設遇到第一條錯誤就中止整批,先前已 commit 的留下、後面的全部丟掉。對於批次 seeding、清理、冪等匯入這類「跳過壞行就好」的場景,加上 `--continue-on-error`(或 `SQLCAST_CONTINUE_ON_ERROR=1`),腳本會透傳 `--force` 給 `mysql`。任意一台 host 在 stderr 出現過 `ERROR` 行,都會被歸到 `partial` 類並附上錯誤條數;只要有任何一台 partial 或 failed,退出碼即為 1:

```
--- summary ---
ok:     us jp
partial: in(3)
failed: (none)
```

## 設定

| 檔案 | 用途 |
|---|---|
| `countries.conf` | 路由表。每行 `<code>  <host>`,`#` 註解與空白行會被忽略。`<code>` 即 `--only=` 接受的值。 |
| `my.cnf` | 共享憑證。MySQL option file 格式,`[client]` group 提供 `user` 與 `password`。 |

兩份檔案皆已加入 `.gitignore`,倉庫只入庫 `*.example` 範本。

環境變數:

| 變數 | 說明 |
|---|---|
| `SQLCAST_COUNTRIES_FILE` | 路由表路徑(預設 `${SCRIPT_DIR}/countries.conf`) |
| `SQLCAST_MY_CNF` | 憑證檔路徑(預設 `${SCRIPT_DIR}/my.cnf`) |
| `SQLCAST_ALLOW_DESTRUCTIVE` | 設為 `1` 放行破壞性 SQL(等同 `--allow-destructive`) |
| `SQLCAST_CONTINUE_ON_ERROR` | 設為 `1` 出錯繼續(等同 `--continue-on-error`) |

連線一律帶上 `--ssl-mode=REQUIRED`,目標 MySQL 必須支援 TLS。

### 單一 host 憑證覆寫

預設所有 host 都用 `my.cnf` 裡共享的 `[client]` group 認證。要讓某個 host 改用不同的登入資訊,加一段 `[client_<code>]`,`<code>` 即 `countries.conf` 中的國家碼。sqlcast 呼叫 `mysql` 時會透傳 `--defaults-group-suffix=_<code>`:`[client_<code>]` 內設定的選項會覆寫 `[client]` 同名選項,沒寫到的仍從 `[client]` 繼承。沒有對應段落的 host 則照舊使用 `[client]`。

```ini
# my.cnf
[client]
user     = shared_user
password = "shared_password"

[client_us]
password = "us_only_password"   # user 自動從 [client] 繼承
```

國家碼同時被當作 option group 的 suffix 使用,並會拼進 per-host 錯誤檔的路徑,因此必須落在 `[A-Za-z0-9_.-]` 範圍內、且首字元必須是英數字 —— 解析 `countries.conf` 時即進行驗證。段名拼錯(例如 `[client_uss]`)會靜默退回 `[client]`,正式使用前請以 `mysql --defaults-file=my.cnf --defaults-group-suffix=_us --print-defaults` 自行確認。

## 破壞性 SQL 守衛

下列語句預設會被攔截並退出(碼 2)。掃描前會先剝除註解與字串字面值,因此寫在註解裡或字串字面值中的 `DROP` 不會誤傷;`/*! … */`、`/*+ … */` 區塊會先被解包再掃描(MySQL 實際上會執行其中內容)。

| 類別 | 攔截對象 |
|---|---|
| DDL 刪除 | `DROP TABLE/DATABASE/SCHEMA/INDEX/VIEW/TRIGGER/FUNCTION/PROCEDURE/EVENT/USER/TABLESPACE/SERVER` |
| 表級清空 / 改名 | `TRUNCATE [TABLE]`、`RENAME TABLE` |
| 全表 DML | `DELETE` / `UPDATE` 不帶 `WHERE`(逐條掃描,只要有一條光禿禿的就整批拒絕) |

需要時請顯式放行(`--allow-destructive` 或 `SQLCAST_ALLOW_DESTRUCTIVE=1`)。

> 守衛只是最後一道安全網,並非 SQL 解析器。`ALTER TABLE … DROP COLUMN`、`DELETE … WHERE 1=1`、以及 `WHERE` 只出現在子查詢裡的外層 `DELETE` 等,仍可能溜過去 —— 執行前請自行確認 SQL。

## 測試

```bash
./tests/test_sqlcast.sh
```

`mysql` 透過 `PATH` stub 頂替,不會建立任何真實連線。包含互動貼上回歸測試(需要 `expect`,缺少時會自動略過)。

## FAQ

**`ERROR 1045 (28000): Access denied`,但密碼明明是對的?**
MySQL option file 解析器會把行內的 `#` 視為註解起點 —— 如果 `my.cnf` 中 `password = ...` 那行包含 `#`、`;` 或空白字元,只有 `#` 之前的部分會被送去認證。用雙引號括起即可:

```ini
[client]
user     = your_user
password = "your#shared!password"
```

## License

MIT — 見 [LICENSE](LICENSE)。

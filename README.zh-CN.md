# sqlcast

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

> Fan out one SQL script to many MySQL hosts — sequentially, with a guard against accidental DROPs.

把同一份 SQL 顺序下发到多个 MySQL 主机(典型场景:每国一套测试库),末尾汇总成功 / 失败,默认拦截 `DROP` / `TRUNCATE` / 不带 `WHERE` 的 `DELETE`、`UPDATE`,避免一份手滑的迁移把所有库扫了。

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

需要 `mysql` client(macOS:`brew install mysql-client`,keg-only,脚本会自己补 PATH;Linux:发行版包管理装 `mysql-client` / `default-mysql-client`)。

```bash
git clone <this-repo>
cd sqlcast

cp countries.conf.example countries.conf   # 替换 host 为真实地址
cp my.cnf.example my.cnf                   # 填 user / password
chmod 600 my.cnf                           # 必填 —— 权限不对脚本会拒绝运行

./sqlcast.sh migrations/v1.sql
```

## 用法

```bash
./sqlcast.sh migrations/v1.sql               # 跑 .sql 文件
./sqlcast.sh                                 # 交互:粘贴 SQL,空行 Enter 执行
echo "SELECT VERSION();" | ./sqlcast.sh      # 管道 / 重定向
./sqlcast.sh --only=us,in migrations/v1.sql  # 只跑指定国家
./sqlcast.sh --allow-destructive drop.sql    # 显式放行破坏性 SQL
./sqlcast.sh --continue-on-error seed.sql    # 单条出错不要中断后续
```

脚本不指定默认数据库,SQL 自行 `USE` 或用全限定名。

| 退出码 | 含义 |
|---|---|
| `0` | 所有 host 成功 |
| `1` | 有 host 失败或 partial |
| `2` | 用法错误或破坏性 SQL 被拦 |

### 出错继续(continue-on-error)

`mysql` 默认遇到第一条错误就中止整批,前面已 commit 的留下、后面的丢掉。批量 seeding / 清理 / 幂等导入这种「跳过坏行就好」的场景,加 `--continue-on-error`(或 `SQLCAST_CONTINUE_ON_ERROR=1`),脚本会透传 `--force` 给 `mysql`。任意一台 host 在 stderr 出过 `ERROR` 都会被归到 `partial` 桶并附错误条数;只要有 partial 或 failed,退出码就是 1:

```
--- summary ---
ok:     us jp
partial: in(3)
failed: (none)
```

## 配置

| 文件 | 作用 |
|---|---|
| `countries.conf` | 路由表。每行 `<code>  <host>`,`#` 注释、空行忽略。`<code>` 给 `--only=` 用。 |
| `my.cnf` | 共享凭证。MySQL option file 格式,`[client]` group 提供 `user` 与 `password`。 |

两份都在 `.gitignore`,仓库里只入库 `*.example` 模板。

环境变量:

| 变量 | 说明 |
|---|---|
| `SQLCAST_COUNTRIES_FILE` | 路由表路径(默认 `${SCRIPT_DIR}/countries.conf`) |
| `SQLCAST_MY_CNF` | 凭证文件路径(默认 `${SCRIPT_DIR}/my.cnf`) |
| `SQLCAST_ALLOW_DESTRUCTIVE` | 设为 `1` 放行破坏性 SQL(等价 `--allow-destructive`) |
| `SQLCAST_CONTINUE_ON_ERROR` | 设为 `1` 出错继续(等价 `--continue-on-error`) |

连接始终带上 `--ssl-mode=REQUIRED`,目标 MySQL 必须支持 TLS。

### 单 host 凭证覆盖

默认所有 host 都用 `my.cnf` 里共享的 `[client]` group 认证。要给某个 host 用不同的登入凭证,加一段 `[client_<code>]`,`<code>` 即 `countries.conf` 里的国家码。sqlcast 调用 `mysql` 时透传 `--defaults-group-suffix=_<code>`:`[client_<code>]` 里写到的 option 覆盖 `[client]` 同名 option,没写的仍从 `[client]` 继承。没有对应段的 host 直接用 `[client]`。

```ini
# my.cnf
[client]
user     = shared_user
password = "shared_password"

[client_us]
password = "us_only_password"   # user 自动从 [client] 继承
```

国家码也作为 option group 的 suffix 使用、并被拼进 per-host err 文件路径,因此必须落在 `[A-Za-z0-9_.-]` 内、首字符为字母或数字,`countries.conf` 解析时即校验。段名拼错(如 `[client_uss]`)会静默回落到 `[client]` —— 上线前用 `mysql --defaults-file=my.cnf --defaults-group-suffix=_us --print-defaults` 自己核一遍。

## 破坏性 SQL 守卫

默认拦截以下语句并退出(码 2)。扫描前剥除注释和字符串字面量,所以注释里、字符串里出现不会误伤;`/*! … */`、`/*+ … */` 内部会被解包再扫(MySQL 实际会执行这些)。

| 类别 | 拦截 |
|---|---|
| DDL 删除 | `DROP TABLE/DATABASE/SCHEMA/INDEX/VIEW/TRIGGER/FUNCTION/PROCEDURE/EVENT/USER/TABLESPACE/SERVER` |
| 表级清空 / 改名 | `TRUNCATE [TABLE]`、`RENAME TABLE` |
| 全表 DML | `DELETE` / `UPDATE` 不带 `WHERE`(逐条扫描,只要有一条不带就整批拒绝) |

需要时显式放行(`--allow-destructive` 或 `SQLCAST_ALLOW_DESTRUCTIVE=1`)。

> 守卫是最后一道安全网,不是 SQL 解析器。`ALTER TABLE … DROP COLUMN`、`DELETE … WHERE 1=1`、`WHERE` 只出现在子查询里的外层 `DELETE` 等仍可能漏过,执行前请自己确认。

## 测试

```bash
./tests/test_sqlcast.sh
```

`mysql` 通过 PATH stub 顶替,不会建立真实连接。包含交互粘贴回归(需要 `expect`,缺失自动跳过)。

## FAQ

**`ERROR 1045 (28000): Access denied`,但密码确实是对的?**
MySQL option file 解析器把行内 `#` 当注释起点 —— 如果 `my.cnf` 里 `password = ...` 含 `#` / `;` / 空格,它只会取 `#` 前那段去认证。用双引号括起即可:

```ini
[client]
user     = your_user
password = "your#shared!password"
```

## License

MIT — see [LICENSE](LICENSE).

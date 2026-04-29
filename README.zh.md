# sqlcast

[English](README.md) | [中文](README.zh.md)

> Fan out one SQL script to many MySQL hosts — sequentially, with a guard against accidental DROPs.

把同一份 SQL 顺序下发到多个 MySQL 主机(典型场景:每国一套测试库),末尾汇总成功 / 失败,默认拦截 `DROP` / `TRUNCATE` / 不带 `WHERE` 的 `DELETE`、`UPDATE`,避免一份手滑的迁移把所有库扫了。

```
$ ./sqlcast.sh migrations/v1.sql
running migrations/v1.sql across: ng gh ug zm ke

=== ng (ng-db.example) ===
=== gh (gh-db.example) ===
=== ug (ug-db.example) ===
=== zm (zm-db.example) ===
=== ke (ke-db.example) ===

--- summary ---
ok:     ng gh ug zm
failed: ke
```

## 快速上手

需要 `mysql` client(macOS:`brew install mysql-client`,keg-only,脚本会自己补 PATH;Linux:发行版包管理装 `mysql-client` / `default-mysql-client`)。

```bash
git clone <this-repo>
cd sqlcast

cp countries.conf.example countries.conf   # 替换 host 为真实地址
cp my.cnf.example my.cnf                   # 填 user / password
chmod 600 my.cnf

./sqlcast.sh migrations/v1.sql
```

## 用法

```bash
./sqlcast.sh migrations/v1.sql               # 跑 .sql 文件
./sqlcast.sh                                 # 交互:粘贴 SQL,空行 Enter 执行
echo "SELECT VERSION();" | ./sqlcast.sh      # 管道 / 重定向
./sqlcast.sh --only=ng,ke migrations/v1.sql  # 只跑指定国家
./sqlcast.sh --allow-destructive drop.sql    # 显式放行破坏性 SQL
```

任一国失败退出码非零(便于接 CI)。脚本不指定默认数据库,SQL 自行 `USE` 或用全限定名。

## 配置

| 文件 | 作用 |
|---|---|
| `countries.conf` | 路由表。每行 `<code>  <host>`,`#` 注释、空行忽略。`<code>` 给 `--only=` 用。 |
| `my.cnf` | 共享凭证。MySQL option file 格式,`[client]` group 提供 `user` 与 `password`。 |

两份都在 `.gitignore`,仓库里只入库 `*.example` 模板。

环境变量(默认指向脚本同目录):

| 变量 | 默认 |
|---|---|
| `SQLCAST_COUNTRIES_FILE` | `${SCRIPT_DIR}/countries.conf` |
| `SQLCAST_MY_CNF` | `${SCRIPT_DIR}/my.cnf` |
| `SQLCAST_ALLOW_DESTRUCTIVE` | `1` 等价于 `--allow-destructive` |

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

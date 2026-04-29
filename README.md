# sqlcast

把同一份 SQL 一次性下发到 `countries.conf` 里所有国家的测试 MySQL,顺序执行,末尾汇总成功/失败。

> ⚠️ `countries.conf` 与 `my.cnf` 含内网 hostname / 密码,**不要提交**(均在 `.gitignore`)。仓库里只入库 `*.example` 模板。

## 安装

```bash
brew install mysql-client    # macOS,keg-only;脚本会自动从 brew 路径补 PATH

cp countries.conf.example countries.conf   # 替换成真实 host
cp my.cnf.example my.cnf                    # 填上 user / password
chmod 600 my.cnf
```

默认读 `${SCRIPT_DIR}/my.cnf` 与 `${SCRIPT_DIR}/countries.conf`,分别可用
`SQLCAST_MY_CNF=` 与 `SQLCAST_COUNTRIES_FILE=` 覆盖。

## 用法

```bash
./sqlcast.sh migrations/v1.sql               # 跑 .sql 文件
./sqlcast.sh                                 # 交互:粘贴 SQL,空行 Enter 执行(或 Ctrl-D)
echo "SELECT VERSION();" | ./sqlcast.sh      # 管道 / 重定向
./sqlcast.sh --only=ng,ke migrations/v1.sql  # 只跑指定国家
```

任一国失败,退出码非零(便于接 CI)。脚本本身不指定默认数据库,SQL 自行 `USE` 或用全限定名。

## 破坏性 SQL 守卫

默认拦截以下语句并退出(码 2)。扫描前会剥除注释和字符串字面量,所以注释里、字符串里出现不会误伤;`/*! … */`、`/*+ … */` 内部会被解包再扫(MySQL 实际会执行这些)。

| 类别 | 拦截 |
|---|---|
| DDL 删除 | `DROP TABLE/DATABASE/SCHEMA/INDEX/VIEW/TRIGGER/FUNCTION/PROCEDURE/EVENT/USER/TABLESPACE/SERVER` |
| 表级清空 / 改名 | `TRUNCATE [TABLE]`、`RENAME TABLE` |
| 全表 DML | `DELETE` / `UPDATE` 不带 `WHERE`(逐条扫描,只要有一条不带就整批拒绝) |

确实需要时显式放行:

```bash
./sqlcast.sh --allow-destructive drop_old_indexes.sql
SQLCAST_ALLOW_DESTRUCTIVE=1 ./sqlcast.sh drop_old_indexes.sql
```

> 守卫是最后一道安全网,不是 SQL 解析器。`ALTER TABLE … DROP COLUMN`、`DELETE … WHERE 1=1`、`WHERE` 只出现在子查询里的外层 `DELETE` 等仍可能漏过,执行前请自己确认。

## countries.conf

每行一个国家,空白分隔两字段;`#` 注释、空行忽略。`--only=` 用 `<code>` 过滤。

```
<code>  <host>
```

## FAQ

**`ERROR 1045 (28000): Access denied`,但密码确实是对的?**
MySQL option file 解析器会把行内 `#` 当注释起点——如果 `my.cnf` 里 `password = ...` 含 `#` / `;` / 空格,它只会取 `#` 前那段去认证。用双引号括起即可:

```ini
[client]
user     = your_user
password = "your#shared!password"
```

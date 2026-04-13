# Hive Table-Level Replication Patterns

## Overview

The `HIVE_DB` argument supports both full database and table-level replication
using Hive's `REPL DUMP` regex pattern syntax.

| Format | Example | Behavior |
|--------|---------|----------|
| `db_name` | `sales` | Replicate all tables in the database |
| `db_name.'pattern'` | `sales.'t1'` | Replicate only tables matching the regex pattern |

The table pattern must be enclosed in single quotes and follows Java regex syntax.
Patterns are anchored by default (match the full table name), support lookahead
for exclusions (`(?!...)`), and are case-sensitive.

The Hive REPL DUMP syntax for table-level replication is:

```sql
REPL DUMP <db_name>.'<regex_pattern>' WITH (<properties>);
```

---

## Scenarios

All examples below show the value to pass as `HIVE_DB`.

### Scenario 1: Full Database Dump

```
HIVE_DB="sales"
```

Dumps all tables in the `sales` database.

---

### Scenario 2: All Tables via Regex

```
HIVE_DB="sales.'.*'"
```

Same as a full dump. Matches every table name.

---

### Scenario 3: Specific Tables (Include via OR)

```
HIVE_DB="sales.'t1|orders|course'"
```

- Includes: `t1`, `orders`, `course`

---

### Scenario 4: Pattern Match (Numeric Tables)

```
HIVE_DB="sales.'t[0-9]+'"
```

- Includes: `t1`, `t2`, `t3`, `t10`

---

### Scenario 5: Exclude One Table (Basic)

```
HIVE_DB="sales.'(?!t1).*'"
```

Excludes `t1` from the dump.

Important: This also excludes `t10` because `(?!t1)` matches the prefix.
To exclude only the exact table `t1`, see Scenario 6.

---

### Scenario 6: Exclude Exact Table Only (Correct Way)

```
HIVE_DB="sales.'(?!t1$).*'"
```

The `$` anchors the exclusion to an exact match.

- Excludes: `t1` only
- Includes: `t10`, `t2`, `t3`, `orders`, `course`

Note: Escape `$` as `\$` in the shell to prevent variable expansion.

---

### Scenario 7: Prefix + Exclusion

```
HIVE_DB="sales.'t(?!1$).*'"
```

All tables starting with `t`, excluding `t1` exactly.

- Includes: `t2`, `t3`, `t10`
- Excludes: `t1`

---

### Scenario 8: Exclude Multiple Exact Tables

```
HIVE_DB="sales.'t(?!1$|2$).*'"
```

All `t`-prefixed tables except `t1` and `t2`.

- Includes: `t3`, `t10`
- Excludes: `t1`, `t2`

---

### Scenario 9: Exclude All Numeric Tables

```
HIVE_DB="sales.'(?!t[0-9]+$).*'"
```

- Includes: `course`, `orders`, `stores`, `sales_data`, `q4`
- Excludes: `t1`, `t2`, `t3`, `t10`

---

### Scenario 10: Only Non-t Tables

```
HIVE_DB="sales.'(?!t).*'"
```

Includes all tables that do not start with `t`.

---

### Scenario 11: Exact Match vs Prefix

Exact match (only `t1`):
```
HIVE_DB="sales.'t1'"
```

Prefix match (`t1` and `t10`):
```
HIVE_DB="sales.'t1.*'"
```

---

### Scenario 12: Ends With Pattern

```
HIVE_DB="sales.'.*data'"
```

- Matches: `sales_data`

---

### Scenario 13: Contains Pattern

```
HIVE_DB="sales.'.*or.*'"
```

- Matches: `orders`, `stores`

---

### Scenario 14: Length-Based Match

```
HIVE_DB="sales.'t[0-9]{2}'"
```

Matches `t` followed by exactly two digits.

- Matches: `t10`
- Does not match: `t1`, `t2` (single digit)

---

### Scenario 15: No Match Case

```
HIVE_DB="sales.'xyz.*'"
```

No tables match. The REPL DUMP command succeeds but produces an empty dump.

---

## How the Script Handles Table Patterns

The script parses `HIVE_DB` into separate components:

```
Input:  sales.'(t1|t2)'

HIVE_DB_NAME       = sales             (database name only)
HIVE_TABLE_PATTERN = '(t1|t2)'         (table regex)
HIVE_REPL_SPEC     = sales.'(t1|t2)'   (full REPL DUMP identifier)
```

The table pattern is used only in REPL DUMP. All other operations use the
database name:

| Operation | Variable | Example |
|-----------|----------|---------|
| REPL DUMP | `HIVE_REPL_SPEC` | `REPL DUMP sales.'(t1\|t2)' WITH(...)` |
| REPL LOAD | `HIVE_DB_NAME` | `REPL LOAD sales INTO sales WITH(...)` |
| REPL STATUS | `HIVE_DB_NAME` | `REPL STATUS sales` |
| SHOW DATABASES | `HIVE_DB_NAME` | `SHOW DATABASES LIKE 'sales'` |
| HDFS paths | `HIVE_DB_NAME` | `hdfs://ns/user/hive/repl/sales` |
| Scheduled query names | `HIVE_DB_NAME` | `sq_repl_dump_sales` |
| DistCp YARN tags | `HIVE_DB_NAME` | `hive-repl-distcp-sales` |
| Log file name | `HIVE_DB_NAME` | `hive_bdr_sales_20250413.log` |

---

## Scheduled Queries and Table Patterns

Scheduled query names are derived from the database name, not the table pattern:

```
sq_repl_dump_<db_name>
sq_repl_load_<db_name>
```

This means one scheduled replication per database. To change the table pattern
for an existing scheduled query:

1. Drop the existing scheduled queries on source and destination:
   ```sql
   DROP SCHEDULED QUERY sq_repl_dump_sales;
   DROP SCHEDULED QUERY sq_repl_load_sales;
   ```

2. Re-run the script with the new pattern.

---

## Quick Reference

| Goal | HIVE_DB value |
|------|---------------|
| All tables | `sales` |
| Single table | `sales.'t1'` |
| Multiple specific tables | `sales.'(t1\|orders\|course)'` |
| Tables matching prefix | `sales.'t.*'` |
| Tables matching suffix | `sales.'.*data'` |
| Tables containing string | `sales.'.*or.*'` |
| Exclude one table | `sales.'(?!t1$).*'` |
| Exclude multiple tables | `sales.'(?!t1$\|t2$).*'` |
| Exclude by prefix | `sales.'(?!t).*'` |
| Exact digit count | `sales.'t[0-9]{2}'` |

# Project 02 — Query Tuning Case Studies

**Status:** ✅ Complete · **Completed:** October 2026

---

## Objective

Diagnose and resolve five classic SQL Server performance anti-patterns on a ~10 GB `StackOverflow2010` workload — Key Lookups, Implicit Conversions (`CONVERT_IMPLICIT`), Non-SARGable Predicates, Missing Composite Indexes, and Parameter Sniffing — and prove every improvement with **measured before/after `SET STATISTICS IO, TIME ON` figures**.

---

## Method

Every case study followed the same repeatable engineering discipline:

1. **Measure baseline** — capture `SET STATISTICS IO, TIME ON` (`logical reads`, `Scan count`, `CPU time`, `elapsed time`) and inspect the Actual Execution Plan (`Ctrl + M`).
2. **Diagnose** — identify the root-cause operator in the execution plan (Key Lookup, `CONVERT_IMPLICIT` warning on `SELECT`, non-SARGable scalar function on an indexed column, parallel Clustered Index Scan, or cached plan reuse across skewed parameters).
3. **Hypothesise** — state the exact index or query change and *why* it changes the optimizer's physical operator choice.
4. **Change** — apply a single targeted change.
5. **Re-measure** — run the exact same workload and compare logical reads, CPU, and elapsed duration.

**Why logical reads is the primary metric:** wall-clock duration fluctuates with buffer-pool state and background CPU load. Logical reads (8 KB pages read from the buffer pool) is a deterministic measure of the actual I/O work performed by the storage engine.

---

## Summary of Measured Results

| # | Case Study | Root Cause | Fix Applied | Logical Reads (`Before → After`) | Read Reduction | CPU (`Before → After`) | Elapsed (`Before → After`) |
|---:|---|---|---|---:|---:|---:|---:|
| **1** | **Key Lookup (`dbo.Users`)** | Narrow index on `(Reputation DESC)` forced random Key Lookups per qualifying row | Covering index with `INCLUDE (DisplayName, CreationDate, Location)` + `PAGE` compression | **`56,342 → 97`** | **99.83%** | `125 ms → 47 ms` | `325 ms → 102 ms` |
| **2** | **Implicit Conversion (`dbo.UserAccountLookup`)** | `NVARCHAR(40)` parameter against `VARCHAR(40)` column caused column-side `CONVERT_IMPLICIT` scan | Matched parameter datatype (`VARCHAR(40)`) to column datatype | **`1,777 → 3`** | **99.83%** | `125 ms → 0 ms` | `192 ms → 1 ms` |
| **3** | **Non-SARGable Predicate (`dbo.Users`)** | `WHERE YEAR(CreationDate) = 2010 AND MONTH(CreationDate) = 5` prevented B-tree seek | Rewrote to half-open range `CreationDate >= '2010-05-01' AND < '2010-06-01'` | **`1,262 → 86`** | **93.19%** | `344 ms → 15 ms` | `473 ms → 117 ms` |
| **4** | **Missing Index (`dbo.Comments`, 3.87M rows)** | Parallel Clustered Index Scan across entire `Comments` table (`Scan count 13`) | Engineered composite index `ON (UserId, Score) INCLUDE (PostId, CreationDate)` | **`171,982 → 4`** | **99.998%** | `1,658 ms → 0 ms` | `503 ms → 69 ms` |
| **5** | **Parameter Sniffing (`dbo.Badges`, 1.1M rows)** | Cached Seek + Key Lookup plan compiled for rare `'Legendary'` (`131` reads) reused for common `'Student'` | Added `OPTION (RECOMPILE)` so skewed values compile cardinality-appropriate plans | **`411,268 → 6,637`** | **98.39%** | `703 ms → 642 ms` | `749 ms → 546 ms` |

Full verbatim `SET STATISTICS IO, TIME ON` output is saved in [`evidence/query-tuning-statistics-io.txt`](../evidence/query-tuning-statistics-io.txt), and the repeatable script is committed at [`scripts/query-tuning/01-run-all-case-studies.sql`](../scripts/query-tuning/01-run-all-case-studies.sql).

---

## Case Study 1 — Key Lookup on `dbo.Users`

### The Query

```sql
SELECT Id, DisplayName, Reputation, CreationDate, Location
FROM dbo.Users
WHERE Reputation >= 5000
ORDER BY Reputation DESC;
```

### Baseline (Narrow Index `IX_Users_Reputation ON dbo.Users (Reputation DESC)`)

```text
Table 'Users'. Scan count 1, logical reads 56342, physical reads 140, page server reads 0, read-ahead reads 6288, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 125 ms,  elapsed time = 325 ms.
```

### Diagnosis

`IX_Users_Reputation` only stores `Reputation` (key) and `Id` (the clustered key pointer). To return `DisplayName`, `CreationDate`, and `Location`, the execution plan performs an **Index Seek (NonClustered)** on `IX_Users_Reputation` paired with a **Key Lookup (Clustered)** on `PK_Users_Id` through a Nested Loops join. Because the Key Lookup executes once per qualifying row, reading ~18,000+ qualifying rows required **`56,342` logical page reads** (~440 MB of buffer pool traffic — over 7× the size of the entire `Users` table).

### Hypothesis

Adding `DisplayName`, `CreationDate`, and `Location` as non-key `INCLUDE` columns at the leaf level makes the index **covering** for this query. The optimizer can satisfy both the `WHERE`/`ORDER BY` and the `SELECT` list from a single ordered range scan of the nonclustered index, eliminating the Key Lookup and Nested Loops join completely.

### Change Applied

```sql
CREATE NONCLUSTERED INDEX IX_Users_Reputation_Covering
ON dbo.Users (Reputation DESC)
INCLUDE (DisplayName, CreationDate, Location)
WITH (DATA_COMPRESSION = PAGE);
GO

DROP INDEX IF EXISTS IX_Users_Reputation ON dbo.Users;
GO
```

### After (Covering Index `IX_Users_Reputation_Covering`)

```text
Table 'Users'. Scan count 1, logical reads 97, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 47 ms,  elapsed time = 102 ms.
```

### Measured Result

| Metric | Before (Seek + Key Lookup) | After (Covering Index Seek) | Improvement |
|---|---:|---:|---:|
| **Logical reads** | `56,342` | **`97`** | **-99.83% (`580×` fewer reads)** |
| **Physical / read-ahead reads** | `140` / `6,288` | **`0` / `0`** | **-100%** |
| **CPU time** | `125 ms` | **`47 ms`** | **-62.4%** |
| **Elapsed time** | `325 ms` | **`102 ms`** | **-68.6%** |

### Trade-offs

A covering index is wider than a single-column index and must be maintained on every `INSERT`, `DELETE`, or `UPDATE` touching `Reputation`, `DisplayName`, `CreationDate`, or `Location`. Applying `DATA_COMPRESSION = PAGE` mitigates the leaf-level storage footprint, and in production I would monitor `sys.dm_db_index_usage_stats` (`user_seeks` vs `user_updates`) to confirm read savings outweigh write maintenance.

---

## Case Study 2 — Implicit Conversion (`CONVERT_IMPLICIT`)

### The Scenario & Query

Created `dbo.UserAccountLookup` (299,398 rows from `dbo.Users`) with an indexed `AccountCode VARCHAR(40)` column (`IX_UserAccountLookup_AccountCode ON (AccountCode) INCLUDE (DisplayName, Reputation)`).

When an ORM (such as Entity Framework or JDBC) passes a Unicode string parameter (`@Bad nvarchar(40) = N'ACC-0022656'`), SQL Server's **Data Type Precedence** rules dictate that `varchar` (lower precedence) must be converted up to `nvarchar` (higher precedence). Because the column is the lower-precedence type, SQL Server applies `CONVERT_IMPLICIT(nvarchar(40), [AccountCode], 0)` to **every row in the index**, destroying SARGability.

```sql
-- BEFORE: NVARCHAR(40) parameter against VARCHAR(40) indexed column
DECLARE @Bad nvarchar(40) = N'ACC-0022656';
SELECT UserId, AccountCode, DisplayName, Reputation
FROM dbo.UserAccountLookup
WHERE AccountCode = @Bad;

-- AFTER: Matching VARCHAR(40) parameter
DECLARE @Good varchar(40) = 'ACC-0022656';
SELECT UserId, AccountCode, DisplayName, Reputation
FROM dbo.UserAccountLookup
WHERE AccountCode = @Good;
```

### Baseline (`@Bad nvarchar(40)` — Column-Side `CONVERT_IMPLICIT`)

```text
(1 row affected)
Table 'UserAccountLookup'. Scan count 1, logical reads 1777, physical reads 0, page server reads 0, read-ahead reads 70, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 125 ms,  elapsed time = 192 ms.
```

### After (`@Good varchar(40)` — Matching Data Types)

```text
(1 row affected)
Table 'UserAccountLookup'. Scan count 1, logical reads 3, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 0 ms,  elapsed time = 1 ms.
```

### Measured Result

| Metric | Before (`NVARCHAR` Param → Index Scan) | After (`VARCHAR` Param → Index Seek) | Improvement |
|---|---:|---:|---:|
| **Rows returned** | `1` | `1` | Identical result |
| **Logical reads** | `1,777` | **`3`** | **-99.83% (`592×` fewer reads)** |
| **CPU time** | `125 ms` | **`0 ms`** | **-100%** |
| **Elapsed time** | `192 ms` | **`1 ms`** | **-99.48%** |

---

## Case Study 3 — Non-SARGable Predicate (`YEAR()` / `MONTH()` vs Date Range)

### The Scenario & Query

With a covering nonclustered index `IX_Users_CreationDate ON dbo.Users (CreationDate) INCLUDE (DisplayName, Reputation)`, a report filters for users registered in May 2010 (`15,795` rows).

```sql
-- BEFORE (Non-SARGable): functions wrapped around the indexed CreationDate column
SELECT Id, DisplayName, Reputation, CreationDate
FROM dbo.Users
WHERE YEAR(CreationDate) = 2010
  AND MONTH(CreationDate) = 5;

-- AFTER (SARGable): half-open date range predicate
SELECT Id, DisplayName, Reputation, CreationDate
FROM dbo.Users
WHERE CreationDate >= '2010-05-01T00:00:00'
  AND CreationDate <  '2010-06-01T00:00:00';
```

### Baseline (Non-SARGable `YEAR()` and `MONTH()`)

```text
(15795 rows affected)
Table 'Users'. Scan count 1, logical reads 1262, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 344 ms,  elapsed time = 473 ms.
```

### After (SARGable Half-Open Range)

```text
(15795 rows affected)
Table 'Users'. Scan count 1, logical reads 86, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 15 ms,  elapsed time = 117 ms.
```

### Measured Result

| Metric | Before (Index Scan) | After (Index Seek) | Improvement |
|---|---:|---:|---:|
| **Rows returned** | `15,795` | `15,795` | Identical result |
| **Logical reads** | `1,262` | **`86`** | **-93.19% (`14.7×` fewer reads)** |
| **CPU time** | `344 ms` | **`15 ms`** | **-95.64% (`23×` less CPU)** |
| **Elapsed time** | `473 ms` | **`117 ms`** | **-75.26%** |

**Why half-open ranges (`>= start AND < next_period_start`) beat `BETWEEN`:** `BETWEEN '2010-05-01' AND '2010-05-31 23:59:59.997'` is fragile across `datetime`, `datetime2`, and `smalldatetime` rounding rules. `>= '2010-05-01' AND < '2010-06-01'` is exact for every temporal data type in SQL Server.

---

## Case Study 4 — Missing Index on a 3.87-Million-Row Table (`dbo.Comments`)

### The Query

```sql
SELECT Id, PostId, Score, CreationDate
FROM dbo.Comments
WHERE UserId = 22656
  AND Score > 5
ORDER BY CreationDate DESC;
```

### Baseline (No Nonclustered Index — Parallel Clustered Index Scan)

```text
(536 rows affected)
Table 'Worktable'. Scan count 0, logical reads 0, physical reads 0...
Table 'Comments'. Scan count 13, logical reads 171982, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 1658 ms,  elapsed time = 503 ms.
```

### Diagnosis & Index Design

Without a nonclustered index on `UserId`, SQL Server scanned the entire `dbo.Comments` clustered index across parallel threads (`Scan count 13`), reading **`171,982` pages (~1.34 GB of memory reads)** and burning **`1,658 ms` of CPU** to return just `536` rows.

Rather than blindly copying `sys.dm_db_missing_index_details` recommendations (which do not order key columns by selectivity or account for existing indexes), I designed the composite index using the **Equality → Inequality → Include** rule:
1. **Equality key first:** `UserId` (`WHERE UserId = 22656`) narrows the search space to one user's rows immediately.
2. **Inequality key second:** `Score` (`AND Score > 5`) allows a clean range seek within that user's slice of the B-tree.
3. **Included columns:** `PostId, CreationDate` cover the `SELECT` list and `ORDER BY` without bloating the intermediate B-tree pages (`Id` is already present as the clustered key locator).

```sql
CREATE NONCLUSTERED INDEX IX_Comments_UserId_Score
ON dbo.Comments (UserId, Score)
INCLUDE (PostId, CreationDate)
WITH (DATA_COMPRESSION = PAGE);
GO
```

### After (Composite Index `IX_Comments_UserId_Score`)

```text
(536 rows affected)
Table 'Worktable'. Scan count 0, logical reads 0, physical reads 0...
Table 'Comments'. Scan count 1, logical reads 4, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 0 ms,  elapsed time = 69 ms.
```

### Measured Result

| Metric | Before (Parallel Clustered Scan) | After (Single-Thread Index Seek) | Improvement |
|---|---:|---:|---:|
| **Rows returned** | `536` | `536` | Identical result |
| **Scan count** | `13` (parallel scan) | **`1`** (serial seek) | Freed 12 worker threads |
| **Logical reads** | `171,982` | **`4`** | **-99.998% (`42,995×` fewer reads!)** |
| **CPU time** | `1,658 ms` | **`0 ms`** | **-100%** |
| **Elapsed time** | `503 ms` | **`69 ms`** | **-86.28%** |

---

## Case Study 5 — Parameter Sniffing (`dbo.Badges`)

### The Scenario

`dbo.Badges` (~1.1 million rows) has extreme data skew on `Name`:
- `'Legendary'` is rare (~36 rows).
- `'Student'` is heavily populated (~220,000+ rows).

With a narrow nonclustered index `IX_Badges_Name ON dbo.Badges (Name)` and stored procedure `dbo.usp_GetBadgesByName`:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_GetBadgesByName
    @BadgeName nvarchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UserId, Name, Date
    FROM dbo.Badges
    WHERE Name = @BadgeName;
END
GO
```

### Baseline: Reproducing the Bad Cached Plan

1. **Cleared cache (`DBCC FREEPROCCACHE`) and called with the rare parameter first (`@BadgeName = N'Legendary'`):**
   ```text
   Table 'Badges'. Scan count 1, logical reads 131, physical reads 0...
   SQL Server Execution Times:
      CPU time = 0 ms,  elapsed time = 27 ms.
   ```
   SQL Server sniffed `'Legendary'`, estimated ~36 rows, and cached an **Index Seek (`IX_Badges_Name`) + Key Lookup (`PK_Badges_Id`)** plan.

2. **Called immediately with the common parameter (`@BadgeName = N'Student'`):**
   ```text
   Table 'Badges'. Scan count 1, logical reads 411268, physical reads 0...
   SQL Server Execution Times:
      CPU time = 703 ms,  elapsed time = 749 ms.
   ```
   Because SQL Server reused the cached Seek + Key Lookup plan for `'Student'`, it executed hundreds of thousands of random Key Lookups against `PK_Badges_Id` — performing **`411,268` logical reads** (over **60× the size of the entire `Badges` table**, which is only `6,637` pages!).

### Fix Applied & Trade-off Analysis

Added statement-level `OPTION (RECOMPILE)` so SQL Server compiles a fresh plan using the actual runtime parameter value on each call:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_GetBadgesByName
    @BadgeName nvarchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UserId, Name, Date
    FROM dbo.Badges
    WHERE Name = @BadgeName
    OPTION (RECOMPILE);
END
GO
```

### After (`@BadgeName = N'Student'` with `OPTION (RECOMPILE)`)

```text
SQL Server parse and compile time:
   CPU time = 0 ms, elapsed time = 5 ms.
Table 'Badges'. Scan count 13, logical reads 6637, physical reads 0...
SQL Server Execution Times:
   CPU time = 642 ms,  elapsed time = 546 ms.
```

### Measured Result (`@BadgeName = N'Student'`)

| Metric | Before (Sniffed `'Legendary'` Plan) | After (`OPTION (RECOMPILE)`) | Improvement |
|---|---:|---:|---:|
| **Execution Plan** | Index Seek + Key Lookup (Nested Loops) | Clustered Index Scan | Optimal for high row count |
| **Logical reads** | `411,268` | **`6,637`** | **-98.39% (`62×` fewer reads)** |
| **Compile overhead** | `0 ms` | `5 ms` | Negligible (`5 ms` elapsed) |
| **Elapsed time** | `749 ms` | **`546 ms`** | **-27.10%** |

**Comparing the 4 production remedies for Parameter Sniffing:**
1. **Make the index covering (`INCLUDE (UserId, Date)`):** Best long-term fix when feasible — removes the Key Lookup entirely so a single Index Seek plan works well for both `'Legendary'` and `'Student'`.
2. **`OPTION (RECOMPILE)`:** Ideal for moderate-frequency queries with severe data skew (paid `5 ms` compile time to save `404,631` logical reads). Bad for procedures called thousands of times per second.
3. **`OPTION (OPTIMIZE FOR (@BadgeName = N'Student'))`:** Optimizes for the heavy case so it never blows up the buffer pool with 411k random lookups, at the cost of scanning `6,637` pages for rare badges.
4. **Query Store Plan Forcing (`sp_query_store_force_plan`):** Zero-code-change emergency fix during a live production incident while developers prepare a permanent index or procedure change.

---

## Overall Findings & Lessons Learned

1. **Logical reads exposes hidden bombs that wall-clock time hides:** In Case Study 5, `'Student'` with the bad plan ran in `749 ms` because the whole `Badges` table was warm in RAM — yet it did **`411,268` logical reads** (~3.2 GB of buffer pool churn). Under concurrent production load or cold cache, 411k random lookups causes severe `PAGEIOLATCH_SH` contention.
2. **A narrow nonclustered index can be worse than no index at all past the tipping point:** In Case Study 1, forcing the narrow index on `Reputation >= 5000` required `56,342` logical reads (`7.4×` more pages than scanning the entire `Users` clustered index), whereas adding 3 `INCLUDE` columns dropped the cost to `97` logical reads.
3. **Data Type Precedence (`NVARCHAR` > `VARCHAR`) is why ORM queries scan indexed columns:** Passing an `NVARCHAR` parameter against a `VARCHAR` column forces SQL Server to apply `CONVERT_IMPLICIT` to the column on every row (`1,777` reads vs `3` reads).
4. **Explicit `WITH (INDEX(...))` hints are validated at batch compile time (`Msg 308`):** Putting `CREATE INDEX` and `SELECT ... WITH (INDEX(...))` in the same batch without `GO` fails at compile time because the index does not exist until the DDL statement actually executes.

---

## Evidence Index

| Artefact | File |
|---|---|
| Verbatim `SET STATISTICS IO, TIME ON` logs (Cases 1–5) | [`evidence/query-tuning-statistics-io.txt`](../evidence/query-tuning-statistics-io.txt) |
| Repeatable SQL script for all 5 case studies | [`scripts/query-tuning/01-run-all-case-studies.sql`](../scripts/query-tuning/01-run-all-case-studies.sql) |
| `Msg 308` compile-time index hint resolution write-up | [`runbooks/troubleshooting-log.md`](../runbooks/troubleshooting-log.md) |

---

## Interview Talking Points

- Why logical reads beats elapsed duration as a primary query-tuning metric
- What a Key Lookup is, what the tipping point is, and the two ways to eliminate a lookup (covering `INCLUDE` columns or changing the clustered index key)
- Why `CONVERT_IMPLICIT` happens when comparing `VARCHAR` columns to `NVARCHAR` parameters, and how to spot `PlanAffectingConvert` warnings in execution plans
- Why `WHERE YEAR(CreationDate) = 2010` is non-SARGable and why half-open date ranges (`>=` and `<`) are safer than `BETWEEN`
- Why you shouldn't blindly create every index suggested by `sys.dm_db_missing_index_details`
- How Parameter Sniffing happens, why it is a feature until data is skewed, and the trade-offs between a covering index, `OPTION (RECOMPILE)`, `OPTIMIZE FOR`, and Query Store plan forcing

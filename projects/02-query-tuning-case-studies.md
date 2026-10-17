# Project 02 — Query Tuning Case Studies

**Status:** 🔲 Planned · **Week 5** · **Est. 10 hours**

> **How to use this file:** Case Study 1 is a worked template showing the required level of detail. Replace its `[FILL IN]` values with your real results, then repeat the pattern for four more queries. Delete this quote block when done.

---

## Objective

Identify the five worst-performing queries in a 10 GB workload, tune each one, and document the improvement with **measured before/after figures** — not impressions.

---

## Method

Every case study follows the same discipline:

1. **Identify** — find the query with `sp_BlitzCache` (sorted by reads, CPU or duration)
2. **Measure baseline** — `SET STATISTICS IO, TIME ON`, capture the actual execution plan
3. **Diagnose** — read the plan: scans, key lookups, spills, bad estimates, implicit conversions
4. **Hypothesise** — state the intended fix *and why* before making it
5. **Change** — one change at a time
6. **Re-measure** — same query, same conditions
7. **Record** — before/after logical reads, CPU, duration, plan screenshots

**Logical reads is the primary metric.** Duration varies with cache state and server load; logical reads is a stable measure of work done.

Clear caches between tests (lab only — never in production):

```sql
DBCC FREEPROCCACHE;
DBCC DROPCLEANBUFFERS;
```

---

## Summary of results

| # | Problem | Fix | Logical reads before → after | Improvement |
|---|---|---|---|---|
| 1 | Key lookup on `Users` | Covering index with INCLUDE | `[FILL IN]` | `[FILL IN]` |
| 2 | Implicit conversion | Corrected parameter datatype | `[FILL IN]` | `[FILL IN]` |
| 3 | Non-SARGable predicate | Rewrote to range predicate | `[FILL IN]` | `[FILL IN]` |
| 4 | Missing index / table scan | Targeted nonclustered index | `[FILL IN]` | `[FILL IN]` |
| 5 | Parameter sniffing | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |

---

## Case Study 1 — Key lookup on the Users table

### The query

```sql
SELECT Id, DisplayName, Reputation, CreationDate, Location
FROM dbo.Users
WHERE Reputation > 100000
ORDER BY Reputation DESC;
```

### Baseline

```
Table 'Users'. Scan count 1, logical reads [FILL IN], physical reads [FILL IN]
CPU time = [FILL IN] ms,  elapsed time = [FILL IN] ms
```

`[FILL IN — screenshot: evidence/screenshots/cs1-plan-before.png]`

### Diagnosis

`[FILL IN. Expected pattern: an Index Seek on a nonclustered index on Reputation, followed by a Key Lookup back to the clustered index to fetch DisplayName, CreationDate and Location. The Key Lookup executes once per qualifying row, so cost scales with row count. The optimiser may reject the index entirely past the tipping point and scan instead.]`

### Hypothesis

Adding the returned columns as `INCLUDE` columns makes the index *covering*, eliminating the lookup entirely.

### Change

```sql
CREATE NONCLUSTERED INDEX IX_Users_Reputation_Covering
ON dbo.Users (Reputation DESC)
INCLUDE (DisplayName, CreationDate, Location)
WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
```

### After

```
Table 'Users'. Scan count 1, logical reads [FILL IN]
CPU time = [FILL IN] ms,  elapsed time = [FILL IN] ms
```

`[FILL IN — screenshot: evidence/screenshots/cs1-plan-after.png]`

### Result

| Metric | Before | After | Change |
|---|---|---|---|
| Logical reads | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| CPU (ms) | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| Duration (ms) | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |

### Trade-offs

**A covering index is not free.** It costs disk space, and every `INSERT`/`UPDATE`/`DELETE` on those columns must maintain it. In production I'd check write volume against read frequency before adding it, and check `sys.dm_db_index_usage_stats` afterwards to confirm it's actually being used.

`[FILL IN — index size added, measured via sp_BlitzIndex]`

---

## Case Study 2 — Implicit conversion

`[FILL IN. Setup: query a column typed INT or VARCHAR while passing the other type — e.g. WHERE SomeIntColumn = '12345' or an NVARCHAR parameter against a VARCHAR column. Watch the plan add CONVERT_IMPLICIT and downgrade a seek to a scan. Fix by matching datatypes. sp_BlitzCache flags these automatically.]`

---

## Case Study 3 — Non-SARGable predicate

`[FILL IN. Setup: WHERE YEAR(CreationDate) = 2010 — wrapping the column in a function prevents index seeks. Rewrite as WHERE CreationDate >= '2010-01-01' AND CreationDate < '2011-01-01'. Same results, index seek instead of scan.]`

---

## Case Study 4 — Missing index

`[FILL IN. Find a genuine table scan, check the missing index DMVs, but do NOT blindly apply the suggestion — the DMVs over-suggest, ignore existing indexes, and don't consider column order. Design the index yourself and justify the key column order.]`

```sql
SELECT TOP 20
    ROUND(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans), 0) AS score,
    d.statement, d.equality_columns, d.inequality_columns, d.included_columns
FROM sys.dm_db_missing_index_groups g
JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle
JOIN sys.dm_db_missing_index_details d ON d.index_handle = g.index_handle
ORDER BY score DESC;
```

---

## Case Study 5 — Parameter sniffing

`[FILL IN. Setup: a stored procedure filtering on a heavily skewed column. Run it first with a selective parameter (plan: seek), then with a non-selective one (reuses the seek plan, performs terribly). Demonstrate the cached plan is the problem, then evaluate fixes: OPTIMIZE FOR, RECOMPILE, local variables, or Query Store plan forcing — and discuss the trade-offs of each.]`

---

## Index cleanup

Tuning also means removing indexes that cost writes and deliver nothing:

```sql
EXEC sp_BlitzIndex @DatabaseName = 'StackOverflow2010';
```

`[FILL IN — duplicate, overlapping or unused indexes found and removed]`

---

## Overall findings

`[FILL IN — 4–5 genuine conclusions. Strong examples:]`

- *Logical reads and duration diverge badly on a warm cache; reads is the honest metric.*
- *The missing index DMV suggested N indexes; only M were worth creating, because...*
- *Key lookups only matter past a row-count threshold — below the tipping point the optimiser is right to use them.*

---

## Interview talking points

- Why logical reads beats duration as a tuning metric
- What a key lookup is and the two ways to eliminate one
- Why you shouldn't blindly apply missing-index DMV suggestions
- What SARGable means and how to spot a non-SARGable predicate
- The four main responses to parameter sniffing and when each applies
- How you'd verify a new index is actually being used

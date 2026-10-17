# Runbook — "The Database Is Slow"

**Purpose:** structured triage for reported slowness.
**Audience:** DBA on call.
**Target:** identify the bottleneck within 10 minutes.

> This runbook exists because the wrong instinct under pressure is to start changing things. The right instinct is to find out what's actually waiting.

---

## Step 0 — Establish scope (60 seconds)

Ask before you touch anything:

- One user, one application, or everyone?
- One query, or all queries?
- When did it start? What changed?
- Is it slow, or is it *blocked/hung*?

**Scope determines direction.** One slow query is a tuning problem. Everything slow is a server problem.

---

## Step 1 — What's running right now?

```sql
EXEC sp_WhoIsActive @get_plans = 1, @get_task_info = 2;
```

Look for: long-running sessions, `blocking_session_id` populated, high `wait_info`.

No sp_WhoIsActive available:

```sql
SELECT r.session_id, r.status, r.command, r.wait_type, r.wait_time,
       r.blocking_session_id, r.cpu_time, r.total_elapsed_time,
       DB_NAME(r.database_id) AS db,
       SUBSTRING(t.text, (r.statement_start_offset/2)+1,
           ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
             ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1) AS query_text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id > 50 AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;
```

---

## Step 2 — Is it blocking?

```sql
SELECT blocking_session_id, session_id, wait_type, wait_time/1000.0 AS wait_sec,
       wait_resource, DB_NAME(database_id) AS db
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;
```

**Find the head blocker** — the session blocking others that isn't itself blocked. That's the one to deal with.

```sql
-- Last resort, and understand the consequences first
-- KILL <session_id>;
```

> Killing a long transaction triggers a rollback that can take **longer than the original transaction**. Check `sys.dm_exec_requests.percent_complete` after killing. Don't kill and walk away.

---

## Step 3 — What is the server waiting on?

```sql
WITH waits AS (
  SELECT wait_type,
         wait_time_ms/1000.0 AS wait_s,
         (wait_time_ms - signal_wait_time_ms)/1000.0 AS resource_s,
         signal_wait_time_ms/1000.0 AS signal_s,
         waiting_tasks_count AS waits,
         100.0 * wait_time_ms / SUM(wait_time_ms) OVER() AS pct
  FROM sys.dm_os_wait_stats
  WHERE wait_type NOT IN (
    'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK',
    'SLEEP_SYSTEMTASK','SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE',
    'CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT',
    'BROKER_TO_FLUSH','BROKER_TASK_STOP','CLR_MANUAL_EVENT','CLR_AUTO_EVENT',
    'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT','XE_DISPATCHER_WAIT',
    'XE_DISPATCHER_JOIN','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'DIRTY_PAGE_POLL','SP_SERVER_DIAGNOSTICS_SLEEP','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE','QDS_SHUTDOWN_QUEUE','PREEMPTIVE_XE_GETTARGETSTATE')
)
SELECT TOP 15 wait_type, CAST(wait_s AS DECIMAL(18,2)) AS wait_s,
       CAST(pct AS DECIMAL(5,2)) AS pct, waits
FROM waits WHERE pct > 0.5 ORDER BY wait_s DESC;
```

Or simply: `EXEC sp_BlitzFirst @Seconds = 30, @ExpertMode = 1;`

### Reading the answer

| Wait type | Means | Look at |
|---|---|---|
| `PAGEIOLATCH_*` | Reading data pages from disk | Missing indexes, memory pressure, slow storage |
| `LCK_M_*` | Blocking | Step 2; consider RCSI |
| `CXPACKET` / `CXCONSUMER` | Parallelism | Cost threshold (default 5 is far too low), MaxDOP |
| `WRITELOG` | Log write latency | Log file storage, oversized transactions |
| `RESOURCE_SEMAPHORE` | Queries waiting for memory grants | Bad estimates, missing indexes |
| `SOS_SCHEDULER_YIELD` | CPU pressure | Query tuning, core count |
| `ASYNC_NETWORK_IO` | Client not consuming results fast enough | **Usually the application, not SQL Server** |
| `PAGELATCH_*` (tempdb) | tempdb allocation contention | tempdb file count |

---

## Step 4 — Which queries are responsible?

```sql
EXEC sp_BlitzCache @SortOrder = 'reads';      -- then 'cpu', 'duration'
```

Or from Query Store, last hour:

```sql
SELECT TOP 20
    qt.query_sql_text,
    rs.avg_duration/1000.0 AS avg_ms,
    rs.avg_logical_io_reads,
    rs.count_executions
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan p  ON rs.plan_id = p.plan_id
JOIN sys.query_store_query q ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE rs.last_execution_time > DATEADD(HOUR, -1, GETUTCDATE())
ORDER BY rs.avg_logical_io_reads DESC;
```

---

## Step 5 — Rule out the environment

```sql
-- Memory pressure
SELECT object_name, counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Page life expectancy','Memory Grants Pending');

-- Storage latency by file
SELECT DB_NAME(vfs.database_id) AS db, mf.physical_name,
       vfs.io_stall_read_ms  / NULLIF(vfs.num_of_reads,0)  AS avg_read_ms,
       vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes,0) AS avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL,NULL) vfs
JOIN sys.master_files mf
  ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY avg_read_ms DESC;
```

Rough guide: under 10 ms good, 10–20 ms acceptable, over 20 ms investigate.

Also check: disk space, a backup or index rebuild running, someone else's maintenance window.

---

## Step 6 — Communicate

Before you fix anything, tell the requester:

> "Confirmed — the slowness is caused by [X]. I'm doing [Y]. Expected resolution [Z]. I'll update you at [time]."

**This step is not optional.** In interviews, communication is weighted as heavily as diagnosis.

---

## Decision summary

```
Slow reported
  ├─ Everyone affected?
  │    ├─ Yes → Step 3 (waits) → Step 5 (resources)
  │    └─ No  → Step 4 (that query) → tuning
  ├─ Blocking present? → Step 2 → head blocker
  └─ Started suddenly? → what changed: deploy, stats, plan, data volume, job
```

---

## Rules

1. **Diagnose before changing.** Restarting SQL Server destroys the evidence.
2. **One change at a time**, measured.
3. **Write it down** — time, symptom, finding, action, outcome.
4. **Escalate early.** Not knowing is fine; guessing on production is not.

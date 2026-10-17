# Project 01 — Backup & Recovery Strategy

**Status:** 🟡 In progress · **Week 2** · **Est. 8 hours**

> **How to use this file:** the structure, T-SQL and drill design are ready. Replace every `[FILL IN]` with your own real numbers and observations as you do the work. Delete this quote block when you're done.

---

## Objective

Design, implement and **prove** a backup strategy for a 10 GB OLTP database with a stated RPO of 15 minutes and RTO of 30 minutes.

The point of this project is not to take backups. It's to demonstrate that I can **restore** — including to an arbitrary point in time — and that I've tested it rather than assumed it.

---

## Requirements

| | Target | Achieved |
|---|---|---|
| **RPO** (max acceptable data loss) | 15 minutes | `[FILL IN — worst measured log gap]` |
| **RTO** (max acceptable downtime) | 30 minutes | `[FILL IN — accident to database online]` |
| Database | StackOverflow2010, ~10 GB | |
| Recovery model | FULL | |
| Backup verification | `VERIFYONLY WITH CHECKSUM` every run | |
| Restore test | Automated, weekly | |

---

## Strategy

| Backup type | Frequency | Retention | Rationale |
|---|---|---|---|
| Full | Weekly, Sunday 01:00 | 4 weeks | Baseline; 10 GB is quick to restore |
| Differential | Daily 01:00 | 1 week | Cuts restore chain length dramatically |
| Transaction log | Every 15 min | 3 days | Directly sets the 15-minute RPO |

**Why this shape:** log backup frequency *is* the RPO. Differentials exist to shorten the restore chain — without them a Saturday restore would need six days of log backups.

**Storage:** data in `C:\SQLData`, logs in `C:\SQLLogs`, backups in `C:\SQLBackup`. Separated because a full data volume takes the logs with it, and a full backup volume stops every backup on the instance.

---

## Implementation

### 0. Prerequisites

```sql
-- Instance and edition
SELECT @@SERVERNAME, SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductVersion');

-- Logical file names — required for every MOVE clause
SELECT mf.file_id, mf.type_desc, mf.name AS logical_name, mf.physical_name,
       mf.size * 8 / 1024 AS size_mb
FROM sys.master_files mf
WHERE mf.database_id = DB_ID(N'StackOverflow2010');
```

```powershell
# The service account must be able to write the backup folders
New-Item -ItemType Directory -Force -Path C:\SQLBackup\FULL,C:\SQLBackup\DIFF,
    C:\SQLBackup\LOG,C:\SQLBackup\DRILL | Out-Null
icacls "C:\SQLBackup" /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F" /T
```

`[FILL IN — service account from sys.dm_server_services, and whether it was the default instance account]`

### 1. Set recovery model

```sql
ALTER DATABASE StackOverflow2010 SET RECOVERY FULL;

SELECT d.name, d.recovery_model_desc, d.log_reuse_wait_desc,
       drs.last_log_backup_lsn,
       CASE WHEN drs.last_log_backup_lsn IS NULL
            THEN 'PSEUDO-SIMPLE — log backups fail until a full backup exists'
            ELSE 'Log chain active' END AS log_chain_state
FROM sys.databases d
LEFT JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
WHERE d.name = N'StackOverflow2010';
```

> **Pseudo-simple:** a database in FULL recovery that has never had a full backup behaves like SIMPLE. Proven deliberately by attempting a log backup first, which fails with:
> ```
> Msg 4214 — BACKUP LOG cannot be performed because there is no current database backup.
> ```
> `sys.database_recovery_status.last_log_backup_lsn` is `NULL` until the first full (or `COPY_ONLY` full) backup breaks pseudo-simple.

**Observed:** `[FILL IN — did you reproduce 4214? what did last_log_backup_lsn show?]`

### 2. Take the base full backup

```sql
BACKUP DATABASE StackOverflow2010
TO DISK = 'C:\SQLBackup\FULL\SO2010_FULL_001.bak'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
```

`CHECKSUM` computes a backup checksum so media damage can be detected later by `VERIFYONLY ... WITH CHECKSUM`. `COMPRESSION` typically cuts size 70–80% and *speeds* the backup up because there's less to write. `INIT` overwrites the file instead of appending — without it the file grows forever.

**Result:** `[FILL IN — duration, size on disk, compression ratio, MB/sec from the success message]`

**Verified:**

```sql
RESTORE VERIFYONLY
FROM DISK = 'C:\SQLBackup\FULL\SO2010_FULL_001.bak'
WITH CHECKSUM, STATS = 10;
-- The backup set on file 1 is valid.
```

`[FILL IN — VERIFYONLY output]`

### 3. Differential and log backups

```sql
BACKUP DATABASE StackOverflow2010
TO DISK = 'C:\SQLBackup\DIFF\SO2010_DIFF_001.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, INIT, STATS = 10;

BACKUP LOG StackOverflow2010
TO DISK = 'C:\SQLBackup\LOG\SO2010_LOG_001.trn'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
```

A differential is "every extent changed since the last full", tracked by the DCM pages, so its cost is proportional to change, not database size. Its `database_backup_lsn` must equal the parent full's `last_lsn` — that's the machine-readable proof it belongs to that chain.

**Result:** `[FILL IN — differential size, log size, log_reuse_wait_desc before and after]`

### 4. Deploy Ola Hallengren's Maintenance Solution

Downloaded from https://ola.hallengren.com/downloads.html and deployed to `master`.

```sql
-- Full backups (weekly)
EXECUTE dbo.DatabaseBackup
  @Databases = 'USER_DATABASES',
  @Directory = 'C:\SQLBackup',
  @DirectoryStructure = '{BackupType}',
  @BackupType = 'FULL',
  @Verify = 'Y', @Compress = 'Y', @CheckSum = 'Y',
  @CleanupTime = 672,          -- hours = 4 weeks
  @LogToTable = 'Y';

-- Differential (daily)
EXECUTE dbo.DatabaseBackup
  @Databases = 'USER_DATABASES',
  @Directory = 'C:\SQLBackup',
  @DirectoryStructure = '{BackupType}',
  @BackupType = 'DIFF',
  @Verify = 'Y', @Compress = 'Y', @CheckSum = 'Y',
  @CleanupTime = 168,
  @LogToTable = 'Y';

-- Log (every 15 minutes)
EXECUTE dbo.DatabaseBackup
  @Databases = 'USER_DATABASES',
  @Directory = 'C:\SQLBackup',
  @DirectoryStructure = '{BackupType}',
  @BackupType = 'LOG',
  @Verify = 'Y', @Compress = 'Y', @CheckSum = 'Y',
  @CleanupTime = 72,
  @LogToTable = 'Y';
```

`@CleanupTime` is in **hours**. `@LogToTable = 'Y'` writes every run to `master.dbo.CommandLog`, which is where you diagnose a failed job.

Scheduled via SQL Server Agent jobs with failure notifications to the Windows event log:

| Job | Schedule |
|---|---|
| `DatabaseBackup - USER_DATABASES - FULL` | Weekly, Sunday 01:00 |
| `DatabaseBackup - USER_DATABASES - DIFF` | Daily 01:00 |
| `DatabaseBackup - USER_DATABASES - LOG` | Every 15 minutes, 00:00–23:59 |

`[FILL IN — screenshot of the Agent job list → evidence/screenshots/agent-jobs.png]`

**Job outcomes:**

```sql
SELECT j.name, h.step_name, h.run_status, h.run_date, h.run_time, h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
ORDER BY h.instance_id DESC;
```

`[FILL IN — run_status of the first successful run of each job]`

### 5. Verify the chain

```sql
SELECT
    bs.type,
    bs.backup_start_date,
    bs.backup_finish_date,
    CAST(bs.compressed_backup_size / 1048576.0 AS decimal(12,1)) AS size_mb,
    bs.first_lsn,
    bs.last_lsn,
    bs.database_backup_lsn,
    bs.is_copy_only,
    mf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON bs.media_set_id = mf.media_set_id
WHERE bs.database_name = 'StackOverflow2010'
ORDER BY bs.backup_start_date;
```

An unbroken log chain means each log backup's `first_lsn` matches the previous one's `last_lsn`. A differential belongs to a full when its `database_backup_lsn` matches that full's `last_lsn`.

`[FILL IN — paste the chain output or the CSV in evidence/]`

---

## Recovery drills

**This section is the actual deliverable.** Anyone can schedule a backup.

### Drill 1 — Point-in-time restore (10,001 rows, 0 seconds of data loss)

**Scenario:** a `DELETE` without a `WHERE` clause empties `dbo.Drill_Orders`. Recover to the instant before it ran.

Method: full → +2,500 rows → differential → +2,500 rows → log backup → marker row → capture time → `DELETE` → tail-log backup. Then restore to a new database with `STOPAT` at the captured time.

```sql
-- The chain
BACKUP DATABASE StackOverflow2010 TO DISK = 'C:\SQLBackup\DRILL\PITR_01_full.bak'
WITH INIT, COMPRESSION, CHECKSUM;
-- ... inserts, then:
BACKUP DATABASE StackOverflow2010 TO DISK = 'C:\SQLBackup\DRILL\PITR_02_diff.bak'
WITH DIFFERENTIAL, INIT, COMPRESSION, CHECKSUM;
-- ... inserts, then:
BACKUP LOG StackOverflow2010 TO DISK = 'C:\SQLBackup\DRILL\PITR_03_log.trn'
WITH INIT, COMPRESSION, CHECKSUM;
-- ... marker row, capture time, DELETE, then:
BACKUP LOG StackOverflow2010 TO DISK = 'C:\SQLBackup\DRILL\PITR_04_log_after.trn'
WITH INIT, COMPRESSION, CHECKSUM;
```

```sql
-- Restore to a copy, stopping before the delete
RESTORE DATABASE SO2010_Drill
FROM DISK = 'C:\SQLBackup\DRILL\PITR_01_full.bak'
WITH MOVE 'StackOverflow2010'     TO 'C:\SQLData\SO2010_Drill.mdf',
     MOVE 'StackOverflow2010_log' TO 'C:\SQLLogs\SO2010_Drill_log.ldf',
     NORECOVERY, REPLACE, STATS = 10;

RESTORE DATABASE SO2010_Drill
FROM DISK = 'C:\SQLBackup\DRILL\PITR_02_diff.bak'
WITH NORECOVERY, STATS = 10;

RESTORE LOG SO2010_Drill
FROM DISK = 'C:\SQLBackup\DRILL\PITR_03_log.trn'
WITH NORECOVERY, STATS = 10;

RESTORE LOG SO2010_Drill
FROM DISK = 'C:\SQLBackup\DRILL\PITR_04_log_after.trn'
WITH STOPAT = '<captured crash time>', RECOVERY, STATS = 10;
```

**Key concepts demonstrated:** `NORECOVERY` on every restore but the last; `STOPAT` for point-in-time; tail-log backup taken *before* touching anything; restore to a new name rather than over the original.

**Result:**

- Rows recovered: `[FILL IN — expected 10,001]`
- Marker row (`CustomerID = -1`) present: `[FILL IN — expected 1]`
- Time to full recovery (RTO, accident → online): `[FILL IN]`
- Data loss: `[FILL IN — expected 0 rows / 0 seconds]`

`[FILL IN — screenshot of the recovered row counts → evidence/screenshots/pitr-verified.png]`

The full repeatable drill is committed as [`scripts/backup-and-recovery/01-pitr-drill-setup.sql`](../scripts/backup-and-recovery/01-pitr-drill-setup.sql) and [`02-pitr-drill-restore.sql`](../scripts/backup-and-recovery/02-pitr-drill-restore.sql).

### Drill 2 — Tail-log backup

The `STOPAT` drill only works because the log was captured after the accident. Prove what that looks like operationally:

```sql
ALTER DATABASE StackOverflow2010 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
BACKUP LOG StackOverflow2010
TO DISK = 'C:\SQLBackup\LOG\SO2010_TAIL.trn'
WITH NORECOVERY, CHECKSUM, INIT;
GO

SELECT name, state_desc FROM sys.databases WHERE name = 'StackOverflow2010';
-- RESTORING

-- In an incident: restore to another server and repoint.
-- In the lab: bring the original straight back.
RESTORE DATABASE StackOverflow2010 WITH RECOVERY;
GO
ALTER DATABASE StackOverflow2010 SET MULTI_USER;
GO
```

**Why it matters:** without the tail-log capture, everything since the last scheduled log backup is unrecoverable. This is the single command that most often separates a 15-minute outage from a day-long one.

`[FILL IN — observed state after the tail-log backup, and the size of the tail log]`

### Drill 3 — Restore verification with dbatools

```powershell
# Structural check only — fast
Test-DbaLastBackup -SqlInstance localhost -Database StackOverflow2010 -VerifyOnly

# Full test: restore the latest chain, run CHECKDB, drop the copy
Test-DbaLastBackup -SqlInstance localhost -Database StackOverflow2010
```

**Why this matters:** a backup you haven't restored is a hypothesis, not a backup. This automates the proof and, scheduled weekly, turns "we think our backups are good" into a report.

**Result:** `[FILL IN — RestoreResult, DbccResult, elapsed time]`

### Drill 4 — Corruption detection and page restore

Deliberately corrupted a data page in a disposable 20 MB database (`DbaDrillLab`) using `DBCC WRITEPAGE` with `direct = 1`, which bypasses the buffer pool and breaks the stored page checksum exactly like failing hardware.

```sql
-- Detect
SELECT COUNT(*) FROM DbaDrillLab.dbo.CorruptMe;
-- Msg 824: SQL Server detected a logical consistency-based I/O error: incorrect checksum

DBCC CHECKDB ('DbaDrillLab') WITH NO_INFOMSGS, ALL_ERRORMSGS;

SELECT database_id, file_id, page_id, event_type, error_count
FROM msdb.dbo.suspect_pages
WHERE database_id = DB_ID('DbaDrillLab');
```

```sql
-- Repair: page restore, online
RESTORE DATABASE DbaDrillLab PAGE = '1:<page_id>'
FROM DISK = 'C:\SQLBackup\DRILL\DbaDrillLab_FULL_01.bak'
WITH NORECOVERY;

BACKUP LOG DbaDrillLab
TO DISK = 'C:\SQLBackup\DRILL\DbaDrillLab_TAIL.trn'
WITH INIT, CHECKSUM;

RESTORE LOG DbaDrillLab
FROM DISK = 'C:\SQLBackup\DRILL\DbaDrillLab_TAIL.trn'
WITH RECOVERY;
```

**Result:**

- Corrupted page: `[FILL IN — e.g. 1:12345]`
- Detection error: `[FILL IN — Msg 824 / 8909 / 8928]`
- `suspect_pages.event_type` before repair: `[FILL IN]`
- `CHECKDB` clean after page restore: `[FILL IN]`

**Note on `REPAIR_ALLOW_DATA_LOSS`:** it is a last resort, it does what the name says, and the correct first answer to corruption is always *restore from backup*.

### Drill 5 — Broken backup chain and `COPY_ONLY`

Deliberately took a normal full backup mid-chain and observed the effect on the differential base.

| Attempt | Result |
|---|---|
| full F1 + diff D1 (correct pairing) | `[FILL IN — rows restored]` |
| full F1 + diff D2 (D2 belongs to F2) | `[FILL IN — expect Msg 3136]` |
| full F2 + diff D2 | `[FILL IN — rows restored]` |
| full F2 + diff D3, with a `COPY_ONLY` full in between | `[FILL IN — expect success]` |

```
[FILL IN — paste the exact Msg 3136 text here]
```

**Conclusion:** a normal full backup resets the differential base, which invalidates older differentials. A `COPY_ONLY` full does not, which is why ad-hoc backups on a log-shipped or mirrored database must use `COPY_ONLY`.

### Drill 6 — Damaged backup file

Overwrote 4 KB in the middle of a copy of a `.bak` with PowerShell to simulate bit rot.

```sql
RESTORE HEADERONLY FROM DISK = 'C:\SQLBackup\DRILL\CHAIN_01_full_DAMAGED.bak';       -- succeeds
RESTORE VERIFYONLY FROM DISK = 'C:\SQLBackup\DRILL\CHAIN_01_full_DAMAGED.bak'
WITH CHECKSUM;                                                                        -- fails
```

**Result:** `[FILL IN — error number and message]`

**Conclusion:** `HEADERONLY` reads metadata and tells you nothing about whether the data is readable. Only `VERIFYONLY WITH CHECKSUM` (or a real restore) tests the file. This is why every Ola job runs with `@Verify = 'Y'` and `@CheckSum = 'Y'`.

---

## What the drills proved

| Claim | Evidence |
|---|---|
| Backups run and are verified | `[FILL IN]` |
| I can restore the whole database | `[FILL IN — duration]` |
| I can restore to an arbitrary point in time | 10,001 rows, marker present, `[FILL IN — seconds]` |
| Data loss is inside the 15-minute RPO | `[FILL IN]` |
| Recovery is inside the 30-minute RTO | `[FILL IN]` |
| Corruption can be detected and repaired surgically | `[FILL IN]` |
| A broken chain is detectable before you need it | `[FILL IN]` |

---

## Findings

`[FILL IN — 3–5 things you actually learned. Prompts, not answers:]`

- Backup compression reduced the 8.4 GB database to `X` GB and the backup still ran at `Y` MB/sec — less I/O outweighed the CPU cost.
- The first log backup after switching to FULL was `X` MB because the database had been in pseudo-simple mode with no chain.
- A 10 GB restore takes `X` seconds, so the 30-minute RTO is dominated by human decision time, not restore throughput.
- The restored copy stayed in FULL recovery and its log began to grow immediately — a leftover restore copy becomes a disk-space incident.
- `COPY_ONLY` full backups do not reset the differential base, which is why ad-hoc backups don't break the chain.
- `RESTORE VERIFYONLY` without `WITH CHECKSUM` would not have caught the damage introduced in Drill 6.

---

## Evidence index

| Artefact | File |
|---|---|
| Agent job list | `evidence/screenshots/agent-jobs.png` |
| Backup chain from msdb | `evidence/backup-chain.csv` |
| PITR row-count verification | `evidence/screenshots/pitr-verified.png` |
| `Test-DbaLastBackup` output | `evidence/dbatools-restore-test.txt` |
| Corruption detection | `evidence/screenshots/corruption-824.png` |
| `CHECKDB` clean after repair | `evidence/screenshots/checkdb-clean.png` |
| Msg 3136 broken chain | `evidence/broken-chain-3136.txt` |
| Damaged backup caught by VERIFYONLY | `evidence/damaged-backup.txt` |
| Drill scripts | `scripts/backup-and-recovery/` |

---

## Interview talking points

- Why the log backup interval *is* the RPO, and how to measure the real gap from `msdb`
- Why a tail-log backup must be taken before any restore attempt
- What `NORECOVERY` does and why every restore but the last needs it
- Why `COPY_ONLY` exists and what breaks without it
- Why "we have backups" and "we can restore" are different claims
- `HEADERONLY` vs `VERIFYONLY` vs `CHECKDB` — three different levels of proof
- Pseudo-simple recovery: what Msg 4214 means and why it happens
- What you do first when a developer says they deleted the wrong table

---

## References

- [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/)
- [Microsoft Docs — Recovery Models](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/recovery-models-sql-server)
- [Microsoft Docs — Restore Pages](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-pages-sql-server)
- [Microsoft Docs — Tail-Log Backups](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/tail-log-backups-sql-server)
- [dbatools Test-DbaLastBackup](https://docs.dbatools.io/Test-DbaLastBackup)
- [Paul Randal — DBCC WRITEPAGE](https://www.sqlskills.com/blogs/paul/dbcc-writepage/)

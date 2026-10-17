# Project 01 — Backup & Recovery Strategy

**Status:** ✅ Complete · **Completed:** October 2026

---

## Objective

Design, implement and **prove** a backup strategy for a ~10 GB OLTP database (`StackOverflow2010`) with a stated RPO of 15 minutes and RTO of 30 minutes.

The point of this project is not merely to schedule backups. It is to demonstrate that I can **restore** — including to an arbitrary point in time before a destructive `DELETE`, recover a single corrupted data page online without a full database restore, and diagnose broken backup chains from `msdb` LSN metadata.

---

## Requirements & Measured Results

| Metric | Target | Achieved (Measured in Lab) |
|---|---|---|
| **RPO** (max acceptable data loss) | 15 minutes | **15 minutes** scheduled log interval (**0 rows / 0 seconds** lost when tail-log is captured) |
| **RTO** (max acceptable downtime) | 30 minutes | **~2 minutes** for full + diff + log PITR restore (~59s full restore + <5s diff/log rollforward) |
| **Surgical Page Restore RTO** | < 5 minutes | **60.6 seconds** (`16:53:05.169` corruption → `16:54:05.808` verified clean on page `1:1451`) |
| **Database** | `StackOverflow2010` (~8.57 GB allocated data) | `8,568.08 MB` uncompressed → **`2,598.60 MB` compressed (69.7% reduction)** |
| **Recovery model** | `FULL` | Verified via `sys.databases` and `sys.database_recovery_status` |
| **Backup verification** | `VERIFYONLY WITH CHECKSUM` every run | Enforced on manual backups and Ola Hallengren jobs (`@Verify = 'Y'`, `@CheckSum = 'Y'`) |

---

## Strategy

| Backup type | Frequency | Retention | Rationale |
|---|---|---|---|
| Full | Weekly, Sunday 01:00 | 4 weeks (672 hrs) | Baseline; ~2.6 GB compressed restores in ~1 minute |
| Differential | Daily 01:00 | 1 week (168 hrs) | Cuts restore chain length to at most 1 diff + <24h of logs |
| Transaction log | Every 15 min | 3 days (72 hrs) | Directly sets the 15-minute RPO and keeps the transaction log reusable |

**Why this shape:** log backup frequency *is* the RPO. Differentials exist to shorten the restore chain — without them a Saturday restore would require rolling forward six days of 15-minute log backups (~576 files).

**Storage:** data in `C:\SQLData`, logs in `C:\SQLLogs`, backups in `C:\SQLBackup`. Separated because a full data volume takes the logs with it, and a full backup volume stops every backup on the instance.

---

## Implementation

### 0. Prerequisites & Environment Verification

```sql
-- Instance, edition, and service configuration
SELECT @@SERVERNAME, SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductVersion');

SELECT servicename, service_account, instant_file_initialization_enabled
FROM sys.dm_server_services;
```

**Observed environment (`sys.dm_server_services`):**

| Service | Service Account | Instant File Initialization |
|---|---|---|
| `SQL Server (MSSQLSERVER)` | `NT Service\MSSQLSERVER` | **`Y`** |
| `SQL Server Agent (MSSQLSERVER)` | `NT Service\SQLSERVERAGENT` | `N` |

```powershell
# Grant NTFS write permissions on the backup tree to the default instance service account
New-Item -ItemType Directory -Force -Path C:\SQLBackup\FULL,C:\SQLBackup\DIFF,
    C:\SQLBackup\LOG,C:\SQLBackup\DRILL | Out-Null
icacls "C:\SQLBackup" /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F" /T
```

### 1. Set recovery model and prove Pseudo-Simple behaviour

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

> **Pseudo-simple:** a database in `FULL` recovery that has never had a full backup (or was switched to `SIMPLE` and back) behaves like `SIMPLE`. Attempting a log backup before establishing a base full backup fails with `Msg 4214 — BACKUP LOG cannot be performed because there is no current database backup.`

**Observed:**
- When `StackOverflow2010` was switched back to `SIMPLE` between sessions, attempting `BACKUP LOG` immediately failed with **`Msg 4208`** (*"The statement BACKUP LOG is not allowed while the recovery model is SIMPLE"*).
- After switching back to `FULL`, `drs.last_log_backup_lsn` was `NULL` until a new base full backup (`SO2010_FULL_002.bak`) was taken to establish a fresh log chain (`first_lsn = 282000001071600001`).

### 2. Take the base full backup

```sql
BACKUP DATABASE StackOverflow2010
TO DISK = 'C:\SQLBackup\FULL\SO2010_FULL_001.bak'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
```

`CHECKSUM` computes a backup checksum so media damage can be detected later by `VERIFYONLY ... WITH CHECKSUM`. `COMPRESSION` cut the backup file size by **69.7%** and reduced disk write volume. `INIT` overwrites the file instead of appending a second backup set to the same file.

**Measured result (`msdb.dbo.backupset`):**

| File | Duration | Uncompressed Size | Compressed Size | Space Saved | Throughput | `first_lsn` |
|---|---|---|---|---|---|---|
| `SO2010_FULL_001.bak` | **62 sec** | `8,568.08 MB` | **`2,598.60 MB`** | **69.7%** (3.3:1) | **138.2 MB/s** | `282000001065500001` |
| `SO2010_FULL_002.bak` | **58 sec** | `8,568.08 MB` | **`2,598.60 MB`** | **69.7%** (3.3:1) | **147.7 MB/s** | `282000001071600001` |

**Verified:**

```sql
RESTORE VERIFYONLY
FROM DISK = 'C:\SQLBackup\FULL\SO2010_FULL_001.bak'
WITH CHECKSUM, STATS = 10;
```

Output: `The backup set on file 1 is valid.`

### 3. Differential and transaction log backups

```sql
BACKUP DATABASE StackOverflow2010
TO DISK = 'C:\SQLBackup\DIFF\SO2010_DIFF_001.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, INIT, STATS = 10;

BACKUP LOG StackOverflow2010
TO DISK = 'C:\SQLBackup\LOG\SO2010_LOG_001.trn'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
```

A differential backs up every 64 KB extent changed since the base full backup, tracked by Differential Changed Map (DCM) pages. Its **`differential_base_lsn`** must equal the parent full backup's **`first_lsn`**.

**Measured results:**
- **`SO2010_DIFF_001.bak`**: `< 1 sec`, `2.08 MB` uncompressed → **`0.16 MB` compressed**, `differential_base_lsn = 282000001065500001` (matches `SO2010_FULL_001.bak`'s `first_lsn`).
- **`SO2010_LOG_001.trn`**: `< 1 sec`, `0.07 MB` uncompressed, `first_lsn = 282000001071600001` → `last_lsn = 282000001072700001`.
- **`SO2010_LOG_002.trn`** (after updating 1,000 rows in `dbo.Users`): `< 1 sec`, `0.20 MB` uncompressed → `0.05 MB` compressed, `first_lsn = 282000001072700001` → `last_lsn = 282000001104500001`.
- Notice that `SO2010_LOG_001.last_lsn` (`282000001072700001`) equals `SO2010_LOG_002.first_lsn` (`282000001072700001`), proving an unbroken log chain.

### 4. Deploy Ola Hallengren's Maintenance Solution

Downloaded from https://ola.hallengren.com/downloads.html and deployed to `master` (`CommandExecute`, `DatabaseBackup`, `DatabaseIntegrityCheck`, `IndexOptimize`, and `dbo.CommandLog`).

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

**Observed execution:** Ola Hallengren `DatabaseBackup` executed cleanly on `2026-10-17 16:00:58` and `16:01:23`, completing full backups of `StackOverflow2010` in **12–14 seconds** and logging execution details to `master.dbo.CommandLog`.

| Job | Schedule |
|---|---|
| `DatabaseBackup - USER_DATABASES - FULL` | Weekly, Sunday 01:00 |
| `DatabaseBackup - USER_DATABASES - DIFF` | Daily 01:00 |
| `DatabaseBackup - USER_DATABASES - LOG` | Every 15 minutes, 00:00–23:59 |

### 5. Verify the chain in `msdb`

```sql
SELECT
    bs.database_name,
    CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' END AS backup_type,
    bs.is_copy_only,
    bs.backup_start_date,
    DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date) AS duration_sec,
    CAST(bs.backup_size / 1048576.0 AS decimal(12,2))            AS uncompressed_mb,
    CAST(bs.compressed_backup_size / 1048576.0 AS decimal(12,2)) AS compressed_mb,
    bs.first_lsn,
    bs.last_lsn,
    bs.differential_base_lsn,
    mf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = 'StackOverflow2010'
ORDER BY bs.backup_start_date;
```

**Measured `StackOverflow2010` backup chain from `msdb.dbo.backupset`:**

| Type | Start Time | Duration (s) | Uncompressed (MB) | Compressed (MB) | `first_lsn` | `last_lsn` | `differential_base_lsn` | File |
|---|---|---:|---:|---:|---|---|---|---|
| FULL | `2026-10-17 14:06:45` | 62 | 8,568.08 | 2,598.60 | `282000001065500001` | `282000001065800001` | `NULL` | `C:\SQLBackup\FULL\SO2010_FULL_001.bak` |
| DIFF | `2026-10-17 14:30:50` | 0 | 2.08 | 0.16 | `282000001068800001` | `282000001069100001` | `282000001065500001` | `C:\SQLBackup\DIFF\SO2010_DIFF_001.bak` |
| FULL | `2026-10-17 14:40:24` | 58 | 8,568.08 | 2,598.60 | `282000001071600001` | `282000001071900001` | `NULL` | `C:\SQLBackup\FULL\SO2010_FULL_002.bak` |
| LOG | `2026-10-17 14:42:44` | 0 | 0.07 | 0.00 | `282000001071600001` | `282000001072700001` | `NULL` | `C:\SQLBackup\LOG\SO2010_LOG_001.trn` |
| LOG | `2026-10-17 14:47:33` | 0 | 0.20 | 0.05 | `282000001072700001` | `282000001104500001` | `NULL` | `C:\SQLBackup\LOG\SO2010_LOG_002.trn` |
| FULL | `2026-10-17 16:05:10` | 59 | 8,568.08 | 2,598.66 | `282000001250200001` | `282000001250500001` | `NULL` | `C:\SQLBackup\DRILL\PITR_01_full.bak` |
| DIFF | `2026-10-17 16:07:04` | 0 | 3.08 | 0.26 | `282000001323700001` | `282000001324000001` | `282000001250200001` | `C:\SQLBackup\DRILL\PITR_02_diff.bak` |
| LOG | `2026-10-17 16:07:38` | 0 | 1.45 | 0.35 | `282000001104500001` | `282000001394100001` | `NULL` | `C:\SQLBackup\DRILL\PITR_03_log.trn` |
| LOG | `2026-10-17 16:09:30` | 0 | 1.26 | 0.31 | `282000001394100001` | `282000001642800001` | `NULL` | `C:\SQLBackup\DRILL\PITR_04_log_after.trn` |
| LOG | `2026-10-17 16:22:07` | 0 | 0.45 | 0.45 | `282000001642800001` | `282000001731400001` | `NULL` | `C:\SQLBackup\LOG\SO2010_TAIL.trn` |

Full 26-row export saved to [`evidence/backup-chain.csv`](../evidence/backup-chain.csv).

---

## Recovery Drills

### Drill 1 — Point-in-time restore (10,001 rows, 0 seconds of data loss)

**Scenario:** a `DELETE` without a `WHERE` clause empties `dbo.Drill_Orders`. Recover to the exact instant before the `DELETE` ran.

**Timeline executed on `2026-10-17`:**
1. **`16:05:10`** — Created `dbo.Drill_Orders` with 5,000 rows; took `PITR_01_full.bak` (`59 sec`, `2,598.66 MB` compressed, `first_lsn = 282000001250200001`).
2. **`16:07:04`** — Inserted 2,500 rows (total 7,500); took `PITR_02_diff.bak` (`0.26 MB` compressed, `differential_base_lsn = 282000001250200001`).
3. **`16:07:38`** — Inserted 2,500 rows (total 10,000); took `PITR_03_log.trn` (`0.35 MB` compressed, `last_lsn = 282000001394100001`).
4. **`16:09:30`** — Inserted marker row (`CustomerID = -1`, `Amount = 99999.99`, total **10,001 rows**), recorded exact pre-disaster timestamp in `dbo.Drill_Control`, executed `DELETE FROM dbo.Drill_Orders;` (0 rows remaining), and immediately captured `PITR_04_log_after.trn` (`first_lsn = 282000001394100001` → `last_lsn = 282000001642800001`).

```sql
-- Restore to a side-by-side copy (SO2010_Drill), stopping immediately before the DELETE
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
WITH STOPAT = @CrashTime, RECOVERY, STATS = 10;
```

**Measured Result:**
- **Rows recovered in `SO2010_Drill.dbo.Drill_Orders`:** **`10,001`** (all 10,000 batch rows + 1 marker row)
- **Marker row (`CustomerID = -1`, `Amount = 99999.99`) present:** **Yes (`1` row)**
- **Total restore time (RTO):** **~2 minutes** (~59s full + <5s differential and log rollforward)
- **Data loss (RPO achieved):** **0 rows / 0 seconds**

The repeatable scripts are committed at [`scripts/backup-and-recovery/01-pitr-drill-setup.sql`](../scripts/backup-and-recovery/01-pitr-drill-setup.sql) and [`scripts/backup-and-recovery/02-pitr-drill-restore.sql`](../scripts/backup-and-recovery/02-pitr-drill-restore.sql).

---

### Drill 2 — Tail-log backup (`WITH NORECOVERY`)

```sql
ALTER DATABASE StackOverflow2010 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
BACKUP LOG StackOverflow2010
TO DISK = 'C:\SQLBackup\LOG\SO2010_TAIL.trn'
WITH NORECOVERY, CHECKSUM, INIT;
GO

SELECT name, state_desc FROM sys.databases WHERE name = 'StackOverflow2010';
-- Observed state_desc: RESTORING

RESTORE DATABASE StackOverflow2010 WITH RECOVERY;
GO
ALTER DATABASE StackOverflow2010 SET MULTI_USER;
GO
```

**Measured Result (`2026-10-17 16:22:07`):**
- **State after `BACKUP LOG ... WITH NORECOVERY`:** `RESTORING` (prevents any further writes while capturing the tail of the log).
- **Tail-log size:** **`0.45 MB`** (`first_lsn = 282000001642800001` → `last_lsn = 282000001731400001`, continuing seamlessly from `PITR_04_log_after.trn`).
- **Brought back online:** `RESTORE DATABASE StackOverflow2010 WITH RECOVERY;` returned `state_desc = ONLINE`.

---

### Drill 3 — Automated restore verification with `dbatools`

```powershell
# Fix PowerShell execution policy for current user so signed/local modules load cleanly
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
Import-Module dbatools -Force

# Fast header/verify check
Test-DbaLastBackup -SqlInstance localhost -Database StackOverflow2010 -VerifyOnly

# Full automated test: restores latest chain to a temp copy, runs DBCC CHECKDB, drops copy
Test-DbaLastBackup -SqlInstance localhost -Database StackOverflow2010 `
    -DataDirectory C:\SQLData -LogDirectory C:\SQLLogs
```

**Why this matters:** a backup you haven't restored is a hypothesis, not a backup. Running `Import-Module dbatools` initially surfaced a Windows PowerShell `PSSecurityException` (`running scripts is disabled on this system`), which was resolved at the `CurrentUser` scope (`RemoteSigned`) and documented in the troubleshooting runbook.

---

### Drill 4 — Corruption detection and surgical page restore (`DbaDrillLab`)

Deliberately corrupted an allocated data page in `DbaDrillLab.dbo.CorruptMe` (20,000 rows) using `DBCC WRITEPAGE(..., 4000, 4, 0xDEADBEEF, 1)` (`direct = 1` bypasses the buffer pool and breaks the on-disk page checksum, simulating storage bit rot).

**Important lesson learned during setup:** an initial attempt using a hardcoded example page (`1:12345`) failed with **`Msg 3194`** (*"Page (1:12345) is beyond the end of the file"*) and cascading **`Msg 3117`** because a 20 MB database only has ~2,560 pages. I redesigned the script to query `sys.dm_db_database_page_allocations` dynamically after taking the full backup, log the target page to `master.dbo.CorruptionLabRun`, corrupt it, and restore that exact page from `DbaDrillLab_FULL.bak`.

```sql
-- 1. Detect corruption
SELECT COUNT(*) FROM DbaDrillLab.dbo.CorruptMe;
-- Msg 824, Level 24, State 2: SQL Server detected a logical consistency-based I/O error: incorrect checksum

DBCC CHECKDB (N'DbaDrillLab') WITH NO_INFOMSGS, ALL_ERRORMSGS;

SELECT database_id, file_id, page_id, event_type, error_count
FROM msdb.dbo.suspect_pages
WHERE database_id = DB_ID(N'DbaDrillLab');

-- 2. Surgical single-page restore + tail-log recovery
RESTORE DATABASE DbaDrillLab PAGE = '1:1451'
FROM DISK = N'C:\SQLBackup\DRILL\DbaDrillLab_FULL.bak'
WITH NORECOVERY;

BACKUP LOG DbaDrillLab
TO DISK = N'C:\SQLBackup\DRILL\DbaDrillLab_TAIL.trn'
WITH INIT, CHECKSUM;

RESTORE LOG DbaDrillLab
FROM DISK = N'C:\SQLBackup\DRILL\DbaDrillLab_TAIL.trn'
WITH RECOVERY;
```

**Measured Result (`master.dbo.CorruptionLabRun` & `msdb.dbo.backupset`):**

| RunID | FileID | PageID | CorruptedAt | RepairedAt | Total Repair Time | Post-Repair `CHECKDB` & Row Count |
|---:|---:|---:|---|---|---|---|
| **1** | `1` | **`1451`** | `2026-10-17 16:53:05.169` | `2026-10-17 16:54:05.808` | **60.6 seconds** | Clean (`0` allocation/consistency errors), **20,000 rows** |
| **2** | `1` | **`1451`** | `2026-10-17 16:55:51.575` | `2026-10-17 17:01:15.030` | **5 min 23 sec** | Clean (`0` allocation/consistency errors), **20,000 rows** |

- **Base full backup (`DbaDrillLab_FULL.bak`):** `13.08 MB` uncompressed → `0.98 MB` compressed (`first_lsn = 43000000687600001`).
- **Tail-log backups (`DbaDrillLab_TAIL.trn`):** `0.07 MB` (`first_lsn = 43000000687600001` → `43000000700400001` in Run 1; `43000000700400001` → `43000000708300001` in Run 2).
- **Detection error:** `Msg 824, Level 24, State 2` (incorrect checksum on page `1:1451`, `suspect_pages.event_type = 2`).

**Note on `REPAIR_ALLOW_DATA_LOSS`:** it is a last resort that deletes damaged pages to make structures consistent. Restoring the single damaged page (`1:1451`) recovered 100% of the 20,000 rows in 60 seconds with zero data loss.

---

### Drill 5 — Broken backup chain and `COPY_ONLY` (`ChainLab`)

Deliberately took a normal full backup (`F2`) mid-chain to prove how it invalidates prior differentials, then took a `COPY_ONLY` full backup (`F3`) to prove it preserves the differential base.

**Measured LSNs in `ChainLab` (`2026-10-17 17:02:19`):**

| Step | Backup File | Type | `is_copy_only` | `first_lsn` | `differential_base_lsn` | Valid Base Full |
|---|---|---|---:|---|---|---|
| **F1** | `CHAIN_01_full.bak` | FULL | `0` | `39000000105500001` | `NULL` | — |
| **D1** | `CHAIN_02_diff.bak` | DIFF | `0` | `39000000115600001` | `39000000105500001` | Matches **F1** (`CHAIN_01_full.bak`) |
| **F2** | `CHAIN_03_full.bak` | FULL | `0` | `39000000125300001` | `NULL` | Resets differential base |
| **D2** | `CHAIN_04_diff.bak` | DIFF | `0` | `39000000135700001` | `39000000125300001` | Matches **F2** (`CHAIN_03_full.bak`) |
| **F3** | `CHAIN_05_full_copyonly.bak` | FULL | **`1`** | `39000000136600001` | `NULL` | **Does NOT reset** differential base |
| **D3** | `CHAIN_06_diff.bak` | DIFF | `0` | `39000000144400001` | **`39000000125300001`** | Still matches **F2** (`CHAIN_03_full.bak`)! |

**Restore Attempts & Outcomes:**

| Attempt | Combination Tested | Measured Outcome |
|---|---|---|
| **Attempt 1** | **F1 + D1** (`CHAIN_01_full` + `CHAIN_02_diff`) | **Succeeded** — `1,100` rows restored |
| **Attempt 2** | **F1 + D2** (`CHAIN_01_full` + `CHAIN_04_diff`) | **Failed with `Msg 3136`** (F1 restored 505 pages, then D2 was rejected because its `differential_base_lsn` `39000000125300001` belongs to F2, not F1) |
| **Attempt 3** | **F2 + D2** (`CHAIN_03_full` + `CHAIN_04_diff`) | **Succeeded** — `1,300` rows restored |
| **Attempt 4** | **F2 + D3** (`CHAIN_03_full` + `CHAIN_06_diff`, after `COPY_ONLY` F3) | **Succeeded** — `1,400` rows restored |

**Exact output captured from Attempt 2 (`evidence/broken-chain-3136.txt`):**

```text
Processed 504 pages for database 'ChainTest2', file 'ChainLab' on file 1.
Processed 1 pages for database 'ChainTest2', file 'ChainLab_log' on file 1.
RESTORE DATABASE successfully processed 505 pages in 0.021 seconds (187.569 MB/sec).
Msg 3136, Level 16, State 1, Line 7
This differential backup cannot be restored because the database has not been restored to the correct earlier state.
Msg 3013, Level 16, State 1, Line 7
RESTORE DATABASE is terminating abnormally.
```

---

### Drill 6 — Damaged backup file (`HEADERONLY` vs `VERIFYONLY WITH CHECKSUM`)

Overwrote 4 KB in the middle of a copy of `CHAIN_01_full.bak` (`CHAIN_01_full_DAMAGED.bak`) with PowerShell to simulate media bit rot.

```sql
RESTORE HEADERONLY FROM DISK = 'C:\SQLBackup\DRILL\CHAIN_01_full_DAMAGED.bak';       -- succeeds!
RESTORE VERIFYONLY FROM DISK = 'C:\SQLBackup\DRILL\CHAIN_01_full_DAMAGED.bak'
WITH CHECKSUM;                                                                        -- fails with Msg 3189 / 3013
```

**Result:** `RESTORE HEADERONLY` succeeded because it only reads the backup header metadata at the front of the file. `RESTORE VERIFYONLY ... WITH CHECKSUM` read every page in the backup set and caught the corrupted bytes immediately (`Msg 3189: Damage to the backup set was detected` / `Msg 3013: VERIFY DATABASE is terminating abnormally`).

---

## Summary of What the Drills Proved

| Claim | Measured Proof |
|---|---|
| Backups run with compression & checksums | `8,568.08 MB` → `2,598.60 MB` (**69.7% reduction**), verified via `RESTORE VERIFYONLY WITH CHECKSUM` |
| Full database restore is well inside 30-min RTO | **58–62 seconds** for full backup; **~2 minutes** for full + diff + 2 logs PITR |
| Arbitrary point-in-time recovery works | **10,001 rows** recovered including marker row (`CustomerID = -1`), **0 rows lost** |
| Tail-log capture prevents post-backup data loss | `SO2010_TAIL.trn` (`0.45 MB`) captured uncommitted tail and placed DB into `RESTORING` |
| Single corrupted page can be repaired surgically | Page **`1:1451`** restored and rolled forward in **60.6 seconds** (`CHECKDB` clean, 20,000 rows intact) |
| Broken differential chains are diagnosable via LSNs | Reproduced `Msg 3136` and proved `diff.differential_base_lsn = full.first_lsn` (`39000000125300001`) |
| `COPY_ONLY` preserves the differential chain | `CHAIN_06_diff.bak` retained `differential_base_lsn = 39000000125300001` after `CHAIN_05_full_copyonly.bak` |

---

## Key Findings & Lessons Learned

1. **Backup compression is a speed win as well as a storage win:** Compressing `StackOverflow2010` reduced the `.bak` from `8,568.08 MB` to `2,598.60 MB` (69.7% smaller) and completed in 58–62 seconds (~145 MB/sec) because writing 6 GB less to disk far outweighed the CPU cost of compression.
2. **Switching `FULL` → `SIMPLE` breaks the log chain immediately (`Msg 4208`):** Setting the database to `SIMPLE` between lab sessions truncated the log at checkpoint. Switching back to `FULL` left the database in pseudo-simple mode (`last_log_backup_lsn IS NULL`), requiring a new full backup (`SO2010_FULL_002.bak`) to start a new chain.
3. **Differential pairing uses `differential_base_lsn = full.first_lsn`:** A common trap is comparing `database_backup_lsn` to `last_lsn`. In `msdb.dbo.backupset`, `ChainLab` proved that `CHAIN_04_diff.bak` (`differential_base_lsn = 39000000125300001`) pairs with `CHAIN_03_full.bak` (`first_lsn = 39000000125300001`), and remains paired with `CHAIN_03_full.bak` even after a `COPY_ONLY` full backup (`CHAIN_05_full_copyonly.bak`, `first_lsn = 39000000136600001`).
4. **Always read the *first* error in a multi-statement batch (`Msg 3194` → `Msg 3117`):** When a `RESTORE DATABASE ... PAGE` statement fails (e.g., `Msg 3194` page beyond EOF), the subsequent `RESTORE LOG` fails with `Msg 3117` (*"no files are ready to rollforward"*). `Msg 3117` is a symptom; the root cause is always the earlier statement that failed to start the rollforward set.
5. **A 10 GB restore takes ~1 minute, so a 30-minute RTO is dominated by human decision time:** Having a tested runbook and pre-written `msdb` restore-chain queries matters more for RTO than raw storage speed.

---

## Evidence Index

| Artefact | File |
|---|---|
| SSMS verification results (IFI, `msdb` LSNs, `CorruptionLabRun`) | [`evidence/screenshots/msdb-drill-results.png`](../evidence/screenshots/msdb-drill-results.png) |
| Full 26-row backup chain export from `msdb` | [`evidence/backup-chain.csv`](../evidence/backup-chain.csv) |
| Broken differential chain (`Msg 3136`) & LSN proof | [`evidence/broken-chain-3136.txt`](../evidence/broken-chain-3136.txt) |
| Page corruption (`Msg 824`) & page `1:1451` restore log | [`evidence/page-restore-1451.txt`](../evidence/page-restore-1451.txt) |
| Damaged backup caught by `VERIFYONLY WITH CHECKSUM` | [`evidence/damaged-backup.txt`](../evidence/damaged-backup.txt) |
| Repeatable PITR & restore-chain scripts | [`scripts/backup-and-recovery/`](../scripts/backup-and-recovery/) |
| Real lab errors & root-cause write-ups | [`runbooks/troubleshooting-log.md`](../runbooks/troubleshooting-log.md) |

---

## Interview Talking Points

- Why the log backup interval *is* the RPO, and how to measure the real gap from `msdb.dbo.backupset`
- Why a tail-log backup (`WITH NORECOVERY`) must be taken before any restore attempt
- What `NORECOVERY` does and why every restore step except the last requires it
- Why `COPY_ONLY` exists (`differential_base_lsn` preservation) and how taking an ad-hoc full backup without it causes `Msg 3136`
- Why "we have backups" and "we can restore" are different claims (`HEADERONLY` vs `VERIFYONLY WITH CHECKSUM` vs automated `Test-DbaLastBackup` + `DBCC CHECKDB`)
- Pseudo-simple recovery: what `Msg 4214` and `Msg 4208` mean and how to verify `last_log_backup_lsn` in `sys.database_recovery_status`
- How to perform a surgical single-page restore (`PAGE = '1:1451'`) in 60 seconds instead of restoring an entire multi-terabyte database or running `REPAIR_ALLOW_DATA_LOSS`

---

## References

- [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/)
- [Microsoft Docs — Recovery Models](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/recovery-models-sql-server)
- [Microsoft Docs — Restore Pages](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-pages-sql-server)
- [Microsoft Docs — Tail-Log Backups](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/tail-log-backups-sql-server)
- [dbatools Test-DbaLastBackup](https://docs.dbatools.io/Test-DbaLastBackup)
- [Paul Randal — DBCC WRITEPAGE](https://www.sqlskills.com/blogs/paul/dbcc-writepage/)

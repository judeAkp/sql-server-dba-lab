# Project 04 — Automated Daily Health Check

**Status:** ✅ Complete · **Completed:** October 2026

---

## Objective

Build and schedule an automated daily SQL Server health check using **PowerShell + `dbatools`** and T-SQL catalog diagnostics that audits the entire instance every morning at 07:00, generates a prioritised HTML exception report (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`), and proves its effectiveness through deliberate fault injection and live remediation.

**The DBA principle:** you should learn about a failed backup, an offline database, or a runaway transaction log from your own 07:00 report — never from a user asking why the application is down.

---

## What It Checks

| Check | Severity | Threshold | Why It Matters |
|---|---|---|---|
| **Database state** | `CRITICAL` | Not `ONLINE` | Catches `OFFLINE`, `SUSPECT`, `RECOVERY_PENDING`, or stuck `RESTORING` databases immediately |
| **Last full backup age** | `CRITICAL` | `> 24 hours` or `NEVER` (excl. `tempdb`) | No full backup = no disaster recovery baseline |
| **Last log backup age (`FULL` recovery)** | `HIGH` | `> 30 minutes` or `NEVER` | Directly governs RPO and prevents transaction log full (`Msg 9002`) incidents |
| **Failed SQL Agent jobs** | `HIGH` | Any failure in last 24 hours (`step_id = 0`) | Scheduled maintenance jobs fail silently unless actively monitored |
| **Transaction log space used** | `HIGH` | `> 80%` used | Early warning before a log file fills its volume |
| **Disk volume free space** | `HIGH` | `< 15%` free (`sys.dm_os_volume_stats`) | A full data, log, or backup volume halts operations instance-wide |
| **Last good `DBCC CHECKDB`** | `MEDIUM` | `> 7 days` or `NEVER` (`1900-01-01`) | Undetected page corruption eventually ages out all clean backups |
| **Long-running queries** | `MEDIUM` | `> 5 minutes` elapsed | Flags runaway reports or blocking chains early |

Full PowerShell implementation: [`scripts/powershell/Daily-HealthCheck.ps1`](../scripts/powershell/Daily-HealthCheck.ps1)
Rendered HTML report sample: [`evidence/HealthCheck_Sample_Report.html`](../evidence/HealthCheck_Sample_Report.html)
Verbatim SSMS execution log: [`evidence/healthcheck-alert-and-remediation.txt`](../evidence/healthcheck-alert-and-remediation.txt)

---

## Implementation & Setup

### 1. PowerShell + `dbatools` Configuration

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true
```

### 2. Core Health-Check Query Logic (`msdb` + `sys.databases` + `DATABASEPROPERTYEX`)

Rather than checking a hard-coded list of database names, the health check dynamically joins `sys.databases` to `msdb.dbo.backupset` and `DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime')` so **every newly created database on the instance is audited automatically**:

```sql
WITH BackupAndCheckDb AS (
    SELECT
        d.name COLLATE DATABASE_DEFAULT AS DatabaseName,
        d.state_desc COLLATE DATABASE_DEFAULT AS StateDesc,
        d.recovery_model_desc COLLATE DATABASE_DEFAULT AS RecoveryModel,
        MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS LastFullBackup,
        MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS LastLogBackup,
        CAST(DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS datetime) AS LastGoodCheckDb
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs ON bs.database_name = d.name
    WHERE d.name <> N'tempdb'
    GROUP BY d.name, d.state_desc, d.recovery_model_desc
)
...
```

> **System Catalog Collation Discovery (`Msg 451`):**
> In `sys.databases`, `d.name` uses the instance collation (`Latin1_General_CI_AS`), whereas Microsoft defines internal status description columns (`d.state_desc`, `d.recovery_model_desc`) with collation `Latin1_General_CI_AS_KS_WS` (Kana-sensitive, Width-sensitive). Concatenating `DatabaseName` and `StateDesc` across a `UNION ALL` initially threw `Msg 451: Cannot resolve collation conflict between "Latin1_General_CI_AS_KS_WS" and "Latin1_General_CI_AS"`. Normalising both columns with `COLLATE DATABASE_DEFAULT` inside the CTE resolved it cleanly.

---

## Scheduling via SQL Server Agent

Deployed as a scheduled SQL Server Agent job (`[DBA - Daily Health Check]`) in `msdb`, running daily at **07:00:00**:

```sql
EXEC msdb.dbo.sp_add_job
    @job_name         = N'DBA - Daily Health Check',
    @enabled          = 1,
    @description      = N'Runs Daily-HealthCheck.ps1 at 07:00 to audit backups, DB state, Agent jobs, CHECKDB age, log usage, and disk space.',
    @category_name    = N'Database Maintenance',
    @owner_login_name = N'sa';

EXEC msdb.dbo.sp_add_jobstep
    @job_name          = N'DBA - Daily Health Check',
    @step_name         = N'Run Daily-HealthCheck.ps1',
    @subsystem         = N'PowerShell',
    @command           = N'powershell.exe -ExecutionPolicy Bypass -File "C:\Projects\sql-server-dba-lab\scripts\powershell\Daily-HealthCheck.ps1" -SqlInstance localhost -OutputPath "C:\Reports"',
    @on_success_action = 1,
    @on_fail_action    = 2;

EXEC msdb.dbo.sp_add_jobschedule
    @job_name          = N'DBA - Daily Health Check',
    @name              = N'Daily_0700_Schedule',
    @enabled           = 1,
    @freq_type         = 4,        -- Daily
    @freq_interval     = 1,
    @active_start_time = 070000;   -- 07:00:00
```

**Verified in `msdb.dbo.sysjobs`:** `Created and scheduled SQL Server Agent job: [DBA - Daily Health Check] (Daily at 07:00:00).`

---

## Deliberate Failure Test & Real-World Shadow Database Discovery

A monitoring check that has never fired is untested. To validate the health check:
1. Created `OfflineAlertDB` and took it **`OFFLINE`** (`ALTER DATABASE OfflineAlertDB SET OFFLINE WITH ROLLBACK IMMEDIATE`).
2. Created `UnbackedUpAlertDB` in `FULL` recovery with zero backups and zero `CHECKDB` history.
3. Executed the health check across the instance.

### Verbatim Output — Run A (Deliberate Faults Injected)

```text
=== HEALTH CHECK RUN A — BEFORE REMEDIATION (DELIBERATE FAULTS INJECTED) ===
CRITICAL | Database State    | OfflineAlertDB | Status is OFFLINE (expected ONLINE)
CRITICAL | Full Backup       | UnbackedUpAlertDB | Last full backup: NEVER
HIGH     | Log Backup        | DWConfiguration | FULL recovery, last log backup: NEVER
HIGH     | Log Backup        | MyDatabase | FULL recovery, last log backup: NEVER
HIGH     | Log Backup        | StackOverflow201 | FULL recovery, last log backup: NEVER
HIGH     | Log Backup        | UnbackedUpAlertDB | FULL recovery, last log backup: NEVER
MEDIUM   | CHECKDB Integrity | AdventureWorks2022 | Last good DBCC CHECKDB: NEVER
MEDIUM   | CHECKDB Integrity | DWConfiguration | Last good DBCC CHECKDB: NEVER
MEDIUM   | CHECKDB Integrity | DWDiagnostics | Last good DBCC CHECKDB: NEVER
MEDIUM   | CHECKDB Integrity | DWQueue | Last good DBCC CHECKDB: NEVER
MEDIUM   | CHECKDB Integrity | MyDatabase | Last good DBCC CHECKDB: NEVER
MEDIUM   | CHECKDB Integrity | StackOverflow201 | Last good DBCC CHECKDB: NEVER
MEDIUM   | CHECKDB Integrity | UnbackedUpAlertDB | Last good DBCC CHECKDB: NEVER
```

### What Run A Proved (Including an Unplanned Real-World Discovery!)

1. **Caught both injected faults immediately:**
   - `OfflineAlertDB` flagged as **`CRITICAL | Database State | Status is OFFLINE`**.
   - `UnbackedUpAlertDB` flagged across **`CRITICAL` (Full Backup: NEVER)**, **`HIGH` (Log Backup: NEVER)**, and **`MEDIUM` (CHECKDB: NEVER)**.
2. **Discovered real forgotten ("shadow") databases on the instance:**
   - The script automatically uncovered **`StackOverflow201`** (an empty database created with a typo during Week 1 setup) and **`MyDatabase`**, both sitting in `FULL` recovery with `last log backup: NEVER` and `Last good DBCC CHECKDB: NEVER`!
   - It also flagged **`AdventureWorks2022`** and the three PolyBase system databases (`DWConfiguration`, `DWDiagnostics`, `DWQueue` installed by the Basic installer) as having never had `DBCC CHECKDB` executed.
3. **Confirmed remediated core databases were 100% green:**
   - After taking full backups of `master` (`609 pages`, `0.433s`), `model` (`377 pages`, `0.242s`), and `msdb` (`1,849 pages`, `0.272s`), backing up **`42,437` log pages (`~331 MB` generated during Project 02 index creation)** on `StackOverflow2010` (`2.638s`, `125.68 MB/sec`), and running `DBCC CHECKDB` on `master`, `model`, `msdb`, `StackOverflow2010`, and `SecVaultLab`, **none of those five core databases triggered an alert**.

---

## Remediation Executed

```sql
-- 1. Back up system databases
BACKUP DATABASE [master] TO DISK = N'C:\SQLBackup\SYSTEM\master_FULL.bak' WITH INIT, COMPRESSION, CHECKSUM;
BACKUP DATABASE [model]  TO DISK = N'C:\SQLBackup\SYSTEM\model_FULL.bak'  WITH INIT, COMPRESSION, CHECKSUM;
BACKUP DATABASE [msdb]   TO DISK = N'C:\SQLBackup\SYSTEM\msdb_FULL.bak'   WITH INIT, COMPRESSION, CHECKSUM;

-- 2. Back up active transaction logs on FULL recovery databases
BACKUP LOG [StackOverflow2010] TO DISK = N'C:\SQLBackup\LOG\SO2010_LOG_HealthCheck.trn' WITH INIT, COMPRESSION, CHECKSUM;
BACKUP LOG [SecVaultLab]       TO DISK = N'C:\SQLBackup\LOG\SecVaultLab_LOG_HealthCheck.trn' WITH INIT, COMPRESSION, CHECKSUM;

-- 3. Run DBCC CHECKDB across monitored databases
DBCC CHECKDB (N'master')            WITH NO_INFOMSGS;
DBCC CHECKDB (N'model')             WITH NO_INFOMSGS;
DBCC CHECKDB (N'msdb')              WITH NO_INFOMSGS;
DBCC CHECKDB (N'StackOverflow2010') WITH PHYSICAL_ONLY, NO_INFOMSGS;
DBCC CHECKDB (N'SecVaultLab')       WITH NO_INFOMSGS;
```

---

## Key Findings & Lessons Learned

1. **Instance-wide catalog queries catch "shadow databases" that manual checks miss:** Querying `sys.databases LEFT JOIN msdb.dbo.backupset` uncovered `StackOverflow201` (an old typo database), `MyDatabase`, and `DWConfiguration` sitting in `FULL` recovery without log backups. In production, a forgotten database in `FULL` recovery without log backups is a ticking disk-space time bomb.
2. **Monitor *backup age in `msdb`*, not just SQL Agent job success:** A backup job can report `Succeeded` while skipping a database (e.g., if someone excluded it or if the database was created after a static maintenance plan was built). Checking `MAX(backup_finish_date)` per database in `msdb.dbo.backupset` proves the backup actually happened.
3. **Index builds in `FULL` recovery generate massive transaction log volume:** The `StackOverflow2010` log backup taken during remediation processed **`42,437` pages (~331 MB)** in `2.638 seconds` — all generated by the index creation drills in Project 02. Without our health check flagging log backup age, that log space could not be reused (`log_reuse_wait_desc = LOG_BACKUP`).
4. **`sys.databases` mixes collations internally (`Msg 451`):** `sys.databases.name` uses the server collation (`Latin1_General_CI_AS`), while `state_desc` and `recovery_model_desc` use `Latin1_General_CI_AS_KS_WS`. Always apply `COLLATE DATABASE_DEFAULT` when concatenating catalog status columns with object names.

---

## Interview Talking Points

- Why you must monitor **last backup age in `msdb`** rather than relying solely on SQL Agent job success notifications
- How the health check caught real forgotten databases (`StackOverflow201`, `MyDatabase`, `DW*`) sitting in `FULL` recovery with no log backups
- Why `DBCC CHECKDB` age (`DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime')`) is critical: if corruption goes undetected longer than your backup retention window, all of your valid backups age out and are replaced by corrupted backups
- Why `sys.databases.state_desc` causes `Msg 451` (`Latin1_General_CI_AS_KS_WS`) when concatenated with `sys.databases.name`
- How `Test-DbaLastBackup` (weekly restore verification) complements `Daily-HealthCheck.ps1` (daily operational exception reporting)

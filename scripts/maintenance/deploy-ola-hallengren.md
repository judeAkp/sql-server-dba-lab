# Deploying Ola Hallengren's Maintenance Solution

The de-facto industry standard for SQL Server backups, integrity checks and index maintenance. Free, and used in a large proportion of production estates.

**Source:** https://ola.hallengren.com/

---

## Install

1. Download `MaintenanceSolution.sql`
2. Open in SSMS, set the backup directory at the top:
   ```sql
   SET @CreateJobs = 'Y'
   SET @BackupDirectory = N'C:\SQLBackup'
   SET @CleanupTime = 336   -- hours to retain
   ```
3. Execute against `master`

Creates: `CommandExecute`, `DatabaseBackup`, `DatabaseIntegrityCheck`, `IndexOptimize` and a set of Agent jobs.

---

## Job schedule

| Job | Schedule | Purpose |
|---|---|---|
| DatabaseBackup — USER_DATABASES — FULL | Sun 01:00 | Weekly baseline |
| DatabaseBackup — USER_DATABASES — DIFF | Mon–Sat 01:00 | Shortens restore chain |
| DatabaseBackup — USER_DATABASES — LOG | Every 15 min | Sets the RPO |
| DatabaseBackup — SYSTEM_DATABASES — FULL | Daily 00:30 | master, model, msdb |
| DatabaseIntegrityCheck — USER_DATABASES | Sat 22:00 | CHECKDB |
| IndexOptimize — USER_DATABASES | Sun 03:00 | Index and statistics |
| CommandLog Cleanup | Weekly | Housekeeping |
| Output File Cleanup | Weekly | Housekeeping |

---

## Recommended parameters

```sql
-- Backups: verify, compress, checksum
EXECUTE dbo.DatabaseBackup
  @Databases = 'USER_DATABASES',
  @Directory = N'C:\SQLBackup',
  @BackupType = 'FULL',
  @Verify = 'Y', @Compress = 'Y', @CheckSum = 'Y',
  @CleanupTime = 672,
  @LogToTable = 'Y';

-- Index maintenance: reorganise 5-30% fragmentation, rebuild above 30%,
-- and only touch indexes with more than 1000 pages
EXECUTE dbo.IndexOptimize
  @Databases = 'USER_DATABASES',
  @FragmentationLow = NULL,
  @FragmentationMedium = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
  @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
  @FragmentationLevel1 = 5,
  @FragmentationLevel2 = 30,
  @MinNumberOfPages = 1000,
  @UpdateStatistics = 'ALL',
  @OnlyModifiedStatistics = 'Y',
  @LogToTable = 'Y';

-- Integrity
EXECUTE dbo.DatabaseIntegrityCheck
  @Databases = 'USER_DATABASES',
  @CheckCommands = 'CHECKDB',
  @LogToTable = 'Y';
```

---

## Verify it ran

```sql
SELECT TOP 50 DatabaseName, CommandType, StartTime, EndTime,
       DATEDIFF(SECOND, StartTime, EndTime) AS duration_sec, ErrorNumber
FROM master.dbo.CommandLog
ORDER BY StartTime DESC;
```

---

## Why this rather than Maintenance Plans

- Handles log chains and retention correctly
- Verifies backups (`@Verify`)
- Skips maintenance on databases that don't need it
- Logs everything to a queryable table
- Fragmentation thresholds instead of blanket rebuilds
- Widely used, so a new employer will recognise it immediately

Knowing this solution by name is itself a signal in interviews.

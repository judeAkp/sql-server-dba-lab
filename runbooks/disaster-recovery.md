# Runbook — Disaster Recovery

**Purpose:** restore a database after data loss, corruption or server failure.
**RPO:** 15 minutes · **RTO:** 30 minutes

> ⚠️ **Read Step 1 before doing anything else.** The most common way to make a recoverable situation unrecoverable is to act before capturing the tail of the log.

---

## Step 1 — STOP. Assess and preserve.

**Do not:**
- Restart the SQL Server service
- Detach the database
- Run `REPAIR_ALLOW_DATA_LOSS`
- Delete or overwrite anything

**Do:**
1. Record the exact time the problem started
2. Establish what happened: bad DELETE/UPDATE, dropped object, corruption, hardware, ransomware?
3. Determine scope: one table, one database, the instance?
4. **Take a tail-log backup if the log file is intact:**

```sql
BACKUP LOG [DatabaseName]
TO DISK = 'C:\SQLBackup\LOG\[DatabaseName]_TAIL.trn'
WITH NORECOVERY, CHECKSUM, INIT;
```

`NORECOVERY` leaves the database in restoring state and prevents further changes. **This single command is often the difference between losing 15 minutes and losing a day.**

If the database is inaccessible:
```sql
BACKUP LOG [DatabaseName]
TO DISK = 'C:\SQLBackup\LOG\[DatabaseName]_TAIL.trn'
WITH CONTINUE_AFTER_ERROR, NO_TRUNCATE;
```

5. Notify stakeholders with an initial ETA.

---

## Step 2 — Identify the restore path

```sql
SELECT bs.backup_start_date,
       CASE bs.type WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Diff' WHEN 'L' THEN 'Log' END AS type,
       bs.first_lsn, bs.last_lsn, bs.checkpoint_lsn,
       bmf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.database_name = '[DatabaseName]'
  AND bs.backup_start_date > DATEADD(DAY,-8,GETDATE())
ORDER BY bs.backup_start_date;
```

**The chain you need:**
1. Most recent full backup **before** the incident
2. Most recent differential after that full
3. **Every** log backup after that differential, in order
4. The tail-log backup from Step 1

Verify each file is readable before starting:
```sql
RESTORE VERIFYONLY FROM DISK = '[path]' WITH CHECKSUM;
RESTORE HEADERONLY FROM DISK = '[path]';
```

---

## Step 3 — Restore

**Restore to a NEW database name where possible.** It preserves the damaged original for investigation and lets you compare before cutting over.

```sql
-- 3.1 Full — NORECOVERY
RESTORE DATABASE [DatabaseName_Recovered]
FROM DISK = 'C:\SQLBackup\FULL\[file].bak'
WITH MOVE '[LogicalDataName]' TO 'C:\SQLData\[DatabaseName]_Rec.mdf',
     MOVE '[LogicalLogName]'  TO 'C:\SQLLogs\[DatabaseName]_Rec_log.ldf',
     NORECOVERY, STATS = 5, CHECKSUM;

-- 3.2 Differential — NORECOVERY
RESTORE DATABASE [DatabaseName_Recovered]
FROM DISK = 'C:\SQLBackup\DIFF\[file].bak'
WITH NORECOVERY, STATS = 5;

-- 3.3 Each log in order — NORECOVERY
RESTORE LOG [DatabaseName_Recovered]
FROM DISK = 'C:\SQLBackup\LOG\[file].trn'
WITH NORECOVERY;

-- 3.4 Final log, stopping just before the incident
RESTORE LOG [DatabaseName_Recovered]
FROM DISK = 'C:\SQLBackup\LOG\[tail].trn'
WITH STOPAT = 'YYYY-MM-DD HH:MM:SS', NORECOVERY;

-- 3.5 Bring online
RESTORE DATABASE [DatabaseName_Recovered] WITH RECOVERY;
```

**Rule: `NORECOVERY` on every restore except the last.**

Monitor progress:
```sql
SELECT r.session_id, r.command, r.percent_complete,
       DATEADD(SECOND, r.estimated_completion_time/1000, GETDATE()) AS est_finish
FROM sys.dm_exec_requests r
WHERE r.command LIKE 'RESTORE%';
```

---

## Step 4 — Validate before cutover

```sql
-- Integrity
DBCC CHECKDB('[DatabaseName_Recovered]') WITH NO_INFOMSGS;

-- Row counts vs expectation
SELECT t.name, SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0,1)
GROUP BY t.name ORDER BY t.name;

-- Confirm the specific lost data is present
```

**Get business sign-off that the data is correct before cutting over.**

---

## Step 5 — Cut over

```sql
ALTER DATABASE [DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE [DatabaseName] MODIFY NAME = [DatabaseName_Damaged];
ALTER DATABASE [DatabaseName_Recovered] MODIFY NAME = [DatabaseName];
ALTER DATABASE [DatabaseName] SET MULTI_USER;
```

Then:
- Fix orphaned users (`ALTER USER x WITH LOGIN = y`)
- Re-enable Agent jobs
- **Take an immediate full backup — the old chain is no longer valid**
- Confirm the application connects

---

## Scenario variations

### Corruption
```sql
DBCC CHECKDB('[db]') WITH NO_INFOMSGS, ALL_ERRORMSGS;
```
If it's a small number of pages, page-level restore is faster than a full restore:
```sql
RESTORE DATABASE [db] PAGE = '1:12345' FROM DISK = '[full].bak' WITH NORECOVERY;
RESTORE LOG [db] FROM DISK = '[log].trn' WITH NORECOVERY;
RESTORE LOG [db] WITH RECOVERY;
```
`REPAIR_ALLOW_DATA_LOSS` is a last resort. It deletes data to make the database consistent. Restore from backup first, always.

### Lost master
1. Rebuild system DBs: `setup /ACTION=REBUILDDATABASE /QUIET /INSTANCENAME=... /SQLSYSADMINACCOUNTS=...`
2. Start in single-user: `sqlservr -m`
3. `RESTORE DATABASE master FROM DISK='...' WITH REPLACE;`
4. Restart normally, then restore msdb and model.

### Lost msdb
Engine keeps running; jobs and backup history are gone. Restore msdb from backup like a user database.

---

## Post-incident

Within 48 hours, document:
- Timeline (detection → resolution)
- Root cause
- Actual data loss vs RPO target
- Actual downtime vs RTO target
- What worked, what didn't
- Preventive actions

---

## Quarterly drill

A DR plan that hasn't been tested is a document, not a plan.

- [ ] Full restore to a scratch instance
- [ ] Point-in-time restore to an arbitrary timestamp
- [ ] `Test-DbaLastBackup` across all databases
- [ ] Verify RTO is still achievable at current data volume
- [ ] Confirm TDE certificates are backed up and restorable

# Troubleshooting Log

Real errors encountered in this lab, and how they were resolved. Kept because diagnosis is the skill, not the individual error.

---

## Msg 5120 — Unable to open physical file

**Always read the OS error number. It tells you which problem you have.**

### OS error 2 — "The system cannot find the file specified"

The file isn't at the path given.

```powershell
Get-ChildItem C:\SQLData\*.mdf
Get-ChildItem C:\SQLLogs\*.ldf
```

Causes seen: sample database shipped as a `.7z` archive and hadn't been extracted; double extension (`db.mdf.mdf`); `.ndf` files present that weren't listed in the attach statement.

### OS error 5 — "Access is denied"

The file exists; the SQL Server service account can't open it.

```sql
SELECT servicename, service_account FROM sys.dm_server_services;
```

```powershell
icacls "C:\SQLData" /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F" /T
icacls "C:\SQLLogs" /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F" /T
```

**Verify the grant reached the files, not just the folder.** `icacls` reports how many objects it processed — if it says 1, it only did the folder.

Other causes: files extracted directly into the data directory (inherits the wrong owner); read-only attribute set by the archive tool; Windows "downloaded file" blocking; **Windows Controlled Folder Access** blocking `sqlservr.exe`.

**Prevention:** move databases with `BACKUP`/`RESTORE` rather than detach/attach. SQL Server creates the files itself and permissions are correct by construction.

---

## Msg 207 — Invalid column name (querying a system view)

**Context:** checking that the log chain was live after the first full backup.

```sql
SELECT drs.database_id, drs.last_log_backup_lsn, drs.recovery_model_desc
FROM sys.database_recovery_status drs;
```

**Symptom:** `Msg 207, Level 16, State 1 — Invalid column name 'recovery_model_desc'.`

**Diagnosis:** `sys.database_recovery_status` has only seven columns —
`database_id`, `database_guid`, `family_guid`, `last_log_backup_lsn`,
`recovery_fork_guid`, `first_recovery_fork_guid`, `fork_point_lsn`.
The recovery model is on `sys.databases`, not on the recovery-status view.

**Root cause:** assumed two DMVs shared a column name because they both
describe recovery. They don't; DMVs are narrow and non-overlapping.

**Fix:**

```sql
SELECT d.name, d.recovery_model_desc, drs.last_log_backup_lsn
FROM sys.databases d
LEFT JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
WHERE d.name = N'StackOverflow2010';
```

**Prevention:** ask the catalog instead of guessing:

```sql
SELECT column_id, name, TYPE_NAME(system_type_id) AS data_type
FROM sys.all_columns
WHERE object_id = OBJECT_ID(N'sys.database_recovery_status')
ORDER BY column_id;
```

**Bonus finding:** `last_log_backup_lsn` is `NULL` for two different reasons —
SIMPLE recovery, *or* FULL recovery with no current full/differential backup
(pseudo-simple). Always select `recovery_model_desc` alongside it or you
can't tell the two apart.

---

## Msg 4208 — BACKUP LOG is not allowed while the recovery model is SIMPLE

**Context:** building the full/diff/log chain. A log backup had worked earlier in
the same session; the next day it failed.

**Symptom:**

```
Msg 4208, Level 16, State 1
The statement BACKUP LOG is not allowed while the recovery model is SIMPLE.
Use BACKUP DATABASE or change the recovery model using ALTER DATABASE.
Msg 3013, Level 16, State 1
BACKUP LOG is terminating abnormally.
```

**Diagnosis:** the database had been switched back to SIMPLE between sessions,
to stop the log growing while the lab was idle. Under SIMPLE, log records are
discarded at checkpoint, so there is no continuous log stream to back up and
**point-in-time recovery is impossible by design**. The error is the engine
refusing to hand over a false sense of safety.

Forensic check — `backupset.recovery_model` records the model *at the time of
each backup*, so it tells you when the change happened:

```sql
SELECT CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' ELSE 'LOG' END AS backup_type,
       bs.backup_finish_date, bs.recovery_model
FROM msdb.dbo.backupset bs
WHERE bs.database_name = N'StackOverflow2010'
ORDER BY bs.backup_finish_date;
```

**Root cause:** switching FULL → SIMPLE breaks the log chain at the next
checkpoint. Switching back to FULL does not repair it — the old chain is gone.

**Fix:** FULL, then a **fresh full backup** to start a new chain, then log backups.

```sql
ALTER DATABASE StackOverflow2010 SET RECOVERY FULL;
GO
BACKUP DATABASE StackOverflow2010
TO DISK = N'C:\SQLBackup\FULL\SO2010_FULL_002.bak'
WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
GO
-- BACKUP LOG now works again
```

**Prevention:** before switching out of FULL, back up the log first — that is
Microsoft's stated prerequisite, and it preserves the chain. If the lab has to
sit idle, take the log backup *then* switch, and accept that coming back means
starting a new chain with a new full backup.

**Interview value:** this is the exact chain of reasoning behind "why can't you
point-in-time restore a SIMPLE database?" — and it's a real incident, not a
textbook answer.

---

## Msg 208 — Invalid object name 'dbo.Users'

**Context:** generating activity before a log backup, while building the
full/diff/log chain.

**Symptom:**

```
Msg 208, Level 16, State 1
Invalid object name 'dbo.Users'.
```

**Diagnosis:** the query window was in `master`. `dbo.Users` is *unqualified* —
SQL Server resolves it against the current database context, and `master` has no
`Users` table. Nothing was wrong with the table, the permissions or the instance.

```sql
SELECT DB_NAME() AS current_database;   -- master
```

**Root cause:** a `USE master;` earlier in the session for a server-level
statement (`ALTER DATABASE`, `BACKUP`) carried over to an unqualified DML
statement.

**Fix:**

```sql
USE StackOverflow2010;
GO
UPDATE TOP (1000) dbo.Users
SET LastAccessDate = SYSDATETIME()
WHERE Id % 100 = 0;
```

**Prevention:** three-part names when context isn't obvious —
`StackOverflow2010.dbo.Users`. And note which statements care:

| Statement | Cares about database context? |
|---|---|
| `UPDATE` / `SELECT` / `INSERT` with unqualified names | **Yes** |
| `BACKUP DATABASE StackOverflow2010` | No — database is named in the statement |
| `ALTER DATABASE x SET RECOVERY FULL` | No |
| `DBCC CHECKDB('x')` | No |
| `RESTORE DATABASE ... WITH MOVE` | No — but `MOVE` targets are file paths, not DB context |

**Lesson carried forward:** server-level commands force you into `master`, so
the very next unqualified DML statement is a trap. Add `USE <db>;` before any
block that touches user objects.

---

## Msg 3194 — Page (1:12345) is beyond the end of the file

**Context:** practising a page-level restore after deliberately corrupting a page.

**Symptom:**

```
Msg 3194, Level 16, State 1
Page (1:12345) is beyond the end of the file. Only pages that are in the
current range of the file can be restored.
Msg 3013, Level 16, State 1
RESTORE DATABASE is terminating abnormally.
```

Followed by:

```
Msg 3117, Level 16, State 1
The log or differential backup cannot be restored because no files are ready
to rollforward.
```

**Diagnosis:** two separate mistakes, one hiding behind the other.

1. `12345` was a **placeholder page id** copied literally from the walkthrough.
   An 8 KB page × 12,345 implies a ~100 MB file; the 20 MB drill database has
   about 2,560 pages. There is no page 12,345, so there is nothing to restore.
2. The full backup used as the page source was taken **before** `dbo.CorruptMe`
   was created, so it didn't contain the table at all.

`Msg 3117` is a *symptom*, not a cause: because the `RESTORE ... PAGE` failed,
there was no rollforward set, so the subsequent `RESTORE LOG` had nothing to do.

**Root cause:** restoring a page requires the page to exist **in the backup being
read**. A page id is a physical location, not a stable identifier — it has to be
discovered from the live database and matched to a backup that already contained
that table.

**Fix:** discover the page id programmatically and record it, so the corruption
and the repair can't disagree:

```sql
SELECT TOP (1) allocated_page_file_id AS file_id,
               allocated_page_page_id AS page_id
FROM sys.dm_db_database_page_allocations
     (DB_ID(N'DbaDrillLab'), OBJECT_ID(N'DbaDrillLab.dbo.CorruptMe'),
      NULL, NULL, 'DETAILED')
WHERE is_allocated = 1 AND page_type_desc = 'DATA_PAGE'
ORDER BY allocated_page_page_id DESC;
```

Then build the RESTORE dynamically so no number is typed by hand:

```sql
SET @sql = N'RESTORE DATABASE DbaDrillLab PAGE = '''
         + CAST(@fileId AS nvarchar(10)) + N':' + CAST(@pageId AS nvarchar(10)) + N''''
         + N' FROM DISK = N''C:\SQLBackup\DRILL\DbaDrillLab_FULL.bak'''
         + N' WITH NORECOVERY;';
PRINT @sql;
EXEC sys.sp_executesql @sql;
```

**Prevention:** back up **after** populating, not before. When the dynamic script ran against `DbaDrillLab.dbo.CorruptMe` (20,000 rows), it discovered real allocated data page **`1:1451`**, corrupted it, restored `PAGE = '1:1451'` from `DbaDrillLab_FULL.bak`, applied the tail-log backup, and passed `DBCC CHECKDB` in **60.6 seconds** (`RunID = 1`, `16:53:05.169` → `16:54:05.808`).

**Interview value:** "why does a page restore fail with Msg 3117?" — because the
page restore never started, so there was no rollforward set. Reading the *first*
error rather than the last is the skill.

---

## PowerShell `PSSecurityException` — `dbatools` cannot be loaded because running scripts is disabled

**Context:** running `Import-Module dbatools` and `Test-DbaLastBackup` to automate restore verification.

**Symptom:**

```
Import-Module : File ...\Documents\WindowsPowerShell\Modules\dbatools.library\2026.9.14\dbatools.library.psm1
cannot be loaded because running scripts is disabled on this system.
+ CategoryInfo          : SecurityError: (:) [Import-Module], PSSecurityException
+ FullyQualifiedErrorId : UnauthorizedAccess,Microsoft.PowerShell.Commands.ImportModuleCommand
```

Followed by `CommandNotFoundException` (`CouldNotAutoloadMatchingModule`) on `Test-DbaLastBackup`.

**Diagnosis:** `dbatools` installed cleanly from PSGallery, but Windows PowerShell's default execution policy (`Restricted`) blocked `.psm1` module scripts from executing. The second error (`Test-DbaLastBackup` could not be loaded) is a cascade from the blocked `Import-Module`.

**Fix:** allow local scripts and signed remote scripts for the current user account without weakening machine-wide policy:

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
Import-Module dbatools -Force
Get-Command Test-DbaLastBackup
```

**Prevention:** set `RemoteSigned` at the `CurrentUser` scope on management workstations, and keep PowerShell modules outside OneDrive-synced `Documents` folders where Files On-Demand can dehydrate `.dll`/`.psm1` files.

---

## Msg 308 — Index specified in the FROM clause does not exist (same-batch DDL + index hint)

**Context:** creating a narrow nonclustered index (`CREATE NONCLUSTERED INDEX IX_Users_Reputation ON dbo.Users (Reputation DESC)`) and immediately running a `SELECT ... FROM dbo.Users WITH (INDEX(IX_Users_Reputation))` in the same T-SQL batch during Project 02 Case Study 1.

**Symptom:**

```
Msg 308, Level 16, State 1, Line 12
Index 'IX_Users_Reputation' on table 'dbo.Users' (specified in the FROM clause) does not exist.
```

**Diagnosis:** SQL Server compiles and binds the entire batch before executing the first statement in that batch. Deferred Name Resolution applies to *tables* created in the same batch, but **does not apply to explicit `WITH (INDEX(...))` hints** — the parser/algebrizer checks `sys.indexes` for `IX_Users_Reputation` at compile time, before the `CREATE INDEX` statement above it has executed, and aborts the batch.

**Fix:** place a `GO` batch separator between `CREATE NONCLUSTERED INDEX` and the `SELECT ... WITH (INDEX(...))` statement so the DDL commits in Batch 1 before Batch 2 is compiled:

```sql
CREATE NONCLUSTERED INDEX IX_Users_Reputation
ON dbo.Users (Reputation DESC);
GO

SELECT Id, DisplayName, Reputation, CreationDate, Location
FROM dbo.Users WITH (INDEX(IX_Users_Reputation))
WHERE Reputation >= 5000
ORDER BY Reputation DESC;
GO
```

**Prevention:** always terminate DDL statements (`CREATE`/`ALTER`/`DROP`) with `GO` when subsequent statements in the script reference the new schema object or hint it explicitly.

---

## `DENY CONTROL` vs `DENY ALTER` — Why `DENY CONTROL ON SCHEMA::dbo` broke `SELECT` (`Msg 229`)

**Context:** creating the `db_application` role in Project 03 to allow CRUD (`SELECT, INSERT, UPDATE, DELETE`) while preventing schema modifications.

**Symptom:**

```
Msg 229, Level 14, State 5
The SELECT permission was denied on the object 'Users', database 'StackOverflow2010', schema 'dbo'.
```

**Diagnosis:** the initial role script ran:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO db_application;
DENY ALTER, CONTROL ON SCHEMA::dbo TO db_application;
```

In SQL Server's permission hierarchy, **`CONTROL` is an umbrella permission that implies every permission on that securable — including `SELECT`, `INSERT`, `UPDATE`, and `DELETE`**. Because `DENY` always overrides `GRANT`, denying `CONTROL` on `SCHEMA::dbo` implicitly denied `SELECT` and `UPDATE` as well.

**Fix:** revoke the `CONTROL` deny and only deny `ALTER` on the schema:

```sql
REVOKE CONTROL ON SCHEMA::dbo FROM db_application;
DENY ALTER ON SCHEMA::dbo TO db_application;
```

**Interview value:** "Does `DENY CONTROL` only block ownership changes?" — No! Denying `CONTROL` denies *all* child permissions covered by `CONTROL`, including `SELECT`. To block DDL while allowing CRUD, simply grant `SELECT, INSERT, UPDATE, DELETE` (and optionally `DENY ALTER`).

---

## `Msg 262` (`SHOWPLAN permission denied`) & Unreverted `EXECUTE AS USER` Session Trap (`Msg 15151`)

**Context:** testing least-privilege database roles in SSMS using `EXECUTE AS USER = N'usr_reporting'; ... REVERT;` right after completing Project 02 query tuning.

**Symptom:**

```
Msg 262, Level 14, State 4
SHOWPLAN permission denied in database 'StackOverflow2010'.
```

Followed on the next run by:

```
Msg 15151, Level 16, State 1
Cannot find the schema 'dbo', because it does not exist or you do not have permission.
```

**Diagnosis:** two interacting behaviours:
1. **"Include Actual Execution Plan" (`Ctrl + M`) was still toggled on in SSMS** from Project 02. When `Ctrl + M` is active, SSMS sends `SET STATISTICS XML ON`. While impersonating `usr_reporting` (a read-only role without `SHOWPLAN`), SQL Server blocked the query with `Msg 262` because generating an execution plan requires `SHOWPLAN`.
2. **Unreverted impersonation context:** When `Msg 262` aborted the batch *before* the `REVERT;` line ran, the SSMS tab remained impersonating `usr_reporting`! Running the next administrative script in that same tab failed with `Msg 15151` because the session was still running as `usr_reporting` rather than `dbo`/`sysadmin`.

**Fix:**
1. Disable `SET STATISTICS XML OFF;` and start impersonation test scripts with `REVERT;` so any leftover impersonation context is cleared first.
2. Verify current context with `SELECT USER_NAME() AS db_user, SUSER_SNAME() AS login_name;`.

---

## `Msg 468` — Collation conflict between `Latin1_General_CI_AS` and `SQL_Latin1_General_CP1_CI_AS`

**Context:** joining `sys.database_principals` in `StackOverflow2010` to `sys.server_principals` in `master` to verify orphaned user remapping.

**Symptom:**

```
Msg 468, Level 16, State 9
Cannot resolve the collation conflict between "Latin1_General_CI_AS" and "SQL_Latin1_General_CP1_CI_AS" in the equal to operation.
```

**Diagnosis:** a classic UK SQL Server issue. A SQL Server instance installed on a UK Windows locale (`en-GB`) defaults to server collation **`Latin1_General_CI_AS`**, whereas `StackOverflow2010` (created in the US) uses database collation **`SQL_Latin1_General_CP1_CI_AS`**. Joining character columns across database and server catalog views (or joining user tables to `#temp` tables in `tempdb`) fails unless the collation is unified.

**Fix:** add `COLLATE DATABASE_DEFAULT` to both sides of the string comparison:

```sql
SELECT dp.name, dp.sid, sp.sid
FROM sys.database_principals dp
JOIN sys.server_principals sp
    ON dp.name COLLATE DATABASE_DEFAULT = sp.name COLLATE DATABASE_DEFAULT
WHERE dp.name = N'app_legacy_svc';
```

**Interview value:** almost every UK organisation has mixed `Latin1_General_CI_AS` and `SQL_Latin1_General_CP1_CI_AS` databases from third-party vendors. Knowing `COLLATE DATABASE_DEFAULT` from real experience is an instant credibility signal in UK interviews.

---

## Msg 102 — Incorrect syntax near 'GOUSE'

**Symptom:** `Msg 102, Level 15, State 1 — Incorrect syntax near 'GOUSE'.`

**Diagnosis:** two lines were joined during a paste — `GO` and `USE master;`
arrived as a single token `GOUSE`. `GO` is not T-SQL; it's a batch separator
understood by SSMS/sqlcmd, and it must sit alone on its line.

**Fix:** put `GO` on its own line and re-run. When pasting a long block, run it
in labelled chunks (build → corrupt → detect → repair) rather than all at once,
so a truncation is obvious immediately.

**Prevention:** watch the first line of any pasted block. If the previous
statement ended without a terminator and the next begins with `USE` or `ALTER`,
a paste that dropped a newline will merge them.

---

## Msg 3136 — This differential backup cannot be restored

**Context:** deliberately restoring a differential onto the wrong full backup,
to prove the chain is validated rather than assumed.

**Symptom:**

```
Msg 3136, Level 16, State 1
This differential backup cannot be restored because the database has not been
restored to the correct earlier state.
Msg 3013, Level 16, State 1
RESTORE DATABASE is terminating abnormally.
```

**Diagnosis:** the full restored cleanly (`Processed 504 pages...`) and only the
differential was rejected. That asymmetry is the tell: the full is fine, the
pairing is wrong.

The pairing key is **`differential_base_lsn`**, and it must equal the full's
**`first_lsn`** — plus `differential_base_guid` = the full's `backup_set_uuid`.

**The trap:** `database_backup_lsn` is a *different* column and looks like it
should be the answer. It records the begin-of-checkpoint LSN of the most recent
full, matching that full's `checkpoint_lsn` — not its `last_lsn`. Pairing on
`database_backup_lsn = last_lsn` is wrong and will send you hunting for the
wrong file.

**Fix — find the correct full before restoring:**

```sql
SELECT
    diff.backup_start_date          AS diff_taken,
    diff.differential_base_lsn,
    full.backup_start_date          AS base_full_taken,
    full.first_lsn                  AS full_first_lsn,
    full.is_copy_only,
    mf.physical_device_name         AS base_full_file
FROM msdb.dbo.backupset diff
JOIN msdb.dbo.backupset full
     ON  full.database_name   = diff.database_name
     AND full.type            = 'D'
     AND full.first_lsn       = diff.differential_base_lsn
     AND full.backup_set_uuid = diff.differential_base_guid
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = full.media_set_id
WHERE diff.database_name = N'ChainLab'
  AND diff.type = 'I'
ORDER BY diff.backup_start_date;
```

**Root cause in this lab:** a normal full backup (`F2`) was taken after `F1` and
before the differential. A normal full **resets the differential base**, so every
later differential is based on `F2`. `D2` belongs to `F2`, never to `F1`.

**The counterpart:** a `COPY_ONLY` full does **not** reset the differential base.
That is why ad-hoc backups on a log-shipped or mirrored database must use
`COPY_ONLY` — otherwise the next differential silently changes parents and the
existing restore chain is invalidated.

**Recovery from the error:** the target database is left in `RESTORING`. Either
restore the correct full and re-apply the differential, or abandon it:

```sql
RESTORE DATABASE ChainTest2 WITH RECOVERY;   -- brings the F1 state online
```

**Interview value:** "what happens if you take a full backup in the middle of a
differential chain?" — all existing differentials become unusable for restoring
past that point, because the base moved. `COPY_ONLY` is the answer to *not*
causing that.

---

## Default install left the instance misconfigured

Running the SQL Server installer in **Basic** mode skips every configuration screen.

Audit findings and fixes:

| Issue | Fix |
|---|---|
| Max server memory unbounded | `sp_configure 'max server memory (MB)', 8192` |
| Single tempdb data file | `ALTER DATABASE tempdb ADD FILE` × 3, equal sizes |
| Instant File Initialisation off | Grant *Perform volume maintenance tasks* to the service account |
| Cost threshold for parallelism = 5 | Raised to 50 |
| Windows auth only | Mixed mode enabled where SQL auth needed |
| All files on C:\ root | Separated into `C:\SQLData`, `C:\SQLLogs`, `C:\SQLBackup` |

**Why this is in the portfolio:** "you've inherited a badly configured SQL Server, what do you check first?" is a standard interview question, and this is a first-hand answer.

---

## Template for new entries

```
## [Error number / symptom]

**Context:** what I was doing
**Symptom:** exact error text
**Diagnosis:** how I narrowed it down, what I ruled out
**Root cause:** what it actually was
**Fix:** the commands
**Prevention:** how to avoid it next time
```

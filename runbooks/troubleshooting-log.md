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

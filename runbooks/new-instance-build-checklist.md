# Runbook — New SQL Server Instance Build

Standard build and post-install configuration. Every setting below has a reason; the reason is the point.

---

## Pre-install

- [ ] OS patched, static IP, machine named per convention
- [ ] Create folders: `C:\SQLData`, `C:\SQLLogs`, `C:\SQLBackup`, `C:\SQLTemp`
- [ ] Separate volumes for data / log / tempdb / backup where available
- [ ] Antivirus exclusions for `.mdf`, `.ndf`, `.ldf`, `.bak`, `.trn` and `sqlservr.exe`
- [ ] Windows power plan set to **High Performance** (Balanced throttles CPU)
- [ ] Service account created (domain account for production; least privilege)

---

## Install — use Custom, never Basic

| Screen | Setting | Reason |
|---|---|---|
| Feature Selection | Database Engine only unless SSIS/SSRS required | Reduce attack surface and patch load |
| Instance | Default, or named for side-by-side versions | |
| Service Accounts | Dedicated least-privilege account | Never LocalSystem in production |
| **Perform Volume Maintenance** | **Tick** | Enables Instant File Initialisation |
| Collation | `SQL_Latin1_General_CP1_CI_AS` unless app requires otherwise | Mismatches cause join failures later |
| Authentication | Windows preferred; Mixed only if required | |
| Data Directories | Data / Log / Backup separated | I/O separation and recoverability |
| TempDB | 4–8 equal files, pre-sized, fixed growth | Reduces allocation contention |
| MaxDOP | Per Microsoft guidance for core count | Default 0 is rarely right |
| Max Memory | Total RAM minus 4 GB (or minus 10% on large servers) | Leave the OS room |

---

## Post-install configuration

```sql
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;

-- Memory
EXEC sp_configure 'max server memory (MB)', 8192; RECONFIGURE;

-- Parallelism: default cost threshold of 5 dates from 1997
EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 4; RECONFIGURE;

-- Backup compression on by default
EXEC sp_configure 'backup compression default', 1; RECONFIGURE;

-- Optimise for ad hoc workloads: cache stubs, not full plans, for single-use queries
EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;

-- Remote DAC for emergency access
EXEC sp_configure 'remote admin connections', 1; RECONFIGURE;
```

### model database
```sql
ALTER DATABASE model MODIFY FILE (NAME = modeldev,  SIZE = 256MB, FILEGROWTH = 128MB);
ALTER DATABASE model MODIFY FILE (NAME = modellog,  SIZE = 128MB, FILEGROWTH = 64MB);
```
New databases inherit these — this is how you stop percentage autogrowth spreading.

### Verify
```sql
SELECT @@VERSION;
SELECT SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductLevel'), SERVERPROPERTY('Collation');
SELECT servicename, service_account, instant_file_initialization_enabled
FROM sys.dm_server_services;
SELECT name, physical_name, size/128.0 AS mb FROM sys.master_files WHERE database_id = 2;
```

---

## Operational setup

- [ ] Deploy [Ola Hallengren's Maintenance Solution](https://ola.hallengren.com/)
- [ ] Schedule full / diff / log backups to meet the agreed RPO
- [ ] Schedule `DBCC CHECKDB` weekly
- [ ] Schedule index and statistics maintenance
- [ ] Configure Database Mail and an operator
- [ ] Create alerts for severity 17–25 and error 825
- [ ] Install [First Responder Kit](https://www.brentozar.com/first-aid/) and `sp_WhoIsActive`
- [ ] Enable Query Store on user databases
- [ ] Set up the daily health check job
- [ ] **Take a baseline backup of master, model and msdb**
- [ ] Document the build in this repo

---

## Post-install audit — what defaults get wrong

Run against any inherited server:

```sql
EXEC sp_Blitz @CheckServerInfo = 1;
```

Common findings: unbounded max memory · single tempdb file · IFI disabled · cost threshold 5 · no backups or no log backups · CHECKDB never run · `sa` enabled · autogrowth in percent · databases in FULL recovery with no log backups.

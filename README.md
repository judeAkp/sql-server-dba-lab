# SQL Server DBA Lab

A self-built SQL Server 2022 environment used to practise production database administration: backup and recovery, security hardening, performance tuning, automation, high availability, and Azure SQL migration.

Every project and runbook in this repository has been **executed and verified** in the lab, with measured outputs and real error resolutions documented.

---

## Environment

| | |
|---|---|
| **Engine** | SQL Server 2022 Developer Edition (16.0 RTM) |
| **Tools** | SSMS, Azure Data Studio, PowerShell + dbatools |
| **Host** | Windows 11 Workstation |
| **Sample data** | StackOverflow2010 (~9 GB, 19.61M rows), AdventureWorks2022, DbaDrillLab, ChainLab, SecVaultLab |
| **Storage layout** | `C:\SQLData` / `C:\SQLLogs` / `C:\SQLBackup` (separated, Instant File Initialization enabled) |

---

## Projects (6/6 Complete ✅)

| Project | What it demonstrates | Status |
|---|---|---|
| [01 — Backup & Recovery Strategy](projects/01-backup-recovery-strategy.md) | Full/diff/log chain, STOPAT point-in-time restore (10,001 rows, 0 data loss), 60s surgical page restore (`1:1451`), LSN chain proof | ✅ |
| [02 — Query Tuning Case Studies](projects/02-query-tuning-case-studies.md) | 5 tuned queries with measured logical reads (`56,342→97`, `1,777→3`, `1,262→86`, `171,982→4`, `411,268→6,637`) | ✅ |
| [03 — Security Hardening Baseline](projects/03-security-hardening.md) | Least-privilege roles (`EXECUTE AS` verified), orphaned user SID remap, `AES_256` TDE + cert backup, SQL Server Audit, UK GDPR masking | ✅ |
| [04 — Automated Health Check](projects/04-automated-healthcheck.md) | PowerShell + dbatools daily HTML report, Agent-scheduled (`07:00`), verified via fault injection & shadow-DB discovery | ✅ |
| [05 — Always On & High Availability](projects/05-availability-group.md) | `TCP 5022` `AES` HADR endpoint, readable standby (`WITH STANDBY`), `901 ms` zero-data-loss role-swap failover, AG DMV architecture | ✅ |
| [06 — Azure SQL Migration](projects/06-azure-sql-migration.md) | Automated blocker assessment (`sys.sql_expression_dependencies`), `PARTIAL` containment & `sp_migrate_user_to_contained`, `uksouth` SKU sizing | ✅ |

*(🔲 planned · 🟡 in progress · ✅ complete)*

---

## Runbooks

Operational procedures written for use under pressure — numbered steps, exact T-SQL, no prose.

- [Disaster Recovery](runbooks/disaster-recovery.md) — point-in-time restore, tail-log backup, single-page restore, master rebuild
- [Slow Server Triage](runbooks/slow-server-triage.md) — first 10 minutes when "the database is slow"
- [Security Hardening Baseline](projects/03-security-hardening.md) — least privilege, audit, UK GDPR considerations
- [New Instance Build](runbooks/new-instance-build-checklist.md) — install decisions and post-install config
- [Troubleshooting Log](runbooks/troubleshooting-log.md) — 15 real errors hit in this lab (`Msg 5120`, `207`, `208`, `4208`, `3194/3117`, `3136`, `308`, `262`, `468`, `451`, `47105`, `2628`, `5061/12819`, PowerShell ExecutionPolicy) and how they were resolved

---

## Scripts

```
scripts/
├── backup-and-recovery/  point-in-time restore drill, restore chain report
├── query-tuning/         5 repeatable query-tuning case studies (STATISTICS IO/TIME)
├── security/             server hardening, least-privilege roles, TDE, Audit, GDPR masking
├── high-availability/    HADR TCP 5022 endpoint, readable standby, zero-data-loss role swap
├── azure-migration/      Azure SQL DB blocker assessment, partial containment, SKU sizing
├── monitoring/           health checks, wait stats, blocking, backup status
├── maintenance/          Ola Hallengren deployment, index & stats jobs
└── powershell/           Daily-HealthCheck.ps1 (dbatools + HTML report generator)
```

---

## Notes

Concept notes written while learning — architecture, system databases, storage internals, recovery models.

---

## About

Transitioning from SQL/data work into SQL Server Database Administration. Building this lab publicly to document hands-on operational work and verified recovery drills rather than just claiming them.

📍 UK · Open to Junior SQL Server DBA / Database Support roles

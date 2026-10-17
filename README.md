# SQL Server DBA Lab

A self-built SQL Server 2022 environment used to practise production database administration: backup and recovery, security hardening, performance tuning, automation and high availability.

Every runbook in this repository has been **executed and verified** in the lab, not copied from documentation.

---

## Environment

| | |
|---|---|
| **Engine** | SQL Server 2022 Developer Edition (16.0 RTM) |
| **Tools** | SSMS, Azure Data Studio, PowerShell + dbatools |
| **Host** | Windows 11, Hyper-V VMs for multi-node work |
| **Sample data** | StackOverflow2010 (~10 GB), DbaDrillLab, ChainLab |
| **Storage layout** | `C:\SQLData` / `C:\SQLLogs` / `C:\SQLBackup` (separated, IFI enabled) |

---

## Projects

| Project | What it demonstrates | Status |
|---|---|---|
| [01 — Backup & Recovery Strategy](projects/01-backup-recovery-strategy.md) | Full/diff/log chain, STOPAT point-in-time restore (10,001 rows, 0 data loss), 60s surgical page restore (`1:1451`), LSN chain proof | ✅ |
| [02 — Query Tuning Case Studies](projects/02-query-tuning-case-studies.md) | 5 tuned queries with before/after logical reads and plans | 🔲 |
| [03 — Security Hardening Baseline](projects/03-security-hardening.md) | Least-privilege roles, audit, UK GDPR considerations | 🔲 |
| [04 — Automated Health Check](projects/04-automated-healthcheck.md) | PowerShell + dbatools daily report, Agent-scheduled | 🔲 |
| [05 — Always On Availability Group](projects/05-availability-group.md) | 2-node AG built, failed over and documented | 🔲 |
| [06 — Azure SQL Migration](projects/06-azure-sql-migration.md) | On-prem → Azure SQL DB using DMA | 🔲 |

*(🔲 planned · 🟡 in progress · ✅ complete)*

---

## Runbooks

Operational procedures written for use under pressure — numbered steps, exact T-SQL, no prose.

- [Disaster Recovery](runbooks/disaster-recovery.md) — point-in-time restore, tail-log backup, single-page restore, master rebuild
- [Slow Server Triage](runbooks/slow-server-triage.md) — first 10 minutes when "the database is slow"
- [Security Hardening Baseline](projects/03-security-hardening.md) — least privilege, audit, UK GDPR considerations
- [New Instance Build](runbooks/new-instance-build-checklist.md) — install decisions and post-install config
- [Troubleshooting Log](runbooks/troubleshooting-log.md) — real errors hit in this lab (`Msg 5120`, `207`, `208`, `4208`, `3194/3117`, `3136`, PowerShell ExecutionPolicy) and how they were resolved

---

## Scripts

```
scripts/
├── backup-and-recovery/  point-in-time restore drill, restore chain report
├── monitoring/           health checks, wait stats, blocking, backup status
├── maintenance/          Ola Hallengren deployment, index & stats jobs
└── powershell/           dbatools automation
```

---

## Notes

Concept notes written while learning — architecture, system databases, storage internals, recovery models.

---

## About

Transitioning from SQL/data work into SQL Server Database Administration. Building this lab publicly to document hands-on operational work and verified recovery drills rather than just claiming them.

📍 UK · Open to Junior SQL Server DBA / Database Support roles

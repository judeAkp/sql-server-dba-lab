# Project 04 — Automated Daily Health Check

**Status:** 🔲 Planned · **Week 6** · **Est. 5 hours**

> Replace `[FILL IN]` with your own results. Delete this block when done.

---

## Objective

Build a PowerShell script using **dbatools** that runs every morning, checks the estate for the things that actually cause incidents, and emails an HTML report — so problems are found before users report them.

**The DBA principle:** you should learn about a failed backup from your own monitoring, not from a user asking why their data is gone.

---

## What it checks

| Check | Why it matters | Threshold |
|---|---|---|
| Last full backup | No backup = no recovery | > 24h = alert |
| Last log backup (FULL recovery DBs) | Directly sets RPO | > 30 min = alert |
| Failed Agent jobs (last 24h) | Silent failures are the norm | any = alert |
| Disk free space | Full disk = instance down | < 15% = alert |
| Database state | Suspect/recovery pending | not ONLINE = alert |
| Last CHECKDB | Undetected corruption spreads into backups | > 7 days = alert |
| Log file % used | Runaway log growth | > 80% = alert |
| Long-running queries | Early sign of blocking | > 5 min = alert |
| Error log severity 17–25 | Real errors | any = alert |

---

## Setup

```powershell
Install-Module dbatools -Scope CurrentUser -Force
Import-Module dbatools
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register
```

---

## The script

Full version: [`scripts/powershell/Daily-HealthCheck.ps1`](../scripts/powershell/Daily-HealthCheck.ps1)

Core logic:

```powershell
$instance = 'localhost'

# Backups older than 24 hours
$staleBackups = Get-DbaLastBackup -SqlInstance $instance |
    Where-Object { $_.LastFullBackup -lt (Get-Date).AddHours(-24) }

# Failed jobs
$failedJobs = Get-DbaAgentJobHistory -SqlInstance $instance -StartDate (Get-Date).AddDays(-1) |
    Where-Object { $_.Status -ne 'Succeeded' -and $_.StepID -eq 0 }

# Disk space
$diskSpace = Get-DbaDiskSpace -ComputerName $env:COMPUTERNAME |
    Where-Object { $_.PercentFree -lt 15 }

# Databases not online
$dbStates = Get-DbaDatabase -SqlInstance $instance |
    Where-Object { $_.Status -ne 'Normal' }

# CHECKDB age
$checkDb = Get-DbaLastGoodCheckDb -SqlInstance $instance |
    Where-Object { $_.LastGoodCheckDb -lt (Get-Date).AddDays(-7) }
```

---

## Scheduling

Deployed as a SQL Server Agent job running the PowerShell script daily at 07:00, with an operator notification on failure.

`[FILL IN — screenshot of the Agent job configuration]`

---

## Sample output

`[FILL IN — screenshot of the generated HTML report]`

---

## Deliberate failure test

A monitoring script that has never caught anything is untested.

`[FILL IN — break something on purpose (stop the backup job for 25 hours, fill a disk, take a database offline), confirm the report catches it, and screenshot the alert.]`

---

## Findings

`[FILL IN. Examples:]`
- *`Get-DbaLastBackup` reports per-database; system databases needed separate handling because tempdb has no backups by design.*
- *Running the script as an Agent job required the service account to have... *

---

## Interview talking points

- Why you'd monitor last-backup-age rather than job-success
- Why CHECKDB age matters (corruption ages into your backup retention)
- What dbatools is and why the community standardised on it
- The difference between monitoring and alerting

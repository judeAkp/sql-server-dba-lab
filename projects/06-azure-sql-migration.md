# Project 06 — Azure SQL Migration

**Status:** 🔲 Planned · **Week 7** · **Est. 6 hours**

> Replace `[FILL IN]`. Delete this block when done.
>
> ⚠️ Activate your Azure free account at the START of this week — the credit expires after 30 days. https://azure.microsoft.com/en-gb/free/

---

## Objective

Assess an on-premises database for cloud readiness, migrate it to Azure SQL Database, and document the differences a DBA has to account for.

**Why it's on the CV:** a large share of current UK DBA work is on-prem → cloud migration. Having done one end-to-end, even at lab scale, is directly relevant.

---

## Choosing the target

| | Azure SQL Database | SQL Managed Instance | SQL Server on Azure VM |
|---|---|---|---|
| Model | PaaS, single DB | PaaS, near-full instance | IaaS |
| SQL Agent | ❌ (use Elastic Jobs) | ✅ | ✅ |
| Cross-database queries | ❌ | ✅ | ✅ |
| CLR, Service Broker | ❌ | ✅ | ✅ |
| Backups | Automatic | Automatic | You manage |
| OS access | None | None | Full |
| Patching | Microsoft | Microsoft | You |
| Best for | New apps, single DBs | Lift-and-shift | Full control / legacy |

**Chosen:** `[FILL IN — and justify]`

> This comparison is a **guaranteed interview question**. Know it cold.

---

## 1. Assessment with Data Migration Assistant

Download: https://learn.microsoft.com/en-us/sql/dma/dma-overview

`[FILL IN — run an assessment against StackOverflow2010 or WideWorldImporters. Record: blocking issues, behaviour changes, unsupported features. Screenshot the report.]`

---

## 2. Provision the target

```bash
az sql server create --name [name] --resource-group dba-lab \
  --location uksouth --admin-user sqladmin --admin-password '[password]'

az sql db create --resource-group dba-lab --server [name] \
  --name StackOverflowAzure --service-objective S2

# Firewall — your IP only
az sql server firewall-rule create --resource-group dba-lab --server [name] \
  --name AllowMyIP --start-ip-address [ip] --end-ip-address [ip]
```

**Region note:** `uksouth` or `ukwest` for UK data residency — a real consideration under UK GDPR, and worth mentioning.

---

## 3. Migrate

`[FILL IN — method used: DMA, BACPAC export/import, or Azure Database Migration Service. Record duration and any failures.]`

```powershell
# BACPAC approach
sqlpackage /Action:Export /SourceServerName:localhost `
  /SourceDatabaseName:StackOverflow2010 /TargetFile:C:\Temp\SO2010.bacpac

sqlpackage /Action:Import /TargetServerName:[server].database.windows.net `
  /TargetDatabaseName:StackOverflowAzure /TargetUser:sqladmin `
  /SourceFile:C:\Temp\SO2010.bacpac
```

---

## 4. Validate

`[FILL IN — row counts per table, object counts, a sample of queries run against both, performance comparison]`

---

## 5. What changes for the DBA

| On-premises | Azure SQL Database |
|---|---|
| You schedule backups | Automatic, 7–35 day PITR retention |
| SQL Agent jobs | Elastic Jobs or Azure Automation |
| `sys.dm_os_wait_stats` (instance) | `sys.dm_db_wait_stats` (database) |
| You size hardware | DTU or vCore tiers, scalable live |
| Windows auth | Microsoft Entra ID |
| You patch | Microsoft patches |
| USE database | One database per connection |

`[FILL IN — what surprised you]`

---

## 6. DR in Azure

`[FILL IN — configure geo-replication or a failover group; test the failover; note the RPO/RTO Microsoft publishes vs what you measured]`

---

## 7. Cost

`[FILL IN — service tier chosen, monthly cost estimate, and how you'd right-size. Cost awareness is genuinely valued and rarely demonstrated by juniors.]`

⚠️ **Delete all resources when finished** or the free credit drains.

```bash
az group delete --name dba-lab --yes
```

---

## Interview talking points

- Azure SQL DB vs Managed Instance vs SQL on VM
- DTU vs vCore
- How backups work in Azure SQL and what PITR window you get
- What you lose moving to PaaS (Agent, cross-DB queries, OS access)
- Data residency and why UK region choice matters

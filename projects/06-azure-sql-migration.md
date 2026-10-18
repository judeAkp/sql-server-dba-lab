# Project 06 — Azure SQL Migration Readiness & Compatibility Assessment

**Status:** ✅ Complete · **Completed:** October 2026

---

## Objective

Assess an on-premises ~9 GB, **19.61-million-row** SQL Server database (`StackOverflow2010`) for migration to **Azure SQL Database (Singleton PaaS)** in **`uksouth` (London)**, detect and remediate blocking compatibility issues (`sys.sql_expression_dependencies`, heaps, non-contained `master` logins, legacy `COMPATIBILITY_LEVEL = 100`), convert instance logins to **Contained Database Users** (`sp_migrate_user_to_contained`), and right-size the target Azure SKU from measured storage and I/O metrics.

Repeatable assessment & remediation script: [`scripts/azure-migration/01-azure-migration-readiness-lab.sql`](../scripts/azure-migration/01-azure-migration-readiness-lab.sql)
Verbatim SSMS execution log: [`evidence/azure-migration-assessment.txt`](../evidence/azure-migration-assessment.txt)

---

## 1. Choosing the Azure SQL Target Architecture

| Capability / Requirement | Azure SQL Database (PaaS Singleton) | Azure SQL Managed Instance (PaaS MI) | SQL Server on Azure VM (IaaS) |
|---|---|---|---|
| **Service Model** | Database-scoped PaaS | Instance-scoped PaaS | Full OS + SQL Server IaaS |
| **3-Part Cross-Database Queries** | ❌ Blocked (`Msg 40515` / `SQL71562`) | ✅ Supported | ✅ Supported |
| **SQL Server Agent** | ❌ No (use Azure Elastic Jobs / Automation) | ✅ Supported natively | ✅ Supported natively |
| **Authentication Model** | Contained Database Users / Entra ID | Instance Logins + Contained + Entra ID | Full Active Directory / Mixed Mode |
| **Backups & Patching** | Automated (7–35 day PITR, geo-redundant) | Automated | DBA manages OS & SQL patching/backups |
| **High Availability** | Built-in local HA (99.99% SLA) | Built-in local HA (99.99% SLA) | DBA builds WSFC / Availability Group |
| **Best Fit** | Modern single-DB apps wanting lowest admin overhead | Lift-and-shift estates relying on cross-DB queries, CLR, or SQL Agent | Legacy apps requiring OS-level access, SSIS/SSRS on box, or specific SQL versions |

**Target Chosen for `StackOverflow2010`:** **Azure SQL Database (PaaS Singleton)** in **`uksouth` (London)** (with **Azure West (`ukwest`, Cardiff)** as the paired geo-DR region to maintain strict UK GDPR data residency inside the United Kingdom).
- **Justification:** Once the single cross-database reporting procedure (`dbo.usp_LegacyCrossDbReport`) and instance-scoped login (`[app_legacy_svc]`) are remediated, `StackOverflow2010` is a self-contained single-database OLTP workload (`11` tables, `19.61M` rows, `8.82 GB` data) that does not require paying the 4–5× cost premium of an Azure SQL Managed Instance.

---

## 2. Automated Pre-Migration Readiness Assessment (`Run A — Before Remediation`)

Before exporting a `.bacpac` (`SqlPackage /Action:Export`) or running Azure Data Migration Assistant (DMA), I ran a T-SQL catalog readiness check against `StackOverflow2010` (`sys.sql_expression_dependencies`, `sys.indexes`, `sys.database_principals`, and `sys.databases`):

```sql
WITH MigrationIssues AS (
    -- 1. Cross-database 3-part dependencies (Blocked in Azure SQL Database Singleton)
    SELECT 1 AS SortOrder,
           N'BLOCKER [Cross-DB Query]   | ' + OBJECT_NAME(d.referencing_id) COLLATE DATABASE_DEFAULT
           + N' references external DB [' + d.referenced_database_name COLLATE DATABASE_DEFAULT
           + N'].[' + COALESCE(d.referenced_schema_name, N'dbo') COLLATE DATABASE_DEFAULT
           + N'].[' + d.referenced_entity_name COLLATE DATABASE_DEFAULT + N']' AS IssueText
    FROM sys.sql_expression_dependencies d
    WHERE d.referenced_database_name IS NOT NULL
      AND d.referenced_database_name <> DB_NAME()

    UNION ALL

    -- 2. User tables without a clustered index (Heaps)
    SELECT 2,
           N'WARNING [Heap Table]       | dbo.' + t.name COLLATE DATABASE_DEFAULT
           + N' has no Clustered Index (index_id = 0)'
    FROM sys.tables t
    JOIN sys.indexes i ON t.object_id = i.object_id
    WHERE i.index_id = 0 AND t.is_ms_shipped = 0

    UNION ALL

    -- 3. Instance-scoped SQL users mapped to master logins
    SELECT 3,
           N'WARNING [Non-Contained Usr]| User [' + dp.name COLLATE DATABASE_DEFAULT
           + N'] is mapped to master login (' + dp.authentication_type_desc COLLATE DATABASE_DEFAULT
           + N') -> migrate to Contained User'
    FROM sys.database_principals dp
    WHERE dp.type = 'S' AND dp.principal_id > 4 AND dp.authentication_type_desc = N'INSTANCE'
)
SELECT IssueText FROM MigrationIssues ORDER BY SortOrder, IssueText;
```

### Verbatim Assessment Output (Before Remediation)

```text
=== 2. AZURE SQL DB READINESS ASSESSMENT — BEFORE REMEDIATION ===
BLOCKER [Cross-DB Query]   | usp_LegacyCrossDbReport references external DB [msdb].[dbo].[backupset]
WARNING [Heap Table]       | dbo.LegacyStagingHeap has no Clustered Index (index_id = 0)
WARNING [Non-Contained Usr]| User [app_legacy_svc] is mapped to master login (INSTANCE) -> migrate to Contained User
```

Additionally, Section 5 revealed that `StackOverflow2010` was still running at **`compatibility_level = 100` (SQL Server 2008)** (`Containment State = NONE`).

---

## 3. Remediation & Conversion to Contained Database (`sp_migrate_user_to_contained`)

### Step 3.1 — Resolving `Msg 5061` & `Msg 12819` When Enabling Partial Containment

Attempting `ALTER DATABASE StackOverflow2010 SET CONTAINMENT = PARTIAL` while other connections held shared (`S`) database locks initially failed with:

```text
Msg 5061, Level 16, State 1
ALTER DATABASE failed because a lock could not be placed on database 'StackOverflow2010'. Try again later.
Msg 12819, Level 16, State 1, Procedure sys.sp_migrate_user_to_contained
sp_migrate_user_to_contained cannot be used in a non-contained database (a database with CONTAINMENT set to NONE).
```

**Root cause & fix:** Switching `CONTAINMENT` requires an exclusive database lock (`X` lock) and fails if your own session or another SSMS tab holds an open connection context on `StackOverflow2010`. Switching to `SINGLE_USER WITH ROLLBACK IMMEDIATE` in `master`, setting `CONTAINMENT = PARTIAL` and `COMPATIBILITY_LEVEL = 160`, and returning to `MULTI_USER` allowed `sp_migrate_user_to_contained` to convert `[app_legacy_svc]` cleanly:

```sql
USE master;
GO
ALTER DATABASE StackOverflow2010 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE StackOverflow2010 SET CONTAINMENT = PARTIAL;
ALTER DATABASE StackOverflow2010 SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE StackOverflow2010 SET MULTI_USER;
GO

USE StackOverflow2010;
GO
-- Convert instance-mapped SQL login user to a self-contained database user
EXEC sys.sp_migrate_user_to_contained
    @username     = N'app_legacy_svc',
    @rename       = N'keep_name',
    @disablelogin = N'disable_login';
GO

-- Remove the cross-database procedure and staging heap
DROP PROCEDURE IF EXISTS dbo.usp_LegacyCrossDbReport;
DROP TABLE IF EXISTS dbo.LegacyStagingHeap;
GO
```

**Why `sp_migrate_user_to_contained` is a major win for Azure SQL:**
It copies the password hash directly from `master.sys.sql_logins` into `StackOverflow2010.sys.database_principals` (`authentication_type_desc = DATABASE`) and disables the old server login in `master`. When the database is exported to Azure SQL Database or fails over to `ukwest`, the user's credentials travel *inside* the database with **zero orphaned SIDs**.

---

## 4. Measured Footprint & Azure SKU Right-Sizing (`uksouth`)

```text
=== 5. FOOTPRINT & AZURE SKU SIZING SUMMARY (Target: uksouth) ===
Database               : StackOverflow2010
Compatibility Level    : 100 -> Upgraded to 160 (SQL Server 2022 / Azure SQL v12)
Containment State      : PARTIAL
User Tables            : 11
Total Rows (All Tables): 19,610,103
Allocated Data Size    : 8,820.38 MB (~8.61 GB)
Allocated Log Size     : 511.94 MB (~0.50 GB)
Recommended Azure Target: Azure SQL Database (PaaS) | Region: uksouth (London) | Tier: Standard S2 (50 DTUs, 250 GB max) or GP_S_Gen5_2 Serverless
```

### Target Provisioning & Migration Commands (`az sql` + `SqlPackage`)

```bash
# 1. Provision logical SQL Server and S2 database in uksouth (London)
az sql server create \
  --name sql-dbalab-uksouth \
  --resource-group rg-dba-lab-uk \
  --location uksouth \
  --enable-ad-only-auth

az sql db create \
  --resource-group rg-dba-lab-uk \
  --server sql-dbalab-uksouth \
  --name StackOverflow2010 \
  --service-objective S2 \
  --backup-storage-redundancy Geo
```

```powershell
# 2. Export schema + data to .bacpac and import to Azure SQL Database
SqlPackage /Action:Export `
  /SourceServerName:localhost `
  /SourceDatabaseName:StackOverflow2010 `
  /TargetFile:C:\SQLBackup\StackOverflow2010.bacpac `
  /SourceTrustServerCertificate:True

SqlPackage /Action:Import `
  /TargetServerName:sql-dbalab-uksouth.database.windows.net `
  /TargetDatabaseName:StackOverflow2010 `
  /SourceFile:C:\SQLBackup\StackOverflow2010.bacpac
```

---

## 5. What Changes for the DBA in Azure SQL Database

| Operational Area | On-Premises SQL Server 2022 | Azure SQL Database (PaaS) |
|---|---|---|
| **Backups** | DBA schedules Ola Hallengren jobs (`FULL` / `DIFF` / `LOG`) | Provider-managed automatic backups (full weekly, diff 12–24h, log every 5–10m; 7–35 day PITR + LTR up to 10 years) |
| **Wait Statistics** | `sys.dm_os_wait_stats` (instance-wide) | **`sys.dm_db_wait_stats`** (database-scoped) |
| **Resource Throttling** | Hardware-bound (CPU, RAM, SAN IOPS) | Tier-governed (`sys.dm_db_resource_stats` tracks `avg_cpu_percent`, `avg_data_io_percent`, `avg_log_write_percent` every 15 seconds) |
| **Job Scheduling** | SQL Server Agent (`msdb.dbo.sysjobs`) | Azure Elastic Jobs, Azure Automation Runbooks, or Azure Functions |
| **Authentication** | Windows AD / `master` SQL Logins | Microsoft Entra ID (Azure AD) + Contained Database Users (`CONTAINMENT = PARTIAL`) |
| **High Availability** | DBA builds WSFC / AG / Log Shipping | Built into service tier (Standard/General Purpose uses remote storage failover; Business Critical uses 4-node local Always On AG) |

---

## Interview Talking Points

- **Azure SQL Database vs Managed Instance vs SQL on Azure VM:** Use Azure SQL DB for single-database applications where you want automatic patching/HA and lowest cost; use Managed Instance for lift-and-shift migrations that depend on cross-database queries, SQL Agent, or Service Broker; use SQL VM when you need OS-level access or legacy SQL Server versions.
- **DTU vs vCore purchasing models:** DTU bundles CPU, memory, and I/O into a single blended metric (great for simple, predictable sizing like `S2 = 50 DTUs`); vCore lets you scale compute cores, memory, and storage IOPS independently and unlocks **Azure Hybrid Benefit** (reusing existing on-premises SQL Server licences to save up to 55%).
- **Why Contained Database Users (`CONTAINMENT = PARTIAL`) matter in the cloud:** Because Azure SQL Database failover groups fail over at the database level rather than the `master` instance level, authenticating users inside the database (`sp_migrate_user_to_contained` / Entra ID) prevents orphaned-user outages during geo-failover.
- **UK Data Residency:** Always deploy primary workloads to **`uksouth` (London)** and geo-secondary failover groups to **`ukwest` (Cardiff)** so customer PII never leaves UK jurisdiction under UK GDPR.

# Project 05 — High Availability: Always On Architecture & Warm-Standby Failover Lab

**Status:** ✅ Complete · **Completed:** October 2026

---

## Objective

Configure and verify SQL Server High Availability infrastructure on SQL Server 2022 Developer Edition:
1. Provision and verify an encrypted **Always On / Database Mirroring TCP Endpoint (`Hadr_endpoint` on Port `5022`, `AES` encryption)** and diagnose HADR service-level prerequisites (`Msg 47105`).
2. Build and test a **Readable Warm-Standby Secondary (`WITH STANDBY`)**, proving read-only query access (`1,000` → `1,500` rows replicated) while enforcing write protection (`Msg 3906`).
3. Execute a **planned zero-data-loss role-swap failover** (`BACKUP LOG ... WITH NORECOVERY` on Primary → `RESTORE LOG ... WITH RECOVERY` on Secondary) measured at **`901 ms`**, followed by reverse log shipping back to the former Primary.
4. Document multi-node Windows Server Failover Cluster (`WSFC`) vs Clusterless (`CLUSTER_TYPE = NONE`) Always On Availability Group design, quorum math, and DMV monitoring (`redo_queue_size`, `log_send_queue_size`).

Repeatable script: [`scripts/high-availability/01-ha-endpoint-and-failover-drill.sql`](../scripts/high-availability/01-ha-endpoint-and-failover-drill.sql)
Verbatim SSMS execution log: [`evidence/ha-failover-drill-log.txt`](../evidence/ha-failover-drill-log.txt)

---

## 1. Always On Availability Group Topology & Quorum Design

### Production Two-Node Synchronous AG Topology (`CLUSTER_TYPE = WSFC`)

```
┌─────────────────────────┐                  ┌─────────────────────────┐
│       SQLNODE01         │   TCP :5022      │       SQLNODE02         │
│   Primary Replica       │◄────────────────►│   Secondary Replica     │
│   SYNCHRONOUS_COMMIT    │   AES Encrypted  │   SYNCHRONOUS_COMMIT    │
│   Read / Write          │                  │   READ_ONLY / Offload   │
└───────────┬─────────────┘                  └───────────┬─────────────┘
            │                                            │
            └─────────────────────┬──────────────────────┘
                                  │
                     ┌────────────▼────────────┐
                     │  WSFC Cluster Quorum    │
                     │  Node + File Share /    │
                     │  Cloud Witness (3 votes)│
                     └────────────┬────────────┘
                                  │
                     ┌────────────▼────────────┐
                     │  AG Virtual Listener    │
                     │  SQLAG-LISTENER :1433   │
                     └─────────────────────────┘
```

**Why a Witness is mandatory in a 2-node cluster:**
With only two voting nodes and no witness, if `SQLNODE01` loses power, `SQLNODE02` has `1` out of `2` votes (`50%` — not a majority `> 50%`). To prevent split-brain, WSFC shuts the cluster down and the Availability Group goes **offline**. Adding a File Share Witness (`\\Fileserver\ClusterWitness`) or Azure Cloud Witness gives the cluster **3 total votes**, allowing `SQLNODE02 + Witness` (`2/3` votes = `66.7%`) to maintain quorum and perform automatic failover.

---

## 2. Lab Execution — HADR TCP Endpoint (`:5022`) & `Msg 47105` Diagnosis

```sql
-- Create the Always On / Database Mirroring TCP Endpoint with required AES encryption
CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATA_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
GO

SELECT
    e.name AS endpoint_name,
    e.protocol_desc,
    e.type_desc,
    e.state_desc,
    te.port,
    dm.role_desc,
    dm.encryption_algorithm_desc
FROM sys.database_mirroring_endpoints dm
JOIN sys.endpoints e ON dm.endpoint_id = e.endpoint_id
JOIN sys.tcp_endpoints te ON e.endpoint_id = te.endpoint_id;
```

**Measured Endpoint Verification (`sys.database_mirroring_endpoints`):**

| Endpoint Name | Protocol | Type | State | TCP Port | Role | Encryption |
|---|---|---|---|---:|---|---|
| `Hadr_endpoint` | `TCP` | `DATABASE_MIRRORING` | **`STARTED`** | **`5022`** | `ALL` | `AES` (`REQUIRED`) |

### Reproducing `Msg 47105` (Service-Level HADR Prerequisite)

Attempting `CREATE AVAILABILITY GROUP [AG_ReadScale_Lab] WITH (CLUSTER_TYPE = NONE)` while `SERVERPROPERTY('IsHadrEnabled') = 0` captured the exact engine prerequisite error:

```text
Msg 47105: The Always On Availability Groups feature must be enabled for this server instance before you can perform availability group operations. Please enable the feature, then retry the operation.
```

**Why `IsHadrEnabled = 0` and the Configuration Manager tab is disabled on Windows 11 (Client OS vs Server OS):**
- Even though **SQL Server 2022 Developer Edition** includes every Enterprise Edition database engine feature (TDE, Page Compression, Online Indexing, `DATA_MIRRORING` endpoints), opening **SQL Server Configuration Manager → SQL Server (MSSQLSERVER) Properties → Always On High Availability** on a **Windows 11** host shows the tab/checkbox disabled.
- **Root cause:** Always On Availability Groups on Windows rely on the **Windows Server Failover Clustering (`Failover-Clustering` / `ClusSvc`)** operating-system feature. Because WSFC only exists on **Windows Server** (2016/2019/2022/2025) and does not exist on client Windows editions (Windows 10/11), SQL Server Configuration Manager blocks enabling HADR on a non-Server Windows OS.
- In a Windows Server environment (once `Install-WindowsFeature -Name Failover-Clustering` is installed), HADR is enabled via Configuration Manager or `Enable-DbaAgHadr -SqlInstance localhost -Force`.

---

## 3. Live Warm-Standby & Readable Secondary Drill (`WITH STANDBY`)

To execute and measure end-to-end transaction replication, read-only secondary querying, write protection, and role-swap failover on a single host, I built `HA_PrimaryDB` and `HA_SecondaryDB`:

### Step 3.1 — Seed Primary & Initialize Readable Secondary (`STANDBY`)

```sql
-- 1. Take base Full Backup of HA_PrimaryDB (1,000 rows in dbo.Transactions)
BACKUP DATABASE HA_PrimaryDB
TO DISK = N'C:\SQLBackup\HA\HA_Primary_FULL.bak'
WITH INIT, COMPRESSION, CHECKSUM;

-- 2. Initialize HA_SecondaryDB in STANDBY mode (undo file allows read-only access between log restores)
RESTORE DATABASE HA_SecondaryDB
FROM DISK = N'C:\SQLBackup\HA\HA_Primary_FULL.bak'
WITH MOVE N'HA_PrimaryDB'     TO N'C:\SQLData\HA_SecondaryDB.mdf',
     MOVE N'HA_PrimaryDB_log' TO N'C:\SQLLogs\HA_SecondaryDB_log.ldf',
     STANDBY = N'C:\SQLBackup\HA\HA_Secondary_Undo.trn',
     REPLACE;
```

**Measured Output:**
- **Base Full Backup (`HA_Primary_FULL.bak`):** `465 pages in 0.106 seconds (34.211 MB/sec)`.
- **Secondary Initialization (`HA_SecondaryDB`):** `465 pages in 0.030 seconds (120.882 MB/sec)`, state = `ONLINE (Standby / Read-Only)` (`is_read_only = 1`, `is_in_standby = 1`).
- **Readable Secondary Test:** `PASS [Readable Secondary]: SELECT on HA_SecondaryDB returned 1000 rows.`
- **Write Protection Test:** Attempting `INSERT` on `HA_SecondaryDB` was blocked immediately:
  ```text
  PASS [Write Protection]: Write on HA_SecondaryDB blocked -> Msg 3906: Failed to update database "HA_SecondaryDB" because the database is read-only.
  ```

### Step 3.2 — Transaction Log Shipping & Synchronization (`1,000 → 1,500` Rows)

Inserted `500` additional rows into `HA_PrimaryDB` (`Batch 2`), took a transaction log backup (`HA_Log_01.trn`), and applied it to `HA_SecondaryDB` `WITH STANDBY`:

```text
Processed 12 pages for database 'HA_PrimaryDB', file 'HA_PrimaryDB_log' on file 1.
BACKUP LOG successfully processed 12 pages in 0.007 seconds (12.765 MB/sec).
Processed 0 pages for database 'HA_SecondaryDB', file 'HA_PrimaryDB' on file 1.
Processed 12 pages for database 'HA_SecondaryDB', file 'HA_PrimaryDB_log' on file 1.
RESTORE LOG successfully processed 12 pages in 0.007 seconds (12.765 MB/sec).
Synchronization verified: Primary rows = 1500 | Readable Secondary rows = 1500.
```

---

## 4. Planned Zero-Data-Loss Failover (Role Swap) & Reverse Synchronization

Executed a full planned role swap between `HA_PrimaryDB` and `HA_SecondaryDB`:

```sql
-- 1. Demote HA_PrimaryDB by taking a tail-log backup WITH NORECOVERY
ALTER DATABASE HA_PrimaryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
BACKUP LOG HA_PrimaryDB
TO DISK = N'C:\SQLBackup\HA\HA_TailLog_Failover.trn'
WITH NORECOVERY, INIT, COMPRESSION, CHECKSUM;

-- 2. Promote HA_SecondaryDB to Read-Write Primary by applying the tail log WITH RECOVERY
RESTORE LOG HA_SecondaryDB
FROM DISK = N'C:\SQLBackup\HA\HA_TailLog_Failover.trn'
WITH RECOVERY;
```

**Measured Failover Results:**

| Metric | Measured Result |
|---|---|
| **Tail-log capture (`HA_PrimaryDB WITH NORECOVERY`)** | `7 pages in 0.006 seconds (7.893 MB/sec)` — `HA_PrimaryDB` entered `RESTORING` |
| **Tail-log apply & recovery (`HA_SecondaryDB WITH RECOVERY`)** | `7 pages in 0.010 seconds (4.736 MB/sec)` — `HA_SecondaryDB` became Read-Write Primary |
| **Total End-to-End Role Swap Duration (RTO)** | **`901 ms` (`0.90 seconds`)** |
| **Data Loss (RPO)** | **`0 rows` (`1,500` rows preserved across both nodes)** |
| **Reverse Log Ship (`HA_SecondaryDB` → `HA_PrimaryDB WITH STANDBY`)** | `4 pages in 0.003 seconds (8.138 MB/sec)` — `HA_PrimaryDB` transitioned to Warm-Standby Secondary |

---

## 5. Always On AG Monitoring DMVs (`redo_queue_size` & `log_send_queue_size`)

In a production Always On Availability Group, the two critical health metrics are in `sys.dm_hadr_database_replica_states`:

```sql
SELECT
    ag.name                                        AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ar.availability_mode_desc,
    ars.synchronization_health_desc,
    DB_NAME(drs.database_id)                       AS database_name,
    drs.synchronization_state_desc,
    drs.log_send_queue_size                        AS unsent_log_kb,
    drs.log_send_rate                              AS send_rate_kb_sec,
    drs.redo_queue_size                            AS unredone_log_kb,
    drs.redo_rate                                  AS redo_rate_kb_sec,
    CAST(drs.redo_queue_size * 1.0 / NULLIF(drs.redo_rate, 0) AS decimal(10,1))
                                                   AS est_failover_redo_sec
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id
JOIN sys.dm_hadr_database_replica_states drs
    ON ar.replica_id = drs.replica_id;
```

- **`log_send_queue_size` (KB):** Amount of transaction log on the Primary that has not yet been hardened on the Secondary. In `ASYNCHRONOUS_COMMIT` mode, **`log_send_queue_size` represents your potential data loss (RPO)** if the Primary dies abruptly.
- **`redo_queue_size` (KB):** Amount of hardened log on the Secondary waiting to be replayed against data pages. **`redo_queue_size / redo_rate` determines how long failover will take (RTO)** before the Secondary can come online.

---

## 6. High Availability Technology Comparison

| Technology | Scope | Automatic Failover | Readable Secondary | Shared Storage Required? | Best Use Case |
|---|---|---|---|---|---|
| **Always On Availability Group (Enterprise)** | Group of databases | **Yes** (`SYNCHRONOUS_COMMIT`) | **Yes** (up to 8 secondaries) | **No** (each node has independent storage) | Mission-critical OLTP needing <30s automatic failover + read-scale reporting offload |
| **Basic Availability Group (Standard Edition)** | **1 database** per AG | **Yes** (2 nodes max) | **No** | **No** | Standard Edition HA replacement for deprecated Database Mirroring |
| **Failover Cluster Instance (FCI)** | **Entire SQL instance** (`master`, `msdb`, jobs, logins move together) | **Yes** | **No** (passive node is stopped) | **Yes** (SAN, S2D, or SMB file share) | Protecting the entire instance when SAN/shared storage exists and apps rely heavily on SQL Agent jobs |
| **Log Shipping (`WITH STANDBY`)** | Per database | **No** (manual / scripted role swap) | **Yes** (between log restores via `.trn` undo file) | **No** | Low-cost warm DR across WAN/offsite with zero cluster licensing complexity |

---

## Interview Talking Points

- **AG vs FCI:** An FCI shares storage (SAN) so a storage failure is a single point of failure, but the whole instance (`msdb` jobs, logins) fails over together. An AG duplicates storage across independent nodes (protecting against storage failure) and allows read-only secondaries, but logins and SQL Agent jobs must be synced separately (e.g. via `dbatools` `Copy-DbaLogin` / `Copy-DbaAgentJob`).
- **Synchronous vs Asynchronous Commit:** Synchronous Commit waits for the secondary to harden the log block to disk (`hardened_lsn`) before acknowledging the commit to the client (`RPO = 0`, at the cost of network round-trip latency). Asynchronous Commit acknowledges immediately after local log flush (zero latency impact, best for cross-region DR, but `log_send_queue_size > 0` means potential data loss on unplanned failover).
- **Why an Availability Group is NOT a backup:** If someone drops a table (`DROP TABLE dbo.Users`) or corrupts logical data on the Primary, that transaction is **replicated to every Secondary in milliseconds**. Only a point-in-time backup chain (`STOPAT`) can recover from logical human/application errors.

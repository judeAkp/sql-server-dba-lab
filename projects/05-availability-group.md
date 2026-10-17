# Project 05 — Always On Availability Group

**Status:** 🔲 Planned · **Week 6** · **Est. 8 hours**

> Replace `[FILL IN]`. Delete this block when done.

---

## Objective

Build a two-node Always On Availability Group, perform both planned and unplanned failovers, and document the process — including what goes wrong.

**Why this project matters disproportionately:** most junior candidates have never touched AGs. Having built one, broken it and fixed it puts you ahead of people with more years but less curiosity.

---

## Lab topology

```
┌─────────────────┐         ┌─────────────────┐
│   SQLNODE01     │         │   SQLNODE02     │
│  Primary        │◄───────►│  Secondary      │
│  SQL 2022 Dev   │  Sync   │  SQL 2022 Dev   │
└────────┬────────┘         └────────┬────────┘
         │                           │
         └───────────┬───────────────┘
                     │
          ┌──────────▼──────────┐
          │  WSFC Cluster       │
          │  File Share Witness │
          └─────────────────────┘
                     │
          ┌──────────▼──────────┐
          │  Listener           │
          │  SQLAG-LISTENER     │
          └─────────────────────┘
```

Built on Hyper-V: 2 × Windows Server VMs, 4 GB RAM each, domain-joined.

---

## Build steps

### 1. Prerequisites
`[FILL IN — domain controller VM, both nodes joined, static IPs, firewall rules for 1433 and 5022]`

### 2. Windows Server Failover Cluster

```powershell
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

Test-Cluster -Node SQLNODE01, SQLNODE02
New-Cluster -Name SQLCLUSTER -Node SQLNODE01, SQLNODE02 -StaticAddress 192.168.1.100 -NoStorage

# Quorum: file share witness for a 2-node cluster
Set-ClusterQuorum -NodeAndFileShareMajority \\DC01\ClusterWitness
```

**Why a witness:** with two nodes and no witness, losing one node loses quorum and the cluster goes down. The witness provides the tie-breaking vote. This is a guaranteed interview question.

### 3. Enable Always On
`[FILL IN — SQL Server Configuration Manager → Properties → Always On High Availability → tick, restart service. Both nodes.]`

### 4. Prepare the database

```sql
ALTER DATABASE AGTestDB SET RECOVERY FULL;
BACKUP DATABASE AGTestDB TO DISK = '\\DC01\Backup\AGTestDB.bak' WITH INIT, COMPRESSION;
BACKUP LOG AGTestDB TO DISK = '\\DC01\Backup\AGTestDB.trn';
```

Restore on the secondary `WITH NORECOVERY` — the secondary must be left in restoring state to join the AG.

### 5. Create the AG

```sql
CREATE AVAILABILITY GROUP [AG01]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY)
FOR DATABASE AGTestDB
REPLICA ON
  'SQLNODE01' WITH (
      ENDPOINT_URL = 'TCP://SQLNODE01.lab.local:5022',
      AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
      FAILOVER_MODE = AUTOMATIC,
      SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)),
  'SQLNODE02' WITH (
      ENDPOINT_URL = 'TCP://SQLNODE02.lab.local:5022',
      AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
      FAILOVER_MODE = AUTOMATIC,
      SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY));
```

### 6. Listener

```sql
ALTER AVAILABILITY GROUP [AG01]
ADD LISTENER 'SQLAG-LISTENER' (
    WITH IP ((N'192.168.1.101', N'255.255.255.0')), PORT = 1433
);
```

**What the listener is for:** applications connect to the listener name, not a node. On failover the listener follows the primary, so the application reconnects without a config change.

---

## Failover tests

### Test 1 — Planned manual failover

```sql
ALTER AVAILABILITY GROUP [AG01] FAILOVER;
```

`[FILL IN — time taken, whether connections dropped, what the application saw]`

### Test 2 — Unplanned (kill the primary)

`[FILL IN — hard power off the primary VM. Record: automatic failover time, data loss (should be zero in synchronous commit), what appears in the error log on the surviving node.]`

### Test 3 — Quorum loss

`[FILL IN — stop the witness and one node. Observe the cluster losing quorum and the AG going offline. This teaches why witness placement matters.]`

---

## Monitoring

```sql
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.synchronization_health_desc,
    drs.database_id,
    drs.synchronization_state_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id;
```

**`redo_queue_size` is the metric that matters** — it's how far behind the secondary is, and therefore how long a failover will actually take.

---

## Problems encountered

`[FILL IN — genuinely the most valuable section. Record every failure honestly: endpoint permissions, firewall ports, the database not being in NORECOVERY, DNS issues with the listener, quorum surprises. "I broke it and here's how I diagnosed it" is a far better story than "it worked first time".]`

---

## AG vs the alternatives

| Technology | Granularity | Automatic failover | Readable secondary | Shared storage |
|---|---|---|---|---|
| Availability Group | Database | Yes | Yes | No |
| Failover Cluster Instance | Whole instance | Yes | No | Yes |
| Log shipping | Database | No | Yes (with delay) | No |
| Replication | Table/article | No | Yes | No |

`[FILL IN — when you'd choose each]`

---

## Interview talking points

- AG vs FCI — the actual difference and when you'd pick each
- Synchronous vs asynchronous commit, and the RPO implication
- What the listener does and why applications need it
- Why a 2-node cluster needs a witness
- What `redo_queue_size` tells you
- Why AGs are not a replacement for backups

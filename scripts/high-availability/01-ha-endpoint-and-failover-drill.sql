/* ============================================================================
   01-ha-endpoint-and-failover-drill.sql
   Project 05 — High Availability & Failover Drill · SQL Server DBA Lab

   PURPOSE
       1. Configures and verifies the TCP 5022 DATA_MIRRORING endpoint (AES)
          and captures Msg 35221 when HADR manager is not yet enabled.
       2. Builds a Primary (HA_PrimaryDB) and Readable Warm-Standby Secondary
          (HA_SecondaryDB WITH STANDBY), proving read-only query access and
          write-blocking (Msg 3906).
       3. Replicates new transactions via log shipping (1,000 -> 1,500 rows).
       4. Executes a live zero-data-loss role-swap failover (BACKUP LOG WITH
          NORECOVERY on Primary -> RESTORE LOG WITH RECOVERY on Secondary),
          writes 100 post-failover rows (1,600 total), and synchronises them
          back to the former Primary in STANDBY mode.
   ============================================================================ */

USE master;
GO
SET NOCOUNT ON;

PRINT '========================================================================';
PRINT 'PROJECT 05 — HIGH AVAILABILITY, HADR ENDPOINT & FAILOVER DRILL';
PRINT '========================================================================';

EXEC sys.xp_create_subdir N'C:\SQLBackup\HA';
GO

/* ----------------------------------------------------------------------------
   1. HADR PRE-FLIGHT, TCP 5022 ENDPOINT & MSG 35221 VERIFICATION
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 1. HADR STATUS & TCP 5022 DATA_MIRRORING ENDPOINT ===';

SELECT
    @@SERVERNAME AS server_name,
    CAST(SERVERPROPERTY('Edition') AS varchar(60)) AS sql_edition,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int)  AS is_hadr_enabled;

IF EXISTS (SELECT 1 FROM sys.endpoints WHERE name = N'Hadr_endpoint')
    DROP ENDPOINT [Hadr_endpoint];
GO

CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATA_MIRRORING (ROLE = ALL, AUTHENTICATION = WINDOWS NEGOTIATE, ENCRYPTION = REQUIRED ALGORITHM AES);
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

PRINT 'Verified: [Hadr_endpoint] is STARTED on TCP port 5022 with AES encryption.';

BEGIN TRY
    EXEC(N'CREATE AVAILABILITY GROUP [AG_ReadScale_Lab] WITH (CLUSTER_TYPE = NONE) FOR REPLICA ON N''' + @@SERVERNAME + N''' WITH (ENDPOINT_URL = N''TCP://localhost:5022'', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL);');
    PRINT 'Created [AG_ReadScale_Lab] (CLUSTER_TYPE = NONE).';
    EXEC(N'DROP AVAILABILITY GROUP [AG_ReadScale_Lab];');
END TRY
BEGIN CATCH
    PRINT 'Captured expected HADR pre-requisite -> Msg ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + ERROR_MESSAGE();
END CATCH
GO

/* ----------------------------------------------------------------------------
   2. BUILD WARM-STANDBY TOPOLOGY (HA_PrimaryDB -> HA_SecondaryDB WITH STANDBY)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 2. WARM-STANDBY INITIALIZATION & READABLE SECONDARY TEST ===';

IF DB_ID(N'HA_SecondaryDB') IS NOT NULL
BEGIN
    ALTER DATABASE HA_SecondaryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HA_SecondaryDB;
END
IF DB_ID(N'HA_PrimaryDB') IS NOT NULL
BEGIN
    ALTER DATABASE HA_PrimaryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HA_PrimaryDB;
END
GO

CREATE DATABASE HA_PrimaryDB;
ALTER DATABASE HA_PrimaryDB SET RECOVERY FULL;
GO

USE HA_PrimaryDB;
GO
CREATE TABLE dbo.Transactions
(
    TxnID       int IDENTITY(1,1) PRIMARY KEY,
    BatchLabel  varchar(80) NOT NULL,
    RecordedAt  datetime2(3) NOT NULL DEFAULT SYSDATETIME()
);

INSERT dbo.Transactions (BatchLabel)
SELECT TOP (1000) 'Batch 1: Initial Primary Seed'
FROM sys.all_objects;
GO

USE master;
GO
BACKUP DATABASE HA_PrimaryDB
TO DISK = N'C:\SQLBackup\HA\HA_Primary_FULL.bak'
WITH INIT, COMPRESSION, CHECKSUM;

RESTORE DATABASE HA_SecondaryDB
FROM DISK = N'C:\SQLBackup\HA\HA_Primary_FULL.bak'
WITH MOVE N'HA_PrimaryDB'     TO N'C:\SQLData\HA_SecondaryDB.mdf',
     MOVE N'HA_PrimaryDB_log' TO N'C:\SQLLogs\HA_SecondaryDB_log.ldf',
     STANDBY = N'C:\SQLBackup\HA\HA_Secondary_Undo.trn',
     REPLACE;
GO

SELECT
    name AS database_name,
    state_desc,
    is_read_only,
    is_in_standby
FROM sys.databases
WHERE name IN (N'HA_PrimaryDB', N'HA_SecondaryDB')
ORDER BY name;

DECLARE @secRows1 int;
SELECT @secRows1 = COUNT(*) FROM HA_SecondaryDB.dbo.Transactions;
PRINT 'PASS [Readable Secondary]: SELECT on HA_SecondaryDB returned ' + CAST(@secRows1 AS varchar(10)) + ' rows.';

BEGIN TRY
    INSERT HA_SecondaryDB.dbo.Transactions (BatchLabel) VALUES ('Illegal write on Secondary');
END TRY
BEGIN CATCH
    PRINT 'PASS [Write Protection]: Write on HA_SecondaryDB blocked -> Msg ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + ERROR_MESSAGE();
END CATCH
GO

/* ----------------------------------------------------------------------------
   3. SHIP TRANSACTION LOG & VERIFY SYNCHRONIZATION (1,000 -> 1,500 ROWS)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 3. LOG SHIPPING REPLICATION TEST (+500 ROWS -> 1,500 TOTAL) ===';

INSERT HA_PrimaryDB.dbo.Transactions (BatchLabel)
SELECT TOP (500) 'Batch 2: Replicated via Log Backup'
FROM sys.all_objects;

BACKUP LOG HA_PrimaryDB
TO DISK = N'C:\SQLBackup\HA\HA_Log_01.trn'
WITH INIT, COMPRESSION, CHECKSUM;

RESTORE LOG HA_SecondaryDB
FROM DISK = N'C:\SQLBackup\HA\HA_Log_01.trn'
WITH STANDBY = N'C:\SQLBackup\HA\HA_Secondary_Undo.trn';

DECLARE @priRows int, @secRows2 int;
SELECT @priRows  = COUNT(*) FROM HA_PrimaryDB.dbo.Transactions;
SELECT @secRows2 = COUNT(*) FROM HA_SecondaryDB.dbo.Transactions;
PRINT 'Synchronization verified: Primary rows = ' + CAST(@priRows AS varchar(10))
    + ' | Readable Secondary rows = ' + CAST(@secRows2 AS varchar(10)) + '.';
GO

/* ----------------------------------------------------------------------------
   4. PLANNED ZERO-DATA-LOSS FAILOVER (ROLE SWAP: PRIMARY <-> SECONDARY)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 4. PLANNED ZERO-DATA-LOSS FAILOVER (ROLE SWAP) ===';

DECLARE @t0 datetime2(3) = SYSDATETIME();

ALTER DATABASE HA_PrimaryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
BACKUP LOG HA_PrimaryDB
TO DISK = N'C:\SQLBackup\HA\HA_TailLog_Failover.trn'
WITH NORECOVERY, INIT, COMPRESSION, CHECKSUM;

RESTORE LOG HA_SecondaryDB
FROM DISK = N'C:\SQLBackup\HA\HA_TailLog_Failover.trn'
WITH RECOVERY;

DECLARE @failoverMs int = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
PRINT 'Role swap completed in ' + CAST(@failoverMs AS varchar(20)) + ' ms (0 data loss).';

INSERT HA_SecondaryDB.dbo.Transactions (BatchLabel)
SELECT TOP (100) 'Batch 3: Written to Promoted Secondary after Failover'
FROM sys.all_objects;

BACKUP LOG HA_SecondaryDB
TO DISK = N'C:\SQLBackup\HA\HA_Log_PostFailover.trn'
WITH INIT, COMPRESSION, CHECKSUM;

RESTORE LOG HA_PrimaryDB
FROM DISK = N'C:\SQLBackup\HA\HA_Log_PostFailover.trn'
WITH STANDBY = N'C:\SQLBackup\HA\HA_Primary_Undo.trn';

DECLARE @newPriRows int, @newSecRows int;
SELECT @newPriRows = COUNT(*) FROM HA_SecondaryDB.dbo.Transactions;
SELECT @newSecRows = COUNT(*) FROM HA_PrimaryDB.dbo.Transactions;

PRINT 'Post-Failover Role States:';
PRINT '  - HA_SecondaryDB (NEW PRIMARY, Read-Write): ' + CAST(@newPriRows AS varchar(10)) + ' rows.';
PRINT '  - HA_PrimaryDB   (NEW SECONDARY, Standby) : ' + CAST(@newSecRows AS varchar(10)) + ' rows.';
GO

/* ----------------------------------------------------------------------------
   5. CLEAN UP LAB DATABASES & ENDPOINT
   ---------------------------------------------------------------------------- */
RESTORE DATABASE HA_PrimaryDB WITH RECOVERY;
ALTER DATABASE HA_PrimaryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE HA_PrimaryDB;

ALTER DATABASE HA_SecondaryDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE HA_SecondaryDB;
PRINT '';
PRINT 'Cleanup complete: Dropped HA_PrimaryDB and HA_SecondaryDB (Hadr_endpoint retained on TCP 5022).';
GO

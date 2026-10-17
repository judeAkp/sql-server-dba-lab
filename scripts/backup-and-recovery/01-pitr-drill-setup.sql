/* ============================================================================
   01-pitr-drill-setup.sql
   Project 01 — Backup & Recovery · SQL Server DBA Lab

   PURPOSE
       Build a known-good full → differential → log chain, insert a marker row,
       then run a DELETE with no WHERE clause and capture the tail of the log.
       Run 02-pitr-drill-restore.sql afterwards to restore to the moment before
       the delete.

   RUN AGAINST
       SQL Server 2022 Developer Edition. StackOverflow2010 must exist and be
       able to enter FULL recovery.

   SAFETY
       * Creates and drops dbo.Drill_Orders inside StackOverflow2010.
       * Deletes rows from dbo.Drill_Orders only — never a real table.
       * Overwrites files in C:\SQLBackup\DRILL (WITH INIT).

   HAND-OFF
       The recovery target time is written to dbo.Drill_Control inside
       StackOverflow2010. 02-pitr-drill-restore.sql reads it automatically.
   ============================================================================ */

SET NOCOUNT ON;
GO

USE master;
GO

/* ---------------------------------------------------------------------------
   0. Pre-flight
   --------------------------------------------------------------------------- */

IF DB_ID(N'StackOverflow2010') IS NULL
    THROW 50000, N'StackOverflow2010 not found on this instance. Attach or restore it first.', 1;

IF CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) NOT LIKE N'%Developer%'
   AND CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) NOT LIKE N'%Enterprise%'
   AND CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) NOT LIKE N'%Standard%'
    THROW 50001, N'This drill needs an edition that supports backup compression and SQL Server Agent.', 1;

-- Backup folder must exist before we start; the service account must be able
-- to write to it (see the pre-flight checklist in the walkthrough).
CREATE TABLE #fe (FileExists int, IsDirectory int, ParentExists int);
INSERT #fe EXEC master.dbo.xp_fileexist N'C:\SQLBackup\DRILL';
IF (SELECT FileExists FROM #fe) <> 1
BEGIN
    DROP TABLE #fe;
    THROW 50002, N'C:\SQLBackup\DRILL does not exist. Create it and grant the service account Full Control.', 1;
END
DROP TABLE #fe;
GO

/* ---------------------------------------------------------------------------
   1. Build the drill table: 5,000 rows
   --------------------------------------------------------------------------- */

USE StackOverflow2010;
GO

IF OBJECT_ID(N'dbo.Drill_Orders', N'U') IS NOT NULL
    DROP TABLE dbo.Drill_Orders;
GO

CREATE TABLE dbo.Drill_Orders
(
    OrderID    int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_Drill_Orders PRIMARY KEY,
    CustomerID int           NOT NULL,
    Amount     decimal(10,2) NOT NULL,
    OrderDate  datetime2(3)  NOT NULL CONSTRAINT DF_Drill_Orders_OrderDate DEFAULT SYSDATETIME()
);
GO

-- Control table: survives the DELETE, and carries the recovery target time
-- across to the restore script.
IF OBJECT_ID(N'dbo.Drill_Control', N'U') IS NULL
    CREATE TABLE dbo.Drill_Control
    (
        RunID       int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Drill_Control PRIMARY KEY,
        CrashTime   datetime2(3) NOT NULL,
        ExpectedRows int         NOT NULL,
        CreatedAt   datetime2(3) NOT NULL CONSTRAINT DF_Drill_Control_CreatedAt DEFAULT SYSDATETIME()
    );
GO

INSERT dbo.Drill_Orders (CustomerID, Amount)
SELECT TOP (5000)
       ABS(CHECKSUM(NEWID())) % 10000,
       CAST(ABS(CHECKSUM(NEWID())) % 500000 / 100.0 AS decimal(10,2))
FROM sys.all_objects a
CROSS JOIN sys.all_objects b;

SELECT COUNT(*) AS rows_after_seed_5000 FROM dbo.Drill_Orders;
GO

/* ---------------------------------------------------------------------------
   2. Base full backup
   --------------------------------------------------------------------------- */

BACKUP DATABASE StackOverflow2010
TO DISK = N'C:\SQLBackup\DRILL\PITR_01_full.bak'
WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
GO

/* ---------------------------------------------------------------------------
   3. +2,500 rows, then a differential
   --------------------------------------------------------------------------- */

INSERT dbo.Drill_Orders (CustomerID, Amount)
SELECT TOP (2500)
       ABS(CHECKSUM(NEWID())) % 10000,
       CAST(ABS(CHECKSUM(NEWID())) % 500000 / 100.0 AS decimal(10,2))
FROM sys.all_objects a
CROSS JOIN sys.all_objects b;

SELECT COUNT(*) AS rows_after_insert_7500 FROM dbo.Drill_Orders;
GO

BACKUP DATABASE StackOverflow2010
TO DISK = N'C:\SQLBackup\DRILL\PITR_02_diff.bak'
WITH DIFFERENTIAL, INIT, COMPRESSION, CHECKSUM, STATS = 10;
GO

/* ---------------------------------------------------------------------------
   4. +2,500 rows, then a log backup
   --------------------------------------------------------------------------- */

INSERT dbo.Drill_Orders (CustomerID, Amount)
SELECT TOP (2500)
       ABS(CHECKSUM(NEWID())) % 10000,
       CAST(ABS(CHECKSUM(NEWID())) % 500000 / 100.0 AS decimal(10,2))
FROM sys.all_objects a
CROSS JOIN sys.all_objects b;

SELECT COUNT(*) AS rows_before_crash_10000 FROM dbo.Drill_Orders;
GO

BACKUP LOG StackOverflow2010
TO DISK = N'C:\SQLBackup\DRILL\PITR_03_log.trn'
WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
GO

/* ---------------------------------------------------------------------------
   5. The accident

   A marker row is inserted, the recovery target time is captured, and only
   then is the table emptied. The two-second gap guarantees the DELETE's log
   records are strictly later than the captured time, so STOPAT is unambiguous.
   --------------------------------------------------------------------------- */

INSERT dbo.Drill_Orders (CustomerID, Amount) VALUES (-1, 0.01);
GO

DECLARE @crash_time datetime2(3) = SYSDATETIME();

INSERT dbo.Drill_Control (CrashTime, ExpectedRows)
VALUES (@crash_time, 10001);

SELECT
    CONVERT(varchar(23), @crash_time, 121) AS crash_time,
    10001                                  AS expected_rows_after_restore,
    1                                      AS expected_marker_rows;

WAITFOR DELAY '00:00:02';
GO

DELETE FROM dbo.Drill_Orders;

SELECT COUNT(*) AS rows_after_accident_must_be_0 FROM dbo.Drill_Orders;
GO

/* ---------------------------------------------------------------------------
   6. Capture the tail of the log — without this the drill proves nothing
   --------------------------------------------------------------------------- */

BACKUP LOG StackOverflow2010
TO DISK = N'C:\SQLBackup\DRILL\PITR_04_log_after.trn'
WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
GO

SELECT
    CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' END AS backup_type,
    bs.backup_finish_date,
    CAST(bs.compressed_backup_size / 1048576.0 AS decimal(10,1)) AS size_mb,
    mf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = N'StackOverflow2010'
  AND bs.backup_finish_date >= DATEADD(HOUR, -1, SYSDATETIME())
ORDER BY bs.backup_finish_date;
GO

PRINT N'';
PRINT N'=== SETUP COMPLETE ====================================================';
PRINT N'Next: run 02-pitr-drill-restore.sql.';
PRINT N'The recovery target time is stored in StackOverflow2010.dbo.Drill_Control.';
PRINT N'Expected result after restore: 10001 rows, including CustomerID = -1.';
PRINT N'=======================================================================';
GO

/* ============================================================================
   02-pitr-drill-restore.sql
   Project 01 — Backup & Recovery · SQL Server DBA Lab

   PURPOSE
       Restore the chain produced by 01-pitr-drill-setup.sql to a NEW database
       (SO2010_Drill) and stop at the instant before the accidental DELETE.

   PREREQUISITE
       Run 01-pitr-drill-setup.sql first. The recovery target time is read from
       StackOverflow2010.dbo.Drill_Control — no manual copying required.

   WHY A NEW NAME
       Restoring over the original destroys the only copy of the current state.
       Restore to a copy, verify it, then cut over. Always.

   EXPECTED RESULT
       SO2010_Drill.dbo.Drill_Orders = 10,001 rows, including 1 marker row.
   ============================================================================ */

SET NOCOUNT ON;
GO

--------------------------------------------------------------------------------
-- 1. Sanity: confirm this is the backup set we think it is, and check the
--    logical file names used by the MOVE clauses below.
--------------------------------------------------------------------------------
RESTORE HEADERONLY  FROM DISK = N'C:\SQLBackup\DRILL\PITR_01_full.bak';
RESTORE FILELISTONLY FROM DISK = N'C:\SQLBackup\DRILL\PITR_01_full.bak';

SELECT name AS source_logical_name, type_desc
FROM StackOverflow2010.sys.database_files;
GO

--------------------------------------------------------------------------------
-- 2. Restore sequence
--    All four RESTORE statements are in one batch so @CrashTime stays in scope.
--------------------------------------------------------------------------------
DECLARE @CrashTime datetime = (
    SELECT TOP (1) CONVERT(datetime, CrashTime)
    FROM StackOverflow2010.dbo.Drill_Control
    ORDER BY RunID DESC
);

IF @CrashTime IS NULL
    THROW 50010, N'No drill run found. Run 01-pitr-drill-setup.sql first.', 1;

IF DB_ID(N'SO2010_Drill') IS NOT NULL
    THROW 50011, N'SO2010_Drill already exists. Drop it before running the drill again.', 1;

SELECT @CrashTime AS recovery_target, SYSDATETIME() AS restore_started_at;

-- 2.1 FULL — restore, leave in NORECOVERY
RESTORE DATABASE SO2010_Drill
FROM DISK = N'C:\SQLBackup\DRILL\PITR_01_full.bak'
WITH MOVE N'StackOverflow2010'     TO N'C:\SQLData\SO2010_Drill.mdf',
     MOVE N'StackOverflow2010_log' TO N'C:\SQLLogs\SO2010_Drill_log.ldf',
     NORECOVERY, REPLACE, STATS = 10;

-- 2.2 DIFFERENTIAL — still NORECOVERY
RESTORE DATABASE SO2010_Drill
FROM DISK = N'C:\SQLBackup\DRILL\PITR_02_diff.bak'
WITH NORECOVERY, STATS = 10;

-- 2.3 LOG backup taken before the accident — still NORECOVERY
RESTORE LOG SO2010_Drill
FROM DISK = N'C:\SQLBackup\DRILL\PITR_03_log.trn'
WITH NORECOVERY, STATS = 10;

-- 2.4 TAIL LOG — stop at the target and bring the database online
RESTORE LOG SO2010_Drill
FROM DISK = N'C:\SQLBackup\DRILL\PITR_04_log_after.trn'
WITH STOPAT = @CrashTime, RECOVERY, STATS = 10;
GO

--------------------------------------------------------------------------------
-- 3. Prove it
--------------------------------------------------------------------------------
SELECT COUNT(*) AS rows_recovered_expected_10001
FROM SO2010_Drill.dbo.Drill_Orders;

SELECT COUNT(*) AS marker_rows_expected_1
FROM SO2010_Drill.dbo.Drill_Orders
WHERE CustomerID = -1;

SELECT
    MIN(OrderDate) AS first_order,
    MAX(OrderDate) AS last_order,
    SYSDATETIME()  AS restore_finished_at
FROM SO2010_Drill.dbo.Drill_Orders;
GO

PRINT N'';
PRINT N'=== VERIFY BEFORE YOU TRUST IT =========================================';
PRINT N'rows_recovered should be 10001 and marker_rows should be 1.';
PRINT N'If marker_rows = 0, the STOPAT time was before the marker insert.';
PRINT N'If rows_recovered = 0, the STOPAT time was after the DELETE.';
PRINT N'=======================================================================';
PRINT N'Cleanup (run after recording evidence):';
PRINT N'  ALTER DATABASE SO2010_Drill SET RECOVERY SIMPLE;';
PRINT N'  DROP DATABASE SO2010_Drill;';
GO

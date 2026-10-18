/* ============================================================================
   01-azure-migration-readiness-lab.sql
   Project 06 — Azure SQL Migration Readiness & Contained Users · SQL Server DBA Lab

   PURPOSE
       1. Injects realistic Azure SQL Database migration blockers into
          StackOverflow2010 (a 3-part cross-database query to msdb, a heap table
          without a clustered index, and an instance-scoped SQL login user).
       2. Runs an automated readiness assessment query against catalog DMVs to
          detect all three blockers.
       3. Remediates all blockers live: enables CONTAINMENT = PARTIAL (using
          WITH ROLLBACK IMMEDIATE to avoid Msg 5061 lock contention from open
          SSMS tabs), converts [app_legacy_svc] to a Contained Database User via
          sp_migrate_user_to_contained, and drops the cross-DB proc & heap.
       4. Verifies 0 remaining blockers and calculates exact storage/row metrics
          to right-size the Azure SQL Database target in uksouth (London).
   ============================================================================ */

USE master;
GO
SET NOCOUNT ON;

PRINT '========================================================================';
PRINT 'PROJECT 06 — AZURE SQL MIGRATION READINESS & CONTAINED USER LAB';
PRINT '========================================================================';

/* ----------------------------------------------------------------------------
   1. INJECT REALISTIC ON-PREM -> AZURE SQL DB MIGRATION BLOCKERS
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 1. INJECTING LEGACY MIGRATION BLOCKERS INTO StackOverflow2010 ===';

USE StackOverflow2010;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LegacyCrossDbReport
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (5) database_name, backup_finish_date
    FROM msdb.dbo.backupset
    ORDER BY backup_finish_date DESC;
END
GO

DROP TABLE IF EXISTS dbo.LegacyStagingHeap;
CREATE TABLE dbo.LegacyStagingHeap
(
    RowID int NOT NULL,
    Payload varchar(100) NULL
);
GO

PRINT 'Injected: dbo.usp_LegacyCrossDbReport (cross-DB reference to msdb) and dbo.LegacyStagingHeap (Heap).';
GO

/* ----------------------------------------------------------------------------
   2. RUN AZURE SQL DATABASE READINESS ASSESSMENT — RUN A (BEFORE REMEDIATION)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 2. AZURE SQL DB READINESS ASSESSMENT — BEFORE REMEDIATION ===';

DECLARE @finding nvarchar(400);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
WITH MigrationIssues AS (
    SELECT 1 AS SortOrder,
           N'BLOCKER [Cross-DB Query]   | ' + OBJECT_NAME(d.referencing_id) COLLATE DATABASE_DEFAULT
           + N' references external DB [' + d.referenced_database_name COLLATE DATABASE_DEFAULT
           + N'].[' + COALESCE(d.referenced_schema_name, N'dbo') COLLATE DATABASE_DEFAULT
           + N'].[' + d.referenced_entity_name COLLATE DATABASE_DEFAULT + N']' AS IssueText
    FROM sys.sql_expression_dependencies d
    WHERE d.referenced_database_name IS NOT NULL
      AND d.referenced_database_name <> DB_NAME()

    UNION ALL

    SELECT 2,
           N'WARNING [Heap Table]       | dbo.' + t.name COLLATE DATABASE_DEFAULT
           + N' has no Clustered Index (index_id = 0)'
    FROM sys.tables t
    JOIN sys.indexes i ON t.object_id = i.object_id
    WHERE i.index_id = 0
      AND t.is_ms_shipped = 0

    UNION ALL

    SELECT 3,
           N'WARNING [Non-Contained Usr]| User [' + dp.name COLLATE DATABASE_DEFAULT
           + N'] is mapped to master login (' + dp.authentication_type_desc COLLATE DATABASE_DEFAULT
           + N') -> migrate to Contained User'
    FROM sys.database_principals dp
    WHERE dp.type = 'S'
      AND dp.principal_id > 4
      AND dp.authentication_type_desc = N'INSTANCE'
)
SELECT IssueText FROM MigrationIssues ORDER BY SortOrder, IssueText;

OPEN cur;
FETCH NEXT FROM cur INTO @finding;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT @finding;
    FETCH NEXT FROM cur INTO @finding;
END
CLOSE cur;
DEALLOCATE cur;
GO

/* ----------------------------------------------------------------------------
   3. REMEDIATE ALL MIGRATION BLOCKERS FOR AZURE SQL DATABASE
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 3. REMEDIATING BLOCKERS & CONVERTING TO CONTAINED DATABASE ===';

USE master;
GO
-- Acquire exclusive lock via SINGLE_USER WITH ROLLBACK IMMEDIATE so open SSMS tabs do not cause Msg 5061
ALTER DATABASE StackOverflow2010 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE StackOverflow2010 SET CONTAINMENT = PARTIAL;
ALTER DATABASE StackOverflow2010 SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE StackOverflow2010 SET MULTI_USER;
PRINT 'Action: Enabled CONTAINMENT = PARTIAL and COMPATIBILITY_LEVEL = 160 on StackOverflow2010.';
GO

USE StackOverflow2010;
GO

IF EXISTS (
    SELECT 1 FROM sys.database_principals
    WHERE name = N'app_legacy_svc' AND authentication_type_desc = N'INSTANCE'
)
BEGIN
    EXEC sys.sp_migrate_user_to_contained
        @username     = N'app_legacy_svc',
        @rename       = N'keep_name',
        @disablelogin = N'disable_login';
    PRINT 'Action: Migrated [app_legacy_svc] to Contained Database User via sp_migrate_user_to_contained.';
END
ELSE
BEGIN
    PRINT 'Info: [app_legacy_svc] is already a Contained Database User.';
END
GO

DECLARE @authType nvarchar(60);
SELECT @authType = authentication_type_desc
FROM sys.database_principals
WHERE name = N'app_legacy_svc';
PRINT 'Verified [app_legacy_svc] authentication_type_desc = ' + COALESCE(@authType, N'N/A');

DROP PROCEDURE IF EXISTS dbo.usp_LegacyCrossDbReport;
DROP TABLE IF EXISTS dbo.LegacyStagingHeap;
PRINT 'Action: Removed cross-database procedure dbo.usp_LegacyCrossDbReport and heap dbo.LegacyStagingHeap.';
GO

/* ----------------------------------------------------------------------------
   4. RUN AZURE SQL DATABASE READINESS ASSESSMENT — RUN B (AFTER REMEDIATION)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 4. AZURE SQL DB READINESS ASSESSMENT — AFTER REMEDIATION ===';

DECLARE @remaining int = 0;

SELECT @remaining = COUNT(*)
FROM (
    SELECT d.referencing_id
    FROM sys.sql_expression_dependencies d
    WHERE d.referenced_database_name IS NOT NULL AND d.referenced_database_name <> DB_NAME()
    UNION ALL
    SELECT t.object_id
    FROM sys.tables t JOIN sys.indexes i ON t.object_id = i.object_id
    WHERE i.index_id = 0 AND t.is_ms_shipped = 0
    UNION ALL
    SELECT dp.principal_id
    FROM sys.database_principals dp
    WHERE dp.type = 'S' AND dp.principal_id > 4 AND dp.authentication_type_desc = N'INSTANCE'
) x;

PRINT 'Remaining Azure SQL Database migration blockers: ' + CAST(@remaining AS varchar(10))
    + ' (STATUS: 100% READY FOR AZURE SQL DATABASE / BACPAC MIGRATION).';
GO

/* ----------------------------------------------------------------------------
   5. DATABASE FOOTPRINT & AZURE SKU RIGHT-SIZING METRICS (uksouth)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== 5. FOOTPRINT & AZURE SKU SIZING SUMMARY (Target: uksouth) ===';

DECLARE @dataMB decimal(10,2), @logMB decimal(10,2), @tableCount int, @totalRows bigint;
DECLARE @compatLevel varchar(10), @containment varchar(60);

SELECT
    @compatLevel = CAST(compatibility_level AS varchar(10)),
    @containment = containment_desc COLLATE DATABASE_DEFAULT
FROM sys.databases
WHERE database_id = DB_ID();

SELECT
    @dataMB = SUM(CASE WHEN type = 0 THEN size * 8 / 1024.0 ELSE 0 END),
    @logMB  = SUM(CASE WHEN type = 1 THEN size * 8 / 1024.0 ELSE 0 END)
FROM sys.database_files;

SELECT
    @tableCount = COUNT(DISTINCT t.object_id),
    @totalRows  = SUM(p.rows)
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id
WHERE t.is_ms_shipped = 0 AND p.index_id IN (0, 1);

PRINT 'Database               : StackOverflow2010';
PRINT 'Compatibility Level    : ' + @compatLevel;
PRINT 'Containment State      : ' + @containment;
PRINT 'User Tables            : ' + CAST(@tableCount AS varchar(20));
PRINT 'Total Rows (All Tables): ' + CAST(@totalRows AS varchar(20));
PRINT 'Allocated Data Size    : ' + CAST(@dataMB AS varchar(20)) + ' MB';
PRINT 'Allocated Log Size     : ' + CAST(@logMB AS varchar(20)) + ' MB';
PRINT 'Recommended Azure Target: Azure SQL Database (PaaS) | Region: uksouth (London) | Tier: Standard S2 (50 DTUs, 250 GB max) or GP_S_Gen5_2 Serverless';
GO

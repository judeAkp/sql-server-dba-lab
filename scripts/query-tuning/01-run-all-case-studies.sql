/* ============================================================================
   01-run-all-case-studies.sql
   Project 02 — Query Tuning Case Studies · SQL Server DBA Lab

   HOW TO USE
       1. Open this file in SSMS.
       2. Press Ctrl + M (Include Actual Execution Plan) if you want to inspect
          the visual plans, or run straight through and copy the Messages tab!
       3. Every Case Study prints clear === CASE STUDY N: BEFORE / AFTER ===
          markers in the Messages tab so you can copy-paste the whole Messages
          output in one go.
   ============================================================================ */

USE StackOverflow2010;
GO

SET NOCOUNT ON;
PRINT '========================================================================';
PRINT 'PROJECT 02 — QUERY TUNING CASE STUDIES (StackOverflow2010)';
PRINT 'Database: ' + DB_NAME() + ' | Server: ' + @@SERVERNAME;
PRINT '========================================================================';
GO

/* ----------------------------------------------------------------------------
   CASE STUDY 1 — Key Lookup vs Covering Index (dbo.Users)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== CASE STUDY 1: KEY LOOKUP vs COVERING INDEX (dbo.Users) ===';

DROP INDEX IF EXISTS IX_Users_Reputation ON dbo.Users;
DROP INDEX IF EXISTS IX_Users_Reputation_Covering ON dbo.Users;
GO

CREATE NONCLUSTERED INDEX IX_Users_Reputation
ON dbo.Users (Reputation DESC);
GO

PRINT '--- CS1 BEFORE (Narrow index IX_Users_Reputation -> Index Seek + Key Lookup) ---';
SET STATISTICS IO, TIME ON;

SELECT Id, DisplayName, Reputation, CreationDate, Location
FROM dbo.Users WITH (INDEX(IX_Users_Reputation))
WHERE Reputation >= 5000
ORDER BY Reputation DESC;

SET STATISTICS IO, TIME OFF;
GO

CREATE NONCLUSTERED INDEX IX_Users_Reputation_Covering
ON dbo.Users (Reputation DESC)
INCLUDE (DisplayName, CreationDate, Location)
WITH (DATA_COMPRESSION = PAGE);
GO

DROP INDEX IF EXISTS IX_Users_Reputation ON dbo.Users;
GO

PRINT '--- CS1 AFTER (Covering index IX_Users_Reputation_Covering -> Index Seek only) ---';
SET STATISTICS IO, TIME ON;

SELECT Id, DisplayName, Reputation, CreationDate, Location
FROM dbo.Users
WHERE Reputation >= 5000
ORDER BY Reputation DESC;

SET STATISTICS IO, TIME OFF;
GO

/* ----------------------------------------------------------------------------
   CASE STUDY 2 — Implicit Conversion / CONVERT_IMPLICIT (dbo.UserAccountLookup)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== CASE STUDY 2: IMPLICIT CONVERSION (VARCHAR column vs NVARCHAR parameter) ===';

DROP TABLE IF EXISTS dbo.UserAccountLookup;
GO

SELECT
    Id AS UserId,
    CAST(CONCAT('ACC-', RIGHT(CONCAT('0000000', Id), 7)) AS varchar(40)) AS AccountCode,
    DisplayName,
    Reputation,
    CreationDate
INTO dbo.UserAccountLookup
FROM dbo.Users;
GO

ALTER TABLE dbo.UserAccountLookup ADD CONSTRAINT PK_UserAccountLookup PRIMARY KEY CLUSTERED (UserId);
CREATE NONCLUSTERED INDEX IX_UserAccountLookup_AccountCode
ON dbo.UserAccountLookup (AccountCode)
INCLUDE (DisplayName, Reputation);
GO

PRINT '--- CS2 BEFORE (NVARCHAR(40) parameter causes CONVERT_IMPLICIT on column -> Index Scan) ---';
SET STATISTICS IO, TIME ON;

DECLARE @SearchCode_Bad nvarchar(40) = N'ACC-0022656';
SELECT UserId, AccountCode, DisplayName, Reputation
FROM dbo.UserAccountLookup
WHERE AccountCode = @SearchCode_Bad;

SET STATISTICS IO, TIME OFF;
GO

PRINT '--- CS2 AFTER (Matching VARCHAR(40) parameter -> Index Seek) ---';
SET STATISTICS IO, TIME ON;

DECLARE @SearchCode_Good varchar(40) = 'ACC-0022656';
SELECT UserId, AccountCode, DisplayName, Reputation
FROM dbo.UserAccountLookup
WHERE AccountCode = @SearchCode_Good;

SET STATISTICS IO, TIME OFF;
GO

/* ----------------------------------------------------------------------------
   CASE STUDY 3 — Non-SARGable Predicate vs Date Range (dbo.Users)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== CASE STUDY 3: NON-SARGABLE PREDICATE (YEAR/MONTH vs Date Range) ===';

DROP INDEX IF EXISTS IX_Users_CreationDate ON dbo.Users;
GO

CREATE NONCLUSTERED INDEX IX_Users_CreationDate
ON dbo.Users (CreationDate)
INCLUDE (DisplayName, Reputation);
GO

PRINT '--- CS3 BEFORE (WHERE YEAR(CreationDate) = 2010 AND MONTH(CreationDate) = 5 -> Index Scan) ---';
SET STATISTICS IO, TIME ON;

SELECT Id, DisplayName, Reputation, CreationDate
FROM dbo.Users
WHERE YEAR(CreationDate) = 2010
  AND MONTH(CreationDate) = 5;

SET STATISTICS IO, TIME OFF;
GO

PRINT '--- CS3 AFTER (WHERE CreationDate >= 2010-05-01 AND < 2010-06-01 -> Index Seek) ---';
SET STATISTICS IO, TIME ON;

SELECT Id, DisplayName, Reputation, CreationDate
FROM dbo.Users
WHERE CreationDate >= '2010-05-01T00:00:00'
  AND CreationDate <  '2010-06-01T00:00:00';

SET STATISTICS IO, TIME OFF;
GO

/* ----------------------------------------------------------------------------
   CASE STUDY 4 — Missing Index on 3.87M-Row Table (dbo.Comments)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== CASE STUDY 4: MISSING INDEX ON 3.87M ROWS (dbo.Comments) ===';

DROP INDEX IF EXISTS IX_Comments_UserId_Score ON dbo.Comments;
GO

PRINT '--- CS4 BEFORE (No nonclustered index -> Full Clustered Index Scan of 3.87M rows) ---';
SET STATISTICS IO, TIME ON;

SELECT Id, PostId, Score, CreationDate
FROM dbo.Comments
WHERE UserId = 22656
  AND Score > 5
ORDER BY CreationDate DESC;

SET STATISTICS IO, TIME OFF;
GO

CREATE NONCLUSTERED INDEX IX_Comments_UserId_Score
ON dbo.Comments (UserId, Score)
INCLUDE (PostId, CreationDate)
WITH (DATA_COMPRESSION = PAGE);
GO

PRINT '--- CS4 AFTER (Targeted index IX_Comments_UserId_Score -> Surgical Index Seek) ---';
SET STATISTICS IO, TIME ON;

SELECT Id, PostId, Score, CreationDate
FROM dbo.Comments
WHERE UserId = 22656
  AND Score > 5
ORDER BY CreationDate DESC;

SET STATISTICS IO, TIME OFF;
GO

/* ----------------------------------------------------------------------------
   CASE STUDY 5 — Parameter Sniffing (dbo.Badges)
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== CASE STUDY 5: PARAMETER SNIFFING (dbo.Badges) ===';

DROP INDEX IF EXISTS IX_Badges_Name ON dbo.Badges;
GO

CREATE NONCLUSTERED INDEX IX_Badges_Name
ON dbo.Badges (Name);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetBadgesByName
    @BadgeName nvarchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UserId, Name, Date
    FROM dbo.Badges
    WHERE Name = @BadgeName;
END
GO

DBCC FREEPROCCACHE WITH NO_INFOMSGS;
GO

PRINT '--- CS5 STEP A: Warm cache with rare badge (Legendary, ~36 rows -> caches Seek + Key Lookup) ---';
SET STATISTICS IO, TIME ON;
EXEC dbo.usp_GetBadgesByName @BadgeName = N'Legendary';
SET STATISTICS IO, TIME OFF;
GO

PRINT '--- CS5 BEFORE (Common badge Student reuses cached Seek + Key Lookup plan -> 220k+ lookups!) ---';
SET STATISTICS IO, TIME ON;
EXEC dbo.usp_GetBadgesByName @BadgeName = N'Student';
SET STATISTICS IO, TIME OFF;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetBadgesByName
    @BadgeName nvarchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UserId, Name, Date
    FROM dbo.Badges
    WHERE Name = @BadgeName
    OPTION (RECOMPILE);
END
GO

PRINT '--- CS5 AFTER (With OPTION (RECOMPILE) -> Common badge Student uses sequential Scan) ---';
SET STATISTICS IO, TIME ON;
EXEC dbo.usp_GetBadgesByName @BadgeName = N'Student';
SET STATISTICS IO, TIME OFF;
GO

/* ----------------------------------------------------------------------------
   INDEX SIZE METADATA SUMMARY
   ---------------------------------------------------------------------------- */
PRINT '';
PRINT '=== INDEX SIZE SUMMARY ===';
SELECT
    OBJECT_NAME(ps.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(10,2)) AS size_mb,
    SUM(ps.row_count) AS row_count
FROM sys.dm_db_partition_stats ps
JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id IN (
    OBJECT_ID(N'dbo.Users'),
    OBJECT_ID(N'dbo.UserAccountLookup'),
    OBJECT_ID(N'dbo.Comments'),
    OBJECT_ID(N'dbo.Badges')
)
GROUP BY ps.object_id, i.name, i.type_desc
ORDER BY table_name, size_mb DESC;
GO

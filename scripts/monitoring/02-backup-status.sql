/*  Backup status — the first thing to check on any server  */

-- Last backup of each type, per database
SELECT d.name AS database_name, d.recovery_model_desc,
       MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS last_full,
       MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS last_diff,
       MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS last_log,
       DATEDIFF(HOUR,  MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) AS hours_since_full,
       DATEDIFF(MINUTE,MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END), GETDATE()) AS mins_since_log
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON d.name = bs.database_name
WHERE d.database_id <> 2      -- tempdb is never backed up
GROUP BY d.name, d.recovery_model_desc
ORDER BY hours_since_full DESC;

-- Databases with NO backup at all
SELECT d.name, d.recovery_model_desc, d.create_date
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON d.name = bs.database_name
WHERE bs.database_name IS NULL AND d.database_id <> 2;

-- FULL recovery with no log backup in 24h — the classic runaway-log cause
SELECT d.name, d.recovery_model_desc, d.log_reuse_wait_desc,
       MAX(bs.backup_finish_date) AS last_log_backup
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs
       ON d.name = bs.database_name AND bs.type = 'L'
WHERE d.recovery_model_desc = 'FULL' AND d.database_id > 4
GROUP BY d.name, d.recovery_model_desc, d.log_reuse_wait_desc
HAVING MAX(bs.backup_finish_date) < DATEADD(DAY,-1,GETDATE())
    OR MAX(bs.backup_finish_date) IS NULL;

-- Last successful CHECKDB per database
CREATE TABLE #db_info (ParentObject VARCHAR(255), Object VARCHAR(255), Field VARCHAR(255), Value VARCHAR(255));
DECLARE @db NVARCHAR(128);
DECLARE c CURSOR FOR SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4;
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO #db_info EXEC('DBCC DBINFO([' + @db + ']) WITH TABLERESULTS, NO_INFOMSGS');
    FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;
SELECT Value AS last_known_good_checkdb FROM #db_info WHERE Field = 'dbi_dbccLastKnownGood';
DROP TABLE #db_info;

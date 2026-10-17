/* ============================================================================
   03-restore-chain-report.sql
   Project 01 — Backup & Recovery · SQL Server DBA Lab

   PURPOSE
       Before a restore, answer three questions from msdb:
         1. What backup types do I have, and how old are they?
         2. Which files make up the shortest valid restore path to now?
         3. Is the log chain continuous?

   READ-ONLY. Nothing here changes anything.

   NOTE
       This reports the path to the MOST RECENT point. To restore to an earlier
       time, change @TargetTime — the script will pick the newest full backup
       that finished before it.

       COPY_ONLY full backups are deliberately ignored as restore bases: no
       differential is ever based on one, so pairing them would produce a chain
       that fails with Msg 3136.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @db         sysname  = N'StackOverflow2010';
DECLARE @TargetTime datetime = SYSDATETIME();   -- <<< change to restore to an earlier point

IF DB_ID(@db) IS NULL
    THROW 50020, N'Database not found on this instance.', 1;

/* ---------------------------------------------------------------------------
   1. Summary: what do I have?
   --------------------------------------------------------------------------- */
SELECT
    d.name                                    AS database_name,
    d.recovery_model_desc,
    MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS last_full,
    MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS last_diff,
    MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS last_log,
    DATEDIFF(MINUTE, MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END), SYSDATETIME())
                                              AS minutes_since_log,
    d.log_reuse_wait_desc
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON bs.database_name = d.name
WHERE d.name = @db
GROUP BY d.name, d.recovery_model_desc, d.log_reuse_wait_desc;

/* ---------------------------------------------------------------------------
   2. The restore path
      = newest full before @TargetTime
      + newest differential after that full
      + every log backup after the differential (or after the full)
   --------------------------------------------------------------------------- */
DECLARE @full_finish datetime, @diff_finish datetime;

SELECT TOP (1) @full_finish = bs.backup_finish_date
FROM msdb.dbo.backupset bs
WHERE bs.database_name = @db
  AND bs.type = 'D'
  AND bs.is_copy_only = 0
  AND bs.backup_finish_date <= @TargetTime
ORDER BY bs.backup_finish_date DESC;

IF @full_finish IS NULL
BEGIN
    SELECT N'No full backup found before the target time.' AS restore_path_status;
END
ELSE
BEGIN
    SELECT TOP (1) @diff_finish = bs.backup_finish_date
    FROM msdb.dbo.backupset bs
    WHERE bs.database_name = @db
      AND bs.type = 'I'
      AND bs.backup_finish_date > @full_finish
      AND bs.backup_finish_date <= @TargetTime
    ORDER BY bs.backup_finish_date DESC;

    SELECT
        CASE bs.type WHEN 'D' THEN 1 WHEN 'I' THEN 2 ELSE 3 END          AS restore_order,
        CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' ELSE 'LOG' END AS backup_type,
        bs.backup_finish_date,
        CAST(bs.compressed_backup_size / 1048576.0 AS decimal(12,1))     AS size_mb,
        bs.is_copy_only,
        bs.first_lsn,
        bs.last_lsn,
        bs.database_backup_lsn,
        mf.physical_device_name
    FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
    WHERE bs.database_name = @db
      AND bs.backup_finish_date <= @TargetTime
      AND (
              (bs.type = 'D' AND bs.backup_finish_date = @full_finish)
           OR (bs.type = 'I' AND bs.backup_finish_date = @diff_finish)
           OR (bs.type = 'L' AND bs.backup_finish_date >= COALESCE(@diff_finish, @full_finish))
          )
    ORDER BY restore_order, bs.backup_finish_date;

    /* -----------------------------------------------------------------------
       3. Log chain continuity
          Each log backup's first_lsn should equal the previous one's last_lsn.
       ----------------------------------------------------------------------- */
    WITH logchain AS (
        SELECT
            bs.backup_start_date,
            bs.backup_finish_date,
            bs.first_lsn,
            bs.last_lsn,
            LAG(bs.last_lsn) OVER (ORDER BY bs.backup_start_date) AS previous_last_lsn
        FROM msdb.dbo.backupset bs
        WHERE bs.database_name = @db
          AND bs.type = 'L'
          AND bs.backup_finish_date >= @full_finish
    )
    SELECT
        backup_start_date,
        first_lsn,
        last_lsn,
        previous_last_lsn,
        CASE
            WHEN previous_last_lsn IS NULL     THEN 'first log in chain'
            WHEN first_lsn = previous_last_lsn THEN 'continuous'
            ELSE 'BREAK — a log backup is missing'
        END AS chain_status
    FROM logchain
    ORDER BY backup_start_date;
END
GO

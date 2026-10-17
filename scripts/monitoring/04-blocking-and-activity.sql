/*  What is running, what is blocked  */

-- Current activity
SELECT r.session_id, s.login_name, s.host_name, s.program_name,
       r.status, r.command, DB_NAME(r.database_id) AS db,
       r.wait_type, r.wait_time, r.last_wait_type,
       r.blocking_session_id,
       r.cpu_time, r.total_elapsed_time, r.reads, r.writes, r.logical_reads,
       r.percent_complete,
       SUBSTRING(t.text, (r.statement_start_offset/2)+1,
           ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
             ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1) AS running_statement
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id > 50 AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;

-- Blocking chains
SELECT r.blocking_session_id AS blocker, r.session_id AS blocked,
       r.wait_type, r.wait_time/1000.0 AS wait_sec, r.wait_resource,
       DB_NAME(r.database_id) AS db
FROM sys.dm_exec_requests r
WHERE r.blocking_session_id <> 0;

-- Head blockers (blocking others, not blocked themselves)
SELECT DISTINCT r1.blocking_session_id AS head_blocker
FROM sys.dm_exec_requests r1
WHERE r1.blocking_session_id <> 0
  AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests r2
                  WHERE r2.session_id = r1.blocking_session_id
                    AND r2.blocking_session_id <> 0);

-- Open transactions
SELECT s.session_id, s.login_name, s.host_name,
       t.transaction_begin_time,
       DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) AS open_seconds,
       CASE t.transaction_type WHEN 1 THEN 'Read/write' WHEN 2 THEN 'Read-only'
            WHEN 3 THEN 'System' WHEN 4 THEN 'Distributed' END AS tran_type
FROM sys.dm_tran_active_transactions t
JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions s ON st.session_id = s.session_id
ORDER BY t.transaction_begin_time;

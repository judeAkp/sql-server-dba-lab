/*  Wait statistics — start here for "the server is slow"  */

WITH waits AS (
  SELECT wait_type,
         wait_time_ms / 1000.0 AS wait_s,
         (wait_time_ms - signal_wait_time_ms) / 1000.0 AS resource_s,
         signal_wait_time_ms / 1000.0 AS signal_s,
         waiting_tasks_count AS wait_count,
         100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER(),0) AS pct
  FROM sys.dm_os_wait_stats
  WHERE wait_type NOT IN (
    'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK','SLEEP_SYSTEMTASK',
    'SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE','CHECKPOINT_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT','BROKER_TO_FLUSH','BROKER_TASK_STOP',
    'CLR_MANUAL_EVENT','CLR_AUTO_EVENT','DISPATCHER_QUEUE_SEMAPHORE',
    'FT_IFTS_SCHEDULER_IDLE_WAIT','XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'DIRTY_PAGE_POLL','SP_SERVER_DIAGNOSTICS_SLEEP','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE','QDS_SHUTDOWN_QUEUE','PREEMPTIVE_XE_GETTARGETSTATE','WAIT_XTP_HOST_WAIT')
    AND waiting_tasks_count > 0
)
SELECT TOP 20
    wait_type,
    CAST(wait_s     AS DECIMAL(18,2)) AS wait_s,
    CAST(resource_s AS DECIMAL(18,2)) AS resource_s,
    CAST(signal_s   AS DECIMAL(18,2)) AS signal_s,
    wait_count,
    CAST(wait_s / NULLIF(wait_count,0) AS DECIMAL(18,4)) AS avg_wait_s,
    CAST(pct AS DECIMAL(5,2)) AS pct
FROM waits
WHERE pct > 0.5
ORDER BY wait_s DESC;

/*  Reset the counters to measure a specific window:
    DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);

    PAGEIOLATCH_*      disk reads      → indexes, memory, storage
    LCK_M_*            blocking        → find the head blocker, consider RCSI
    CXPACKET/CXCONSUMER parallelism    → cost threshold, MaxDOP
    WRITELOG           log writes      → log storage, transaction size
    RESOURCE_SEMAPHORE memory grants   → estimates, indexes
    SOS_SCHEDULER_YIELD CPU pressure   → tuning, cores
    ASYNC_NETWORK_IO   slow client     → usually the application
    PAGELATCH_* tempdb allocation      → tempdb file count                     */

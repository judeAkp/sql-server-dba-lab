/*  Instance health snapshot
    Run against any SQL Server for a fast overall picture.  */

-- Version and edition
SELECT @@VERSION AS version;
SELECT SERVERPROPERTY('Edition')      AS edition,
       SERVERPROPERTY('ProductLevel') AS patch_level,
       SERVERPROPERTY('Collation')    AS collation,
       SERVERPROPERTY('IsIntegratedSecurityOnly') AS windows_auth_only;

-- Uptime
SELECT sqlserver_start_time,
       DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS uptime_hours
FROM sys.dm_os_sys_info;

-- Services and Instant File Initialisation
SELECT servicename, service_account, startup_type_desc, status_desc,
       instant_file_initialization_enabled
FROM sys.dm_server_services;

-- Key configuration
SELECT name, value_in_use, description
FROM sys.configurations
WHERE name IN ('max server memory (MB)','min server memory (MB)',
               'max degree of parallelism','cost threshold for parallelism',
               'backup compression default','optimize for ad hoc workloads')
ORDER BY name;

-- Database inventory
SELECT name, state_desc, recovery_model_desc, compatibility_level,
       log_reuse_wait_desc, is_auto_shrink_on, is_auto_close_on,
       page_verify_option_desc, create_date
FROM sys.databases ORDER BY database_id;

-- File sizes, free space and autogrowth settings
SELECT DB_NAME(mf.database_id) AS db, mf.name AS logical_name, mf.type_desc,
       mf.physical_name, mf.size/128.0 AS size_mb,
       CASE WHEN mf.is_percent_growth = 1
            THEN CAST(mf.growth AS VARCHAR) + ' %'
            ELSE CAST(mf.growth/128 AS VARCHAR) + ' MB' END AS growth
FROM sys.master_files mf ORDER BY mf.database_id, mf.type;

-- Memory
SELECT object_name, counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Page life expectancy','Memory Grants Pending',
                       'Target Server Memory (KB)','Total Server Memory (KB)');

-- Storage latency per file
SELECT DB_NAME(vfs.database_id) AS db, mf.physical_name,
       vfs.num_of_reads, vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads,0)  AS avg_read_ms,
       vfs.num_of_writes, vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes,0) AS avg_write_ms
FROM sys.dm_io_virtual_file_stats(NULL,NULL) vfs
JOIN sys.master_files mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY avg_read_ms DESC;

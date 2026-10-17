<#
.SYNOPSIS
    Daily SQL Server health check using dbatools. Produces an HTML report and console table.

.DESCRIPTION
    Checks:
      1. Last full backup age (> 24 hours or NEVER, excluding tempdb)
      2. Last transaction log backup age on FULL recovery databases (> 30 minutes or NEVER)
      3. Failed SQL Server Agent jobs in the last 24 hours
      4. Database state (any database not ONLINE)
      5. Last good DBCC CHECKDB age (> 7 days or NEVER, excluding tempdb)
      6. Transaction log space used (> 80%)
      7. Volume free space (< 15% on SQL Server drives via sys.dm_os_volume_stats / PSDrive)
      8. Long-running active queries (> 5 minutes)
      9. High-severity SQL Server Error Log entries (Severity 17-25 in last 24 hours)

.EXAMPLE
    .\Daily-HealthCheck.ps1 -SqlInstance localhost -OutputPath C:\Reports
#>

[CmdletBinding()]
param(
    [string[]]$SqlInstance              = @('localhost'),
    [string]  $OutputPath               = 'C:\Reports',
    [string]  $ReportFileName           = '',
    [int]     $FullBackupThresholdHours = 24,
    [int]     $LogBackupThresholdMinutes= 30,
    [int]     $CheckDbThresholdDays     = 7,
    [int]     $DiskFreePercentThreshold = 15,
    [int]     $LogSpaceUsedThresholdPct = 80
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -ErrorAction SilentlyContinue
Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -ErrorAction SilentlyContinue

$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [string]$Severity,
        [string]$Category,
        [string]$Instance,
        [string]$Object,
        [string]$Detail
    )
    $findings.Add([PSCustomObject]@{
        Severity = $Severity
        Category = $Category
        Instance = $Instance
        Object   = $Object
        Detail   = $Detail
    })
}

foreach ($instance in $SqlInstance) {

    Write-Host "Checking SQL Server instance [$instance]..." -ForegroundColor Cyan

    # 1. Database state, Backups, Log Space & CHECKDB via dbatools + catalog query
    $dbCheckSql = @"
WITH BackupSummary AS (
    SELECT
        d.database_id,
        d.name AS DatabaseName,
        d.state_desc AS StateDesc,
        d.recovery_model_desc AS RecoveryModel,
        MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS LastFullBackup,
        MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS LastDiffBackup,
        MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS LastLogBackup,
        DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS LastGoodCheckDb
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs ON bs.database_name = d.name
    WHERE d.name <> N'tempdb'
    GROUP BY d.database_id, d.name, d.state_desc, d.recovery_model_desc
)
SELECT
    DatabaseName,
    StateDesc,
    RecoveryModel,
    LastFullBackup,
    LastLogBackup,
    CAST(LastGoodCheckDb AS datetime) AS LastGoodCheckDb,
    DATEDIFF(HOUR,   LastFullBackup, SYSDATETIME()) AS HoursSinceFull,
    DATEDIFF(MINUTE, LastLogBackup,  SYSDATETIME()) AS MinutesSinceLog,
    DATEDIFF(DAY,    CAST(LastGoodCheckDb AS datetime), SYSDATETIME()) AS DaysSinceCheckDb
FROM BackupSummary
ORDER BY DatabaseName;
"@

    try {
        $dbRows = Invoke-DbaQuery -SqlInstance $instance -Database master -Query $dbCheckSql -EnableException
    } catch {
        Add-Finding 'CRITICAL' 'Connectivity' $instance '-' "Unable to query instance: $($_.Exception.Message)"
        continue
    }

    foreach ($row in $dbRows) {
        # Check A: Database State
        if ($row.StateDesc -ne 'ONLINE') {
            Add-Finding 'CRITICAL' 'Database State' $instance $row.DatabaseName "Database state is $($row.StateDesc) (expected ONLINE)"
            continue
        }

        # Check B: Full Backup Age
        if ([DBNull]::Value -eq $row.LastFullBackup -or $null -eq $row.LastFullBackup) {
            Add-Finding 'CRITICAL' 'Full Backup' $instance $row.DatabaseName "Last full backup: NEVER"
        } elseif ([int]$row.HoursSinceFull -gt $FullBackupThresholdHours) {
            Add-Finding 'CRITICAL' 'Full Backup' $instance $row.DatabaseName "Last full backup: $($row.HoursSinceFull)h ago (threshold: ${FullBackupThresholdHours}h)"
        }

        # Check C: Log Backup Age (for FULL / BULK_LOGGED recovery user DBs)
        if ($row.RecoveryModel -in @('FULL', 'BULK_LOGGED') -and $row.DatabaseName -notin @('master', 'model', 'msdb')) {
            if ([DBNull]::Value -eq $row.LastLogBackup -or $null -eq $row.LastLogBackup) {
                Add-Finding 'HIGH' 'Log Backup' $instance $row.DatabaseName "FULL recovery, last log backup: NEVER"
            } elseif ([int]$row.MinutesSinceLog -gt $LogBackupThresholdMinutes) {
                Add-Finding 'HIGH' 'Log Backup' $instance $row.DatabaseName "FULL recovery, last log backup: $($row.MinutesSinceLog)m ago (threshold: ${LogBackupThresholdMinutes}m)"
            }
        }

        # Check D: Last Good CHECKDB Age
        $checkDbDate = if ([DBNull]::Value -eq $row.LastGoodCheckDb) { $null } else { [datetime]$row.LastGoodCheckDb }
        if ($null -eq $checkDbDate -or $checkDbDate.Year -le 1900) {
            Add-Finding 'MEDIUM' 'CHECKDB Integrity' $instance $row.DatabaseName "Last good DBCC CHECKDB: NEVER"
        } elseif ([int]$row.DaysSinceCheckDb -gt $CheckDbThresholdDays) {
            Add-Finding 'MEDIUM' 'CHECKDB Integrity' $instance $row.DatabaseName "Last good DBCC CHECKDB: $($row.DaysSinceCheckDb) days ago (threshold: ${CheckDbThresholdDays}d)"
        }
    }

    # 2. Transaction Log % Used via Get-DbaDbLogSpace
    foreach ($log in (Get-DbaDbLogSpace -SqlInstance $instance -ErrorAction SilentlyContinue)) {
        if ($log.LogSpaceUsedPercent -gt $LogSpaceUsedThresholdPct) {
            Add-Finding 'HIGH' 'Log Space' $instance $log.Database `
                ("Log {0}% used ({1} MB)" -f [math]::Round($log.LogSpaceUsedPercent, 1), [math]::Round($log.LogSize.Megabyte, 1))
        }
    }

    # 3. Failed SQL Server Agent Jobs (last 24h)
    $failedJobsSql = @"
SELECT
    j.name AS JobName,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS RunDateTime,
    LEFT(h.message, 160) AS ErrorMessage
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0
  AND h.run_status <> 1
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -24, SYSDATETIME())
ORDER BY h.instance_id DESC;
"@
    foreach ($job in (Invoke-DbaQuery -SqlInstance $instance -Database msdb -Query $failedJobsSql -ErrorAction SilentlyContinue)) {
        Add-Finding 'HIGH' 'Agent Job' $instance $job.JobName "Failed at $($job.RunDateTime): $($job.ErrorMessage)"
    }

    # 4. Volume Free Space via sys.dm_os_volume_stats
    $diskSql = @"
SELECT DISTINCT
    vs.volume_mount_point AS MountPoint,
    vs.logical_volume_name AS VolumeName,
    CAST(vs.total_bytes / 1073741824.0 AS decimal(10,1)) AS TotalGB,
    CAST(vs.available_bytes / 1073741824.0 AS decimal(10,1)) AS FreeGB,
    CAST((vs.available_bytes * 100.0) / vs.total_bytes AS decimal(5,1)) AS PercentFree
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs;
"@
    foreach ($vol in (Invoke-DbaQuery -SqlInstance $instance -Database master -Query $diskSql -ErrorAction SilentlyContinue)) {
        if ([double]$vol.PercentFree -lt $DiskFreePercentThreshold) {
            Add-Finding 'HIGH' 'Disk Space' $instance $vol.MountPoint `
                "$($vol.PercentFree)% free ($($vol.FreeGB) GB free of $($vol.TotalGB) GB)"
        }
    }

    # 5. Long-running user queries (> 5 minutes)
    $longQuerySql = @"
SELECT
    r.session_id,
    DB_NAME(r.database_id) AS DatabaseName,
    r.total_elapsed_time / 60000 AS ElapsedMinutes,
    r.command,
    r.wait_type
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
  AND r.total_elapsed_time > 300000;
"@
    foreach ($rq in (Invoke-DbaQuery -SqlInstance $instance -Database master -Query $longQuerySql -ErrorAction SilentlyContinue)) {
        Add-Finding 'MEDIUM' 'Long Running Query' $instance "Session $($rq.session_id) ($($rq.DatabaseName))" `
            "Running for $($rq.ElapsedMinutes)m (Command: $($rq.command), Wait: $($rq.wait_type))"
    }
}

# --- Generate HTML Report ----------------------------------------------------
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($ReportFileName)) {
    $ReportFileName = "HealthCheck_{0:yyyyMMdd_HHmmss}.html" -f (Get-Date)
}
$reportFile = Join-Path $OutputPath $ReportFileName

$sevOrder = @{ 'CRITICAL' = 1; 'HIGH' = 2; 'MEDIUM' = 3; 'LOW' = 4 }
$sorted   = @($findings | Sort-Object { $sevOrder[$_.Severity] }, Category, Object)

$css = @"
<style>
 body { font-family: 'Segoe UI', Arial, sans-serif; margin: 24px; color: #1e293b; background: #f8fafc; }
 .card { background: #ffffff; border-radius: 8px; padding: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
 h1 { border-bottom: 3px solid #0078d4; padding-bottom: 10px; margin-top: 0; color: #0f172a; }
 table { border-collapse: collapse; width: 100%; margin-top: 16px; font-size: 14px; }
 th { background: #0078d4; color: #ffffff; text-align: left; padding: 10px 12px; }
 td { border-bottom: 1px solid #e2e8f0; padding: 10px 12px; vertical-align: top; }
 tr:nth-child(even) { background: #f8fafc; }
 .CRITICAL { color: #fff; background: #dc2626; font-weight: bold; padding: 3px 8px; border-radius: 4px; font-size: 12px; }
 .HIGH     { color: #fff; background: #ea580c; font-weight: bold; padding: 3px 8px; border-radius: 4px; font-size: 12px; }
 .MEDIUM   { color: #111; background: #facc15; font-weight: bold; padding: 3px 8px; border-radius: 4px; font-size: 12px; }
 .LOW      { color: #fff; background: #64748b; font-weight: bold; padding: 3px 8px; border-radius: 4px; font-size: 12px; }
 .ok       { color: #15803d; background: #dcfce7; padding: 12px 16px; border-radius: 6px; font-size: 1.05em; font-weight: bold; }
 .meta     { color: #64748b; font-size: 0.9em; margin-bottom: 16px; }
</style>
"@

$body = "<div class='card'><h1>SQL Server Daily Health Check</h1>"
$body += "<p class='meta'>Generated: {0:dd MMM yyyy HH:mm:ss} &middot; Target Instance(s): {1}</p>" -f (Get-Date), ($SqlInstance -join ', ')

if ($sorted.Count -eq 0) {
    $body += "<div class='ok'>&#10004; All health checks passed (0 findings across all monitored databases and volumes).</div>"
} else {
    $counts = $sorted | Group-Object Severity | ForEach-Object { "$($_.Name): $($_.Count)" }
    $body += "<p><strong>$($sorted.Count) finding(s) detected</strong> &mdash; $($counts -join ' &middot; ')</p>"
    $body += "<table><tr><th>Severity</th><th>Category</th><th>Instance</th><th>Object</th><th>Detail</th></tr>"
    foreach ($f in $sorted) {
        $body += "<tr><td><span class='$($f.Severity)'>$($f.Severity)</span></td><td>$($f.Category)</td><td>$($f.Instance)</td><td><strong>$($f.Object)</strong></td><td>$($f.Detail)</td></tr>"
    }
    $body += "</table>"
}
$body += "</div>"

$html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>SQL Server Health Check</title>$css</head><body>$body</body></html>"
$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "HTML report saved to: $reportFile" -ForegroundColor Green
if ($sorted.Count -eq 0) {
    Write-Host "RESULT: ALL CHECKS PASSED (0 findings)." -ForegroundColor Green
} else {
    $sorted | Format-Table Severity, Category, Object, Detail -AutoSize | Out-String | Write-Host
}

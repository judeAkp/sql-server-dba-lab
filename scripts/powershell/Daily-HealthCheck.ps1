<#
.SYNOPSIS
    Daily SQL Server health check using dbatools. Produces an HTML report.

.DESCRIPTION
    Checks backup currency, failed Agent jobs, disk space, database state,
    CHECKDB age and log file usage. Designed to run as a scheduled SQL Agent
    job or Windows scheduled task.

.EXAMPLE
    .\Daily-HealthCheck.ps1 -SqlInstance localhost -OutputPath C:\Reports

.NOTES
    Requires: Install-Module dbatools -Scope CurrentUser
#>

[CmdletBinding()]
param(
    [string[]]$SqlInstance = @('localhost'),
    [string]  $OutputPath  = 'C:\Reports',
    [int]     $FullBackupThresholdHours = 24,
    [int]     $LogBackupThresholdMinutes = 30,
    [int]     $CheckDbThresholdDays = 7,
    [int]     $DiskFreePercentThreshold = 15,
    [string]  $MailTo,
    [string]  $MailFrom,
    [string]  $SmtpServer
)

Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Scope FileUserLocal

$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param($Severity, $Category, $Instance, $Object, $Detail)
    $findings.Add([PSCustomObject]@{
        Severity = $Severity; Category = $Category; Instance = $Instance
        Object   = $Object;   Detail   = $Detail
    })
}

foreach ($instance in $SqlInstance) {

    Write-Host "Checking $instance..." -ForegroundColor Cyan

    if (-not (Test-DbaConnection -SqlInstance $instance -ErrorAction SilentlyContinue).ConnectSuccess) {
        Add-Finding 'CRITICAL' 'Connectivity' $instance '-' 'Unable to connect to instance'
        continue
    }

    # --- Backups ---------------------------------------------------------
    foreach ($db in Get-DbaLastBackup -SqlInstance $instance) {
        if ($db.Database -in @('tempdb')) { continue }

        if ($null -eq $db.LastFullBackup -or
            $db.LastFullBackup -lt (Get-Date).AddHours(-$FullBackupThresholdHours)) {
            $age = if ($db.LastFullBackup) { "$([math]::Round(((Get-Date) - $db.LastFullBackup).TotalHours,1))h ago" } else { 'NEVER' }
            Add-Finding 'CRITICAL' 'Backup' $instance $db.Database "Last full backup: $age"
        }

        if ($db.RecoveryModel -eq 'Full' -and
            ($null -eq $db.LastLogBackup -or
             $db.LastLogBackup -lt (Get-Date).AddMinutes(-$LogBackupThresholdMinutes))) {
            $age = if ($db.LastLogBackup) { "$([math]::Round(((Get-Date) - $db.LastLogBackup).TotalMinutes,0))m ago" } else { 'NEVER' }
            Add-Finding 'HIGH' 'Backup' $instance $db.Database "FULL recovery, last log backup: $age"
        }
    }

    # --- Failed Agent jobs -----------------------------------------------
    $failed = Get-DbaAgentJobHistory -SqlInstance $instance -StartDate (Get-Date).AddDays(-1) -ExcludeJobSteps |
              Where-Object Status -ne 'Succeeded'
    foreach ($j in $failed) {
        Add-Finding 'HIGH' 'Agent Job' $instance $j.Job "Failed at $($j.RunDate): $($j.Message)"
    }

    # --- Database state ---------------------------------------------------
    foreach ($db in Get-DbaDatabase -SqlInstance $instance | Where-Object Status -ne 'Normal') {
        Add-Finding 'CRITICAL' 'Database State' $instance $db.Name "Status: $($db.Status)"
    }

    # --- CHECKDB age ------------------------------------------------------
    foreach ($db in Get-DbaLastGoodCheckDb -SqlInstance $instance) {
        if ($db.Database -eq 'tempdb') { continue }
        if ($null -eq $db.LastGoodCheckDb -or
            $db.LastGoodCheckDb -lt (Get-Date).AddDays(-$CheckDbThresholdDays)) {
            $age = if ($db.LastGoodCheckDb) { "$($db.DaysSinceLastGoodCheckdb) days ago" } else { 'NEVER' }
            Add-Finding 'MEDIUM' 'Integrity' $instance $db.Database "Last good CHECKDB: $age"
        }
    }

    # --- Log file usage ---------------------------------------------------
    foreach ($log in Get-DbaDbLogSpace -SqlInstance $instance) {
        if ($log.LogSpaceUsedPercent -gt 80) {
            Add-Finding 'HIGH' 'Log Space' $instance $log.Database `
                ("Log {0}% used ({1} MB)" -f [math]::Round($log.LogSpaceUsedPercent,1), [math]::Round($log.LogSize.Megabyte,0))
        }
    }

    # --- Long-running queries --------------------------------------------
    $long = Get-DbaRunningJob -SqlInstance $instance -ErrorAction SilentlyContinue
    foreach ($q in $long) {
        Add-Finding 'LOW' 'Long Running' $instance $q.Name 'Job still running'
    }
}

# --- Disk space (host level) ---------------------------------------------
foreach ($disk in Get-DbaDiskSpace -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue) {
    if ($disk.PercentFree -lt $DiskFreePercentThreshold) {
        Add-Finding 'HIGH' 'Disk Space' $env:COMPUTERNAME $disk.Name `
            ("{0}% free ({1} GB of {2} GB)" -f [math]::Round($disk.PercentFree,1),
             [math]::Round($disk.Free.Gigabyte,1), [math]::Round($disk.Capacity.Gigabyte,1))
    }
}

# --- Report ---------------------------------------------------------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$reportFile = Join-Path $OutputPath ("HealthCheck_{0:yyyyMMdd_HHmm}.html" -f (Get-Date))

$sevOrder = @{ 'CRITICAL' = 1; 'HIGH' = 2; 'MEDIUM' = 3; 'LOW' = 4 }
$sorted   = $findings | Sort-Object { $sevOrder[$_.Severity] }, Category

$css = @"
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color:#222; }
 h1 { border-bottom: 3px solid #0078d4; padding-bottom: 8px; }
 table { border-collapse: collapse; width: 100%; margin-top: 16px; }
 th { background:#0078d4; color:#fff; text-align:left; padding:8px; }
 td { border-bottom:1px solid #ddd; padding:8px; vertical-align:top; }
 tr:nth-child(even) { background:#f7f7f7; }
 .CRITICAL { color:#fff; background:#c62828; font-weight:bold; padding:2px 8px; border-radius:3px; }
 .HIGH     { color:#fff; background:#ef6c00; font-weight:bold; padding:2px 8px; border-radius:3px; }
 .MEDIUM   { color:#000; background:#fdd835; padding:2px 8px; border-radius:3px; }
 .LOW      { color:#fff; background:#78909c; padding:2px 8px; border-radius:3px; }
 .ok { color:#2e7d32; font-size:1.1em; font-weight:bold; }
 .meta { color:#666; font-size:0.9em; }
</style>
"@

$body = "<h1>SQL Server Health Check</h1>"
$body += "<p class='meta'>Generated {0:dd MMM yyyy HH:mm} &middot; Instances: {1}</p>" -f (Get-Date), ($SqlInstance -join ', ')

if ($sorted.Count -eq 0) {
    $body += "<p class='ok'>&#10004; All checks passed.</p>"
} else {
    $counts = $sorted | Group-Object Severity | ForEach-Object { "$($_.Name): $($_.Count)" }
    $body += "<p><strong>$($sorted.Count) finding(s)</strong> &mdash; $($counts -join ' &middot; ')</p>"
    $body += "<table><tr><th>Severity</th><th>Category</th><th>Instance</th><th>Object</th><th>Detail</th></tr>"
    foreach ($f in $sorted) {
        $body += "<tr><td><span class='$($f.Severity)'>$($f.Severity)</span></td><td>$($f.Category)</td><td>$($f.Instance)</td><td>$($f.Object)</td><td>$($f.Detail)</td></tr>"
    }
    $body += "</table>"
}

$html = "<html><head><meta charset='utf-8'>$css</head><body>$body</body></html>"
$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Report written to $reportFile" -ForegroundColor Green
$sorted | Format-Table -AutoSize

if ($MailTo -and $SmtpServer) {
    $subject = if ($sorted.Count -eq 0) { 'SQL Health Check: All OK' }
               else { "SQL Health Check: $($sorted.Count) finding(s)" }
    Send-MailMessage -To $MailTo -From $MailFrom -Subject $subject `
        -Body $html -BodyAsHtml -SmtpServer $SmtpServer
    Write-Host "Report emailed to $MailTo" -ForegroundColor Green
}

# Non-zero exit if anything critical, so a scheduler can flag it
if ($sorted | Where-Object Severity -eq 'CRITICAL') { exit 1 }

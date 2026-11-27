# Shows whether the TestWoW Telegram program is running, and its latest log lines.
$appDir = Join-Path $env:LOCALAPPDATA 'TestWoWBot'
$running = Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -like '*forever_battle.py*' }
if ($running) {
    Write-Host 'Running in the background.' -ForegroundColor Green
} else {
    Write-Host 'NOT running. Run install.bat again (or restart Windows).' -ForegroundColor Red
}
$log = Join-Path $appDir 'forever_battle.log'
if (Test-Path $log) {
    Write-Host ''
    Write-Host "Last lines of $log :"
    Get-Content $log -Tail 15 -Encoding UTF8
}
Write-Host ''
Read-Host 'Press Enter to close'

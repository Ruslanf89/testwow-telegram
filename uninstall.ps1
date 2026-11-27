# Stops the TestWoW Telegram program and removes it from Windows startup.
$appDir = Join-Path $env:LOCALAPPDATA 'TestWoWBot'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -like '*forever_battle.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path $runKey -Name 'TestWoWBot' -ErrorAction SilentlyContinue
Write-Host 'Stopped, and removed from Windows startup.' -ForegroundColor Green

if (Test-Path $appDir) {
    $answer = Read-Host "Also delete the program folder $appDir ? (y/n)"
    if ($answer -match '^[yY]') {
        Remove-Item $appDir -Recurse -Force
        Write-Host 'Program folder deleted.'
    }
}
Write-Host 'The addon stays in WoW. To remove it, delete Interface\AddOns\TestWoW in your _forever_ folder.'
Read-Host 'Press Enter to close'

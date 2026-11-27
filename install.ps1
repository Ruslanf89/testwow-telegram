# TestWoW installer: copies the addon into WoW, installs the Telegram program,
# makes it start hidden with Windows, and starts it now.
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Join-Path $env:LOCALAPPDATA 'TestWoWBot'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$utf8   = New-Object System.Text.UTF8Encoding $false

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fail($text) {
    Say ''
    Say $text 'Red'
    Read-Host 'Press Enter to close'
    exit 1
}

Say '=== TestWoW installer ===' 'Yellow'

# ---- 1. Python -------------------------------------------------------------
function Find-Pythonw {
    $candidates = @()
    try {
        $exe = & py -3 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { $candidates += "$exe".Trim() }
    } catch {}
    try {
        $exe = & python -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { $candidates += "$exe".Trim() }
    } catch {}
    $candidates += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | ForEach-Object { $_.FullName }
    foreach ($exe in $candidates) {
        $w = Join-Path (Split-Path $exe) 'pythonw.exe'
        if (Test-Path $w) { return $w }
    }
    return $null
}

$pythonw = Find-Pythonw
if (-not $pythonw) {
    Say 'Python 3 is not installed. It is needed to run the Telegram program.' 'Yellow'
    $answer = Read-Host 'Install Python now with winget? (y/n)'
    if ($answer -match '^[yY]') {
        winget install -e --id Python.Python.3.13 --scope user --accept-package-agreements
        $pythonw = Find-Pythonw
    }
    if (-not $pythonw) {
        Fail 'Install Python from https://www.python.org/downloads/ (tick "Add python.exe to PATH"), then run install.bat again.'
    }
}
Say "Python: $pythonw"

# ---- 2. WoW Forever folder ---------------------------------------------------
$configPath = Join-Path $here 'bot\config.json'
if (-not (Test-Path $configPath)) {
    Copy-Item (Join-Path $here 'bot\config.example.json') $configPath
    Start-Process notepad.exe $configPath
    Fail 'First put your bot token (from @BotFather) into bot\config.json (opened in Notepad), save it, then run install.bat again.'
}
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ("$($config.telegram_token)" -match 'PASTE' -or -not $config.telegram_token) {
    Start-Process notepad.exe $configPath
    Fail 'Put your bot token (from @BotFather) into bot\config.json (opened in Notepad), save it, then run install.bat again.'
}

function Test-Forever($dir) {
    if (-not $dir) { return $null }
    foreach ($d in @($dir, (Join-Path $dir '_forever_'))) {
        if ((Test-Path (Join-Path $d 'Interface')) -or (Test-Path (Join-Path $d 'WTF'))) {
            if ((Split-Path $d -Leaf) -eq '_forever_') { return $d }
        }
    }
    return $null
}

$candidates = @($config.wow_dir)
foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                   'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft')) {
    try {
        $p = (Get-ItemProperty $key -ErrorAction Stop).InstallPath
        if ($p) { $candidates += (Split-Path $p.TrimEnd('\')) ; $candidates += $p }
    } catch {}
}
foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
    foreach ($sub in @('Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft',
                       'World of Warcraft', 'Games\World of Warcraft', 'Blizzard\World of Warcraft')) {
        $candidates += (Join-Path $drive $sub)
    }
}
$forever = $null
foreach ($c in $candidates) { $forever = Test-Forever $c; if ($forever) { break } }

if (-not $forever) {
    Say 'Could not find WoW Forever. Choose the World of Warcraft folder (or its _forever_ folder).' 'Yellow'
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the World of Warcraft folder (the one that contains _forever_)'
    if ($dlg.ShowDialog() -eq 'OK') { $forever = Test-Forever $dlg.SelectedPath }
    if (-not $forever) { Fail 'That folder does not contain _forever_. Run install.bat again.' }
}
Say "WoW Forever: $forever"

# ---- 3. Addon ----------------------------------------------------------------
$addons = Join-Path $forever 'Interface\AddOns'
New-Item -ItemType Directory -Force (Join-Path $addons 'TestWoW') | Out-Null
Copy-Item (Join-Path $here 'TestWoW\*') (Join-Path $addons 'TestWoW') -Force
Say 'Addon installed: Interface\AddOns\TestWoW'
if (Test-Path (Join-Path $addons 'ForeverBattle')) {
    Say 'Note: the old ForeverBattle addon is also there. Turn it off in the in-game AddOns list (or delete its folder).' 'Yellow'
}

# ---- 4. Stop a running copy ---------------------------------------------------
Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -like '*forever_battle.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# ---- 5. Program files ---------------------------------------------------------
New-Item -ItemType Directory -Force $appDir | Out-Null
Copy-Item (Join-Path $here 'bot\forever_battle.py') $appDir -Force
$config | Add-Member -NotePropertyName wow_dir -NotePropertyValue $forever -Force
[System.IO.File]::WriteAllText((Join-Path $appDir 'config.json'), ($config | ConvertTo-Json), $utf8)
$state = Join-Path $here 'bot\state.json'
if ((Test-Path $state) -and -not (Test-Path (Join-Path $appDir 'state.json'))) {
    Copy-Item $state $appDir   # keep what was already posted, so nothing is posted twice
}
Say "Program installed: $appDir"

# ---- 6. Start with Windows, hidden --------------------------------------------
$script = Join-Path $appDir 'forever_battle.py'
Set-ItemProperty -Path $runKey -Name 'TestWoWBot' -Value "`"$pythonw`" `"$script`""
Say 'Starts automatically with Windows (hidden, no window).'

# ---- 7. Start now and check -----------------------------------------------------
Start-Process -FilePath $pythonw -ArgumentList "`"$script`"" -WorkingDirectory $appDir
Start-Sleep -Seconds 6
$log = Join-Path $appDir 'forever_battle.log'
$tail = if (Test-Path $log) { Get-Content $log -Tail 4 -Encoding UTF8 } else { @() }
Say ''
$tail | ForEach-Object { Say "  $_" }
Say ''
if ($tail -match 'ready') {
    Say 'Done! The program is running in the background.' 'Green'
} else {
    Say 'The program started, but did not report "ready" yet. Run status.bat in a minute to check.' 'Yellow'
}
Say 'Restart WoW (or /reload) to load the addon. In game: Sync TG = send level, Exit = quit + post session.'
Read-Host 'Press Enter to close'

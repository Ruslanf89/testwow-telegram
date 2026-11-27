# Builds TestWoW-friends.zip: everything a friend needs, with your bot token and group
# already filled in. Friends only post; your PC is the one that answers Telegram commands
# and keeps the pinned message.
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8  = New-Object System.Text.UTF8Encoding $false
$zip   = Join-Path $here 'TestWoW-friends.zip'
$stage = Join-Path $env:TEMP ('testwow-package-' + [guid]::NewGuid().ToString('N'))

$mine = Get-Content (Join-Path $here 'bot\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not "$($mine.chat_id)".StartsWith('-')) {
    Write-Host 'Your config.json has no group chat_id yet. Add the bot to the group first.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

New-Item -ItemType Directory -Force (Join-Path $stage 'bot') | Out-Null
Copy-Item (Join-Path $here 'TestWoW') $stage -Recurse
Copy-Item (Join-Path $here 'bot\forever_battle.py') (Join-Path $stage 'bot')
foreach ($f in 'install', 'uninstall', 'status') {
    Copy-Item (Join-Path $here "$f.ps1"), (Join-Path $here "$f.bat") $stage
}

$friend = [ordered]@{
    telegram_token = $mine.telegram_token
    chat_id        = "$($mine.chat_id)"
    wow_dir        = ''
    pin_ladder     = $false   # only your PC keeps the pinned message
    commands       = $false   # only one PC per bot may read Telegram commands
}
[System.IO.File]::WriteAllText((Join-Path $stage 'bot\config.json'), ($friend | ConvertTo-Json), $utf8)

$readme = @'
TestWoW - level-ups and play sessions to the Telegram group

1. Unzip this folder anywhere.
2. Double-click install.bat.
   - It installs the WoW addon and a small background program.
   - If Python is missing it offers to install it.
   - The program starts with Windows by itself (no window).
3. Restart WoW.

In game there is a small bar:  [Sync TG] [Exit] [...]
  Sync TG = send my level to Telegram now (reloads the UI)
  Exit    = quit (or log out) and post: character, level, time played this session
  ...     = menu: test message, lock/unlock, reset position, hide
  Drag the bar to move it.  /tw show brings it back if hidden.  /tw help for all commands.

status.bat    = is it running? shows the log
uninstall.bat = stop it and remove it from Windows startup

Do not share this zip outside the group: it contains the bot's key.
'@
[System.IO.File]::WriteAllText((Join-Path $stage 'READ ME.txt'), $readme.Replace("`n", "`r`n"), $utf8)

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force

Write-Host "Made $zip" -ForegroundColor Green
Write-Host 'Send it only to friends in the group: it contains the bot token.' -ForegroundColor Yellow
Read-Host 'Press Enter to close'

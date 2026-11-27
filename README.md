# TestWoW: WoW Forever → Telegram

Posts level-ups and play sessions from WoW Forever to the **FPV Battle forever** Telegram group.

```
TestWoW addon --writes--> SavedVariables\TestWoW.lua --read by--> forever_battle.py (background) --> Telegram
```

WoW addons can't use the internet, and WoW only writes the addon's file on
**/reload, logout or exit**. So the addon gives you buttons that save and then reload or exit.

## Install (you and friends)

**First time from GitHub:** create a bot with @BotFather, copy `bot/config.example.json`
to `bot/config.json`, and paste the token in. (`install.bat` does the copy for you if it's missing.)
Then add the bot to your group; it switches to that group by itself.

1. Double-click **install.bat**. It:
   - installs the addon into `_forever_\Interface\AddOns\TestWoW`
   - installs the program into `%LOCALAPPDATA%\TestWoWBot`
   - makes it start **hidden with Windows** and starts it now
   - offers to install Python if it's missing
2. Restart WoW.

| File | What it does |
|---|---|
| `install.bat` | Install or update. Run it again after changing anything. |
| `status.bat` | Shows whether it's running, plus the log |
| `uninstall.bat` | Stops it and removes it from Windows startup |
| `make_friend_package.bat` | Builds `TestWoW-friends.zip` for friends |

## Friends

Run **make_friend_package.bat** and send `TestWoW-friends.zip` to friends. They unzip
it and run `install.bat`. Their copy only posts. Your PC answers Telegram commands
and keeps the pinned message, because Telegram lets only one PC per bot read commands.

The zip contains the bot's token. Only give it to people in the group. If it leaks,
use `/revoke` in @BotFather, put the new token in `bot\config.json`, run `install.bat`,
and send everyone a new zip.

## In game

A small bar, `[Sync TG] [Exit] [...]`:

| | |
|---|---|
| **Sync TG** | Send my current level now (reloads the UI) |
| **Exit** | Asks: **Exit game** / **Log out** / Cancel. Posts *character, level, zone, time played this session, levels gained* |
| **...** or right-click | Menu: send level, test, exit, log out, lock/unlock, reset position, hide |
| Move | Drag the bar (unless locked) |

Commands: `/tw sync`, `/tw test`, `/tw exit`, `/tw logout`, `/tw show`, `/tw hide`,
`/tw lock`, `/tw unlock`, `/tw reset`, `/tw auto`, `/tw popup`, `/tw status`, `/tw help`.

**Level-up while playing:** it's sent automatically. The addon waits until you're out
of combat, then reloads the UI by itself (a short loading screen), and the group gets "⚔️ Level up".
Turn it off with `/tw auto`; then a popup asks "Send now / Later" instead.

**End of session:** when the game closes, the group gets one summary:
*character, level, zone, time played this session, levels gained (e.g. +3, 27 → 30)*.
This works with the **Exit** button, ESC → Exit Game, or Alt+F4. The Exit button
posts it right away. Otherwise it's posted a few seconds after WoW has closed.
The session timer starts at login and keeps running through reloads.

## Telegram commands (answered by your PC only)

- `/status`: the character being played now
- `/usehere`: post in this group instead
- `/chatid`: shows the chat's id

The bot must be an **admin with "Pin messages"** in the group to keep the pinned status.

## Troubleshooting

Run `status.bat`. The log is `%LOCALAPPDATA%\TestWoWBot\forever_battle.log`.
- "NOT running": run `install.bat` again.
- "no TestWoW SavedVariables yet": log in once with the addon enabled.
- "could not pin": make the bot a group admin.

"""Forever Battle - posts WoW level-ups to a Telegram group.

Watches the TestWoW addon's SavedVariables file (and, as a bonus, the chat
log) for FB1 lines and sends them to Telegram. Python 3.8+, standard library only.

    python forever_battle.py            run it
    python forever_battle.py --check    check config and Telegram, then exit

Telegram commands (in the group or in private):
    /chatid   reply with this chat's id (use it for chat_id in config.json)
    /ladder   post the current level list
"""

from __future__ import annotations

import argparse
import glob
import html
import json
import logging
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
STATE_PATH = os.path.join(HERE, "state.json")
LOG_PATH = os.path.join(HERE, "forever_battle.log")

FB_LINE = re.compile(r'"(FB1\|(?:[^"\\]|\\.)*)"')
OLD_LINE_SECONDS = 24 * 3600  # never post lines older than this on first sight

log = logging.getLogger("forever_battle")


# ---------------------------------------------------------------- config / state


def load_json(path: str, default):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:  # -sig: accept Notepad/PowerShell BOM
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        log.error("%s is not valid JSON: %s", path, e)
        sys.exit(1)


def save_json(path: str, data) -> None:
    tmp = path + ".tmp"
    for attempt in range(5):  # antivirus/OneDrive can lock the file for a moment
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            os.replace(tmp, path)
            return
        except OSError as e:
            if attempt == 4:
                log.warning("could not save %s: %s", os.path.basename(path), e)
                return
            time.sleep(0.2)


def find_forever_dir(configured: str) -> str:
    candidates = []
    if configured:
        candidates += [configured, os.path.join(configured, "_forever_")]
    for drive in "CDEFGH":
        for base in (r"Program Files (x86)\World of Warcraft", r"Program Files\World of Warcraft",
                     r"World of Warcraft", r"Games\World of Warcraft"):
            candidates.append(os.path.join(f"{drive}:\\", base, "_forever_"))
    for c in candidates:
        if os.path.isdir(os.path.join(c, "Interface")) or os.path.isdir(os.path.join(c, "WTF")):
            return c
    return ""


def wow_running(wow_root: str) -> bool:
    """True while a WoW game process from this install is running (Windows)."""
    if os.name != "nt" or not wow_root:
        return False
    import ctypes
    from ctypes import wintypes as wt
    psapi = ctypes.WinDLL("psapi")
    k32 = ctypes.WinDLL("kernel32")
    k32.OpenProcess.restype = wt.HANDLE
    k32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    k32.QueryFullProcessImageNameW.argtypes = [wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
    k32.CloseHandle.argtypes = [wt.HANDLE]
    pids = (wt.DWORD * 8192)()
    needed = wt.DWORD()
    if not psapi.EnumProcesses(pids, ctypes.sizeof(pids), ctypes.byref(needed)):
        return True  # cannot tell: assume running, so nothing is posted too early
    root = os.path.normcase(os.path.abspath(wow_root)) + os.sep
    buf = ctypes.create_unicode_buffer(1024)
    for pid in pids[: needed.value // ctypes.sizeof(wt.DWORD)]:
        handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            continue
        try:
            size = wt.DWORD(len(buf))
            if k32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                path = os.path.normcase(buf.value)
                exe = os.path.basename(path)
                if path.startswith(root) and re.fullmatch(r"wow[a-z0-9]*\.exe", exe) and "proxy" not in exe:
                    return True
        finally:
            k32.CloseHandle(handle)
    return False


# ---------------------------------------------------------------- telegram


class Telegram:
    def __init__(self, token: str):
        self.base = f"https://api.telegram.org/bot{token}/"

    def call(self, method: str, http_timeout: float = 20, **params):
        data = json.dumps(params).encode()
        req = urllib.request.Request(self.base + method, data=data,
                                     headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=http_timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            try:
                return json.load(e)
            except Exception:
                return {"ok": False, "description": f"HTTP {e.code}"}

    on_migrate = None  # called with the new id when a group becomes a supergroup

    def send(self, chat_id, text: str, silent: bool = False):
        res = self.call("sendMessage", chat_id=chat_id, text=text, parse_mode="HTML",
                        disable_notification=silent, disable_web_page_preview=True)
        new_id = (res.get("parameters") or {}).get("migrate_to_chat_id")
        if not res.get("ok") and new_id:
            if self.on_migrate:
                self.on_migrate(str(new_id))
            res = self.call("sendMessage", chat_id=new_id, text=text, parse_mode="HTML",
                            disable_notification=silent, disable_web_page_preview=True)
        if not res.get("ok"):
            raise RuntimeError(res.get("description", "sendMessage failed"))
        return res["result"]["message_id"]


# ---------------------------------------------------------------- parsing


def lua_unescape(s: str) -> str:
    return re.sub(r"\\(.)", lambda m: m.group(1), s)


def parse(line: str):
    """Return a dict for an FB1 line, or None."""
    i = line.find("FB1|")
    if i < 0:
        j = line.find("FB1^")
        if j < 0:
            return None
        line = line[:j] + line[j:].replace("^", "|")
        i = j
    body = line[i + 4:].strip()
    parts = body.split("|")
    op = parts[0]
    if op in ("L", "T") and len(parts) >= 7:
        try:
            return {"op": op, "id": parts[1], "ts": int(parts[2]), "name": parts[3],
                    "class": parts[4], "level": int(parts[5]), "zone": "|".join(parts[6:]).strip()}
        except ValueError:
            return None
    if op in ("Q", "E", "M") and len(parts) >= 10:
        # Q|E|M|id|unix|name|class|level|seconds|startLevel|sessionStart|zone
        try:
            return {"op": op, "id": parts[1], "ts": int(parts[2]), "name": parts[3],
                    "class": parts[4], "level": int(parts[5]), "seconds": int(parts[6]),
                    "start_level": int(parts[7]), "start": int(parts[8]),
                    "zone": "|".join(parts[9:]).strip()}
        except ValueError:
            return None
    if op == "H" and len(parts) >= 6:
        try:
            return {"op": "H", "name": parts[2], "class": parts[3], "level": int(parts[4]),
                    "zone": "|".join(parts[5:]).strip()}
        except ValueError:
            return None
    return None


def class_label(token: str) -> str:
    return token[:1].upper() + token[1:].lower() if token else "Adventurer"


def level_text(ev, test=False) -> str:
    head = "🧪 Test" if test else "⚔️ Level up"
    zone = f"\n{html.escape(ev['zone'])}" if ev.get("zone") else ""
    return (f"<b>{head}</b>\n{html.escape(ev['name'])} · {html.escape(class_label(ev['class']))}"
            f"\n<b>Level {ev['level']}</b>{zone}")


def duration_text(seconds: int) -> str:
    h, m = divmod(max(0, seconds) // 60, 60)
    return f"{h}h {m}m" if h else f"{m}m"


def exit_text(ev) -> str:
    gained = ev["level"] - ev["start_level"]
    levels = (f" · +{gained} level{'s' if gained != 1 else ''} ({ev['start_level']} → {ev['level']})"
              if gained > 0 else "")
    zone = f"\n{html.escape(ev['zone'])}" if ev.get("zone") else ""
    return (f"<b>👋 {html.escape(ev['name'])} left the game</b>\n"
            f"{html.escape(class_label(ev['class']))} · <b>Level {ev['level']}</b>{zone}\n"
            f"⏱ Played this session: <b>{duration_text(ev['seconds'])}</b>{levels}")


def sync_text(ev) -> str:
    """Sync button: where the character is right now."""
    gained = ev["level"] - ev["start_level"]
    levels = f" · +{gained} level{'s' if gained != 1 else ''}" if gained > 0 else ""
    zone = f"\n{html.escape(ev['zone'])}" if ev.get("zone") else ""
    return (f"<b>📍 {html.escape(ev['name'])}</b> · {html.escape(class_label(ev['class']))} "
            f"<b>Level {ev['level']}</b>{zone}\n"
            f"⏱ Playing for {duration_text(ev['seconds'])}{levels}")


def display_name(name: str) -> str:
    """'Mamaya-Vahitna' / 'Mamaya  Vahitna' -> 'Mamaya Vahitna'."""
    name = re.sub(r"([^\s-])-([^\s-])", r"\1 \2", name or "")
    return re.sub(r"\s+", " ", name).strip() or "Unknown"


def status_text(row) -> str:
    """Pinned message: only the character being played right now."""
    if not row:
        return "<b>🏆 Forever Battle</b>\nNo character yet."
    zone = f"\n{html.escape(row['zone'])}" if row.get("zone") else ""
    return (f"<b>🏆 Forever Battle</b>\n{html.escape(row['name'])} — "
            f"{html.escape(class_label(row['class']))} {row['level']}{zone}")


# ---------------------------------------------------------------- app


class App:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.tg = Telegram(cfg["telegram_token"])
        self.tg.on_migrate = self.use_chat
        self.chat_id = cfg.get("chat_id")
        self.forever = ""
        self.state = load_json(STATE_PATH, {})
        self.state.setdefault("seen", [])
        self.state.setdefault("roster", {})
        self.state.setdefault("sv_mtimes", {})
        self.state.setdefault("chatlog_offset", None)
        if self.state.get("version") != 2:
            # v2: full names + only the current character is pinned. Drop the old mixed list.
            self.state["roster"] = {}
            self.state.pop("ladder_message_id", None)
            self.state.pop("ladder_chat_id", None)
            self.state["version"] = 2
        self.state.setdefault("current", "")
        self.seen = set(self.state["seen"])
        self.retry_at = {}
        self.next_session_check = 0.0
        self.wow_gone_since = None
        self.lock = threading.Lock()

    def current_row(self):
        return self.state["roster"].get(self.state.get("current", ""))

    def save(self):
        self.state["seen"] = list(self.seen)[-2000:]
        save_json(STATE_PATH, self.state)

    # ---- events

    def handle(self, ev, source: str):
        ev["name"] = display_name(ev["name"])
        if ev["op"] == "H":
            self.update_roster(ev, announce=False)
            self.set_current(ev)
            return
        if ev["op"] in ("Q", "E"):
            self.handle_session(ev, source)
            return
        if ev["id"] in self.seen:
            return
        self.seen.add(ev["id"])
        if time.time() - ev["ts"] > OLD_LINE_SECONDS:
            log.info("skip old line %s (%s lvl %s)", ev["id"], ev["name"], ev["level"])
            return
        if not self.chat_id:
            log.warning("chat_id is not set; add the bot to your group and send /chatid there")
            self.seen.discard(ev["id"])
            return
        if ev["op"] == "T":
            self.tg.send(self.chat_id, level_text(ev, test=True), silent=True)
            log.info("sent test for %s (%s)", ev["name"], source)
            return
        if ev["op"] == "M":
            try:
                self.tg.send(self.chat_id, sync_text(ev), silent=True)
            except Exception:
                self.seen.discard(ev["id"])
                raise
            log.info("sent status of %s: level %s (%s)", ev["name"], ev["level"], source)
            self.update_roster(ev, announce=False)
            self.set_current(ev)
            self.refresh_ladder()
            return
        key = ev["name"].lower()
        prev = self.state["roster"].get(key, {}).get("announced", 0)
        if ev["level"] <= prev:
            log.info("%s level %s already posted; refreshing pinned message only", ev["name"], ev["level"])
            self.update_roster(ev, announce=False)
            self.set_current(ev)
            self.refresh_ladder()
            return
        try:
            self.tg.send(self.chat_id, level_text(ev))
        except Exception:
            self.seen.discard(ev["id"])  # retry next time the file changes
            raise
        log.info("sent level %s for %s (%s)", ev["level"], ev["name"], source)
        self.update_roster(ev, announce=True)
        self.set_current(ev)
        self.refresh_ladder()

    # ---- play sessions
    # Q (Exit button) is posted at once. E is written by the addon on every logout/exit
    # (maybe also /reload), so it is only posted once the game has really closed.
    # One session = one character + login time; it is posted once.

    def handle_session(self, ev, source):
        key = f"S:{ev['name'].lower()}:{ev['start']}"
        if key in self.seen:
            return
        if time.time() - ev["ts"] > OLD_LINE_SECONDS:
            self.seen.add(key)
            return
        pending = self.state.setdefault("pending_sessions", {})
        if ev["op"] == "Q":
            self.post_session(key, ev, source)
            return
        old = pending.get(key)
        if not old or ev["ts"] >= old["ts"]:
            pending[key] = ev  # latest summary of this session
        # An older pending session of the same character has ended (they logged in again).
        for other_key, other in list(pending.items()):
            if (other_key != key and other["name"].lower() == ev["name"].lower()
                    and other["start"] < ev["start"]):
                self.post_session(other_key, other, "earlier session")

    def post_session(self, key, ev, source):
        if not self.chat_id:
            log.warning("chat_id is not set; session of %s waits", ev["name"])
            return
        self.tg.send(self.chat_id, exit_text(ev), silent=True)  # raises -> retried later
        self.seen.add(key)
        self.state.setdefault("pending_sessions", {}).pop(key, None)
        log.info("sent session of %s: level %s, %s played (%s)",
                 ev["name"], ev["level"], duration_text(ev["seconds"]), source)
        self.update_roster(ev, announce=False)
        self.set_current(ev)
        self.refresh_ladder()

    def flush_sessions(self):
        """Post waiting session summaries once WoW has been closed for a few seconds."""
        pending = self.state.get("pending_sessions") or {}
        if not pending or time.time() < self.next_session_check:
            return
        self.next_session_check = time.time() + 3
        if wow_running(os.path.dirname(self.forever)):
            self.wow_gone_since = None
            return
        if self.wow_gone_since is None:
            self.wow_gone_since = time.time()
            return
        if time.time() - self.wow_gone_since < 5:
            return
        self._scan_saved_files()  # pick up the file WoW wrote while closing
        for key, ev in sorted(list(pending.items()), key=lambda kv: kv[1]["ts"]):
            with self.lock:
                try:
                    self.post_session(key, ev, "game closed")
                except Exception as e:
                    log.error("telegram error: %s; will retry", e)
                    self.next_session_check = time.time() + 30
                    break
        self.save()

    def set_current(self, ev):
        self.state["current"] = ev["name"].lower()

    def update_roster(self, ev, announce: bool):
        key = ev["name"].lower()
        row = self.state["roster"].get(key, {"announced": 0})
        row["name"] = ev["name"]
        row["class"] = ev["class"] or row.get("class", "")
        row["level"] = max(ev["level"], row.get("level", 0))
        if ev.get("zone"):
            row["zone"] = ev["zone"]
        if announce:
            row["announced"] = max(ev["level"], row.get("announced", 0))
        self.state["roster"][key] = row

    def refresh_ladder(self):
        if not self.cfg.get("pin_ladder", True) or not self.chat_id:
            return
        text = status_text(self.current_row())
        msg_id = self.state.get("ladder_message_id")
        if msg_id and self.state.get("ladder_chat_id") == self.chat_id:
            res = self.tg.call("editMessageText", chat_id=self.chat_id, message_id=msg_id,
                               text=text, parse_mode="HTML")
            if res.get("ok") or "not modified" in res.get("description", ""):
                return
        try:
            msg_id = self.tg.send(self.chat_id, text, silent=True)
        except Exception as e:
            log.warning("ladder: %s", e)
            return
        self.state["ladder_message_id"] = msg_id
        self.state["ladder_chat_id"] = self.chat_id
        res = self.tg.call("pinChatMessage", chat_id=self.chat_id, message_id=msg_id,
                           disable_notification=True)
        if not res.get("ok"):
            log.warning("could not pin ladder (make the bot an admin): %s", res.get("description"))

    # ---- watchers

    def saved_variable_files(self):
        return glob.glob(os.path.join(self.forever, "WTF", "Account", "*", "SavedVariables", self.cfg.get("addon_name", "TestWoW") + ".lua"))

    def scan_saved(self, first_run: bool):
        before = (self.state.get("current"), json.dumps(self.current_row(), sort_keys=True))
        self._scan_saved_files()
        after = (self.state.get("current"), json.dumps(self.current_row(), sort_keys=True))
        if after != before:
            with self.lock:
                try:
                    self.refresh_ladder()  # switched character, or level/zone changed
                    self.save()
                except Exception as e:
                    log.warning("pinned message: %s", e)

    def _scan_saved_files(self):
        def mtime_of(p):
            try:
                return os.path.getmtime(p)
            except OSError:
                return 0
        # Oldest first, so the newest file's last line decides the current character.
        for path in sorted(self.saved_variable_files(), key=mtime_of):
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if self.state["sv_mtimes"].get(path) == mtime:
                continue
            if time.time() < self.retry_at.get(path, 0):
                continue
            time.sleep(0.3)  # let WoW finish writing
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            ok = True
            for m in FB_LINE.finditer(text):
                ev = parse(lua_unescape(m.group(1)))
                if ev:
                    ok = self.safe_handle(ev, "saved") and ok
            if ok:
                self.state["sv_mtimes"][path] = mtime
                self.retry_at.pop(path, None)
            else:
                self.retry_at[path] = time.time() + 30  # e.g. no internet: try the file again soon
                log.info("will retry in 30 s")
            self.save()

    def scan_chatlog(self):
        path = os.path.join(self.forever, "Logs", "WoWChatLog.txt")
        try:
            size = os.path.getsize(path)
        except OSError:
            if self.state["chatlog_offset"] is None:
                self.state["chatlog_offset"] = 0  # file not there yet: read it from the start
            return
        off = self.state["chatlog_offset"]
        if off is None or off > size:
            off = size if off is None else 0
        if off == size:
            self.state["chatlog_offset"] = off
            return
        with open(path, "rb") as f:
            f.seek(off)
            data = f.read(size - off)
        end = data.rfind(b"\n")
        if end < 0:
            return
        for raw in data[:end].splitlines():
            line = raw.decode("utf-8", errors="replace")
            if "FB1" in line:
                ev = parse(line)
                if ev:
                    self.safe_handle(ev, "chatlog")
        self.state["chatlog_offset"] = off + end + 1
        self.save()

    def safe_handle(self, ev, source) -> bool:
        with self.lock:
            try:
                self.handle(ev, source)
                return True
            except Exception as e:
                log.error("telegram error: %s", e)
                return False

    def use_chat(self, chat_id: str):
        """Make this the chat for level-ups and remember it in config.json."""
        self.chat_id = chat_id
        self.cfg["chat_id"] = chat_id
        save_json(CONFIG_PATH, self.cfg)
        log.info("level-ups now go to chat %s", chat_id)

    def auto_group(self, chat: dict):
        """If level-ups still go to a private chat, switch them to this group."""
        if str(self.chat_id or "").startswith("-"):
            return  # a group is already chosen; use /usehere to change it
        with self.lock:
            self.use_chat(str(chat["id"]))
        try:
            self.tg.send(chat["id"], "✅ Level-ups will be posted in this group.", silent=True)
        except Exception as e:
            log.warning("could not post in group %s: %s", chat.get("title"), e)
        with self.lock:
            self.refresh_ladder()
            self.save()

    # ---- telegram commands (long polling)

    def poll_commands(self):
        offset = None
        while True:
            try:
                params = {"timeout": 25, "allowed_updates": ["message", "my_chat_member"]}
                if offset is not None:
                    params["offset"] = offset
                res = self.tg.call("getUpdates", http_timeout=35, **params)
                if not res.get("ok"):
                    log.warning("getUpdates: %s", res.get("description"))
                    time.sleep(10)
                    continue
                for upd in res["result"]:
                    offset = upd["update_id"] + 1
                    # Bot added to a group (or made admin there): use that group automatically.
                    member = upd.get("my_chat_member")
                    if member:
                        c = member.get("chat", {})
                        status = (member.get("new_chat_member") or {}).get("status", "")
                        log.info("telegram: bot is now '%s' in %s '%s' (%s)",
                                 status, c.get("type"), c.get("title", ""), c.get("id"))
                        if status in ("member", "administrator") and c.get("type") in ("group", "supergroup"):
                            self.auto_group(c)
                        continue
                    msg = upd.get("message") or {}
                    if not msg:
                        continue
                    c = msg.get("chat", {})
                    if msg.get("migrate_to_chat_id") and str(c.get("id")) == str(self.chat_id):
                        with self.lock:
                            self.use_chat(str(msg["migrate_to_chat_id"]))
                        continue
                    text = (msg.get("text") or "").strip()
                    if not text.startswith("/"):
                        continue
                    log.info("telegram: %s in %s '%s' (%s)", text.split()[0], c.get("type"),
                             c.get("title", "private"), c.get("id"))
                    cmd = text.split()[0].split("@")[0].lower()
                    chat = msg["chat"]["id"]
                    chat_type = msg["chat"].get("type", "")
                    if chat_type in ("group", "supergroup") and cmd not in ("/chatid", "/usehere"):
                        self.auto_group(c)
                    if cmd == "/chatid":
                        hint = ("Send /usehere in this group to post level-ups here."
                                if chat_type in ("group", "supergroup")
                                else "Send /usehere in your group (not here) to post level-ups there.")
                        self.tg.send(chat, f"This chat id is <code>{chat}</code>\n{hint}")
                    elif cmd == "/usehere":
                        if chat_type not in ("group", "supergroup"):
                            self.tg.send(chat, "Send /usehere inside the group where level-ups should go.")
                            continue
                        with self.lock:
                            self.use_chat(str(chat))
                        self.tg.send(chat, "✅ Level-ups will be posted in this group.", silent=True)
                        with self.lock:
                            self.refresh_ladder()
                            self.save()
                    elif cmd in ("/status", "/ladder", "/levels"):
                        with self.lock:
                            self.tg.send(chat, status_text(self.current_row()))
                    elif cmd in ("/start", "/help"):
                        self.tg.send(chat, "/usehere - post level-ups in this group\n"
                                           "/status - character I'm playing now\n"
                                           "/chatid - show this chat's id")
            except Exception as e:
                log.warning("poll: %s", e)
                time.sleep(10)

    # ---- main loop

    def wait_for_telegram(self):
        """At Windows startup the internet may not be up yet: keep trying."""
        told = False
        while True:
            try:
                me = self.tg.call("getMe")
            except Exception as e:
                if not told:
                    log.warning("no connection to Telegram yet (%s); retrying", e)
                    told = True
                time.sleep(30)
                continue
            if me.get("ok"):
                return me["result"]
            log.error("Telegram token rejected: %s", me.get("description"))
            sys.exit(1)

    def run(self):
        me = self.wait_for_telegram()
        log.info("bot @%s ready, chat_id=%s", me["username"], self.chat_id or "(not set)")
        if self.cfg.get("commands", True):
            # Only ONE computer may listen for commands per bot (Telegram allows one reader).
            # getUpdates does not work while a webhook (e.g. the old Cloudflare worker) is set.
            info = self.tg.call("getWebhookInfo")
            if info.get("ok") and info["result"].get("url"):
                log.info("removing old webhook %s so commands reach this program", info["result"]["url"])
                self.tg.call("deleteWebhook")
            threading.Thread(target=self.poll_commands, daemon=True).start()
        else:
            log.info("commands are off on this PC (\"commands\": false); only posting")

        first = True
        while True:
            if not self.forever:
                self.forever = find_forever_dir(self.cfg.get("wow_dir", ""))
                if self.forever:
                    log.info("watching %s", self.forever)
                    if not self.saved_variable_files():
                        log.info("no TestWoW SavedVariables yet - log in once with the addon enabled")
                else:
                    log.warning("could not find the _forever_ folder; set wow_dir in config.json")
                    time.sleep(30)
                    continue
            self.scan_saved(first)
            self.scan_chatlog()
            self.flush_sessions()
            first = False
            time.sleep(1.5)


_instance_lock = None


def already_running() -> bool:
    """Only one copy may run (two copies would post everything twice)."""
    global _instance_lock
    import socket
    if _instance_lock is not None:
        return False
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):  # Windows: never share the port
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    try:
        sock.bind(("127.0.0.1", 47613))
        sock.listen(1)
        _instance_lock = sock  # keep it open for as long as the program runs
        return False
    except OSError:
        return True


def main():
    from logging.handlers import RotatingFileHandler
    handlers = [RotatingFileHandler(LOG_PATH, maxBytes=1_000_000, backupCount=1, encoding="utf-8")]
    if sys.stdout is not None:  # None when started hidden with pythonw
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
        handlers.append(logging.StreamHandler(sys.stdout))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", handlers=handlers)
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="check config and Telegram, then exit")
    args = ap.parse_args()
    if not args.check and already_running():
        log.info("already running; this copy exits")
        return

    cfg = load_json(CONFIG_PATH, None)
    if not cfg or not cfg.get("telegram_token") or "PASTE" in cfg.get("telegram_token", ""):
        log.error("Copy config.example.json to config.json and put your bot token in it.")
        sys.exit(1)
    app = App(cfg)
    if args.check:
        me = app.tg.call("getMe")
        print("token:", "OK @" + me["result"]["username"] if me.get("ok") else me.get("description"))
        print("wow folder:", find_forever_dir(cfg.get("wow_dir", "")) or "NOT FOUND")
        if app.chat_id:
            try:
                app.tg.send(app.chat_id, "✅ Forever Battle is connected.", silent=True)
                print("chat_id: OK, test message sent")
            except Exception as e:
                print("chat_id: FAILED -", e)
        else:
            print("chat_id: not set (run the program, then send /chatid in your group)")
        return
    try:
        app.run()
    except KeyboardInterrupt:
        app.save()


if __name__ == "__main__":
    main()

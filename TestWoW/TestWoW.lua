-- TestWoW 0.4.0
--
-- WoW addons cannot talk to the internet. This addon writes "FB1|..." lines into
-- its SavedVariables file. A small program on this PC (forever_battle.py) watches
-- that file and posts to Telegram.
--
-- WoW only writes SavedVariables to disk on /reload, logout or exit. So:
--   Sync  = save a level line and /reload  -> posted within seconds
--   Exit  = save a session line and quit   -> posted when WoW closes
--
-- Lines:
--   FB1|H|version|name|class|level|zone                           login
--   FB1|L|id|unix|name|class|level|zone                           level (or Sync)
--   FB1|T|id|unix|name|class|level|zone                           test
--   FB1|Q|id|unix|name|class|level|seconds|startLevel|start|zone  Exit button: post now
--   FB1|E|id|unix|name|class|level|seconds|startLevel|start|zone  any logout: post when WoW closes

local PREFIX = "FB1|"
local VERSION = "0.4.0"

TestWoWDB = TestWoWDB or {}

local frame = CreateFrame("Frame")

local function say(text)
	print("|cffd4af37TestWoW|r " .. text)
end

local function sanitize(text)
	text = tostring(text or "")
	text = text:gsub("|", "/")
	text = text:gsub("%^", " ")
	text = text:gsub('"', "'")
	text = text:gsub("[\r\n]", " ")
	return text
end

local function plainNumber(value, fallback)
	if type(issecretvalue) == "function" and issecretvalue(value) then
		return fallback
	end
	if type(value) ~= "number" then
		return fallback
	end
	return value
end

local function after(seconds, fn)
	if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
		C_Timer.After(seconds, fn)
	else
		fn()
	end
end

local function remember(line)
	TestWoWDB.lines = TestWoWDB.lines or {}
	local lines = TestWoWDB.lines
	lines[#lines + 1] = line
	while #lines > 40 do
		table.remove(lines, 1)
	end
end

-- WoW Forever characters have a surname. UnitName returns it as the second value.
local function playerName()
	local first, surname = UnitName("player")
	if type(first) ~= "string" or first == "" then
		return "Unknown"
	end
	first = sanitize(first)
	if type(surname) == "string" and surname ~= "" and not first:find(surname, 1, true) then
		first = first .. " " .. sanitize(surname)
	end
	return first
end

local function identity()
	local _, class = UnitClass("player")
	local level = plainNumber(UnitLevel("player"), 0)
	local zone = sanitize(GetZoneText and GetZoneText() or "")
	return playerName(), class or "UNKNOWN", level, zone
end

local function newID()
	return string.format("%08x%04x", time(), math.random(0, 65535))
end

-- Optional live path: a whisper to yourself lands in WoWChatLog.txt (hidden below).
local function whisperSelf(line)
	if TestWoWDB.noWhisper then
		return
	end
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	local me = UnitName("player")
	if type(send) ~= "function" or type(me) ~= "string" then
		return
	end
	pcall(send, (line:gsub("|", "^")), "WHISPER", nil, me)
end

local function record(op, level)
	local name, class, _, zone = identity()
	local line = string.format("%s%s|%s|%d|%s|%s|%d|%s", PREFIX, op, newID(), time(), name, class, level, zone)
	remember(line)
	whisperSelf(line)
	return line
end

local function hideLine(_, _, message)
	return type(message) == "string" and (message:find("FB1|", 1, true) or message:find("FB1^", 1, true)) ~= nil
end

if type(ChatFrame_AddMessageEventFilter) == "function" then
	ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", hideLine)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", hideLine)
end

------------------------------------------------------------------------
-- Play session (survives /reload, restarts on a real login)
------------------------------------------------------------------------

local function sessions()
	TestWoWDB.sessions = TestWoWDB.sessions or {}
	return TestWoWDB.sessions
end

local function startSession()
	local name, _, level = identity()
	sessions()[name] = { start = time(), level = level }
end

local function ensureSession()
	local s = sessions()[playerName()]
	if type(s) ~= "table" or type(s.start) ~= "number" then
		startSession()
	end
end

local function sessionInfo()
	local s = sessions()[playerName()]
	if type(s) ~= "table" or type(s.start) ~= "number" then
		return 0, nil, 0
	end
	return math.max(0, time() - s.start), s.level, s.start
end

-- Session summary line. op "Q" = Exit button (post now), "E" = any logout/exit/reload
-- (the program posts it once the game has closed). Same session start = same session.
local function sessionLine(op)
	local name, class, level, zone = identity()
	local seconds, startLevel, start = sessionInfo()
	return string.format("%s%s|%s|%d|%s|%s|%d|%d|%d|%d|%s", PREFIX, op, newID(), time(), name, class, level,
		seconds, startLevel or level, start, zone), seconds
end

local function formatDuration(seconds)
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	if h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", m)
end

------------------------------------------------------------------------
-- Sync (save + reload) and Exit (save + quit / logout)
------------------------------------------------------------------------

local waitingForCombat = false
local autoReloading = false

local function inCombat()
	return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player"))
end

local function reloadNow()
	if inCombat() then
		if not waitingForCombat then
			waitingForCombat = true
			frame:RegisterEvent("PLAYER_REGEN_ENABLED")
			say("In combat. Will send when combat ends.")
		end
		return
	end
	ReloadUI()
end

local function syncNow()
	local _, _, level = identity()
	if level < 1 then
		say("Could not read your level. Try again in a moment.")
		return
	end
	record("L", level)
	TestWoWDB.lastLevel = level
	say("Sending level " .. level .. " to Telegram (reloading UI)...")
	reloadNow()
end

local function testNow()
	local _, _, level = identity()
	record("T", math.max(level, 1))
	say("Test sent. Reloading UI so the program can read it...")
	reloadNow()
end

local function recordExit()
	local line, seconds = sessionLine("Q")
	remember(line)
	say(string.format("Session %s saved. It is posted to Telegram when the game closes.", formatDuration(seconds)))
end

local function exitGame(mode)
	recordExit()
	if mode == "logout" then
		Logout()
	else
		Quit()
	end
end

StaticPopupDialogs["TESTWOW_EXIT"] = {
	text = "TestWoW\n\nLeave and post your session to Telegram?\n%s",
	button1 = "Exit game",
	button2 = "Cancel",
	button3 = "Log out",
	OnAccept = function()
		exitGame("quit")
	end,
	OnAlt = function()
		exitGame("logout")
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function askExit()
	local name, _, level = identity()
	local seconds = sessionInfo()
	StaticPopup_Show("TESTWOW_EXIT", string.format("%s, level %d, played %s", name, level, formatDuration(seconds)))
end

------------------------------------------------------------------------
-- Popup on level-up: one click sends it.
------------------------------------------------------------------------

StaticPopupDialogs["TESTWOW_LEVEL"] = {
	text = "TestWoW\n\nLevel %s! Send it to Telegram now?\n(This reloads the UI.)",
	button1 = "Send now",
	button2 = "Later",
	OnAccept = function()
		reloadNow()
	end,
	OnCancel = function()
		say("Saved. It will be sent on your next /reload, logout, or Sync.")
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function onLevelUp(level)
	level = plainNumber(level, 0)
	if level < 1 or TestWoWDB.lastLevel == level then
		return
	end
	TestWoWDB.lastLevel = level
	record("L", level)
	if not TestWoWDB.manual then
		-- Auto mode (default): reload by itself once out of combat, so the level is posted now.
		autoReloading = true
		if inCombat() then
			say("Level " .. level .. "! Sending to Telegram after combat...")
		else
			say("Level " .. level .. "! Sending to Telegram in 3 seconds...")
		end
		after(3, reloadNow)
	elseif not TestWoWDB.noPopup then
		StaticPopup_Show("TESTWOW_LEVEL", tostring(level))
	else
		say("Level " .. level .. " saved. Click Sync or type /tw sync to send it.")
	end
end

-- If this client does not let an addon reload by itself, fall back to the one-click popup.
local function onBlocked(addon)
	if addon ~= "TestWoW" or not autoReloading then
		return
	end
	autoReloading = false
	TestWoWDB.manual = true
	say("This client blocks automatic reloads, so you'll get a one-click popup on level-up instead.")
	StaticPopup_Show("TESTWOW_LEVEL", tostring(TestWoWDB.lastLevel or ""))
end

------------------------------------------------------------------------
-- The bar: [Sync] [Exit] [≡]   drag to move, right-click or ≡ for the menu
------------------------------------------------------------------------

local bar, menu
local dragged = false

local function savePosition()
	local point, _, relativePoint, x, y = bar:GetPoint()
	TestWoWDB.barPos = { point, relativePoint, x, y }
end

local function placeBar()
	local pos = TestWoWDB.barPos
	bar:ClearAllPoints()
	if type(pos) == "table" and pos[1] then
		bar:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		bar:SetPoint("TOP", UIParent, "TOP", 0, -120)
	end
end

local function startDrag()
	if TestWoWDB.locked then
		return
	end
	dragged = true
	bar:StartMoving()
end

local function stopDrag()
	bar:StopMovingOrSizing()
	savePosition()
	after(0.1, function()
		dragged = false
	end)
end

-- A click that ends a drag should not also press the button.
local function clicked()
	if dragged then
		dragged = false
		return false
	end
	return true
end

local function tooltip(owner, lines)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		for i, line in ipairs(lines) do
			if i == 1 then
				GameTooltip:AddLine(line)
			else
				GameTooltip:AddLine(line, 1, 1, 1)
			end
		end
		if not TestWoWDB.locked then
			GameTooltip:AddLine("Drag to move. Right-click for options.", 0.7, 0.7, 0.7)
		else
			GameTooltip:AddLine("Locked. Right-click for options.", 0.7, 0.7, 0.7)
		end
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function toggleMenu()
	if menu:IsShown() then
		menu:Hide()
		return
	end
	menu:ClearAllPoints()
	menu:SetPoint("TOP", bar, "BOTTOM", 0, -4)
	menu:Refresh()
	menu:Show()
end

local function makeButton(parent, text, width, onClick, tip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 24)
	b:SetText(text)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", startDrag)
	b:SetScript("OnDragStop", stopDrag)
	b:SetScript("OnClick", function(_, mouse)
		if not clicked() then
			return
		end
		if mouse == "RightButton" then
			toggleMenu()
		else
			onClick()
		end
	end)
	if tip then
		tooltip(b, tip)
	end
	return b
end

local refreshBar

local function makeMenu()
	menu = CreateFrame("Frame", "TestWoWMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	menu:SetFrameStrata("DIALOG")
	menu:SetClampedToScreen(true)
	if menu.SetBackdrop then
		menu:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		menu:SetBackdropColor(0, 0, 0, 0.9)
	end
	menu:Hide()
	tinsert(UISpecialFrames, "TestWoWMenu") -- Escape closes it

	local items = {}
	local function item(label, fn)
		local b = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
		b:SetSize(170, 22)
		b:SetScript("OnClick", function()
			menu:Hide()
			fn()
		end)
		b.label = label
		items[#items + 1] = b
		b:SetPoint("TOP", menu, "TOP", 0, -8 - (#items - 1) * 24)
		return b
	end

	item(function() return "Send my level now" end, syncNow)
	item(function() return "Send test message" end, testNow)
	item(function() return "Exit game + post session" end, function() exitGame("quit") end)
	item(function() return "Log out + post session" end, function() exitGame("logout") end)
	item(function() return TestWoWDB.locked and "Unlock position" or "Lock position" end, function()
		TestWoWDB.locked = not TestWoWDB.locked
		say(TestWoWDB.locked and "Bar locked." or "Bar unlocked. Drag it to move.")
	end)
	item(function() return "Reset position" end, function()
		TestWoWDB.barPos = nil
		placeBar()
	end)
	item(function() return "Hide bar (/tw show)" end, function()
		TestWoWDB.hideBar = true
		refreshBar()
		say("Bar hidden. Type /tw show to bring it back.")
	end)

	menu:SetSize(186, 16 + #items * 24)
	function menu:Refresh()
		for _, b in ipairs(items) do
			b:SetText(b.label())
		end
	end
end

local function makeBar()
	if bar then
		return bar
	end
	bar = CreateFrame("Frame", "TestWoWBar", UIParent)
	bar:SetSize(84 + 64 + 28 + 8, 26)
	bar:SetFrameStrata("MEDIUM")
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", startDrag)
	bar:SetScript("OnDragStop", stopDrag)

	local sync = makeButton(bar, "Sync TG", 84, syncNow,
		{ "TestWoW: Sync", "Send my current level to Telegram.", "(reloads the UI)" })
	sync:SetPoint("LEFT", bar, "LEFT", 0, 0)
	local exit = makeButton(bar, "Exit", 64, askExit,
		{ "TestWoW: Exit", "Quit or log out and post your play session", "(character, level, time played)." })
	exit:SetPoint("LEFT", sync, "RIGHT", 4, 0)
	local more = makeButton(bar, "...", 28, toggleMenu, { "TestWoW", "Options: test, lock, hide." })
	more:SetPoint("LEFT", exit, "RIGHT", 4, 0)

	makeMenu()
	placeBar()
	return bar
end

function refreshBar()
	if TestWoWDB.hideBar then
		if bar then
			bar:Hide()
		end
		if menu then
			menu:Hide()
		end
	else
		makeBar():Show()
	end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local function onOff(value)
	return value and "on" or "off"
end

local function status()
	local name, class, level, zone = identity()
	local seconds = sessionInfo()
	say(string.format("v%s. %s, %s %d, %s. Session %s.", VERSION, name, class, level, zone, formatDuration(seconds)))
	say(string.format("bar %s, locked %s, auto-send on level-up %s, popup when manual %s",
		onOff(not TestWoWDB.hideBar), onOff(TestWoWDB.locked),
		onOff(not TestWoWDB.manual), onOff(not TestWoWDB.noPopup)))
end

local function help()
	say("/tw sync - send your level now     /tw test - test message")
	say("/tw exit - quit game + post session     /tw logout - log out + post session")
	say("/tw show | hide - show/hide the bar     /tw lock | unlock - lock its position")
	say("/tw reset - move the bar back to the top of the screen")
	say("/tw auto - auto-send on level-up on/off (reloads the UI after combat)")
	say("/tw popup - when auto is off: ask with a popup on level-up")
	say("/tw status")
end

SLASH_TESTWOW1 = "/testwow"
SLASH_TESTWOW2 = "/tw"
SlashCmdList.TESTWOW = function(raw)
	local text = string.lower(raw or ""):match("^%s*(.-)%s*$") or ""
	if text == "sync" or text == "send" or text == "now" then
		syncNow()
	elseif text == "test" then
		testNow()
	elseif text == "exit" or text == "quit" then
		exitGame("quit")
	elseif text == "logout" or text == "camp" then
		exitGame("logout")
	elseif text == "show" then
		TestWoWDB.hideBar = false
		refreshBar()
	elseif text == "hide" then
		TestWoWDB.hideBar = true
		refreshBar()
		say("Bar hidden. Type /tw show to bring it back.")
	elseif text == "button" or text == "bar" then
		TestWoWDB.hideBar = not TestWoWDB.hideBar
		refreshBar()
	elseif text == "lock" then
		TestWoWDB.locked = true
		say("Bar locked.")
	elseif text == "unlock" then
		TestWoWDB.locked = false
		say("Bar unlocked. Drag it to move.")
	elseif text == "reset" then
		TestWoWDB.barPos = nil
		TestWoWDB.hideBar = false
		refreshBar()
		placeBar()
	elseif text == "popup" then
		TestWoWDB.noPopup = not TestWoWDB.noPopup
		say("Level-up popup " .. onOff(not TestWoWDB.noPopup) .. ".")
	elseif text == "auto" or text == "autoreload" then
		TestWoWDB.manual = not TestWoWDB.manual
		say("Auto-send on level-up " .. onOff(not TestWoWDB.manual) .. "."
			.. (TestWoWDB.manual and " Use Sync, or the popup." or ""))
	elseif text == "whisper" then
		TestWoWDB.noWhisper = not TestWoWDB.noWhisper
		say("Self-whisper " .. onOff(not TestWoWDB.noWhisper) .. ".")
	elseif text == "" or text == "status" then
		status()
		say("Type /tw help for commands.")
	else
		help()
	end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local sessionChecked = false

frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == "TestWoW" then
			TestWoWDB = TestWoWDB or {}
		end
		return
	end
	if event == "PLAYER_LOGIN" then
		if type(LoggingChat) == "function" then
			LoggingChat(true)
		end
		local name, class, level, zone = identity()
		remember(string.format("%sH|%s|%s|%s|%d|%s", PREFIX, VERSION, name, class, level, zone))
		if TestWoWDB.lastLevel == nil then
			TestWoWDB.lastLevel = level
		end
		refreshBar()
		say(VERSION .. " loaded. Sync = send level, Exit = quit + post session. /tw help")
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		if sessionChecked then
			return -- zoning
		end
		sessionChecked = true
		local isInitialLogin, isReloadingUi = ...
		if isInitialLogin == true then
			startSession()
		elseif isReloadingUi == true or isInitialLogin == false then
			ensureSession()
		else
			-- Old client without these arguments: a recent "seen" means this was a /reload.
			local s = sessions()[playerName()]
			if type(s) == "table" and type(s.seen) == "number" and time() - s.seen < 120 then
				ensureSession()
			else
				startSession()
			end
		end
		return
	end
	if event == "PLAYER_LOGOUT" then
		-- Fires before WoW saves the file, on exit, logout (and possibly /reload).
		-- The program posts this summary once the game has really closed.
		local s = sessions()[playerName()]
		if type(s) == "table" then
			s.seen = time()
		end
		TestWoWDB.ends = TestWoWDB.ends or {}
		TestWoWDB.ends[playerName()] = (sessionLine("E"))
		return
	end
	if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		onBlocked(...)
		return
	end
	if event == "PLAYER_LEVEL_UP" then
		onLevelUp(...)
		return
	end
	if event == "PLAYER_REGEN_ENABLED" then
		frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
		if waitingForCombat then
			waitingForCombat = false
			reloadNow()
		end
	end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")

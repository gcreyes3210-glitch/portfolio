-- Runs the game: intermission -> pick a map -> play that map's game mode -> award wins -> repeat.
-- Each map folder in Workspace.Maps has a "Mode" attribute naming a ModuleScript in
-- ServerScriptService.Modes. The mode decides who wins; this script does everything else.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Boost = require(script.Parent:WaitForChild("Boost"))           -- paid/earned one-round boosts
local WinEffects = require(script.Parent:WaitForChild("WinEffects")) -- celebrations bought in the shop
local Stats = require(script.Parent:WaitForChild("Stats"))           -- lifetime wins/rounds, badges, leaderboards
local Twists = require(script.Parent:WaitForChild("Twists"))         -- random round modifiers (Low Gravity, Tiny...)
local Levels = require(script.Parent:WaitForChild("Levels"))         -- XP + levels (everyone who plays makes progress)
-- EXTRAS (ServerScriptService.Extras): low-player scaling, per-mode stats, awards, nemesis, streaks, ghosts,
-- predictions, weather, the finale, practice servers... Every Hooks call is safe: an extra can't stop the round loop.
local Hooks = require(script.Parent:WaitForChild("Extras"):WaitForChild("RoundHooks"))
-- ELIMINATION GAMES (ServerScriptService.Elimination): every 3rd game, the worst players of each round are cut
-- until the last few play the Final Showdown. elimGame (below) is true during a round of such a game.
local Elim = require(script.Parent:WaitForChild("Elimination"))

------------------------------------------------------------------
-- SETTINGS (change these freely)
local WINS_TO_WIN_GAME = 5    -- first to this many round wins takes the game (was 10: games ran 30+ rounds)
                              -- the scoreboard (RoundCards) reads this from the Status attribute WinsToWin
-- COINS (2x Coins pass owners get double). An average player earns ~220-280 coins an hour.
local COINS_PER_ROUND_PLAYED = 5   -- everyone who plays a round, win or lose
local COINS_PER_ROUND_WIN = 15     -- extra for winning the round
local COINS_FOR_PLACE = { 100, 60, 40 } -- end of the game: 1st (the winner) / 2nd / 3rd by round wins
local COINS_PER_GAME_WIN = COINS_FOR_PLACE[1]
local COINS_FOR_FINISHING_GAME = 20 -- everyone still here when a game ends who played at least
local ROUNDS_TO_FINISH_GAME = 3     --   this many of its rounds
local ROUND_TIME = 120        -- seconds per round (2 minutes)
local INTERMISSION_TIME = 15  -- seconds in the lobby between rounds
local NEW_GAME_INTERMISSION = 60 -- seconds in the lobby before a brand-new game (first to WINS_TO_WIN_GAME) starts
local COUNTDOWN_TIME = 3      -- frozen at the start before "go"
local PREVIEW_TIME = 7        -- the INTRO MOVIE shown to everyone before players are teleported (0 = off). It also explains
                              -- the game (StarterPlayerScripts.GameIntros shows the how-to-play), so it needs time to be read
local NO_REPEAT = 5           -- a game type can't come back until this many other games have been played
local MIN_PLAYERS = 2         -- rounds need this many players in the server (a PRACTICE server always needs just 1,
                              -- and so does a playtest in STUDIO, so ForceMap / Playlist testing still works alone)
local COMEBACK_GAP = 2        -- players this many wins behind the leader get a FREE boost for the round (scaled down for first-to-5)
local FORCE_MAP = nil         -- e.g. "ForestBall" to always play that map while testing
-- TESTING without editing code: select RoundManager and set these attributes in the Properties window.
--   ForceMap (string)  = a map name, e.g. "Maze" -> every round plays that map
--   FastTest (bool)    = true -> 5s intermissions instead of 15/60. REMOVE BOTH before publishing!
-- More test attributes (also on RoundManager, also to REMOVE before publishing):
--   ForceWeather (string) = "Rain" / "Night" / "Fog" / "Sunset" / "None"   (Extras.Weather)
--   ForceFinale (bool)    = true -> the next round is the Final Showdown   (Extras.Finale)
--   PracticeTest (string) = a map name -> this server acts like a practice server (Extras.Practice)
--   HostTest (bool)       = true -> you get the private-server Host button      (ServerScriptService.HostControls)
--   ForceFormat (string)  = "Elimination" / "Classic" -> every game is that kind  (ServerScriptService.Elimination)
--   Playlist (string)     = map names with commas, e.g. "Maze,HexSpleef,MoonRun" -> those games are played in that
--                           order, one round each (then voting is back to normal). The status bar shows [3/29].
--   PlaylistAt (number)   = which game of the Playlist to start from (1 = the first). Use it to carry on where
--                           you stopped: if you quit at [12/29], set PlaylistAt = 12.
--                           A game that needs more players than are here is skipped (with a message).
------------------------------------------------------------------

local status = ReplicatedStorage:WaitForChild("Status")
-- SPECTATOR MODE (StarterPlayerScripts.SpectateClient) reads two things set by this script:
--   Status attribute RoundActive = true while a round is running (there's something to watch)
--   player attribute InRound = true for everyone still playing. A mode sets it to nil when a player
--   is OUT for the rest of the round (SpinBar, HideAndSeek, PirateBattle do this). Only players
--   WITHOUT InRound can spectate, and only players WITH it can be watched.
status:SetAttribute("RoundActive", false)
status:SetAttribute("WinsToWin", WINS_TO_WIN_GAME) -- one place to change it: the UI reads this
local mapsFolder = workspace:WaitForChild("Maps")
local modesFolder = script.Parent:WaitForChild("Modes")
local nextPick = ServerStorage:WaitForChild("NextMapPick") -- set by the lobby's game picker
local questEvent = ServerStorage:WaitForChild("QuestEvent") -- tells the Quest Board about rounds played/won

-- lobby voting pads (ServerScriptService.Voting). Optional: if the module isn't there, voting is simply skipped.
local function getVoting()
	local m = script.Parent:FindFirstChild("Voting")
	if not m then return nil end
	local ok, voting = pcall(require, m)
	return ok and voting or nil
end

local activeMode = nil
local participants = {}
local newGame = true -- true until the first round of a game has started
local gameRounds = setmetatable({}, { __mode = "k" }) -- rounds each player has played in this game
local pulledAFK = {} -- players taken OUT of the current round for going AFK (no win/coins for it)

-- AFK IN A ROUND (AFKServer sets AFK after 45s idle mid-round): take them out like a knockout.
-- Clearing InRound lets modes that check it skip them; breaking the character counts as "out" in modes
-- that watch Humanoid.Died. They're no longer a participant, so they respawn in town, not on the map.
local function pullOutAFK(player)
	if not (activeMode and participants[player]) then return end
	participants[player] = nil
	pulledAFK[player] = true
	player:SetAttribute("InRound", nil)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid.Health = 0 end
end

local function setFrozen(player, frozen)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.WalkSpeed = frozen and 0 or StarterPlayer.CharacterWalkSpeed
	humanoid.JumpHeight = frozen and 0 or StarterPlayer.CharacterJumpHeight
	humanoid.JumpPower = frozen and 0 or StarterPlayer.CharacterJumpPower
end

local function onPlayerAdded(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = leaderstats
	leaderstats.Parent = player
	task.spawn(PlayerData.setup, player) -- adds Coins and loads saved data

	player:GetAttributeChangedSignal("AFK"):Connect(function()
		if player:GetAttribute("AFK") then pullOutAFK(player) end
	end)
	player.CharacterAdded:Connect(function(character)
		if activeMode and participants[player] then
			task.spawn(Boost.onCharacter, player, character) -- re-applies a boost after a respawn
			Twists.onCharacter(player, character)               -- e.g. stay tiny in a Tiny Mode round
			activeMode.onCharacterAdded(player, character)
		end
	end)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
Players.PlayerRemoving:Connect(function(player)
	participants[player] = nil
end)

local function formatTime(seconds)
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function getWins(player)
	local stats = player:FindFirstChild("leaderstats")
	return stats and stats:FindFirstChild("Wins")
end

-- a map can be played only if its game-rules script exists (maps still being built have none yet)
-- and it hasn't crashed in this server (Broken attribute, set below)
local function isReady(map)
	-- (FinaleOnly maps, like the Final Showdown, are never picked as a normal round)
	return map ~= nil and not map:GetAttribute("Broken") and not map:GetAttribute("FinaleOnly") and modesFolder:FindFirstChild(map:GetAttribute("Mode") or "Race") ~= nil
end

-- TEST PLAYLIST (the Playlist / PlaylistAt attributes described at the top): the next game on the list, or nil
-- when there is no list or it has finished. Status attribute PlaylistInfo = "3/29" while a list game is on.
local playlistAt = nil
local function playlistMap()
	status:SetAttribute("PlaylistInfo", nil)
	local list = script:GetAttribute("Playlist")
	if type(list) ~= "string" or list == "" then return nil end
	local names = {}
	for name in string.gmatch(list, "[^,%s]+") do table.insert(names, name) end
	playlistAt = playlistAt or math.max(1, math.floor(tonumber(script:GetAttribute("PlaylistAt")) or 1))
	while playlistAt <= #names do
		local i = playlistAt
		playlistAt += 1
		local map = mapsFolder:FindFirstChild(names[i])
		if not map or map:GetAttribute("Broken") then
			status.Value = "[" .. i .. "/" .. #names .. "] Skipping " .. names[i] .. ": it isn't ready"
			task.wait(2)
		elseif not Hooks.playable(map, #Players:GetPlayers()) then
			status.Value = "[" .. i .. "/" .. #names .. "] Skipping " .. (map:GetAttribute("DisplayName") or map.Name) .. ": it needs more players"
			task.wait(2)
		else
			status:SetAttribute("PlaylistInfo", i .. "/" .. #names)
			return map
		end
	end
	return nil -- the list is finished: back to voting
end

local function pickMap()
	local forced = script:GetAttribute("ForceMap") or FORCE_MAP
	if forced and forced ~= "" and mapsFolder:FindFirstChild(forced) then
		status:SetAttribute("PlaylistInfo", nil)
		return mapsFolder[forced] -- testing: play it even if it isn't ready, so you see its errors
	end
	local listed = playlistMap()
	if listed then return listed end
	-- PRACTICE SERVER (Extras.Practice): only ever the game being practised
	local practiceMap = Hooks.forcedMap()
	if practiceMap then return practiceMap end
	Hooks.votesDecided(getVoting()) -- per-mode stats: which games were on the pads, and their votes
	-- someone paid to choose this round's game
	if nextPick.Value ~= "" and isReady(mapsFolder:FindFirstChild(nextPick.Value)) then
		local chosen = mapsFolder[nextPick.Value]
		nextPick.Value = ""
		nextPick:SetAttribute("PickedBy", nil)
		return chosen
	end
	-- no paid pick: the voting pad with the most players standing on it wins (ties are random)
	local voting = getVoting()
	local voted = voting and voting.getLeader(true)
	if voted and isReady(mapsFolder:FindFirstChild(voted)) then
		return mapsFolder[voted]
	end
	-- nobody voted: pick one of the 3 games on the pads (they never include the game just played)
	local offered = voting and voting.getOptions and voting.getOptions() or {}
	local pool = {}
	for _, id in offered do
		if isReady(mapsFolder:FindFirstChild(id)) and id ~= status:GetAttribute("LastMapId") and not (voting.isRecent and voting.isRecent(id)) then table.insert(pool, mapsFolder[id]) end
	end
	if #pool == 0 then -- no pads for some reason: any game that works with this many players, except the one just played
		for _, m in mapsFolder:GetChildren() do
			local playable = not (voting and voting.isPlayable) or voting.isPlayable(m.Name)
			local recent = voting and voting.isRecent and voting.isRecent(m.Name)
			if m.Name ~= status:GetAttribute("LastMapId") and playable and isReady(m) and not recent then table.insert(pool, m) end
		end
	end
	if #pool == 0 then
		for _, m in mapsFolder:GetChildren() do
			if isReady(m) then table.insert(pool, m) end
		end
	end
	return pool[math.random(#pool)]
end

-- PRIVATE SERVER HOST (ServerScriptService.HostControls) leaves little notes on Status; this applies them:
--   HostNewGame   -> everyone's wins back to 0, a fresh game starts
--   WinsToWinNext -> how many wins take the game (applied when a game starts, or at once if nobody has a win yet)
local function hostSettings()
	if status:GetAttribute("HostNewGame") then
		status:SetAttribute("HostNewGame", nil)
		for _, player in Players:GetPlayers() do
			local w = getWins(player)
			if w then w.Value = 0 end
		end
		table.clear(gameRounds)
		newGame = true
		Elim.gameOver() -- (also ends an Elimination game that was running)
	end
	local wanted = status:GetAttribute("WinsToWinNext")
	if type(wanted) == "number" and wanted >= 1 and wanted ~= WINS_TO_WIN_GAME then
		local anyWins = false
		for _, player in Players:GetPlayers() do
			local w = getWins(player)
			if w and w.Value > 0 then anyWins = true end
		end
		if newGame or not anyWins then
			WINS_TO_WIN_GAME = wanted
			status:SetAttribute("WinsToWin", wanted)
		end
	end
end

-- MAIN LOOP
while true do
	while #Players:GetPlayers() < ((Hooks.isPractice() or game:GetService("RunService"):IsStudio()) and 1 or MIN_PLAYERS) do -- practice servers are solo on purpose
		status.Value = "Waiting for players..."
		task.wait(1)
	end
	hostSettings()
	Elim.prepare(Hooks.isPractice()) -- no game running? A new one starts here: classic (first to N wins) or ELIMINATION
	local label = Elim.label(newGame) or (newGame and "New game starts in" or "Intermission")
	local waitTime = Hooks.intermission(newGame and NEW_GAME_INTERMISSION or INTERMISSION_TIME)
	local practice = Hooks.isPractice() -- a practice server: one game on repeat, no wins / coins / stats
	if practice then label = "Practice round starts in" end
	if script:GetAttribute("FastTest") then waitTime = 5 end
	for i = waitTime, 1, -1 do
		if status:GetAttribute("HostSkip") then break end -- the private-server host pressed START NOW
		if status:GetAttribute("HostNewGame") then hostSettings(); Elim.prepare(Hooks.isPractice()); label = Elim.label(true) or "New game starts in" end
		local picked = nextPick.Value ~= "" and mapsFolder:FindFirstChild(nextPick.Value)
		if picked then
			status.Value = string.format("%s: %d  |  Next: %s (picked by %s)", label, i,
				picked:GetAttribute("DisplayName") or picked.Name, nextPick:GetAttribute("PickedBy") or "?")
		else
			local voting = getVoting()
			local leader, votes = nil, 0
			if voting then leader, votes = voting.getLeader(false) end
			local leaderMap = leader and mapsFolder:FindFirstChild(leader)
			if leaderMap then
				status.Value = string.format("%s: %d  |  Vote leader: %s (%d)", label, i,
					leaderMap:GetAttribute("DisplayName") or leaderMap.Name, votes)
			else
				status.Value = label .. ": " .. i
			end
		end
		task.wait(1)
	end
	status:SetAttribute("HostSkip", nil)
	status:SetAttribute("HostEndRound", nil)
	hostSettings()
	-- NOBODY HERE TO PLAY (everyone is AFK): don't pick a game and play its intro movie to an empty room - say so,
	-- wait, and look again. (The same check after the intro stays: someone can still go AFK while it plays.)
	do
		local anyone = false
		for _, player in Players:GetPlayers() do
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and not player:GetAttribute("AFK") then
				anyone = true
				break
			end
		end
		if not anyone then
			status.Value = "Everyone is AFK! Move around to join the next round."
			task.wait(5)
			continue
		end
	end
	newGame = false

	-- THE FINALE (Extras.Finale): when 2+ players are one win from the game, they play the Final Showdown
	-- instead of a normal round. finalists = the only players who play it; everyone else watches.
	local finaleMap, finalists = nil, nil
	do
		local candidates = {}
		for _, player in Players:GetPlayers() do
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and not player:GetAttribute("AFK") then table.insert(candidates, player) end
		end
		-- ELIMINATION GAME: only the players still alive play; the last few play the Final Showdown
		if Elim.active() then
			local okLineup, fMap, fPlayers = pcall(Elim.lineup, candidates)
			if okLineup then
				finaleMap, finalists = fMap, fPlayers
			else -- (a mistake in the Elimination module must never stop the round loop)
				warn("[RoundManager] Elimination lineup failed: " .. tostring(fMap))
				Elim.gameOver()
			end
		end
		-- (lineup switches back to a classic game when there are too few players - so check again)
		if not Elim.active() then
			finaleMap, finalists = Hooks.finale(candidates, getWins, WINS_TO_WIN_GAME)
		end
	end
	local elimGame = Elim.active() -- this round belongs to an Elimination game: wins don't decide the game

	local map = finaleMap or pickMap()
	local mapName = map:GetAttribute("DisplayName") or map.Name
	-- (test playlist: "[3/29] " in front of the game's name on the status bar)
	local listTag = (not finaleMap and status:GetAttribute("PlaylistInfo")) and ("[" .. status:GetAttribute("PlaylistInfo") .. "] ") or ""
	local modeName = map:GetAttribute("Mode") or "Race"
	-- SAFETY: a missing or crashing game-rules script must never stop the whole game. The map is marked
	-- Broken for this server (it won't be picked again) and everyone goes back to the lobby.
	local okMode, mode = pcall(function() return require(modesFolder[modeName]) end)
	if not okMode or type(mode) ~= "table" then
		warn("[RoundManager] Skipping " .. map.Name .. ": its mode '" .. modeName .. "' couldn't load: " .. tostring(mode))
		map:SetAttribute("Broken", true)
		status.Value = "Oops! That game isn't ready yet - picking another one..."
		task.wait(3)
		continue
	end
	-- a mode can get ready BEFORE the preview, e.g. Find the Button picks its arena so the preview shows it
	if mode.prepare then
		local okPrep, prepErr = pcall(mode.prepare, map)
		if not okPrep then warn("[RoundManager] " .. map.Name .. " prepare failed: " .. tostring(prepErr)) end
	end
	local twistId = nil -- nil most rounds; never in the finale
	if not finaleMap then twistId = Twists.pick(modeName, map.Name) end

	-- MAP PREVIEW (StarterPlayerScripts.MapPreview): everyone's camera flies over the chosen map with a
	-- title card, like "Bowling Bustle - Venice". Each map has PreviewCam / PreviewFocus / PreviewIcon /
	-- PreviewTag attributes. The server first makes every player's game load that area (the maps are far
	-- from town and only nearby things are loaded), so the camera never shows an empty world.
	if PREVIEW_TIME > 0 then
		local focus = map:GetAttribute("PreviewFocus") or map:GetAttribute("Center")
		local camCF = map:GetAttribute("PreviewCam")
		local anchor
		if focus then
			anchor = Instance.new("Part")
			anchor.Name = "PreviewStreamAnchor"
			anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = true, false, false, false
			anchor.Transparency = 1
			anchor.Size = Vector3.new(1, 1, 1)
			anchor.Position = camCF and (camCF.Position + focus) / 2 or focus
			anchor.Parent = workspace
			local pending = 0
			for _, player in Players:GetPlayers() do
				player.ReplicationFocus = anchor
				pending += 1
				task.spawn(function()
					pcall(function() player:RequestStreamAroundAsync(focus, 2) end)
					if camCF then pcall(function() player:RequestStreamAroundAsync(camCF.Position, 1) end) end
					pending -= 1
				end)
			end
			local t0 = os.clock()
			while pending > 0 and os.clock() - t0 < 2.5 do task.wait(0.1) end
		end
		status:SetAttribute("PreviewMapId", map.Name)
		status:SetAttribute("PreviewEnds", workspace:GetServerTimeNow() + PREVIEW_TIME)
		status:SetAttribute("PreviewLength", PREVIEW_TIME)
		status:SetAttribute("PreviewSerial", (status:GetAttribute("PreviewSerial") or 0) + 1)
		for i = PREVIEW_TIME, 1, -1 do
			status.Value = listTag .. mapName .. "  |  Teleporting players in " .. i
			task.wait(1)
		end
		status:SetAttribute("PreviewMapId", nil)
		for _, player in Players:GetPlayers() do
			if player.ReplicationFocus == anchor then player.ReplicationFocus = nil end
		end
		if anchor then anchor:Destroy() end
	end

	local players = {}
	participants = {}
	table.clear(pulledAFK)
	for _, player in Players:GetPlayers() do
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		-- AFK players (ServerScriptService.AFKServer) sit this round out so they don't drag a team down
		if humanoid and humanoid.Health > 0 and not player:GetAttribute("AFK") and (not finalists or table.find(finalists, player)) then
			table.insert(players, player)
			participants[player] = true
		end
	end
	if #players == 0 then
		status.Value = "Everyone is AFK! Move around to join the next round."
		-- (test playlist: nobody played this game, so it stays next on the list)
		if listTag ~= "" and playlistAt then playlistAt -= 1 end
		task.wait(5)
		continue
	end
	-- coins at the start, so the results screen can show what each player earned this round
	local startCoins = {}
	for _, player in Players:GetPlayers() do
		player:SetAttribute("RoundCoins", nil) -- lobby watchers show no coins line
		Levels.resetRoundGain(player)
	end
	for _, player in players do
		local c = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Coins")
		startCoins[player] = c and c.Value or 0
		player:SetAttribute("RoundCoins", nil)
	end

	for _, player in players do player:SetAttribute("InRound", true) end
	status:SetAttribute("RoundMap", mapName)
	status:SetAttribute("RoundMode", modeName) -- SnackServer/SnackUI: snacks only work in some games
	status:SetAttribute("LastMapId", map.Name) -- NO BACK-TO-BACK: voting, the game picker and the random pick all skip this
	do -- NO REPEATS: remember the last 5 game types (Voting.isRecent reads this)
		local recent = { modeName }
		for name in (status:GetAttribute("RecentModes") or ""):gmatch("[^,]+") do
			if #recent >= NO_REPEAT then break end
			if name ~= modeName then table.insert(recent, name) end
		end
		status:SetAttribute("RecentModes", table.concat(recent, ","))
	end
	status:SetAttribute("RoundActive", true)

	-- COMEBACK: anyone far behind the leader gets a free boost this round
	local leaderWins = 0
	for _, player in Players:GetPlayers() do
		local w = getWins(player)
		if w then leaderWins = math.max(leaderWins, w.Value) end
	end
	local comeback = {}
	if #players >= 2 then
		for _, player in players do
			local w = getWins(player)
			if w and leaderWins - w.Value >= COMEBACK_GAP then comeback[player] = true end
		end
	end
	-- MATCH POINT: someone can take the whole game by winning this round (StarterPlayerScripts.MatchPointClient)
	local matchNames = {}
	for _, player in players do
		local w = getWins(player)
		if not elimGame and w and w.Value + Twists.winValue() >= WINS_TO_WIN_GAME then -- winValue is 1 here (twist not started yet)
			table.insert(matchNames, player.DisplayName)
		end
	end
	if twistId == "DoubleWins" then -- with double wins, 8 wins is already match point
		table.clear(matchNames)
		for _, player in players do
			local w = getWins(player)
			if not elimGame and w and w.Value + 2 >= WINS_TO_WIN_GAME then table.insert(matchNames, player.DisplayName) end
		end
	end
	status:SetAttribute("MatchPoint", #matchNames > 0 and table.concat(matchNames, ", ") or nil)

	activeMode = mode
	Hooks.beforeStart(map, modeName, players, twistId, finaleMap ~= nil) -- weather, finale banner, small-lobby flag
	Twists.startRound(twistId, players) -- the twist is on screen during the countdown (TwistClient)
	Boost.startRound(modeName, players, comeback) -- BEFORE start, so modes can check Boost.isBoosted(player)
	local okStart, startErr = pcall(mode.start, map, players)
	if not okStart then
		warn("[RoundManager] " .. map.Name .. " crashed while starting: " .. tostring(startErr))
		map:SetAttribute("Broken", true)
		pcall(mode.stop)
		Boost.endRound()
		Twists.endRound()
		Hooks.roundCrashed()
		activeMode = nil
		participants = {}
		status:SetAttribute("RoundActive", false)
		status:SetAttribute("RoundMode", nil)
		status:SetAttribute("MatchPoint", nil)
		for _, player in Players:GetPlayers() do
			player:SetAttribute("InRound", nil)
			player:LoadCharacter()
		end
		status.Value = "Oops! That game had a problem - picking another one..."
		task.wait(3)
		continue
	end
	Twists.afterStart(players)
	Hooks.afterStart(map, modeName, players) -- tracker, nemesis, ghosts + predictions, how-to cards, per-mode stats
	if not mode.noFreeze then -- a mode can let players move during the countdown (e.g. Spinning Bar)
		for _, player in players do setFrozen(player, true) end
	end
	-- COUNTDOWN (StarterPlayerScripts.RoundCards shows a small 3-2-1 bubble while everyone is frozen; it reads IntroEnds)
	status:SetAttribute("IntroTitle", mapName)
	status:SetAttribute("IntroText", mode.intro)
	status:SetAttribute("IntroMapId", map.Name)
	status:SetAttribute("IntroEnds", workspace:GetServerTimeNow() + (mode.countdown or COUNTDOWN_TIME))
	for i = mode.countdown or COUNTDOWN_TIME, 1, -1 do -- a mode can ask for a longer countdown
		local twistName = status:GetAttribute("TwistName")
		status.Value = listTag .. mapName .. (twistName and ("  |  TWIST: " .. twistName) or "") .. "  |  Starting in " .. i -- the rules were in the intro movie (GameIntros)
		task.wait(1)
	end
	if not mode.noFreeze then
		for _, player in players do
			if player.Parent then setFrozen(player, false) end
		end
	end
	if mode.begin then -- modes that need to know when "go" happens
		local ok, e = pcall(mode.begin)
		if not ok then
			warn("[RoundManager] " .. map.Name .. " begin crashed: " .. tostring(e))
			map:SetAttribute("Broken", true) -- the round loop below ends right away
		end
	end
	Boost.afterBegin() -- boosted players get their speed / health / ⚡ badge now
	Hooks.go()

	-- a map can ask for a longer round (RoundTime); small lobbies get a shorter clock on some maps (Extras.Scaling)
	local timeLeft = Hooks.roundTime(map, ROUND_TIME, #players)
	local function safeWinners() -- a crash in getWinners ends the round instead of the whole game
		local ok, w, msg = pcall(mode.getWinners)
		if not ok then
			warn("[RoundManager] " .. map.Name .. " getWinners crashed: " .. tostring(w))
			map:SetAttribute("Broken", true)
			return {}, "Oops! Something went wrong - round over."
		end
		return w, msg
	end
	while timeLeft > 0 and next(participants) and not map:GetAttribute("Broken") and not status:GetAttribute("HostEndRound") and not safeWinners() do
		status.Value = listTag .. mapName .. "  |  " .. formatTime(timeLeft)
		task.wait(1)
		timeLeft -= 1
	end
	-- the private-server host pressed END ROUND: nobody wins, and the round gives no coins / XP / stats
	-- (otherwise a host could farm coins by starting and ending rounds over and over)
	local hostEnded = status:GetAttribute("HostEndRound") == true
	status:SetAttribute("HostEndRound", nil)
	if timeLeft <= 0 and mode.timeUp and not hostEnded then -- lets a mode pick a winner when the clock runs out
		local ok, e = pcall(mode.timeUp)
		if not ok then warn("[RoundManager] " .. map.Name .. " timeUp crashed: " .. tostring(e)) end
	end
	local winners, message = safeWinners()
	if hostEnded then winners, message = {}, "👑 The host ended the round." end
	if winners and next(pulledAFK) then -- AFK players don't share a team's win
		local kept = {}
		for _, p in winners do
			if not pulledAFK[p] then table.insert(kept, p) end
		end
		winners = kept
	end
	Hooks.beforeStop() -- the awards need the modes' score numbers before the mode tidies them away
	local okStop, stopErr = pcall(mode.stop)
	if not okStop then warn("[RoundManager] " .. map.Name .. " stop crashed: " .. tostring(stopErr)) end
	Boost.endRound()
	activeMode = nil
	participants = {}

	-- award wins and coins. Everyone who played gets a little, winners get more.
	for _, player in players do
		if player.Parent and not pulledAFK[player] and not practice and not hostEnded then
			PlayerData.addCoins(player, COINS_PER_ROUND_PLAYED)
			Levels.add(player, Levels.XP_PLAY_ROUND)
			gameRounds[player] = (gameRounds[player] or 0) + 1
		end
	end
	local champions = {}
	local winValue = Twists.winValue() -- 2 in a Double Wins round
	if practice then
		status.Value = (message or "Round over!") .. "  |  PRACTICE" -- (no wins or coins on a practice server; kept short so it fits the status bar)
	elseif winners and #winners > 0 then
		for _, player in winners do
			local wins = getWins(player)
			if wins then
				-- (in an Elimination game round wins are just for show: no cap, and they never win the game)
				wins.Value = elimGame and (wins.Value + winValue) or math.min(WINS_TO_WIN_GAME, wins.Value + winValue)
				PlayerData.addCoins(player, COINS_PER_ROUND_WIN)
				Levels.add(player, Levels.XP_WIN_ROUND)
				WinEffects.play(player) -- their Win effect from the shop, if they have one
				if not elimGame and wins.Value >= WINS_TO_WIN_GAME then
					table.insert(champions, player)
				end
			end
		end
		if not elimGame and #winners == 1 and getWins(winners[1]) then
			message ..= " (" .. getWins(winners[1]).Value .. "/" .. WINS_TO_WIN_GAME .. ")"
		end
		if winValue > 1 then message ..= "  ✨ x2 WINS!" end
		status.Value = message .. "  +" .. (COINS_PER_ROUND_WIN + COINS_PER_ROUND_PLAYED) .. " coins"
	else
		status.Value = message or "Time's up! Nobody won this round." -- show the mode's own reason (e.g. "You fell!") when it gives one
	end

	-- EXTRAS: awards, streaks, nemesis + prediction payouts, party bonus, per-mode stats and the final-moment
	-- replay. (Before the results screen, so the coins they give show up in "what YOU earned".)
	local replayTime = 0
	if hostEnded then
		Hooks.roundSkipped() -- no awards / streaks / stats for a round the host stopped
	else
		replayTime = Hooks.roundEnded(map, modeName, players, winners, pulledAFK, map:GetAttribute("Broken") == true) or 0
	end
	-- ELIMINATION GAME: cut the bottom players of this round - or, after the final, crown the champion
	if elimGame and not practice and not hostEnded then
		local okElim, champ = pcall(Elim.roundEnded, players, winners, pulledAFK)
		if not okElim then warn("[RoundManager] Elimination failed: " .. tostring(champ)) elseif champ then champions = { champ } end
	end

	-- RESULTS SCREEN (StarterPlayerScripts.RoundCards): who won + what YOU earned this round
	for _, player in players do
		local c = player.Parent and player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Coins")
		if c then player:SetAttribute("RoundCoins", math.max(0, c.Value - (startCoins[player] or c.Value))) end
	end
	local winnerNames = {}
	for _, player in winners or {} do
		if player.Parent then table.insert(winnerNames, player.DisplayName) end
	end
	status:SetAttribute("ResultsMap", mapName)
	status:SetAttribute("ResultsText", message or "Time's up! Nobody won this round.")
	status:SetAttribute("ResultsWinners", table.concat(winnerNames, ", "))
	status:SetAttribute("ResultsSerial", (status:GetAttribute("ResultsSerial") or 0) + 1)

	-- Quest Board progress + lifetime stats: everyone who started the round played it; winners also won it.
	-- The mode name goes along so quests like "Win 2 Horse Races" can count only that mode.
	for _, player in players do
		if player.Parent and not practice and not hostEnded then
			questEvent:Fire(player, "PlayRound", 1, modeName)
			Stats.roundPlayed(player, modeName)
		end
	end
	-- lobby podium: remember who won the last round (comma-separated so team wins work too)
	local ids, names = {}, {}
	for _, player in winners or {} do
		if player.Parent and not practice then
			questEvent:Fire(player, "WinRound", 1, modeName)
			Stats.roundWon(player, modeName)
			table.insert(ids, tostring(player.UserId))
			table.insert(names, player.DisplayName)
		end
	end
	if #ids > 0 then
		status:SetAttribute("LastWinnerIds", table.concat(ids, ","))
		status:SetAttribute("LastWinnerNames", table.concat(names, " & "))
		status:SetAttribute("LastWinnerMap", mapName)
	end
	task.wait(4 + replayTime) -- spectators keep watching during the winner message (+ the final-moment replay)
	Hooks.afterResults() -- weather back to normal etc. (BEFORE RoundActive goes off, so screens tidy up first)

	-- round's over: nothing left to spectate. RoundActive goes off FIRST so clearing InRound
	-- doesn't look like "you just got knocked out" to the spectator script.
	status:SetAttribute("RoundActive", false)
	status:SetAttribute("RoundMode", nil)
	status:SetAttribute("MatchPoint", nil)
	Twists.endRound()
	for _, player in Players:GetPlayers() do
		player:SetAttribute("InRound", nil)
	end

	for _, player in Players:GetPlayers() do
		player:LoadCharacter()
	end

	if #champions > 0 then
		local names = {}
		for _, player in champions do
			PlayerData.addCoins(player, COINS_PER_GAME_WIN)
			Levels.add(player, Levels.XP_WIN_GAME)
			table.insert(names, player.DisplayName)
			if player.Parent then
				questEvent:Fire(player, "WinGame", 1)
				Stats.gameWon(player)
			end
		end
		status.Value = table.concat(names, " & ") .. (#names == 1 and " WINS THE GAME!" or " WIN THE GAME!") .. "  +" .. COINS_PER_GAME_WIN .. " coins"
		-- AWARDS CEREMONY (ServerScriptService.GameEndCeremony): top 3 by wins on the podium, then a new game
		local ranking = {}
		for _, player in Players:GetPlayers() do
			local wins = getWins(player)
			if wins and wins.Value > 0 then table.insert(ranking, player) end
		end
		table.sort(ranking, function(a, b)
			local wa, wb = getWins(a).Value, getWins(b).Value
			if wa ~= wb then return wa > wb end
			return table.find(champions, a) ~= nil and table.find(champions, b) == nil
		end)
		if elimGame then ranking = Elim.ranking(champions[1]) end -- Elimination: the champion, then last cut first
		-- 2nd and 3rd place coins (the winners already got 1st place coins above)
		local place = 1
		for _, player in ranking do
			if not table.find(champions, player) then
				place += 1
				if not COINS_FOR_PLACE[place] then break end
				PlayerData.addCoins(player, COINS_FOR_PLACE[place])
			end
		end
		-- finishing bonus for everyone who stuck with the game
		for _, player in Players:GetPlayers() do
			if (gameRounds[player] or 0) >= ROUNDS_TO_FINISH_GAME then
				PlayerData.addCoins(player, COINS_FOR_FINISHING_GAME)
				Levels.add(player, Levels.XP_FINISH_GAME)
			end
		end
		table.clear(gameRounds)
		local okCeremony, ceremony = pcall(require, script.Parent:FindFirstChild("GameEndCeremony"))
		if okCeremony and ceremony then
			local ok, err = pcall(ceremony.play, ranking, getWins)
			if not ok then
				warn("Ceremony failed: " .. tostring(err))
				status:SetAttribute("CeremonyActive", false)
			end
		else
			task.wait(8)
		end
		for _, player in Players:GetPlayers() do
			local wins = getWins(player)
			if wins then wins.Value = 0 end
		end
		newGame = true
		Elim.gameOver() -- the next game's kind is decided at the top of the loop (Elim.prepare)
	end
end

-- VOTING PADS next to the Level 0 house (Workspace.Lobby.Lawn.VotingPads).
--   * Only 3 games are offered at a time. A new random set is rolled the moment a round starts
--     (never the game that's being played), so votes during a round count for the round after.
--   * Step on a pad = your vote. It STAYS until you step on a different pad - no need to stand there.
--   * RoundManager calls Voting.getLeader() when it picks the next map.
--   * A paid pick (ServerStorage.NextMapPick, from the Market's Game Picker) always beats the vote.
--   * The lobby's pads (Workspace.Lobby...Slot_VotingPads, parts named Pad with a Slot attribute)
--     count as votes too, and ReplicatedStorage.VoteBoard carries a 3D snapshot of each game on offer
--     (from ServerStorage.MapSnapshots) so the boards can show a picture of it (StarterPlayerScripts.VoteBoards).
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

------------------------------------------------------------------
-- SETTINGS
local NUM_OPTIONS = 3
local PAD_RADIUS = 4.9    -- studs from a pad's center that counts as "on the pad" (pads are 9 wide)
local CHECK_EVERY = 0.25  -- seconds
local ICONS = { VolcanoEscape = "🌋", HauntedRun = "🎃", SpinArena = "🌀", BrawlStage = "🥊", KaboomCanyon = "💣", RushHour = "🚦", ForestBall = "⚽", TugOfWar = "💪", PirateBattle = "🏴‍☠️", Speedway = "🏎️",
	Mansion = "🏚️", HideSchool = "🏫", HideCamp = "🏕️", SpinBar = "🌀", BumperCars = "🚙", BalloonShootout = "🎈", HexSpleef = "🐝", PaintParty = "🎨", SimonSays = "🤖", RedLightGreenLight = "🎃", PropHunt = "🛒", FindTheButton = "🔘", Deathrun = "☠️",
	Maze = "🌿", ConveyorChaos = "📦", HorseRace = "🐎", KingOfTheHill = "👑", CoinRush = "💰", SnowballFight = "❄️", BlockParty = "🕺", VolcanoRain = "☄️", HotPotato = "🥔", RisingFlood = "🌊", GlassBridge = "🌉", CaptureTheFlag = "🚩", ZombieInfection = "🧟", TriviaDoors = "❓", SpeedBuild = "🧱", MusicalChairs = "🪑", Mingle = "🎠",
	FreezeTag = "🧊", Dodgeball = "🔴", Disasters = "🌪️", SledRace = "🛷", LaserHeist = "💎", JungleLava = "🌴",
	DisasterCity = "🏙️", DisasterHotel = "🏨", DisasterPier = "🎡", MowerMadness = "🚜", MicroRacers = "🥣", NeonGrid = "⚡", LaserLab = "🔴", RocketSpleef = "🚀", Overseer = "👁️", MoonRun = "🌕", PenaltyShootout = "⚽",
	PizzaDelivery = "🍕", ImposterMall = "🕵️", MazeHunt = "👻", Speedway2 = "🏜️" }
local PALETTE = {
	Color3.fromRGB(255, 120, 120), Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 210, 70),
	Color3.fromRGB(120, 210, 120), Color3.fromRGB(80, 200, 200), Color3.fromRGB(90, 160, 255),
	Color3.fromRGB(160, 120, 240), Color3.fromRGB(240, 120, 200), Color3.fromRGB(255, 140, 170),
}
------------------------------------------------------------------

local Voting = {}
local pads = {}     -- pads[slot] = { model, pos, ring, dot, light, panel, id }
local islandPads = {} -- islandPads[slot] = position of that slot's pad on the island
local ISLAND_PAD_RADIUS = 6.8
local board = nil   -- ReplicatedStorage.VoteBoard (what the picture boards show)
local options = {}  -- options[slot] = map name on that pad right now
local votes = {}    -- votes[player] = map name they voted for (stays until they pick another pad)
local started = false
local lastSkip = nil -- the game being played right now (never offered)
local openMenu = ReplicatedStorage:WaitForChild("OpenMenu")
-- LOW-PLAYER SCALING (ServerScriptService.Extras.Scaling): the real minimum for each map (team games need 4),
-- and which games play WELL with the number of people here (those go on the pads first).
local Scaling = require(script.Parent:WaitForChild("Extras"):WaitForChild("Scaling"))

-- SMALL SERVERS: each map has a MinPlayers attribute (Hide & Seek needs 2, Mingle needs 3...).
-- Only games that can really be played with the people here (not counting AFK players) go on the pads.
local function activeCount()
	local n = 0
	for _, p in Players:GetPlayers() do
		if not p:GetAttribute("AFK") then n += 1 end
	end
	return math.max(n, 1)
end
function Voting.activeCount() return activeCount() end

-- FEATURED GAME OF THE DAY: one game pays DOUBLE coins all day (same game in every server).
-- It shows up on the pads more often and has "⭐ 2x" after its name. Changes at midnight UTC.
local FEATURED_ON_PADS_CHANCE = 0.5 -- chance the featured game is one of the 3 options (when it can be played)
local featuredDay, featuredId = nil, nil
function Voting.featured()
	local day = os.time() // 86400
	if day ~= featuredDay or not (featuredId and workspace.Maps:FindFirstChild(featuredId)) then
		local names = {}
		for _, m in workspace.Maps:GetChildren() do
			if not m:GetAttribute("NoFeature") and Voting.isReady(m.Name) then table.insert(names, m.Name) end
		end
		table.sort(names)
		featuredDay = day
		featuredId = #names > 0 and names[Random.new(day * 7919):NextInteger(1, #names)] or nil
		local status = ReplicatedStorage:FindFirstChild("Status")
		local map = featuredId and workspace.Maps:FindFirstChild(featuredId)
		if status then
			status:SetAttribute("FeaturedMap", featuredId)
			status:SetAttribute("FeaturedName", map and (map:GetAttribute("DisplayName") or map.Name) or nil)
			status:SetAttribute("FeaturedIcon", featuredId and (ICONS[featuredId] or "🎮") or nil)
		end
	end
	return featuredId
end
-- READY: a map only goes on the pads once its game-rules script exists in ServerScriptService.Modes
-- (so a map that's still being built never gets picked), and never if RoundManager marked it Broken
-- after it crashed this server.
function Voting.isReady(id)
	local m = workspace.Maps:FindFirstChild(id)
	if not m or m:GetAttribute("Broken") or m:GetAttribute("FinaleOnly") then return false end -- FinaleOnly = the Final Showdown
	return script.Parent:FindFirstChild("Modes") ~= nil and script.Parent.Modes:FindFirstChild(m:GetAttribute("Mode") or "Race") ~= nil
end
-- NO REPEATS: a game type can't come back until NO_REPEAT other games have been played.
-- RoundManager keeps the last game types in the Status attribute RecentModes (newest first, comma-separated).
-- It goes by game TYPE, so Hide & Seek on the School map counts as a repeat of Hide & Seek in the Mansion.
Voting.NO_REPEAT = 5
function Voting.isRecent(id)
	local m = workspace.Maps:FindFirstChild(id)
	local status = ReplicatedStorage:FindFirstChild("Status")
	if not m or not status then return false end
	local mode = m:GetAttribute("Mode") or "Race"
	for name in (status:GetAttribute("RecentModes") or ""):gmatch("[^,]+") do
		if name == mode then return true end
	end
	return false
end
function Voting.isPlayable(id, count)
	local m = workspace.Maps:FindFirstChild(id)
	return m ~= nil and Voting.isReady(id) and Scaling.minPlayers(m) <= (count or activeCount())
end

local function mapColor(id)
	-- the same game always gets the same color
	local names = {}
	for _, m in workspace.Maps:GetChildren() do table.insert(names, m.Name) end
	table.sort(names)
	for i, n in names do
		if n == id then return PALETTE[(i - 1) % #PALETTE + 1] end
	end
	return Color3.new(1, 1, 1)
end

local function displayName(id)
	local map = workspace.Maps:FindFirstChild(id)
	return map and map:GetAttribute("DisplayName") or id
end

-- the name shown on pads / boards (the featured game gets a star)
local function padName(id)
	local n = displayName(id)
	if id == Voting.featured() then n ..= " ⭐2x" end
	return n
end

local LobbyRef = require(script.Parent:WaitForChild("LobbyRef")) -- this week's lobby (LobbyManager)

-- the old lawn-style pads (VotePad models), if this week's lobby has them
local function findPads()
	local folder = LobbyRef.find("VotingPads")
	if not folder then return nil end
	for _, model in folder:GetChildren() do
		local slot = model:GetAttribute("Slot")
		if slot then
			pads[slot] = {
				model = model, pos = model.Pad.Position, ring = model.Ring, dot = model.Dot,
				light = model.Pad:FindFirstChildOfClass("PointLight"), panel = model.Sign.VoteGui.Panel,
			}
		end
	end
	return folder:FindFirstChild("VoteBanner")
end

local function findIslandPads()
	table.clear(islandPads)
	local lobby = workspace:FindFirstChild("Lobby")
	local f = lobby and lobby:FindFirstChild("Slot_VotingPads", true)
	if not f then return end
	for _, p in f:GetChildren() do
		if p.Name == "Pad" and p:GetAttribute("Slot") then islandPads[p:GetAttribute("Slot")] = p.Position end
	end
end

-- copy the games on offer (name, icon, colour and a 3D snapshot) to ReplicatedStorage.VoteBoard
local function publish()
	if not board then
		board = ReplicatedStorage:FindFirstChild("VoteBoard") or Instance.new("Folder")
		board.Name = "VoteBoard"
		board.Parent = ReplicatedStorage
	end
	board:ClearAllChildren()
	local snaps = ServerStorage:FindFirstChild("MapSnapshots")
	for slot = 1, NUM_OPTIONS do
		local id = options[slot]
		board:SetAttribute("Map" .. slot, id)
		board:SetAttribute("Name" .. slot, id and padName(id) or "")
		board:SetAttribute("Icon" .. slot, id and (ICONS[id] or "🎮") or "")
		board:SetAttribute("Color" .. slot, id and mapColor(id) or Color3.new(1, 1, 1))
		local snap = id and snaps and snaps:FindFirstChild(id)
		-- NO PICTURE YET? (a brand-new game, or one added since the pictures were last made.) Take its picture now,
		-- once, so a voting pad never shows an empty board. It needs the map's PreviewCam attribute.
		if id and not snap then
			local map = workspace:FindFirstChild("Maps") and workspace.Maps:FindFirstChild(id)
			local builder = ServerStorage:FindFirstChild("MapSnapshotBuilder")
			if map and builder then
				local ok, made = pcall(function() return require(builder).build(map) end)
				if ok and made then
					if not snaps then
						snaps = Instance.new("Folder")
						snaps.Name = "MapSnapshots"
						snaps.Parent = ServerStorage
					end
					made.Parent = snaps
					snap = made
				elseif not ok then
					warn("[Voting] couldn't make a picture of " .. id .. ": " .. tostring(made))
				end
			end
		end
		if snap then
			local c = snap:Clone()
			c.Name = "Slot" .. slot
			c.Parent = board
		end
	end
	board:SetAttribute("Serial", (board:GetAttribute("Serial") or 0) + 1)
end

-- pick NUM_OPTIONS random games (skipping the one just played) and put them on the pads
local function setSlot(slot, id)
	options[slot] = id
	local pad = pads[slot]
	if pad then
		pad.model:SetAttribute("MapId", id)
		local color = id and mapColor(id) or Color3.new(1, 1, 1)
		pad.ring.Color, pad.dot.Color, pad.light.Color = color, color, color
		pad.panel.CountBg.BackgroundColor3 = color
		pad.panel.Icon.Text = id and (ICONS[id] or "🎮") or ""
		pad.panel.GameName.Text = id and padName(id) or ""
	end
end

function Voting.rollOptions(skipId)
	lastSkip = skipId
	local count = activeCount()
	local pool = {}
	for _, m in workspace.Maps:GetChildren() do
		if m.Name ~= skipId and Voting.isPlayable(m.Name, count) and not Voting.isRecent(m.Name) then table.insert(pool, m.Name) end
	end
	if #pool < NUM_OPTIONS then -- tiny server with few playable games: allow recent ones rather than empty pads
		for _, m in workspace.Maps:GetChildren() do
			if m.Name ~= skipId and Voting.isPlayable(m.Name, count) and not table.find(pool, m.Name) then table.insert(pool, m.Name) end
		end
	end
	if #pool == 0 then -- should never happen, but never leave the pads empty
		for _, m in workspace.Maps:GetChildren() do
			if m.Name ~= skipId then table.insert(pool, m.Name) end
		end
	end
	for i = #pool, 2, -1 do -- shuffle
		local j = math.random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	-- SMALL SERVERS: games that play well with this many players go to the front of the (shuffled) line, so the
	-- pads fill up with those first. Games that only just work with this few players are the fallback.
	do
		local good, rest = {}, {}
		for _, id in pool do
			local m = workspace.Maps:FindFirstChild(id)
			if m and Scaling.isIdeal(m, count) then table.insert(good, id) else table.insert(rest, id) end
		end
		pool = good
		for _, id in rest do table.insert(pool, id) end
	end
	-- the featured game gets a better chance of being on the pads
	local feat = Voting.featured()
	local at = feat and table.find(pool, feat)
	if at and at > NUM_OPTIONS and math.random() < FEATURED_ON_PADS_CHANCE then
		local slot = math.random(NUM_OPTIONS)
		pool[at], pool[slot] = pool[slot], pool[at]
	end
	table.clear(options)
	table.clear(votes)
	for _, p in Players:GetPlayers() do p:SetAttribute("VotedFor", nil) end
	for slot = 1, NUM_OPTIONS do
		setSlot(slot, pool[slot])
	end
	publish()
end

-- someone left (or went AFK) and a game on the pads now needs more players than are here:
-- swap just that pad for a game that works, and tell the people who voted for it
local function swapUnplayable()
	if #options == 0 then return end
	local count = activeCount()
	local changed = false
	for slot = 1, NUM_OPTIONS do
		local id = options[slot]
		if id and not Voting.isPlayable(id, count) then
			local pool = {}
			for _, m in workspace.Maps:GetChildren() do
				if m.Name ~= lastSkip and not table.find(options, m.Name) and Voting.isPlayable(m.Name, count) and not Voting.isRecent(m.Name) then
					table.insert(pool, m.Name)
				end
			end
			if #pool > 0 then
				local newId = pool[math.random(#pool)]
				for player, v in votes do
					if v == id then
						votes[player] = nil
						if player.Parent then
							player:SetAttribute("VotedFor", nil)
							openMenu:FireClient(player, "Toast", displayName(id) .. " needs more players, so it was swapped for " .. displayName(newId) .. ". Vote again!", true)
						end
					end
				end
				setSlot(slot, newId)
				changed = true
			end
		end
	end
	if changed then publish() end
end

local function counts()
	local c = {}
	for _, id in options do c[id] = 0 end
	for player, id in votes do
		if player.Parent and c[id] and not player:GetAttribute("AFK") then c[id] += 1 end -- AFK players' votes don't count
	end
	return c
end

-- which pad (if any) each player is standing on; standing on one changes their saved vote
local function checkStanding()
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 and not player:GetAttribute("InRound") then
			local p = root.Position
			for slot, pad in pads do
				local id = options[slot]
				local flat = Vector2.new(p.X - pad.pos.X, p.Z - pad.pos.Z).Magnitude
				if id and flat <= PAD_RADIUS and p.Y > pad.pos.Y and p.Y < pad.pos.Y + 8 and votes[player] ~= id then
					votes[player] = id
					player:SetAttribute("VotedFor", id)
					openMenu:FireClient(player, "Toast", "You voted for " .. displayName(id) .. "! Your vote stays until you pick another pad.", true)
					break
				end
			end
			for slot, pos in islandPads do
				local id = options[slot]
				local flat = Vector2.new(p.X - pos.X, p.Z - pos.Z).Magnitude
				if id and flat <= ISLAND_PAD_RADIUS and p.Y > pos.Y and p.Y < pos.Y + 8 and votes[player] ~= id then
					votes[player] = id
					player:SetAttribute("VotedFor", id)
					openMenu:FireClient(player, "Toast", "You voted for " .. displayName(id) .. "! Your vote stays until you pick another pad.", true)
					break
				end
			end
		end
	end
end

-- the game with the most votes (nil if nobody has voted).
-- randomTies = true picks randomly between tied games (used for the real pick);
-- false returns the first one so the status text doesn't flicker.
function Voting.getLeader(randomTies)
	Voting.start()
	local c = counts()
	local best, tied = 0, {}
	for _, id in options do
		local n = c[id] or 0
		if n > best then
			best, tied = n, { id }
		elseif n == best and n > 0 then
			table.insert(tied, id)
		end
	end
	if best == 0 then return nil, 0 end
	if randomTies then return tied[math.random(#tied)], best end
	return tied[1], best
end

function Voting.getCounts()
	return counts()
end

-- the map names on the pads right now (RoundManager picks from these when nobody voted)
function Voting.getOptions()
	Voting.start()
	local list = {}
	for _, id in options do table.insert(list, id) end
	return list
end

-- update the signs, rings and lights
local function redraw(banner, nextPick)
	local picked = nextPick.Value ~= "" and nextPick.Value or nil
	local c = counts()
	local best = 0
	for _, n in c do best = math.max(best, n) end
	for slot, pad in pads do
		local id = options[slot]
		local n = id and c[id] or 0
		local text = n == 1 and "1 vote" or n .. " votes"
		if picked then
			pad.panel.Votes.Text = id == picked and "PICKED!" or text
			pad.ring.Transparency = id == picked and 0 or 0.65
			pad.light.Brightness = id == picked and 2.5 or 0.2
		else
			local leading = n > 0 and n == best
			pad.panel.Votes.Text = (leading and "👑 " or "") .. text
			pad.ring.Transparency = 0
			pad.light.Brightness = leading and 2.5 or (n > 0 and 1.4 or 0.8)
		end
	end
	if board then
		local leaderSlot = 0
		for slot = 1, NUM_OPTIONS do
			local id = options[slot]
			local n = id and c[id] or 0
			board:SetAttribute("Votes" .. slot, n)
			if n > 0 and n == best then leaderSlot = slot end
		end
		local pickedSlot = 0
		for slot = 1, NUM_OPTIONS do if picked and options[slot] == picked then pickedSlot = slot end end
		board:SetAttribute("Leader", leaderSlot)
		board:SetAttribute("Picked", pickedSlot)
	end
	if banner then
		local sub = banner.Board.BannerGui.Sub
		if picked then
			sub.Text = (nextPick:GetAttribute("PickedBy") or "Someone") .. " paid to pick " .. displayName(picked) .. " - votes count next time!"
		else
			sub.Text = "Step on a pad to vote - it stays until you change it"
		end
	end
end

function Voting.start()
	if started then return end
	started = true
	local banner = findPads()
	findIslandPads()
	workspace.DescendantAdded:Connect(function(d) -- the island got rebuilt / streamed: find its pads again
		if d.Name == "Slot_VotingPads" then task.delay(1, findIslandPads) end
	end)
	local nextPick = ServerStorage:WaitForChild("NextMapPick")
	local status = ReplicatedStorage:WaitForChild("Status")
	Voting.rollOptions(nil)
	-- a round just started: its map was already picked, so offer 3 new games for the next one
	status:GetAttributeChangedSignal("RoundActive"):Connect(function()
		if status:GetAttribute("RoundActive") then
			local playing = status:GetAttribute("RoundMap")
			local skip
			for _, m in workspace.Maps:GetChildren() do
				if (m:GetAttribute("DisplayName") or m.Name) == playing then skip = m.Name end
			end
			Voting.rollOptions(skip)
		end
	end)
	Players.PlayerRemoving:Connect(function(p) votes[p] = nil end)
	task.spawn(function()
		local sinceSwapCheck = 0
		while true do
			checkStanding()
			sinceSwapCheck += CHECK_EVERY
			if sinceSwapCheck >= 2 then
				sinceSwapCheck = 0
				swapUnplayable()
			end
			redraw(banner, nextPick)
			task.wait(CHECK_EVERY)
		end
	end)
end

return Voting

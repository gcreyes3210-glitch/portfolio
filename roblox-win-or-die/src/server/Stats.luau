-- LIFETIME STATS + BADGES
-- RoundManager tells this module when someone plays a round, wins a round, or wins a whole game.
-- It keeps each player's all-time numbers (saved with PlayerData as "stats"), hands out badges,
-- and the lobby leaderboards (LobbyExtras) read the numbers from here.
--   saved stats = { wins = 12, played = 40, gameWins = 1, modesWon = { HorseRace = true, ... }, badges = { FirstWin = true },
--                   days = 3, lastDay = 20360, quests = 7, achieved = { Regular = true }, title = "Regular" }
-- ACHIEVEMENTS (ReplicatedStorage.Achievements) unlock here too, and each one becomes a title.
-- Player attributes (for the menus / nametags): TotalWins, GamesPlayed, GameWins, ModesWon, DaysPlayed, QuestsDone, Title
local Players = game:GetService("Players")
local BadgeService = game:GetService("BadgeService")
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Achievements = require(game:GetService("ReplicatedStorage"):WaitForChild("Achievements"))
local catalog = require(game:GetService("ReplicatedStorage"):WaitForChild("Cosmetics"))

------------------------------------------------------------------
-- BADGES: make them on the Creator Dashboard (Creations > WIN or DIE > Engagement > Badges),
-- then paste each badge's ID here. 0 = not made yet (nobody gets it, nothing breaks).
local BADGES = {
	FirstWin = { id = 0, name = "First Win!", icon = "⭐", text = "Win your first round" },
	Champion = { id = 0, name = "Champion", icon = "👑", text = "Win a whole game (first to 5)" },
	AllModes = { id = 0, name = "Master of Everything", icon = "🏅", text = "Win a round of EVERY game mode" },
}
local BADGE_ORDER = { "FirstWin", "Champion", "AllModes" }

-- how each game MODE is called on the Quest Board (a mode can have several maps, e.g. Hide & Seek)
local MODE_INFO = {
	Race = { name = "Lava Obby", icon = "🌋" },
	BallPush = { name = "Forest Ball Push", icon = "⚽" },
	TugOfWar = { name = "Sky Tug of War", icon = "💪" },
	PirateBattle = { name = "Pirate Battle", icon = "🏴‍☠️" },
	KartRace = { name = "Grand Prix", icon = "🏎️" },
	HideAndSeek = { name = "Hide & Seek", icon = "🙈" },
	SpinBar = { name = "Spinning Bar", icon = "🌀" },
	BalloonShoot = { name = "Balloon Shootout", icon = "🎈" },
	HexSpleef = { name = "Hex Spleef", icon = "🐝" },
	PaintParty = { name = "Paint Party", icon = "🎨" },
	SimonSays = { name = "Simon Says", icon = "🤖" },
	RedLightGreenLight = { name = "Red Light, Green Light", icon = "🎃", easyWins = true }, -- lots of winners per round
	PropHunt = { name = "Prop Hunt", icon = "🛒" },
	FindTheButton = { name = "Find the Button", icon = "🔘" },
	Deathrun = { name = "Temple Deathrun", icon = "☠️" },
	Maze = { name = "Escape the Maze", icon = "🌿" },
	HorseRace = { name = "Horse Race", icon = "🐎" },
	BumperCars = { name = "Bumper Cars", icon = "🚙" },
	KingOfTheHill = { name = "King of the Hill", icon = "👑" },
	CoinRush = { name = "Coin Rush", icon = "💰" },
	SnowballFight = { name = "Snowball Fight", icon = "❄️" },
	BlockParty = { name = "Block Party", icon = "🕺" },
	HotPotato = { name = "Hot Potato", icon = "🥔" },
	RisingFlood = { name = "Rising Flood", icon = "🌊" },
	GlassBridge = { name = "Glass Bridge", icon = "🌉" },
	CaptureTheFlag = { name = "Capture the Flag", icon = "🚩" },
	ZombieInfection = { name = "Zombie Infection", icon = "🧟" },
	TriviaDoors = { name = "Trivia Doors", icon = "❓" },
	SpeedBuild = { name = "Speed Build", icon = "🧱" },
	MusicalChairs = { name = "Musical Chairs", icon = "🪑" },
	Mingle = { name = "Mingle", icon = "🎠" },
	ConveyorChaos = { name = "Conveyor Chaos", icon = "📦" },
	LaserLab = { name = "Laser Lab", icon = "🔴" },
	VolcanoRain = { name = "Volcano Eruption", icon = "☄️" },
	FinalShowdown = { name = "Final Showdown", icon = "🏆" },
}
------------------------------------------------------------------

local Stats = {}
local openMenu = game:GetService("ReplicatedStorage"):WaitForChild("OpenMenu")

-- every mode that has at least one map in Workspace.Maps (so the "win every mode" badge counts real ones)
function Stats.allModes()
	local set, list = {}, {}
	for _, map in workspace:WaitForChild("Maps"):GetChildren() do
		local mode = map:GetAttribute("Mode")
		-- (FinaleOnly maps - the Final Showdown - aren't part of "win every mode": most players never get to play it)
		if mode and not set[mode] and not map:GetAttribute("FinaleOnly") then
			set[mode] = true
			table.insert(list, mode)
		end
	end
	table.sort(list)
	return list, set
end

function Stats.modeInfo(mode)
	local info = MODE_INFO[mode]
	if info then return info end
	-- a brand-new mode nobody added above yet: use its map's DisplayName
	for _, map in workspace.Maps:GetChildren() do
		if map:GetAttribute("Mode") == mode then return { name = map:GetAttribute("DisplayName") or mode, icon = "🎮" } end
	end
	return { name = mode, icon = "🎮" }
end

local function data(player)
	local s = PlayerData.getSaved(player, "stats")
	if not s then return nil end
	s.wins = s.wins or 0
	s.played = s.played or 0
	s.gameWins = s.gameWins or 0
	s.modesWon = s.modesWon or {}
	s.badges = s.badges or {}
	s.days = s.days or 0
	s.quests = s.quests or 0
	s.achieved = s.achieved or {}
	s.mastery = s.mastery or {} -- mastery XP per game mode: { HexSpleef = 24, ... }
	return s
end
Stats.get = data

------------------------------------------------------------------ mode mastery
-- coins for reaching each rank (index = rank: 2 Silver, 3 Gold, 4 Diamond, 5 MASTER)
local MASTERY_COINS = { [2] = 25, [3] = 50, [4] = 100, [5] = 200 }
local MASTERY_PLAY_XP, MASTERY_WIN_XP = 1, 3

local function addMastery(player, s, mode, xp)
	if not mode then return end
	local before = s.mastery[mode] or 0
	local after = before + xp
	s.mastery[mode] = after
	local oldIdx = Achievements.masteryRank(before)
	local newIdx, rank = Achievements.masteryRank(after)
	if newIdx > oldIdx then
		local coins = MASTERY_COINS[newIdx] or 0
		if coins > 0 then PlayerData.addCoins(player, coins) end
		local name = Stats.modeInfo(mode).name
		local extra = newIdx == #Achievements.MASTERY_RANKS and " New title unlocked!" or ""
		task.delay(3, function() -- after the round's own messages
			if player.Parent then
				openMenu:FireClient(player, "Toast", rank.icon .. " " .. name .. " mastery: " .. string.upper(rank.name) .. "!  +" .. coins .. " coins." .. extra, true)
			end
		end)
	end
	-- for menus: your XP in the mode that was just played
	player:SetAttribute("Mastery_" .. mode, after)
end

-- for the Mastery page: { { mode, name, icon, xp, rank, rankName, rankIcon, nextXp }, ... }
function Stats.masteryList(player)
	local s = data(player)
	if not s then return nil end
	local list = {}
	for _, m in Achievements.MASTERY_MODES do
		local xp = s.mastery[m.mode] or 0
		local idx, rank, nextXp = Achievements.masteryRank(xp)
		table.insert(list, { mode = m.mode, name = m.name, icon = m.icon, xp = xp, rank = idx, rankName = rank.name, rankIcon = rank.icon, nextXp = nextXp })
	end
	return list
end

------------------------------------------------------------------ achievements + titles
-- every number an achievement can count
function Stats.progress(player)
	local s = data(player)
	if not s then return nil end
	local list, real = Stats.allModes()
	local modes = 0
	for mode in s.modesWon do if real[mode] then modes += 1 end end
	local owned, emotes = 0, 0
	for _, item in catalog do
		if PlayerData.owns(player, item.id) then
			if item.category == "Emote" then emotes += 1 elseif not item.vip then owned += 1 end
		end
	end
	local values = { joined = 1, days = s.days, played = s.played, wins = s.wins, gameWins = s.gameWins,
		modes = modes, quests = s.quests, owned = owned, emotes = emotes }
	for _, m in Achievements.MASTERY_MODES do
		values["mastery_" .. m.mode] = s.mastery[m.mode] or 0
	end
	return values, #list
end

local function goalOf(a, modeCount) return a.goal == "all" and modeCount or a.goal end

-- the title someone shows above their name (checked, so a removed achievement can't stick)
local function titleOf(player, s)
	if s.title == "VIP" and player:GetAttribute("VIP") then return "VIP" end
	if s.title and s.achieved[s.title] and Achievements.byId[s.title] then return s.title end
	return Achievements.DEFAULT_TITLE
end

local function publish(player, s)
	player:SetAttribute("TotalWins", s.wins)
	player:SetAttribute("GamesPlayed", s.played)
	player:SetAttribute("GameWins", s.gameWins)
	player:SetAttribute("DaysPlayed", s.days)
	player:SetAttribute("QuestsDone", s.quests)
	local count = 0
	local _, real = Stats.allModes()
	for mode in s.modesWon do if real[mode] then count += 1 end end
	player:SetAttribute("ModesWon", count)
	player:SetAttribute("Title", titleOf(player, s))
end

-- unlock any achievement whose goal is reached (with a toast, except the free "Newbie" one)
function Stats.check(player)
	local s = data(player)
	local values, modeCount = Stats.progress(player)
	if not s or not values then return end
	for _, a in Achievements.LIST do
		if not s.achieved[a.id] and (values[a.stat] or 0) >= goalOf(a, modeCount) then
			s.achieved[a.id] = true
			if a.id ~= Achievements.DEFAULT_TITLE then
				openMenu:FireClient(player, "Toast", "🏆 Achievement: " .. a.name .. "! New title unlocked - pick it in ACHIEVEMENTS", true)
				PlayerData.saveSoon(player)
			end
		end
	end
end

-- for the Achievements window
function Stats.achievementList(player)
	local s = data(player)
	local values, modeCount = Stats.progress(player)
	if not s or not values then return nil end
	local list = {}
	for _, a in Achievements.LIST do
		local goal = goalOf(a, modeCount)
		table.insert(list, { id = a.id, progress = math.min(values[a.stat] or 0, goal), goal = goal, unlocked = s.achieved[a.id] == true })
	end
	return { list = list, title = titleOf(player, s), vip = player:GetAttribute("VIP") == true }
end

function Stats.setTitle(player, id)
	local s = data(player)
	if not s then return false, "Still loading - try again!" end
	if id == "VIP" then
		if not player:GetAttribute("VIP") then return false, "The VIP title comes with the VIP game pass." end
	elseif not (Achievements.byId[id] and s.achieved[id]) then
		return false, "Unlock that achievement first!"
	end
	s.title = id
	publish(player, s)
	PlayerData.saveSoon(player)
	local name = id == "VIP" and Achievements.VIP_TITLE.name or Achievements.byId[id].name
	return true, "Now showing: " .. name
end

function Stats.questDone(player)
	local s = data(player)
	if not s then return end
	s.quests += 1
	publish(player, s)
	Stats.check(player)
end

local function award(player, key)
	local s = data(player)
	if not s or s.badges[key] then return end
	local badge = BADGES[key]
	s.badges[key] = true -- remembered even while the ID is 0, so it's handed out once the badge exists
	PlayerData.saveSoon(player)
	openMenu:FireClient(player, "Toast", badge.icon .. " Badge unlocked: " .. badge.name .. "!", true)
	if badge.id ~= 0 then
		task.spawn(function()
			local ok, err = pcall(BadgeService.AwardBadge, BadgeService, player.UserId, badge.id)
			if not ok then warn("Badge " .. key .. " failed: " .. tostring(err)) end
		end)
	end
end

-- a player who earned a badge BEFORE its ID was filled in gets the real Roblox badge next time they join
local function catchUp(player)
	if not PlayerData.waitLoaded(player) then return end
	local s = data(player)
	if not s then return end
	-- "played on N different days"
	local today = os.time() // 86400
	if s.lastDay ~= today then
		s.lastDay = today
		s.days += 1
	end
	publish(player, s)
	Stats.check(player)
	-- buying things counts toward the collecting achievements; VIP changes which titles you can pick
	local owned = player:WaitForChild("OwnedCosmetics", 10)
	if owned then owned.ChildAdded:Connect(function() Stats.check(player) end) end
	player:GetAttributeChangedSignal("VIP"):Connect(function() publish(player, s) end)
	for key, owned in s.badges do
		local badge = BADGES[key]
		if owned and badge and badge.id ~= 0 then
			local ok, has = pcall(BadgeService.UserHasBadgeAsync, BadgeService, player.UserId, badge.id)
			if ok and not has then pcall(BadgeService.AwardBadge, BadgeService, player.UserId, badge.id) end
		end
	end
end
Players.PlayerAdded:Connect(catchUp)
for _, p in Players:GetPlayers() do task.spawn(catchUp, p) end

function Stats.roundPlayed(player, mode)
	local s = data(player)
	if not s then return end
	s.played += 1
	addMastery(player, s, mode, MASTERY_PLAY_XP)
	publish(player, s)
	Stats.check(player)
end

function Stats.roundWon(player, mode)
	local s = data(player)
	if not s then return end
	s.wins += 1
	if mode then s.modesWon[mode] = true end
	addMastery(player, s, mode, MASTERY_WIN_XP)
	publish(player, s)
	Stats.check(player)
	award(player, "FirstWin")
	local list = Stats.allModes()
	for _, m in list do
		if not s.modesWon[m] then return end
	end
	award(player, "AllModes")
end

function Stats.gameWon(player)
	local s = data(player)
	if not s then return end
	s.gameWins += 1
	publish(player, s)
	Stats.check(player)
	award(player, "Champion")
end

-- for the BADGES page of the Quest window
function Stats.badgeList(player)
	local s = data(player)
	if not s then return {} end
	local modes = Stats.allModes()
	local won = 0
	for _, m in modes do if s.modesWon[m] then won += 1 end end
	local missing = {}
	for _, m in modes do
		if not s.modesWon[m] then table.insert(missing, Stats.modeInfo(m).icon) end
	end
	local list = {}
	for _, key in BADGE_ORDER do
		local b = BADGES[key]
		local progress, goal = s.badges[key] and 1 or 0, 1
		if key == "AllModes" then progress, goal = won, #modes end
		if key == "FirstWin" then progress = math.min(s.wins, 1) end
		table.insert(list, {
			id = key, text = b.name .. ": " .. b.text, icon = b.icon, owned = s.badges[key] == true,
			progress = s.badges[key] and goal or progress, goal = goal,
			missing = key == "AllModes" and table.concat(missing, " ") or nil,
		})
	end
	return list
end

return Stats

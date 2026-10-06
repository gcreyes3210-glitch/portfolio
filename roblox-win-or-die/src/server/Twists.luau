-- ROUND TWISTS: about 1 in 4 rounds gets a random modifier that changes how the game plays.
-- RoundManager calls Twists.pick() after choosing the map, Twists.startRound() before the mode starts,
-- and Twists.endRound() when it's over. The twist is shown on screen by StarterPlayerScripts.TwistClient,
-- which also does the client-side effects (low gravity, slippery feet, darkness + head lamp).
--
-- TESTING: select RoundManager and set the attribute ForceTwist (string) to a twist id below, e.g. "Night".
--          Set it to "None" to turn twists off. REMOVE it before publishing!
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

------------------------------------------------------------------
-- SETTINGS
local TWIST_CHANCE = 0.25 -- chance a round gets a twist
local TINY_SCALE = 0.55   -- how small everyone gets in a Tiny round

-- each twist: name + icon + one-line description, which modes it works in ("*" = all),
-- maps it never goes on, and how likely it is compared to the others
local TWISTS = {
	LowGravity = {
		name = "Low Gravity", icon = "🪐", text = "Everyone jumps sky-high!", weight = 3,
		modes = { "SpinBar", "HexSpleef", "BlockParty", "CoinRush", "KingOfTheHill", "PaintParty", "HotPotato",
			"RisingFlood", "SnowballFight", "ZombieInfection", "CaptureTheFlag", "Mingle", "ConveyorChaos", "FreezeTag", "Dodgeball", "VolcanoRain" },
	},
	Tiny = {
		name = "Tiny Mode", icon = "🐜", text = "Everyone is shrunk to bug size!", weight = 3,
		modes = { "HideAndSeek", "CoinRush", "PaintParty", "KingOfTheHill", "ZombieInfection", "CaptureTheFlag",
			"SnowballFight", "FindTheButton", "Maze", "HotPotato", "RisingFlood", "Mingle", "BlockParty",
			"ConveyorChaos", "SpinBar", "HexSpleef", "FreezeTag" },
	},
	Night = {
		name = "Lights Out", icon = "🔦", text = "It's dark! You have a head lamp.", weight = 3,
		modes = { "HideAndSeek", "Maze", "FindTheButton", "ZombieInfection", "CaptureTheFlag", "CoinRush",
			"KingOfTheHill", "SnowballFight", "HexSpleef", "SpinBar", "Race", "FreezeTag", "Disasters", "LaserHeist", "SledRace", "VolcanoRain" },
		notMaps = { "Mansion" }, -- already night-time
	},
	Ice = {
		name = "Ice Floors", icon = "🧊", text = "Every floor is slippery!", weight = 3,
		-- not in games that knock you around (King of the Hill, Snowball Fight, Spinning Bar): the ice would soak up the hits
		modes = { "HexSpleef", "BlockParty", "HotPotato", "CoinRush", "PaintParty", "Mingle", "ZombieInfection", "CaptureTheFlag", "FreezeTag", "VolcanoRain" },
	},
	DoubleWins = {
		name = "Double Wins", icon = "✨", text = "Winning this round counts as 2 wins!", weight = 2,
		modes = "*",
	},
}
------------------------------------------------------------------

local Twists = {}
Twists.LIST = TWISTS

local status = ReplicatedStorage:WaitForChild("Status")
local roundManager = script.Parent:WaitForChild("RoundManager")
local current = nil   -- twist id for this round (nil = no twist)
local lastTwist = nil -- never the same twist twice in a row
local preferred = nil -- GHOST VOTE (Extras.Spectators): the twist the spectators voted for the next round

-- knocked-out players vote for the next round's twist; it's used if it fits the game that gets played
function Twists.prefer(id)
	if TWISTS[id] then preferred = id end
end

local function fits(id, info, modeName, mapId)
	if info.notMaps and table.find(info.notMaps, mapId) then return false end
	return info.modes == "*" or table.find(info.modes, modeName) ~= nil
end

-- choose this round's twist (or nil). Also used by the intro card text.
function Twists.pick(modeName, mapId)
	local forced = roundManager:GetAttribute("ForceTwist")
	if forced == "None" then return nil end
	if forced and TWISTS[forced] then return forced end
	status:SetAttribute("TwistBy", nil)
	if preferred then -- the ghosts' pick: a sure thing when it fits this game (used up either way)
		local id = preferred
		preferred = nil
		if fits(id, TWISTS[id], modeName, mapId) then
			status:SetAttribute("TwistBy", "ghosts")
			return id
		end
	end
	if math.random() > TWIST_CHANCE then return nil end
	local pool, total = {}, 0
	for id, info in TWISTS do
		if id ~= lastTwist and fits(id, info, modeName, mapId) then
			table.insert(pool, id)
			total += info.weight
		end
	end
	if total == 0 then return nil end
	local r = math.random() * total
	for _, id in pool do
		r -= TWISTS[id].weight
		if r <= 0 then return id end
	end
	return pool[#pool]
end

local function shrink(character)
	if current ~= "Tiny" or not character then return end
	local hum = character:WaitForChild("Humanoid", 5)
	if not hum or not character.Parent then return end
	task.wait() -- let the mode place the character first
	if character.Parent and character:GetScale() > TINY_SCALE + 0.01 then
		character:ScaleTo(TINY_SCALE)
	end
end

-- Lights Out: a head lamp everyone can see (so you can spot other players' beams in the dark)
local function addLamp(character)
	if current ~= "Night" or not character then return end
	local head = character:WaitForChild("Head", 5)
	if not head or head:FindFirstChild("TwistLamp") then return end
	local att = Instance.new("Attachment")
	att.Name = "TwistLamp"
	att.Position = Vector3.new(0, 0.2, -0.5)
	att.Parent = head
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Front
	spot.Angle = 65
	spot.Range = 48
	spot.Brightness = 3.2
	spot.Color = Color3.fromRGB(255, 240, 205)
	spot.Shadows = true
	spot.Parent = att
	local glow = Instance.new("PointLight") -- a soft glow so nobody is completely invisible
	glow.Range = 7
	glow.Brightness = 0.6
	glow.Color = Color3.fromRGB(255, 225, 170)
	glow.Parent = att
end

-- right before the mode starts
function Twists.startRound(id, players)
	current = id
	if id then lastTwist = id end
	local info = id and TWISTS[id]
	status:SetAttribute("Twist", id)
	status:SetAttribute("TwistName", info and info.name or nil)
	status:SetAttribute("TwistIcon", info and info.icon or nil)
	status:SetAttribute("TwistText", info and info.text or nil)
end

-- after the mode has spawned everyone (server-side effects)
function Twists.afterStart(players)
	if current == "Tiny" then
		for _, p in players do task.spawn(shrink, p.Character) end
	elseif current == "Night" then
		for _, p in players do task.spawn(addLamp, p.Character) end
	end
end

-- a player respawned mid-round (RoundManager calls this from CharacterAdded)
function Twists.onCharacter(player, character)
	if current == "Tiny" then task.spawn(shrink, character)
	elseif current == "Night" then task.spawn(addLamp, character) end
end

-- how many wins a round win is worth this round
function Twists.winValue()
	return current == "DoubleWins" and 2 or 1
end

function Twists.current() return current end

function Twists.endRound()
	current = nil
	status:SetAttribute("Twist", nil)
	status:SetAttribute("TwistName", nil)
	status:SetAttribute("TwistIcon", nil)
	status:SetAttribute("TwistText", nil)
end

return Twists

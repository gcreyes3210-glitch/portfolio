-- KING OF THE HILL (everyone for themselves, nobody gets knocked out).
--  * Everyone starts round the bottom of a big grassy hill inside a castle courtyard.
--  * On top is a glowing golden CROWN ZONE. Stand in it to score points:
--      - alone in the zone  = you're the KING: +3 points a second and you wear a crown
--      - sharing the zone   = +1 point a second each
--  * Everyone gets a BONK BOPPER (click / tap) that knocks people flying. Knock them off the top!
--  * Last 20 seconds = DOUBLE POINTS.
--  * First to 100 points wins straight away. Otherwise, most points when the clock runs out wins.
-- The map is built by ServerStorage.KingHillBuilder. The score panel + the spinning crown statue
-- are in StarterPlayerScripts.KingHillUI (it reads the attributes this script sets).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local openMenu = ReplicatedStorage:WaitForChild("OpenMenu") -- LobbyUI shows "Toast" messages
local assets = ServerStorage:WaitForChild("KingHillAssets")
local Boost = require(script.Parent.Parent:WaitForChild("Boost")) -- boosted players get knocked back less

------------------------------------------------------------------
-- SETTINGS (change these freely)
local TARGET = 100          -- points to win straight away
local KING_RATE = 3         -- points a second when you're alone in the zone
local SHARED_RATE = 1       -- points a second each when the zone is shared
local DOUBLE_TIME = 20      -- the last this-many seconds are worth double
local TICK = 0.25           -- how often the zone is checked (seconds)
local BONK_COOLDOWN = 0.65  -- seconds between swings
local BONK_RANGE = 8        -- studs you can reach
local BONK_POWER = 60       -- how hard a bonk throws you sideways (studs/second)
local BONK_UP = 26          -- ...and upwards
local BONK_TIME = 0.22      -- how long the shove lasts
local BONK_IMMUNE = 0.45    -- after being bonked you can't be bonked again for this long
local BOOST_KNOCK = 0.75    -- boosted players only get knocked back this much (75%)
local HIT_SOUND = "rbxasset://sounds/collide.wav"
-- round length: the KingOfTheHill map's RoundTime attribute (150 = 2.5 minutes)
------------------------------------------------------------------

local KingOfTheHill = {}
KingOfTheHill.intro = "Get to the golden crown on top and STAY there! Click to BONK people off. First to " .. TARGET .. " wins!"
KingOfTheHill.countdown = 4

local map = nil
local round = 0
local started = false
local result = nil        -- { winners = {...}, message = "..." } once decided
local score = {}          -- [player] = points (can be a fraction; the attribute shows it rounded down)
local inGame = {}         -- [player] = true for everyone playing this round
local tools = {}          -- [player] = their Bonk Bopper
local lastSwing = {}      -- [player] = os.clock() of their last swing
local immuneUntil = {}    -- [player] = os.clock() until they can be bonked again
local crowns = {}         -- [player] = crown model on their head
local king = nil          -- player who is alone in the zone right now
local kingToastAt = {}    -- [player] = when we last told them "you're the king"
local closeWarned = {}    -- [player] = true once everyone's been warned they're close to winning
local roundEndsAt = 0
local doubleOn = false
local connections = {}

------------------------------------------------------------------ helpers
local function toast(text, good, list)
	for _, p in list or Players:GetPlayers() do
		if p.Parent then openMenu:FireClient(p, "Toast", text, good) end
	end
end

local function playerList()
	local list = {}
	for p in inGame do
		if p.Parent then table.insert(list, p) end
	end
	return list
end

local function bodyOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and humanoid.Health > 0 then
		return humanoid, root, character
	end
end

local function spawnSpot()
	local list = map.Spawns:GetChildren()
	return list[math.random(#list)]
end

local function sendToStart(player, spot)
	local _, _, character = bodyOf(player)
	if not character then return end
	spot = spot or spawnSpot()
	character:PivotTo(spot.CFrame * CFrame.new(math.random(-2, 2), 3, math.random(-2, 2)))
	task.spawn(function()
		pcall(function() player:RequestStreamAroundAsync(spot.Position, 5) end)
	end)
end

------------------------------------------------------------------ the crown zone look (ring + sparkles change color)
local STATE_COLORS = {
	king = Color3.fromRGB(255, 196, 40),   -- one king
	shared = Color3.fromRGB(255, 70, 60),  -- more than one person up there
	empty = Color3.fromRGB(255, 235, 170), -- nobody
}
local function setZoneLook(state)
	local ring = map and map.Summit:FindFirstChild("ZoneRing")
	if not ring then return end
	local color = STATE_COLORS[state]
	ring.Color = color
	local sparkles = ring:FindFirstChild("ZoneSparkles")
	if sparkles then
		sparkles.Color = ColorSequence.new(color)
		sparkles.Rate = state == "empty" and 40 or 90
	end
	local light = ring:FindFirstChild("ZoneLight")
	if light then light.Color = color end
end

------------------------------------------------------------------ the king's crown
local function removeCrown(player)
	local c = crowns[player]
	if c then c:Destroy() end
	crowns[player] = nil
end

local function giveCrown(player)
	removeCrown(player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then return end
	local crown = assets.KingCrown:Clone()
	crown.Name = "KothCrown"
	crown:PivotTo(head.CFrame * CFrame.new(0, head.Size.Y / 2 + 0.3, 0))
	local w = Instance.new("WeldConstraint")
	w.Part0 = head
	w.Part1 = crown.PrimaryPart
	w.Parent = crown.PrimaryPart
	crown.Parent = character
	crowns[player] = crown
end

local function setKing(player)
	if king == player then return end
	if king then removeCrown(king) end
	king = player
	if player then
		giveCrown(player)
		local now = os.clock()
		if now - (kingToastAt[player] or 0) > 6 then
			kingToastAt[player] = now
			toast("👑 You're the KING! Hold the hill!", true, { player })
		end
	end
	if map then map:SetAttribute("KothKing", player and player.DisplayName or "") end
end

------------------------------------------------------------------ bonking
local function hitFX(pos)
	local a = Instance.new("Part")
	a.Anchored, a.CanCollide, a.CanQuery, a.CanTouch, a.Transparency = true, false, false, false, 1
	a.Size = Vector3.new(1, 1, 1)
	a.Position = pos
	a.Parent = map or workspace
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(255, 240, 120), Color3.fromRGB(255, 140, 40))
	e.Size = NumberSequence.new(1.4, 0)
	e.Speed = NumberRange.new(12, 22)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Lifetime = NumberRange.new(0.3, 0.55)
	e.LightEmission = 1
	e.Parent = a
	e:Emit(18)
	local s = Instance.new("Sound")
	s.SoundId = HIT_SOUND
	s.Volume = 1.2
	s.PlaybackSpeed = 1.3 + math.random() * 0.3
	s.RollOffMaxDistance = 150
	s.Parent = a
	s:Play()
	Debris:AddItem(a, 2)
end

local function knock(victim, dir, power)
	local _, root = bodyOf(victim)
	if not root then return end
	local att = root:FindFirstChild("RootAttachment") or root:FindFirstChildOfClass("Attachment")
	if not att then return end
	local old = root:FindFirstChild("KothKnock")
	if old then old:Destroy() end
	-- a LinearVelocity made on the server is copied to the victim's computer, which moves their character
	-- (StarterPlayerScripts.KingHillUI also makes them stumble over when it sees this)
	local lv = Instance.new("LinearVelocity")
	lv.Name = "KothKnock"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 1e6
	lv.VectorVelocity = dir * power + Vector3.new(0, BONK_UP * (power / BONK_POWER), 0)
	lv.Parent = root
	Debris:AddItem(lv, BONK_TIME)
end

local function swing(player)
	if not (started and not result and inGame[player]) then return end
	local now = os.clock()
	if now - (lastSwing[player] or 0) < BONK_COOLDOWN then return end
	lastSwing[player] = now
	local _, root = bodyOf(player)
	local tool = tools[player]
	if not (root and tool and tool.Parent == player.Character) then return end
	-- the default Animate script plays a sword-slash when this appears in the tool
	local anim = Instance.new("StringValue")
	anim.Name = "toolanim"
	anim.Value = "Slash"
	anim.Parent = tool
	Debris:AddItem(anim, 1)
	local sfx = tool.Handle:FindFirstChild("Bonk")
	if sfx then sfx:Play() end

	local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	for victim in inGame do
		if victim ~= player and (immuneUntil[victim] or 0) < now then
			local _, vroot = bodyOf(victim)
			if vroot then
				local offset = vroot.Position - root.Position
				local flat = offset * Vector3.new(1, 0, 1)
				local dist = offset.Magnitude
				local inFront = flat.Magnitude < 0.01 or flat.Unit:Dot(look) > 0.15
				if dist <= BONK_RANGE and (inFront or dist < 3.5) and math.abs(offset.Y) < 6 then
					immuneUntil[victim] = now + BONK_IMMUNE
					-- push them away from you, mostly the way you're facing
					local dir = flat.Magnitude > 0.01 and (flat.Unit + look).Unit or look
					local power = BONK_POWER * (Boost.isBoosted(victim) and BOOST_KNOCK or 1)
					knock(victim, dir, power)
					hitFX(vroot.Position)
					if victim == king then
						toast("💥 You bonked the KING!", true, { player })
					end
				end
			end
		end
	end
end

local function giveBopper(player)
	local old = tools[player]
	if old then old:Destroy() end
	local humanoid, _, character = bodyOf(player)
	if not humanoid then return end
	local tool = assets["Bonk Bopper"]:Clone()
	tools[player] = tool
	tool.Parent = player:FindFirstChildOfClass("Backpack") or character
	humanoid:EquipTool(tool)
	table.insert(connections, tool.Activated:Connect(function() swing(player) end))
end

------------------------------------------------------------------ scoring
local function publishLeader()
	local best, bestP = -1, nil
	for p in inGame do
		if p.Parent and (score[p] or 0) > best then best, bestP = score[p] or 0, p end
	end
	if not map then return end
	map:SetAttribute("KothLeader", bestP and best > 0 and bestP.DisplayName or "")
	map:SetAttribute("KothLeaderScore", math.floor(math.max(best, 0)))
end

local function addPoints(player, amount)
	score[player] = (score[player] or 0) + amount
	player:SetAttribute("KothScore", math.floor(score[player]))
	if not closeWarned[player] and score[player] >= TARGET * 0.75 then
		closeWarned[player] = true
		toast("⚠️ " .. player.DisplayName .. " has " .. math.floor(score[player]) .. " points - knock them off!", false)
	end
end

local function scoreLoop(token)
	local zc = map:GetAttribute("ZoneCenter")
	local zr = map:GetAttribute("ZoneRadius")
	local outY = map:GetAttribute("OutY")
	local lastState = nil
	while token == round and map do
		if started and not result then
			local now = os.clock()
			if not doubleOn and roundEndsAt - now <= DOUBLE_TIME then
				doubleOn = true
				map:SetAttribute("KothDouble", true)
				toast("⚡ DOUBLE POINTS! Last " .. DOUBLE_TIME .. " seconds!", true)
			end
			local inZone = {}
			for p in inGame do
				local _, root = bodyOf(p)
				if root then
					local pos = root.Position
					if pos.Y < outY then
						sendToStart(p) -- somehow fell out of the courtyard
					else
						local flat = Vector3.new(pos.X - zc.X, 0, pos.Z - zc.Z).Magnitude
						local dy = pos.Y - zc.Y
						if flat <= zr and dy > -1 and dy < 7 then table.insert(inZone, p) end
					end
				end
			end
			local mult = doubleOn and 2 or 1
			local state
			if #inZone == 1 then
				state = "king"
				setKing(inZone[1])
				addPoints(inZone[1], KING_RATE * TICK * mult)
			elseif #inZone > 1 then
				state = "shared"
				setKing(nil)
				for _, p in inZone do addPoints(p, SHARED_RATE * TICK * mult) end
			else
				state = "empty"
				setKing(nil)
			end
			for p in inGame do
				local zoneState = table.find(inZone, p) and (state == "king" and "king" or "shared") or nil
				if p:GetAttribute("KothZone") ~= zoneState then p:SetAttribute("KothZone", zoneState) end
			end
			if state ~= lastState then
				lastState = state
				map:SetAttribute("KothState", state)
				setZoneLook(state)
			end
			publishLeader()
			-- anyone reached the target?
			local winners = {}
			for p in inGame do
				if p.Parent and (score[p] or 0) >= TARGET then table.insert(winners, p) end
			end
			if #winners > 0 then
				local n = {}
				for _, p in winners do table.insert(n, p.DisplayName) end
				result = { winners = winners, message = "👑 " .. table.concat(n, " & ") .. " rules the hill with " .. TARGET .. " points!" }
			end
		end
		task.wait(TICK)
	end
end

------------------------------------------------------------------ the Mode interface (RoundManager calls these)
function KingOfTheHill.start(newMap, players)
	round += 1
	map = newMap
	started, result, king, doubleOn = false, nil, nil, false
	score, inGame, tools, lastSwing, immuneUntil, crowns, kingToastAt, closeWarned = {}, {}, {}, {}, {}, {}, {}, {}
	map:SetAttribute("KothTarget", TARGET)
	map:SetAttribute("KothKing", "")
	map:SetAttribute("KothLeader", "")
	map:SetAttribute("KothLeaderScore", 0)
	map:SetAttribute("KothState", "empty")
	map:SetAttribute("KothDouble", false)
	setZoneLook("empty")

	-- spread everyone round the ring of 16 spots at the bottom of the hill
	local spots = map.Spawns:GetChildren()
	table.sort(spots, function(a, b) return a.Name < b.Name end)
	local offset = math.random(0, #spots - 1)
	local step = math.max(1, math.floor(#spots / math.max(1, #players)))
	for i, player in players do
		inGame[player] = true
		score[player] = 0
		player:SetAttribute("KothScore", 0)
		player:SetAttribute("KothPlayer", true)
		player:SetAttribute("KothZone", nil)
		sendToStart(player, spots[((i - 1) * step + offset) % #spots + 1])
		giveBopper(player)
	end
	publishLeader()
	table.insert(connections, Players.PlayerRemoving:Connect(function(p)
		inGame[p] = nil
		if king == p then setKing(nil) end
	end))
	task.spawn(scoreLoop, round)
end

function KingOfTheHill.begin()
	if not map then return end
	started = true
	roundEndsAt = os.clock() + (map:GetAttribute("RoundTime") or 150)
	toast("GO! Race to the crown on top!", true, playerList())
end

-- reset or respawned mid-round: back to the bottom of the hill with a new bopper
function KingOfTheHill.onCharacterAdded(player, character)
	if not (map and inGame[player]) then return end
	if king == player then setKing(nil) end
	crowns[player] = nil
	character:WaitForChild("HumanoidRootPart")
	character:WaitForChild("Humanoid")
	task.wait(0.1)
	if not (map and inGame[player]) then return end
	sendToStart(player)
	giveBopper(player)
end

-- clock ran out: most points wins
function KingOfTheHill.timeUp()
	if result then return end
	started = false
	local best, winners = 0, {}
	for p in inGame do
		local s = math.floor(score[p] or 0)
		if p.Parent and s > 0 then
			if s > best then
				best, winners = s, { p }
			elseif s == best then
				table.insert(winners, p)
			end
		end
	end
	if #winners == 0 then
		result = { winners = {}, message = "Nobody claimed the hill!" }
	else
		local n = {}
		for _, p in winners do table.insert(n, p.DisplayName) end
		result = { winners = winners, message = "👑 " .. table.concat(n, " & ") .. (#winners == 1 and " is" or " are") .. " King of the Hill with " .. best .. " points!" }
	end
end

function KingOfTheHill.getWinners()
	if not result then return nil end
	local list = {}
	for _, p in result.winners do
		if p.Parent then table.insert(list, p) end
	end
	return list, result.message
end

function KingOfTheHill.stop()
	round += 1 -- the score loop sees this and quits
	started = false
	for _, c in connections do c:Disconnect() end
	connections = {}
	for _, t in tools do t:Destroy() end
	for _, c in crowns do c:Destroy() end
	for _, p in Players:GetPlayers() do
		p:SetAttribute("KothScore", nil)
		p:SetAttribute("KothPlayer", nil)
		p:SetAttribute("KothZone", nil)
	end
	if map then
		setZoneLook("empty")
		map:SetAttribute("KothState", "empty")
		map:SetAttribute("KothKing", "")
		map:SetAttribute("KothDouble", false)
	end
	score, inGame, tools, lastSwing, immuneUntil, crowns, kingToastAt, closeWarned = {}, {}, {}, {}, {}, {}, {}, {}
	map, result, king = nil, nil, nil
end

return KingOfTheHill

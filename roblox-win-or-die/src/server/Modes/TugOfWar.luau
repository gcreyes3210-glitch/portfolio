-- TUG OF WAR: Red vs Blue on platforms 200 studs up. Every time a player nails the
-- skill check, their team pulls the rope. When the red flag passes a team's pole,
-- that team wins, the other team's platform drops away, and they fall.
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local event = ReplicatedStorage:WaitForChild("TugOfWarEvent")

------------------------------------------------------------------
-- SETTINGS
local PULL_STRENGTH = 3     -- studs one whole team moves the rope per round of hits (split across its players)
local MIN_PULL_GAP = 0.35   -- fastest one player is allowed to pull (stops spam/cheating)
local SLOT_SPACING = 5      -- gap between players on the rope
local LEAN = 14             -- how far players lean back while pulling (degrees)
------------------------------------------------------------------

local TEAM_INFO = {
	{ name = "Red", brick = "Bright red", sign = -1 },   -- Red stands on the -X side and pulls that way
	{ name = "Blue", brick = "Bright blue", sign = 1 },
}

local TugOfWar = {}
TugOfWar.intro = "Hit SPACE when the needle is in the box!"

local map, entries, teamOf = nil, {}, {}
local offset, shown = 0, 0   -- where the rope really is / where it's drawn (smoothed)
local active, winner = false, nil
local lastPull = {}
local connections = {}
local ropeBase, flagBase
local savedPlatforms = {}

local function slotCFrame(player)
	local entry = teamOf[player]
	local x = map:GetAttribute("CenterX") + entry.sign * (map:GetAttribute("FirstSlot") + (entry.index[player] - 1) * SLOT_SPACING) + shown
	local pos = Vector3.new(x, map:GetAttribute("TopY") + 3, 0)
	return CFrame.lookAt(pos, pos + Vector3.new(-entry.sign, 0, 0)) * CFrame.Angles(math.rad(LEAN), 0, 0)
end

local function place(player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then
		root.Anchored = true -- players hold the rope; they can't walk off
		char:PivotTo(slotCFrame(player))
	end
end

local function dropPlatform(entry)
	local side = map[entry.name .. "Side"].Platform
	for _, p in side:GetDescendants() do
		if p:IsA("BasePart") then
			table.insert(savedPlatforms, { part = p, cf = p.CFrame })
			p.Anchored = false
		end
	end
	for _, player in entry.players do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			root.Anchored = false
			root.AssemblyLinearVelocity = Vector3.new(0, -10, 0) -- straight down into the pit
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			task.spawn(function()
				-- the fall is fatal: they die when they reach the bottom (or after 6s, whichever is first)
				local t0 = os.clock()
				while humanoid and humanoid.Health > 0 and root.Parent and root.Position.Y > 25 and os.clock() - t0 < 6 do
					task.wait(0.05)
				end
				if humanoid and humanoid.Health > 0 then humanoid.Health = 0 end
			end)
		end
	end
end

local function onPull(player, action)
	if action ~= "Pull" or not active or winner then return end
	local entry = teamOf[player]
	if not entry then return end
	local now = os.clock()
	if lastPull[player] and now - lastPull[player] < MIN_PULL_GAP then return end
	lastPull[player] = now

	offset += entry.sign * PULL_STRENGTH / #entry.players
	local winDistance = map:GetAttribute("WinDistance")
	for _, e in entries do
		if e.sign * offset >= winDistance then
			winner = e
			for _, other in entries do
				if other ~= e then dropPlatform(other) end
			end
		end
	end
end

function TugOfWar.start(newMap, players)
	map = newMap
	entries, teamOf, lastPull, savedPlatforms = {}, {}, {}, {}
	offset, shown, active, winner = 0, 0, false, nil
	ropeBase, flagBase = map.Rope.CFrame, map.Flag.CFrame

	-- deal players out Red, Blue, Red, Blue...
	local list = table.clone(players)
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
	-- PARTIES (ServerScriptService.Extras.Social): friends are moved so the deal below puts them on the same team
	do
		local ex = script.Parent.Parent:FindFirstChild("Extras")
		local ok, Social = pcall(require, ex and ex:FindFirstChild("Social"))
		local ok2, arranged = pcall(function() return ok and Social.arrange(list, 2) end)
		if ok2 and arranged then list = arranged end
	end
	local groups = { {}, {} }
	for i, p in list do table.insert(groups[(i - 1) % 2 + 1], p) end

	for i, info in TEAM_INFO do
		if #groups[i] > 0 then
			local team = Instance.new("Team")
			team.Name = info.name .. " Team"
			team.TeamColor = BrickColor.new(info.brick)
			team.AutoAssignable = false
			team.Parent = Teams
			local entry = { name = info.name, sign = info.sign, team = team, players = groups[i], index = {} }
			table.insert(entries, entry)
			for k, player in groups[i] do
				entry.index[player] = k
				teamOf[player] = entry
				player.Team = team
				place(player)
			end
		end
	end

	table.insert(connections, event.OnServerEvent:Connect(onPull))
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		shown += (offset - shown) * math.min(1, dt * 8)
		map.Rope.CFrame = ropeBase + Vector3.new(shown, 0, 0)
		map.Flag.CFrame = flagBase + Vector3.new(shown, 0, 0)
		if not winner then
			for player in teamOf do
				local char = player.Character
				if char and char:FindFirstChild("HumanoidRootPart") then
					char:PivotTo(slotCFrame(player))
				end
			end
		end
	end))
end

-- called by RoundManager when the countdown hits zero
function TugOfWar.begin()
	active = true
	for player in teamOf do
		if player.Parent then event:FireClient(player, "Start") end
	end
end

function TugOfWar.onCharacterAdded(player, character)
	if teamOf[player] and not winner then
		character:WaitForChild("HumanoidRootPart")
		task.wait()
		place(player)
	end
end

function TugOfWar.getWinners()
	if not winner then return nil end
	local winners = {}
	for _, p in winner.players do
		if p.Parent then table.insert(winners, p) end
	end
	return winners, winner.team.Name .. " wins the tug of war!"
end

function TugOfWar.stop()
	active = false
	event:FireAllClients("Stop")
	for _, c in connections do c:Disconnect() end
	connections = {}
	for _, entry in entries do
		for _, p in entry.players do
			if p.Parent then
				p.Team = nil
				p.Neutral = true
			end
		end
		entry.team:Destroy()
	end
	-- put the rope, flag and any dropped platform back once everyone has fallen
	local m, rb, fb, saved = map, ropeBase, flagBase, savedPlatforms
	task.delay(3, function()
		m.Rope.CFrame, m.Flag.CFrame = rb, fb
		for _, s in saved do
			s.part.Anchored = true
			s.part.AssemblyLinearVelocity = Vector3.zero
			s.part.AssemblyAngularVelocity = Vector3.zero
			s.part.CFrame = s.cf
		end
	end)
	map, entries, teamOf, winner, savedPlatforms = nil, {}, {}, nil, {}
end

return TugOfWar

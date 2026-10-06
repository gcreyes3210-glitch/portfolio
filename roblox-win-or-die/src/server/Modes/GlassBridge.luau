-- GLASS BRIDGE (everyone for themselves, make it across to win).
--  * NO SKIPPING: the rows are far enough apart that you can't jump over one, and sprint is off here.
--  * The bridge has 12 rows of glass. In every row ONE panel is safe and the other SHATTERS when you
--    land on it - and they look exactly the same!
--  * Jump row by row. Fall and you're out (you can spectate).
--  * A safe panel glows mint once someone has stood on it, and a shattered one leaves a hole - so the
--    brave players in front show everyone else the way. Going first is risky... waiting too long is too!
--  * Everyone who reaches the FINISH ledge wins. When the clock runs out, the whole bridge shatters.
-- The map is built by ServerStorage.GlassBridgeBuilder. StarterPlayerScripts.GlassBridgeUI draws the panel
-- (it reads the attributes this script sets).
local Players = game:GetService("Players")
local HitSounds = require(game:GetService("ServerScriptService"):WaitForChild("Extras"):WaitForChild("HitSounds")) -- the SOUND of what hit a player (nothing is written on screen)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local openMenu = ReplicatedStorage:WaitForChild("OpenMenu") -- LobbyUI shows "Toast" messages
local Boost = require(script.Parent.Parent:WaitForChild("Boost")) -- boost = 1 free save if you fall

------------------------------------------------------------------
-- SETTINGS (change these freely)
local HURRY_AT = 20       -- "hurry!" warning when this many seconds are left
local FEET_BOX = Vector3.new(2.4, 1.2, 1.6) -- the area under your feet that counts as "standing on" a panel
local TICK = 0.1
-- round length: the GlassBridge map's RoundTime attribute (100 seconds)
------------------------------------------------------------------

local GLASS = Color3.fromRGB(170, 220, 255)
local SAFE = Color3.fromRGB(150, 255, 200)
local SHATTER = "rbxasset://sounds/glassbreak.wav"

local GlassBridge = {}
GlassBridge.intro = "Cross the glass bridge! In every row one panel is safe and one SHATTERS. Everyone who reaches the finish wins!"
GlassBridge.countdown = 4

local map, runtime = nil, nil
local round = 0
local started, result = false, nil
local alive = {}          -- [player] = true while still on the way across
local finished = {}       -- [player] = place (1st, 2nd...) for everyone who made it
local finishOrder = {}
local startedWith = 0
local panels = {}         -- all glass panels
local fake = {}           -- [panel] = true for the ones that break (the server never tells anyone)
local broken = {}         -- [panel] = true once shattered
local revealed = {}       -- [panel] = true once a safe panel has been stood on
local lastSafe = {}       -- [player] = the last safe panel they stood on (for boost saves)
local endsAt = 0
local connections = {}
local overlap = nil

------------------------------------------------------------------ helpers
local function toast(text, good, list)
	for _, p in list or Players:GetPlayers() do
		if p.Parent then openMenu:FireClient(p, "Toast", text, good) end
	end
end

local function aliveList()
	local list = {}
	for p in alive do
		if p.Parent then table.insert(list, p) end
	end
	return list
end

local function names(list)
	local n = {}
	for _, p in list do table.insert(n, p.DisplayName) end
	return table.concat(n, " & ")
end

local function bodyOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and humanoid.Health > 0 then return humanoid, root, character end
end

local function publishCount()
	if not map then return end
	map:SetAttribute("GlassOnBridge", #aliveList())
	map:SetAttribute("GlassAcross", #finishOrder)
	map:SetAttribute("GlassTotal", startedWith)
end

local function sendTo(player, cf)
	local _, root, character = bodyOf(player)
	if not character then return end
	root.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(cf)
end

------------------------------------------------------------------ the glass
local function resetGlass()
	for _, p in panels do
		p.Color = GLASS
		p.Material = Enum.Material.Glass
		p.Transparency = 0.35
		p.CanCollide = true
		p.CanQuery = true
	end
	fake, broken, revealed = {}, {}, {}
end

-- in every row, pick which side is the fake one
local function shuffleGlass()
	local rows = {}
	for _, p in panels do
		local r = p:GetAttribute("Row")
		rows[r] = rows[r] or {}
		table.insert(rows[r], p)
	end
	for _, pair in rows do
		fake[pair[math.random(#pair)]] = true
	end
end

local function partnerOf(panel)
	for _, p in panels do
		if p ~= panel and p:GetAttribute("Row") == panel:GetAttribute("Row") then return p end
	end
end

local function reveal(panel)
	if revealed[panel] or broken[panel] then return end
	revealed[panel] = true
	panel.Color = SAFE
end

-- CRASH! the panel turns into falling shards and leaves a hole
local function shatter(panel, quiet)
	if broken[panel] then return end
	broken[panel] = true
	panel.CanCollide = false
	panel.CanQuery = false
	panel.Transparency = 1
	if runtime then
		for _ = 1, 8 do
			local s = Instance.new("Part")
			s.Name = "Shard"
			s.Size = Vector3.new(math.random(10, 22) / 10, 0.2, math.random(10, 22) / 10)
			s.CFrame = panel.CFrame * CFrame.new(math.random(-25, 25) / 10, 0, math.random(-25, 25) / 10) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
			s.Color = GLASS
			s.Material = Enum.Material.Glass
			s.Transparency = 0.3
			s.CanCollide, s.CanQuery, s.CanTouch = false, false, false
			s.CastShadow = false
			s.AssemblyLinearVelocity = Vector3.new(math.random(-8, 8), math.random(-4, 6), math.random(-8, 8))
			s.Parent = runtime
			Debris:AddItem(s, 3)
		end
		if not quiet then
			local holder = Instance.new("Part")
			holder.Anchored = true
			holder.CanCollide, holder.CanQuery, holder.CanTouch = false, false, false
			holder.Transparency = 1
			holder.Size = Vector3.new(1, 1, 1)
			holder.Position = panel.Position
			holder.Parent = runtime
			local snd = Instance.new("Sound")
			snd.SoundId = SHATTER
			snd.Volume = 1
			snd.RollOffMaxDistance = 250
			snd.Parent = holder
			snd:Play()
			Debris:AddItem(holder, 3)
		end
	end
	-- the other panel in this row must be the safe one - light it up
	local other = partnerOf(panel)
	if other and fake[panel] then reveal(other) end
end

------------------------------------------------------------------ falling + finishing
local function eliminate(batch)
	for _, player in batch do
		alive[player] = nil
		player:SetAttribute("InRound", nil) -- out for the round: spectator mode takes over
		player:SetAttribute("GlassOut", true)
		HitSounds.player("fall", player) -- through the glass (no message)
	end
	publishCount()
	local token = round
	task.delay(2, function()
		for _, player in batch do
			if token == round and player.Parent and not alive[player] and not finished[player] then player:LoadCharacter() end
		end
	end)
end

local function finish(player)
	alive[player] = nil
	table.insert(finishOrder, player)
	finished[player] = #finishOrder
	player:SetAttribute("GlassFinished", #finishOrder)
	publishCount()
	local place = #finishOrder
	local suffix = place == 1 and "st" or place == 2 and "nd" or place == 3 and "rd" or "th"
	toast("🎉 You made it across! (" .. place .. suffix .. ")", true, { player })
	toast("🎉 " .. player.DisplayName .. " made it across the bridge!", true, aliveList())
	local burst = map:FindFirstChild("Decor") and map.Decor:FindFirstChild("Confetti")
	if burst and burst:FindFirstChild("Burst") then burst.Burst:Emit(60) end
end

local function finalResult()
	local list = {}
	for _, p in finishOrder do
		if p.Parent then table.insert(list, p) end
	end
	if #list == 0 then
		return { winners = {}, message = "💥 Nobody made it across the glass bridge!" }
	elseif #list > 3 then
		return { winners = list, message = "🌉 " .. #list .. " players made it across the glass bridge!" }
	end
	return { winners = list, message = "🌉 " .. names(list) .. " made it across the glass bridge!" }
end

------------------------------------------------------------------ the main loop: who's standing on what
local function mainLoop(token)
	local hurried = false
	while token == round and map do
		if started and not result then
			local bridgeY = map:GetAttribute("BridgeY")
			local outY = map:GetAttribute("OutY")
			local finishZ = map:GetAttribute("FinishZ")
			local fallers = {}
			for player in alive do
				local _, root = bodyOf(player)
				if root then
					local pos = root.Position
					if pos.Y < outY then
						if Boost.useShield(player) then
							local back = lastSafe[player]
							sendTo(player, back and CFrame.new(back.Position + Vector3.new(0, 3.5, 0)) or (map.Spawns:GetChildren()[1].CFrame * CFrame.new(0, 3, 0)))
							toast("⚡ Your boost caught you! No more saves this round.", true, { player })
						else
							table.insert(fallers, player)
						end
					elseif pos.Z >= finishZ and pos.Y > bridgeY - 4 then
						finish(player)
					else
						-- what's under their feet? (a box, so standing across two panels still counts)
						local hits = workspace:GetPartBoundsInBox(CFrame.new(pos - Vector3.new(0, 3.1, 0)), FEET_BOX, overlap)
						for _, panel in hits do
							if fake[panel] then
								if not broken[panel] then shatter(panel) end
							elseif not broken[panel] then
								lastSafe[player] = panel
								reveal(panel)
							end
						end
					end
				end
			end
			if #fallers > 0 then eliminate(fallers) end

			-- players who made it stay on the finish ledge (no going back to test the glass for others!)
			for player in finished do
				local _, root = bodyOf(player)
				if root and (root.Position.Z < finishZ - 1 or root.Position.Y < bridgeY - 4) then
					sendTo(player, map.FinishSpot.CFrame * CFrame.new(0, 3, 0))
					toast("🎉 You're already across - cheer the others on!", true, { player })
				end
			end

			if not hurried and endsAt - workspace:GetServerTimeNow() <= HURRY_AT and #aliveList() > 0 then
				hurried = true
				toast("⏰ Hurry! The bridge shatters in " .. HURRY_AT .. " seconds!", false, aliveList())
			end

			-- nobody left on the way across: round over
			if next(alive) == nil then
				result = finalResult()
			end
		end
		task.wait(TICK)
	end
end

------------------------------------------------------------------ the Mode interface (RoundManager calls these)
function GlassBridge.start(newMap, players)
	round += 1
	map = newMap
	started, result = false, nil
	alive, finished, finishOrder, lastSafe = {}, {}, {}, {}
	local old = map:FindFirstChild("Runtime")
	if old then old:Destroy() end
	runtime = Instance.new("Folder")
	runtime.Name = "Runtime"
	runtime.Parent = map
	panels = map.Bridge.Glass:GetChildren()
	resetGlass()
	shuffleGlass()
	overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { map.Bridge.Glass }
	map:SetAttribute("GlassEnds", 0)

	local spots = map.Spawns:GetChildren()
	table.sort(spots, function(a, b) return a.Name < b.Name end)
	local offset = math.random(0, #spots - 1)
	local step = math.max(1, math.floor(#spots / math.max(1, #players)))
	for i, player in players do
		alive[player] = true
		player:SetAttribute("GlassPlayer", true)
		player:SetAttribute("GlassOut", nil)
		player:SetAttribute("GlassFinished", nil)
		player:SetAttribute("NoSprint", true) -- SprintClient: a sprint jump could skip a row
		local spot = spots[((i - 1) * step + offset) % #spots + 1]
		local _, _, character = bodyOf(player)
		if character then
			character:PivotTo(spot.CFrame * CFrame.new(0, 3, 0))
			task.spawn(function()
				pcall(function() player:RequestStreamAroundAsync(spot.Position, 5) end)
			end)
		end
	end
	startedWith = #players
	publishCount()
	table.insert(connections, Players.PlayerRemoving:Connect(function(p)
		alive[p] = nil
		lastSafe[p] = nil
		publishCount()
	end))
	task.spawn(mainLoop, round)
end

function GlassBridge.begin()
	if not map then return end
	started = true
	endsAt = workspace:GetServerTimeNow() + (map:GetAttribute("RoundTime") or 100)
	map:SetAttribute("GlassEnds", endsAt)
	toast("🌉 GO! Pick your glass carefully...", true, aliveList())
end

-- a player who resets mid-round is out (it would be a free way off a bad panel).
-- If they'd already made it across, they just go back to the finish ledge.
function GlassBridge.onCharacterAdded(player, character)
	if not map then return end
	if finished[player] then
		local token = round
		task.defer(function()
			character:WaitForChild("HumanoidRootPart", 5)
			if token == round and map then sendTo(player, map.FinishSpot.CFrame * CFrame.new(0, 3, 0)) end
		end)
	elseif alive[player] then
		eliminate({ player })
	end
end

-- clock ran out: the whole bridge shatters, and only the players who made it across win
function GlassBridge.timeUp()
	if result then return end
	started = false
	for _, p in panels do
		if not broken[p] then shatter(p, true) end
	end
	local stuck = aliveList()
	result = finalResult()
	if #stuck > 0 then
		result.message = "⏰ Time's up - the bridge shattered! " .. result.message
	end
end

function GlassBridge.getWinners()
	if not result then return nil end
	local list = {}
	for _, p in result.winners do
		if p.Parent then table.insert(list, p) end
	end
	return list, result.message
end

function GlassBridge.stop()
	round += 1 -- the loop sees this and quits
	started = false
	for _, c in connections do c:Disconnect() end
	connections = {}
	for _, p in Players:GetPlayers() do
		for _, a in { "GlassPlayer", "GlassOut", "GlassFinished", "NoSprint" } do p:SetAttribute(a, nil) end
	end
	if map then
		resetGlass()
		for _, a in { "GlassEnds", "GlassOnBridge", "GlassAcross", "GlassTotal" } do map:SetAttribute(a, nil) end
	end
	if runtime then runtime:Destroy() end
	alive, finished, finishOrder, lastSafe, panels = {}, {}, {}, {}, {}
	map, runtime, result, overlap = nil, nil, nil, nil
end

return GlassBridge

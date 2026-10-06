-- HEX SPLEEF (last one standing).
--  * Everyone starts on their own floating gold pad, above four big layers of hexagon tiles.
--    (The pads count as "layer 1" - they vanish once you've been on them, just like floor tiles.)
--  * Step on a tile and it starts to fade. After TILE_FADE_TIME seconds it's GONE for the rest of the round.
--  * Fall through a hole and you land on the layer below. Fall below the bottom layer and you're OUT.
--  * Players who are out do NOT come back into the round - they wait in the lobby.
--  * Last player standing wins. If time runs out, everyone still standing wins.
--  * Playing alone? You play until you fall (practice mode).
--  * SMALL SERVERS (ServerScriptService.Extras.Scaling + Bots): with 3 players or fewer, BOTS fill the round up
--    to 6 contestants (outlast them all to win - if every player falls first, nobody wins), and with few
--    contestants the floor starts SMALLER (the outer rings are already gone) so rounds don't drag.
--
-- How tiles are found: every tile is on a hexagon grid, so from a player's (x, z) position we can
-- work out exactly which tile they're over with a little math - no Touched events needed.
-- The server only marks WHEN a tile will drop (the "FallAt" attribute); each player's
-- HexSpleefClient script does the smooth fade on their own screen.
local Players = game:GetService("Players")
local HitSounds = require(game:GetService("ServerScriptService"):WaitForChild("Extras"):WaitForChild("HitSounds")) -- the SOUND of what hit a player (nothing is written on screen)
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local openMenu = ReplicatedStorage:WaitForChild("OpenMenu")
local Boost = require(script.Parent.Parent:WaitForChild("Boost")) -- boosted players get 1 free save
local Extras = script.Parent.Parent:WaitForChild("Extras")
local Scaling = require(Extras:WaitForChild("Scaling")) -- small lobbies: a smaller floor + bots
local Bots = require(Extras:WaitForChild("Bots"))

------------------------------------------------------------------
-- SETTINGS (change these freely)
local TILE_FADE_TIME = 2.5   -- seconds from stepping on a tile until it's gone (was 3). Keep FADE_TIME in HexSpleefClient the same!
local FOOT_SPREAD = 0.9      -- how wide your feet count as (studs from your center)
local SMALL_FLOOR = { { upTo = 3, rings = 6 }, { upTo = 6, rings = 8 } } -- contestants -> how many rings of tiles the floor starts with (full = 10)
------------------------------------------------------------------

local HexSpleef = {}
HexSpleef.intro = "Every tile you touch fades away in " .. TILE_FADE_TIME .. " seconds! Keep moving - last one standing wins!"
HexSpleef.countdown = 5 -- RoundManager uses this instead of its normal 3-second countdown

local SQRT3 = math.sqrt(3)
local map = nil
local round = 0
local running = false
local alive = {}
local startedWith = 0
local result = nil
local connections = {}
local tiles = {}      -- tiles["layer:q:r"] = tile model
local layerY = {}     -- top surface height of each layer
local bots = {}       -- computer players filling a small round (Extras.Bots)

local function toast(text, good, list)
	for _, p in list or Players:GetPlayers() do
		if p.Parent then openMenu:FireClient(p, "Toast", text, good) end
	end
end

local function aliveList()
	local list = {}
	for p in alive do table.insert(list, p) end
	return list
end

local function names(list)
	local n = {}
	for _, p in list do table.insert(n, p.DisplayName) end
	return table.concat(n, " & ")
end

------------------------------------------------------------------ tiles
local function setTileSolid(tile, solid)
	for _, part in tile:GetChildren() do
		if part:IsA("BasePart") then
			part.Transparency = solid and 0 or 1
			part.CanCollide = solid
			part.CanQuery = solid
		end
	end
end

local function resetTiles()
	tiles, layerY = {}, {}
	for i = 1, map:GetAttribute("Layers") do
		layerY[i] = map:GetAttribute("Layer" .. i .. "Y")
	end
	for _, layer in map.Layers:GetChildren() do
		for _, tile in layer:GetChildren() do
			tile:SetAttribute("FallAt", nil)
			setTileSolid(tile, true)
			tiles[tile:GetAttribute("Layer") .. ":" .. tile:GetAttribute("Q") .. ":" .. tile:GetAttribute("R")] = tile
		end
	end
end

-- which hex (q, r) is this world (x, z) over? (flat-top hex grid math)
local function hexAt(x, z)
	local center = map:GetAttribute("Center")
	local size = map:GetAttribute("GridSize")
	x, z = x - center.X, z - center.Z
	local q = (2 / 3 * x) / size
	local r = (-1 / 3 * x + SQRT3 / 3 * z) / size
	-- round to the nearest hex
	local s = -q - r
	local rq, rr, rs = math.round(q), math.round(r), math.round(s)
	local dq, dr, ds = math.abs(rq - q), math.abs(rr - r), math.abs(rs - s)
	if dq > dr and dq > ds then
		rq = -rr - rs
	elseif dr > ds then
		rr = -rq - rs
	end
	return rq, rr
end

local function dropTile(tile, token)
	if token ~= round then return end
	setTileSolid(tile, false)
end

local function triggerTile(tile)
	if tile:GetAttribute("FallAt") then return end -- already fading
	tile:SetAttribute("FallAt", workspace:GetServerTimeNow() + TILE_FADE_TIME)
	task.delay(TILE_FADE_TIME, dropTile, tile, round)
end

------------------------------------------------------------------ players
-- BOOST save: drop the player onto a random tile of the lowest layer that's still solid
local function rescue(player, root)
	local bottom = #layerY
	local choices = {}
	for k, tile in tiles do
		if string.sub(k, 1, #tostring(bottom) + 1) == bottom .. ":" and not tile:GetAttribute("FallAt") then
			table.insert(choices, tile)
		end
	end
	if #choices == 0 then return false end
	local tile = choices[math.random(#choices)]
	local pos = tile:GetPivot().Position
	player.Character:PivotTo(CFrame.new(pos.X, layerY[bottom] + 4, pos.Z))
	root.AssemblyLinearVelocity = Vector3.zero
	toast("⚡ Your boost saved you! No more saves this round.", true, { player })
	return true
end

-- is the round decided? Bots count as contestants: you have to outlast them too.
-- batch = the players who just fell together (nil when a bot fell), before = players left before that
local function checkEnd(batch, before)
	if result then return end
	local left = aliveList()
	local botsLeft = Bots.aliveCount(bots)
	if startedWith >= 2 then
		if #left == 1 and botsLeft == 0 then
			result = { winners = left, message = left[1].DisplayName .. " is the last one standing!" }
		elseif #left == 0 and botsLeft > 0 then
			result = { winners = {}, message = "🤖 The bots outlasted everyone! Keep moving next time." }
		elseif #left == 0 and batch and before > 0 then
			result = { winners = batch, message = names(batch) .. " fell together - it's a tie!" }
		elseif #left == 0 then
			result = { winners = {}, message = "Everybody fell!" }
		end
	elseif #left == 0 then
		result = { winners = {}, message = "You fell! Keep moving next time." }
	end
end

local function eliminate(batch)
	local before = #aliveList()
	for _, player in batch do
		alive[player] = nil
		player:SetAttribute("InRound", nil) -- out for the round: spectator mode takes over
		HitSounds.player("fall", player) -- you hear the fall (no message)
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then hum.Health = 0 end
	end
	if result then return end
	local left = #aliveList() + Bots.aliveCount(bots)
	checkEnd(batch, before)
end

------------------------------------------------------------------ small servers: a smaller floor + bots
-- the outer rings of every layer start already gone (the spawn pads stay)
local function shrinkFloor(rings)
	for _, tile in tiles do
		local layer, q, r = tile:GetAttribute("Layer"), tile:GetAttribute("Q"), tile:GetAttribute("R")
		if layer > 1 and math.max(math.abs(q), math.abs(r), math.abs(q + r)) > rings then
			tile:SetAttribute("FallAt", 1) -- "fell long ago": screens hide it, and nobody can step or be rescued onto it
			setTileSolid(tile, false)
		end
	end
end

local function botOut(bot)
	if not bot.alive then return end
	Bots.remove(bot, 0.5)
	if result then return end
	checkEnd(nil, 0)
end

-- which layer are these feet standing on? (nil = in the air)
local function layerOf(feet)
	for li, y in layerY do
		if feet > y - 1.5 and feet < y + 1 then return li end
	end
	return nil
end

-- a bot picks a tile 1 or 2 steps away that is still solid and walks (or hops) to it. It likes to keep
-- heading the same way, like a player running across the floor.
local function botThink(bot, li)
	local d = bot.data
	local pos = bot.root.Position
	local q, r = hexAt(pos.X, pos.Z)
	local best, bestScore, bestDq, bestDr = nil, -math.huge, 0, 0
	for dq = -2, 2 do
		for dr = -2, 2 do
			local dist = math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
			if dist >= 1 and dist <= 2 then
				local tile = tiles[li .. ":" .. (q + dq) .. ":" .. (r + dr)]
				if tile and not tile:GetAttribute("FallAt") then
					local score = math.random() * 2 + (dist == 1 and 0.6 or 0)
					if (d.dq or 0) * dq + (d.dr or 0) * dr > 0 then score += 1.2 end
					if score > bestScore then best, bestScore, bestDq, bestDr = tile, score, dq, dr end
				end
			end
		end
	end
	if not best then
		Bots.jump(bot) -- nowhere to go: one last hop
		return
	end
	d.dq, d.dr = bestDq, bestDr
	local target = best:GetPivot().Position
	bot.humanoid:MoveTo(Vector3.new(target.X, pos.Y, target.Z))
	local under = tiles[li .. ":" .. q .. ":" .. r]
	local fallAt = under and under:GetAttribute("FallAt")
	local twoAway = math.max(math.abs(bestDq), math.abs(bestDr), math.abs(bestDq + bestDr)) == 2
	if twoAway or (fallAt and fallAt - workspace:GetServerTimeNow() < 0.9) or math.random() < 0.12 then
		task.delay(0.12, function() Bots.jump(bot) end)
	end
end

local tick = 0
local rescuedUntil = {} -- [player] = os.clock() time; a boost save makes you safe for a moment
local function onHeartbeat(dt)
	tick += dt
	if tick < 0.05 or not map then return end
	tick = 0
	local outY = map:GetAttribute("OutY")
	local fallers = {}
	for p in alive do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if rescuedUntil[p] and os.clock() < rescuedUntil[p] then
			-- just saved: the player's computer needs a moment to catch up with the teleport
		elseif root and hum and hum.Health > 0 and root.Position.Y < outY and Boost.hasShield(p) and rescue(p, root) then
			Boost.useShield(p)
			rescuedUntil[p] = os.clock() + 1.5
		elseif not root or not hum or root.Position.Y < outY then
			table.insert(fallers, p)
		elseif running then
			-- which layer are my feet on? (feet must be right at the tile top, not in mid-air)
			local feet = root.Position.Y - root.Size.Y / 2 - hum.HipHeight
			for li, y in layerY do
				if feet > y - 1.5 and feet < y + 1 then
					-- check under my center and 4 points around it (so the edges of your feet count too)
					local pos = root.Position
					for _, off in { Vector3.zero, Vector3.new(FOOT_SPREAD, 0, 0), Vector3.new(-FOOT_SPREAD, 0, 0), Vector3.new(0, 0, FOOT_SPREAD), Vector3.new(0, 0, -FOOT_SPREAD) } do
						local q, r = hexAt(pos.X + off.X, pos.Z + off.Z)
						local tile = tiles[li .. ":" .. q .. ":" .. r]
						if tile then triggerTile(tile) end
					end
					break
				end
			end
		end
	end
	if #fallers > 0 then eliminate(fallers) end
	-- bots: the same rules as players (their tiles fade, they fall through, below the last layer = out)
	local now = os.clock()
	for _, bot in bots do
		if bot.alive then
			local root = bot.root
			if not root.Parent or bot.humanoid.Health <= 0 or root.Position.Y < outY then
				botOut(bot)
			elseif running then
				local li = layerOf(Bots.feetY(bot))
				if li then
					local pos = root.Position
					for _, off in { Vector3.zero, Vector3.new(FOOT_SPREAD, 0, 0), Vector3.new(-FOOT_SPREAD, 0, 0), Vector3.new(0, 0, FOOT_SPREAD), Vector3.new(0, 0, -FOOT_SPREAD) } do
						local q, r = hexAt(pos.X + off.X, pos.Z + off.Z)
						local tile = tiles[li .. ":" .. q .. ":" .. r]
						if tile then triggerTile(tile) end
					end
					if now >= (bot.data.nextThink or 0) then
						bot.data.nextThink = now + 0.45 + math.random() * 0.35
						botThink(bot, li)
					end
				end
			end
		end
	end
end

------------------------------------------------------------------ the Mode interface (RoundManager calls these)
function HexSpleef.start(newMap, players)
	round += 1
	map = newMap
	running = false
	alive, result = {}, nil
	startedWith = #players
	Bots.clear(bots)
	resetTiles() -- brand-new floor every round

	local spawns = map.Spawns:GetChildren()
	local nextSpawn = math.random(#spawns)
	toast("Tiles fade away " .. TILE_FADE_TIME .. " seconds after you touch them. Fall through a hole and you land on the next layer - miss the last layer and you're OUT!", true, players)
	for _, player in players do
		alive[player] = true
		local char = player.Character
		if char then char:PivotTo(spawns[nextSpawn].CFrame + Vector3.new(0, 3, 0)) end -- each player gets their own pad
		nextSpawn = nextSpawn % #spawns + 1
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			table.insert(connections, hum.Died:Connect(function()
				if alive[player] then eliminate({ player }) end
			end))
		end
	end

	-- SMALL SERVERS: bots take the next pads along, and fewer contestants get a smaller floor
	local botSpots = {}
	for _ = 1, Scaling.botCount("HexSpleef", #players) do
		table.insert(botSpots, spawns[nextSpawn].CFrame)
		nextSpawn = nextSpawn % #spawns + 1
	end
	bots = Bots.create(#botSpots, botSpots, map)
	startedWith = #players + #bots
	for _, size in SMALL_FLOOR do
		if startedWith <= size.upTo then
			shrinkFloor(size.rings)
			break
		end
	end
	if #bots > 0 then
		toast("🤖 " .. #bots .. " bots joined to fill the round. Outlast them all to win!", true, players)
	end

	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		if alive[player] then eliminate({ player }) end
	end))
end

-- "GO!" - tiles start reacting now (not during the countdown)
function HexSpleef.begin()
	running = true
	toast("GO! Don't stand still - keep moving!", true, aliveList())
end

function HexSpleef.onCharacterAdded(player, character)
	-- players who fell stay out: they respawn in the lobby, not back in the arena
end

function HexSpleef.timeUp()
	if result then return end
	local left = aliveList()
	if #left > 0 then
		result = { winners = left, message = names(left) .. " never fell!" }
	end
end

function HexSpleef.getWinners()
	if not result then return nil end
	local list = {}
	for _, p in result.winners do
		if p.Parent then table.insert(list, p) end
	end
	return list, result.message
end

function HexSpleef.stop()
	round += 1 -- any tile timers still waiting will see this and quit
	running = false
	for _, c in connections do c:Disconnect() end
	connections = {}
	Bots.clear(bots)
	map, alive, result, startedWith = nil, {}, nil, 0
end

return HexSpleef

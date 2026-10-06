-- SPINNING BAR (last one standing).
--  * Everyone starts on a round platform high above pink goo.
--  * A low bar sweeps around the platform. Jump over it! Get hit and you're knocked flying.
--  * Fall off the platform = you're out (you respawn in the lobby and spectate the rest of the round).
--  * The bar speeds up the longer the round goes.
--  * Last player standing wins. If the clock runs out, everyone still on the platform wins.
--  * Playing alone? You play until you fall (practice mode).
--  * CRUMBLING FLOOR: a while after the bar starts, floor pieces start to shake, flash red and DROP into
--    the goo - faster and faster, until only about a quarter of the floor is left. Watch your feet!
--    (The floor is Workspace.Maps.SpinBar.Platform.Pieces - 42 pieces in 3 rings; the middle stays.)
--  * SMALL SERVERS (ServerScriptService.Extras.Scaling + Bots): with 3 players or fewer, BOTS fill the round up
--    to 6 contestants. They jump the bar too (and sometimes miss!). Outlast them all to win - if every player
--    falls first, nobody wins. With few contestants the floor also starts crumbling sooner.
--
-- How the bar moves: the SERVER only writes the start time and speed settings as attributes on
-- the map. Every CLIENT (StarterPlayerScripts.SpinBarClient) computes the same angle from the
-- same clock and rotates the bar itself, so it's perfectly smooth and hits feel instant.
local Players = game:GetService("Players")
local HitSounds = require(game:GetService("ServerScriptService"):WaitForChild("Extras"):WaitForChild("HitSounds")) -- the SOUND of what hit a player (nothing is written on screen)
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local openMenu = ReplicatedStorage:WaitForChild("OpenMenu") -- LobbyUI shows "Toast" messages
local Boost = require(script.Parent.Parent:WaitForChild("Boost")) -- boosted players get 1 free save
local Extras = script.Parent.Parent:WaitForChild("Extras")
local Scaling = require(Extras:WaitForChild("Scaling")) -- small lobbies: bots + an earlier crumble
local Bots = require(Extras:WaitForChild("Bots"))

------------------------------------------------------------------
-- SETTINGS (change these freely)
local START_SPEED = 80      -- degrees per second at the start (one lap every 4.5 seconds)
local ACCELERATION = 3      -- how many degrees/second the bar gains every second (was 1.2 - much quicker now)
local MAX_SPEED = 270       -- top speed in degrees per second (reached about 1 minute in)
local START_DELAY = 5       -- seconds after "GO" before the bar starts moving - walk around and pick your spot!
local SPEEDUP_MESSAGE_EVERY = 15 -- tell everyone "faster!" this often
local FALL_FROM = 15        -- seconds after the bar starts before floor pieces start dropping
local FALL_EVERY_START = 4.5 -- seconds between drops at first...
local FALL_EVERY_MIN = 1.5  -- ...getting faster down to this
local FALL_WARN = 1.6       -- a piece shakes and flashes red this long before it drops
local KEEP_FRACTION = 0.25  -- stop dropping when only this much of the floor is left
local SMALL_FALL_FROM = 8   -- small rounds (4 contestants or fewer): the floor starts crumbling this soon instead
local BOT_JUMP_LEAD = 0.27  -- bots jump this many seconds before the bar reaches them (a jump clears it for ~0.4 s)
-- How good the bots are. Tested: with 0.07 / 0.2 every bot was out within ~25 seconds (too easy a win);
-- with these numbers a typical bot lasts about half a minute and the best of five about a minute.
local BOT_MISS = 0.02       -- chance a bot mistimes a jump at the starting speed...
local BOT_MISS_FAST = 0.1   -- ...rising to this much more at top speed
local BOT_CLUMSY = 0.03     -- each bot is up to this much worse than that (so they aren't all the same)
local BOT_MIN_RADIUS = 14   -- bots stay at least this far from the middle (close in, the bar passes too slowly to be jumped)
local BOT_MAX_TURN = math.rad(70)   -- ...and walk around the ring to their next spot, never across the middle
local BOT_CLEAR_ANGLE = math.rad(40) -- before the bar starts, bots get this far away from it (like players picking a spot)
local BOT_GRACE = 0.4       -- the bar can't hit a bot in its first moment of moving (a bot still crossing its path isn't out at once)
local HUB_GUARD_HEIGHT = 400 -- studs: how tall the invisible "no standing here" column over the middle hub is (far higher than any jump)
local HUB_GUARD_EXTRA = 0.1  -- studs: how much wider than the hub's top the column is (so there's no rim left to land on)
-- round length: the SpinBar map's RoundTime attribute (120 = 2 minutes)
------------------------------------------------------------------

local SpinBar = {}
SpinBar.intro = "Jump over the bar! Last one standing wins"
SpinBar.noFreeze = true -- RoundManager lets you walk around during the countdown (the bar is still anyway)

local map = nil
local round = 0
local alive = {}        -- [player] = true while still on the platform
local startedWith = 0
local result = nil      -- { winners = {...}, message = "..." } once decided
local connections = {}
local bots = {}         -- computer players filling a small round (Extras.Bots)
local fallFrom = FALL_FROM

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

-- someone just fell. `batch` = everyone who fell in the same instant (so a tie can win together)
local function eliminate(batch)
	local before = #aliveList()
	for _, player in batch do
		alive[player] = nil -- remove FIRST so the Died event doesn't count them twice
		player:SetAttribute("SpinBarAlive", nil)
		HitSounds.player("bonk", player) -- whacked by the bar (no message)
		player:SetAttribute("InRound", nil) -- out for the round: spectator mode takes over
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then hum.Health = 0 end
	end
	if result then return end
	local left = aliveList()
	local botsLeft = Bots.aliveCount(bots)
	if startedWith >= 2 then
		if #left == 1 and botsLeft == 0 then
			result = { winners = left, message = left[1].DisplayName .. " is the last one standing!" }
		elseif #left == 0 and botsLeft > 0 then
			-- bots are contestants too: every player fell before them
			result = { winners = {}, message = "🤖 The bots outlasted everyone! Practice makes perfect." }
		elseif #left == 0 and before > 0 then
			-- the last players fell at the exact same moment: they share the win
			result = { winners = batch, message = names(batch) .. " fell together - it's a tie!" }
		end
	elseif #left == 0 then
		result = { winners = {}, message = "You got knocked off! Practice makes perfect." }
	end
end

-- a bot fell off: if that leaves one player and no bots, that player wins
local function botOut(bot)
	if not bot.alive then return end
	Bots.remove(bot, 0.5)
	if result then return end
	local left = aliveList()
	local botsLeft = Bots.aliveCount(bots)
	if startedWith >= 2 and #left == 1 and botsLeft == 0 then
		result = { winners = left, message = left[1].DisplayName .. " is the last one standing!" }
	end
end

local function placeOnSpawn(player, spawnPart)
	local char = player.Character
	if not char or not spawnPart then return end
	char:PivotTo(spawnPart.CFrame + Vector3.new(0, 3, 0))
end

-- every 0.1s: anyone who dropped below the platform is out
local tick = 0
local rescuedUntil = {} -- [player] = os.clock() time; a boost save makes you safe for a moment
local function onHeartbeat(dt)
	tick += dt
	if tick < 0.1 or not map then return end
	tick = 0
	local outY = map:GetAttribute("OutY")
	local fallers = {}
	for p in alive do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if rescuedUntil[p] and os.clock() < rescuedUntil[p] then
			-- just saved: the player's computer needs a moment to catch up with the teleport
		elseif root and root.Position.Y < outY and Boost.useShield(p) then
			rescuedUntil[p] = os.clock() + 1.5
			-- BOOST: saved once! back onto the platform
			local spawns = map.Spawns:GetChildren()
			placeOnSpawn(p, spawns[math.random(#spawns)])
			root.AssemblyLinearVelocity = Vector3.zero
			toast("⚡ Your boost saved you! No more saves this round.", true, { p })
		elseif not root or root.Position.Y < outY then
			table.insert(fallers, p)
		end
	end
	if #fallers > 0 then eliminate(fallers) end
end

local function speedAt(t)
	return math.min(MAX_SPEED, START_SPEED + ACCELERATION * math.max(0, t))
end

------------------------------------------------------------------ bots (small servers)
-- Players' own screens work out whether the bar hit them (SpinBarClient). Bots have no screen, so the
-- server does the same maths for them here: where the bar is, whether it swept across the bot this frame,
-- and - for their "brain" - how long until it arrives, so they can jump in time.
local function turnedAt(t, s0, acc, maxS) -- total degrees turned t seconds after the bar started (same as SpinBarClient)
	if t <= 0 then return 0 end
	local tc = (maxS - s0) / acc
	if t < tc then return s0 * t + 0.5 * acc * t * t end
	return s0 * tc + 0.5 * acc * tc * tc + maxS * (t - tc)
end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end

local prevAngle = nil
local pieceSpots = nil -- { { piece, pos } }: where each floor piece is, for bots choosing where to stand
local function botStep()
	if not map or result or #bots == 0 then return end
	local now = workspace:GetServerTimeNow()
	local start = map:GetAttribute("SpinStart") or 0
	local dir = map:GetAttribute("Dir") or 1
	local t = start ~= 0 and now - start or -1
	local angle = (map:GetAttribute("StartAngle") or 0) + dir * math.rad(turnedAt(t, START_SPEED, ACCELERATION, MAX_SPEED))
	local speed = t > 0 and speedAt(t) or 0 -- degrees per second
	local prev = prevAngle or angle
	prevAngle = angle
	local center, barY, barR, barLen = map:GetAttribute("Center"), map:GetAttribute("BarY"), map:GetAttribute("BarRadius"), map:GetAttribute("BarLength")
	local outY = map:GetAttribute("OutY")
	local clock = os.clock()
	for _, bot in bots do
		if bot.alive then
			local root, hum, d = bot.root, bot.humanoid, bot.data
			local pos = root.Position
			if not root.Parent or hum.Health <= 0 or pos.Y < outY then
				botOut(bot)
			elseif clock >= (d.tumbleUntil or 0) then
				local dx, dz = pos.X - center.X, pos.Z - center.Z
				local r = math.sqrt(dx * dx + dz * dz)
				local me = math.atan2(-dz, dx)
				if t > 0 then
					-- 1) did the bar sweep across this bot since the last frame?
					local feet = Bots.feetY(bot)
					local swept = (angle - prev) * dir
					local rel = wrap((me - prev) * dir)
					local margin = math.atan((barR + 1.2) / math.max(r, 0.5))
					local inReach = r >= 2.5 and r <= barLen + 1.2 and feet <= barY + barR and feet + 5 >= barY - barR
					if t > BOT_GRACE and inReach and swept >= 0 and swept < math.pi and rel >= -margin and rel <= swept + margin then
						local sideways = Vector3.new(-math.sin(angle), 0, -math.cos(angle)) * dir
						local outward = r > 0.1 and Vector3.new(dx, 0, dz).Unit or sideways
						Bots.knock(bot, sideways * 75 + outward * 45 + Vector3.new(0, 45, 0), 1.2)
						d.tumbleUntil = clock + 1.2
					elseif speed > 0 then
						-- 2) the bar is coming: jump just before it gets here (sometimes they get it wrong)
						local ahead = wrap((me - angle) * dir)
						if ahead < 0 then ahead += 2 * math.pi end
						local eta = ahead / math.rad(speed)
						d.lead = d.lead or BOT_JUMP_LEAD
						if eta <= d.lead and (d.lastEta or math.huge) > d.lead then
							local miss = (d.clumsy or 0) + BOT_MISS + BOT_MISS_FAST * math.clamp((speed - START_SPEED) / (MAX_SPEED - START_SPEED), 0, 1)
							if math.random() > miss then Bots.jump(bot) end
							d.lead = BOT_JUMP_LEAD + (math.random() - 0.5) * 0.1
						end
						d.lastEta = eta
					end
				end
				-- 3) wander: stand on a piece of floor that's still there (and get off one that's about to drop).
				--    Bots keep away from the middle, walk AROUND the ring, and - before the bar starts - move out of
				--    its way, the same as a player picking a spot.
				local standing = d.piece and not d.piece:GetAttribute("Fallen")
				local waiting = t <= 0 -- the bar hasn't started yet
				local inBarsWay = waiting and math.abs(wrap(me - angle)) < BOT_CLEAR_ANGLE and clock >= (d.clearAgainAt or 0)
				if pieceSpots and (clock >= (d.nextMove or 0) or (d.piece and not standing) or inBarsWay) then
					d.nextMove = clock + 2.5 + math.random() * 3
					if inBarsWay then d.clearAgainAt = clock + 1.5 end -- (still there in a moment? pick another spot)
					local choices, anyRing, anywhere = {}, {}, {}
					for _, spot in pieceSpots do
						if not spot.piece:GetAttribute("Fallen") then
							table.insert(anywhere, spot)
							local clearOfBar = not waiting or math.abs(wrap(spot.angle - angle)) > BOT_CLEAR_ANGLE * 1.4
							if spot.r >= BOT_MIN_RADIUS and clearOfBar then
								table.insert(anyRing, spot)
								if math.abs(wrap(spot.angle - me)) <= BOT_MAX_TURN then table.insert(choices, spot) end
							end
						end
					end
					if #choices == 0 then choices = anyRing end   -- nothing close by: any good spot on the ring
					if #choices == 0 then choices = anywhere end  -- the floor is nearly gone: anything still standing
					if #choices > 0 then
						local spot = choices[math.random(#choices)]
						d.piece = spot.piece
						hum:MoveTo(Vector3.new(spot.pos.X, pos.Y, spot.pos.Z))
					else
						d.piece = nil
						hum:MoveTo(Vector3.new(center.X + math.random(-5, 5), pos.Y, center.Z + math.random(-5, 5)))
					end
				end
			end
		end
	end
end

local function speedMessages(token)
	local startSpeed = START_SPEED
	while true do
		task.wait(SPEEDUP_MESSAGE_EVERY)
		if token ~= round or result or not map then return end
		local t = workspace:GetServerTimeNow() - map:GetAttribute("SpinStart")
		local s = speedAt(t)
		if s >= MAX_SPEED then
			toast("TOP SPEED! Hang in there!", true, aliveList())
			return
		end
		toast(string.format("Faster! Bar speed x%.1f", s / startSpeed), true, aliveList())
	end
end

------------------------------------------------------------------ the crumbling floor
local TweenService = game:GetService("TweenService")
local fallTweens = {}
local function pieceParts(piece)
	local list = {}
	for _, p in piece:GetChildren() do if p:IsA("BasePart") then table.insert(list, p) end end
	return list
end
local function resetFloor()
	for _, tw in fallTweens do tw:Cancel() end
	fallTweens = {}
	local folder = map and map.Platform:FindFirstChild("Pieces")
	if not folder then return end
	for _, piece in folder:GetChildren() do
		piece:SetAttribute("Fallen", nil)
		for _, p in pieceParts(piece) do
			p.CFrame = p:GetAttribute("Home")
			p.Color = p:GetAttribute("BaseColor")
			p.Transparency = 0
			p.CanCollide = true
		end
	end
end
local function dropPiece(piece, token)
	piece:SetAttribute("Fallen", true)
	local parts = pieceParts(piece)
	-- warning: shake + flash red
	local t0 = os.clock()
	local red = false
	while os.clock() - t0 < FALL_WARN do
		if token ~= round then return end
		red = not red
		local jiggle = Vector3.new(math.random(-10, 10) / 100, math.random(-12, 4) / 100, math.random(-10, 10) / 100)
		for _, p in parts do
			p.Color = red and Color3.fromRGB(200, 50, 40) or p:GetAttribute("BaseColor")
			p.CFrame = p:GetAttribute("Home") + jiggle
		end
		task.wait(0.12)
	end
	if token ~= round then return end
	-- drop it into the goo
	for _, p in parts do
		p.CanCollide = false
		local spin = CFrame.Angles(math.rad(math.random(-25, 25)), 0, math.rad(math.random(-25, 25)))
		local tw = TweenService:Create(p, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ CFrame = (p:GetAttribute("Home") - Vector3.new(0, 45, 0)) * spin, Transparency = 1 })
		table.insert(fallTweens, tw)
		tw:Play()
	end
end
local function crumbleLoop(token)
	local spinStart = map:GetAttribute("SpinStart")
	while workspace:GetServerTimeNow() < spinStart + fallFrom do
		task.wait(0.25)
		if token ~= round or result or not map then return end
	end
	toast("⚠️ The floor is CRUMBLING! Watch for red pieces!", false, aliveList())
	local folder = map.Platform:FindFirstChild("Pieces")
	if not folder then return end
	local total = #folder:GetChildren()
	local gap = FALL_EVERY_START
	while token == round and not result and map do
		local standing = {}
		for _, piece in folder:GetChildren() do
			if not piece:GetAttribute("Fallen") then table.insert(standing, piece) end
		end
		if #standing <= total * KEEP_FRACTION then return end
		task.spawn(dropPiece, standing[math.random(#standing)], token)
		task.wait(gap)
		gap = math.max(FALL_EVERY_MIN, gap * 0.9)
	end
end

------------------------------------------------------------------ the hub guard
-- Players used to jump on top of the hub in the middle (the cylinder the bar spins around) and stand there,
-- where the bar can never reach them. An invisible, very tall column now stands on the hub: jump at it and
-- you just bump into it and slide back down to the floor - even with the Low Gravity twist.
-- The column is the part Workspace.Maps.SpinBar.Platform.HubGuard. It starts ABOVE the bar, so the bar spins
-- underneath it as before. If the part ever goes missing (say the map is restored from a backup), this
-- function simply makes it again at the start of the round.
local function guardHub()
	local platform = map and map:FindFirstChild("Platform")
	local hub = platform and platform:FindFirstChild("HubTop") -- the wide top piece of the hub
	if not hub then return end
	local guard = platform:FindFirstChild("HubGuard")
	if not guard then
		guard = Instance.new("Part")
		guard.Name = "HubGuard"
		guard.Shape = Enum.PartType.Cylinder
		guard.Anchored = true
		guard.Transparency = 1 -- invisible
		guard.CastShadow = false
		guard.CanTouch = false
		guard.Parent = platform
	end
	-- (a cylinder part lies on its side: Size.X is its length, Size.Y and Size.Z are how wide it is.
	--  HubTop is turned upright, so its Size.X is its height.)
	local width = hub.Size.Y + HUB_GUARD_EXTRA * 2
	local bottomY = hub.Position.Y - hub.Size.X / 2 -- start at the underside of the hub's top piece...
	guard.Size = Vector3.new(HUB_GUARD_HEIGHT, width, width)
	guard.CFrame = CFrame.new(hub.Position.X, bottomY + HUB_GUARD_HEIGHT / 2, hub.Position.Z) * CFrame.Angles(0, 0, math.pi / 2) -- ...and go straight up
	guard.CanCollide = true
end

------------------------------------------------------------------ the Mode interface (RoundManager calls these)
function SpinBar.start(newMap, players)
	round += 1
	map = newMap
	alive, result = {}, nil
	startedWith = #players
	Bots.clear(bots)
	prevAngle = nil
	resetFloor()
	guardHub() -- nobody can stand on top of the middle hub

	-- the bar holds still until begin(); random direction each round keeps people guessing
	map:SetAttribute("SpinStart", 0)
	map:SetAttribute("StartAngle", math.random() * math.pi * 2)
	map:SetAttribute("Dir", math.random(2) == 1 and 1 or -1)
	map:SetAttribute("StartSpeed", START_SPEED)
	map:SetAttribute("Accel", ACCELERATION)
	map:SetAttribute("MaxSpeed", MAX_SPEED)

	local spawns = map.Spawns:GetChildren()
	local nextSpawn = math.random(#spawns)
	for _, player in players do
		alive[player] = true
		player:SetAttribute("SpinBarAlive", true)
		placeOnSpawn(player, spawns[nextSpawn])
		nextSpawn = nextSpawn % #spawns + 1
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			table.insert(connections, hum.Died:Connect(function()
				if alive[player] then eliminate({ player }) end
			end))
		end
	end

	-- SMALL SERVERS: bots take the next spawns along; fewer contestants = the floor crumbles sooner
	local botSpots = {}
	for _ = 1, Scaling.botCount("SpinBar", #players) do
		table.insert(botSpots, spawns[nextSpawn].CFrame)
		nextSpawn = nextSpawn % #spawns + 1
	end
	bots = Bots.create(#botSpots, botSpots, map)
	for _, bot in bots do bot.data.clumsy = math.random() * BOT_CLUMSY end -- some bots are better than others
	startedWith = #players + #bots
	fallFrom = startedWith <= 4 and SMALL_FALL_FROM or FALL_FROM
	pieceSpots = {}
	local folder = map.Platform:FindFirstChild("Pieces")
	for _, piece in folder and folder:GetChildren() or {} do
		local part = piece:FindFirstChildWhichIsA("BasePart")
		local home = part and part:GetAttribute("Home")
		if home then
			local c = map:GetAttribute("Center")
			local dx, dz = home.Position.X - c.X, home.Position.Z - c.Z
			-- r = how far from the middle, angle = where around the platform (same maths as the bar's angle)
			table.insert(pieceSpots, { piece = piece, pos = home.Position, r = math.sqrt(dx * dx + dz * dz), angle = math.atan2(-dz, dx) })
		end
	end
	if #bots > 0 then
		toast("🤖 " .. #bots .. " bots joined to fill the round. Outlast them all to win!", true, players)
		table.insert(connections, RunService.Heartbeat:Connect(botStep))
	end

	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		if alive[player] then eliminate({ player }) end
	end))
end

-- "GO!"
function SpinBar.begin()
	if not map then return end
	map:SetAttribute("SpinStart", workspace:GetServerTimeNow() + START_DELAY)
	toast("Pick your spot! The bar starts spinning in " .. START_DELAY .. " seconds...", true, aliveList())
	local token = round
	task.delay(START_DELAY, function()
		if token == round and not result then toast("Here comes the bar - JUMP over it!", true, aliveList()) end
	end)
	task.spawn(speedMessages, round)
	task.spawn(crumbleLoop, round)
end

function SpinBar.onCharacterAdded(player, character)
	-- knocked-off players just respawn in the lobby
end

-- clock ran out: everyone still standing wins
function SpinBar.timeUp()
	if result then return end
	local left = aliveList()
	if #left > 0 then
		result = { winners = left, message = names(left) .. " survived the bar!" }
	end
end

function SpinBar.getWinners()
	if not result then return nil end
	local list = {}
	for _, p in result.winners do
		if p.Parent then table.insert(list, p) end
	end
	return list, result.message
end

function SpinBar.stop()
	round += 1
	for _, c in connections do c:Disconnect() end
	connections = {}
	if map then
		map:SetAttribute("SpinStart", 0)
		resetFloor()
	end
	for _, p in Players:GetPlayers() do p:SetAttribute("SpinBarAlive", nil) end
	Bots.clear(bots)
	map, alive, result, startedWith = nil, {}, nil, 0
end

return SpinBar

-- Spins the SpinBar map's bar on this player's screen and knocks you flying if it hits you.
-- The server (Modes.SpinBar) only sets the start time + speed as attributes on the map;
-- every client runs the same math off the same server clock, so everyone sees the same bar.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

------------------------------------------------------------------
-- SETTINGS
local PLAYER_RADIUS = 1.2       -- how "wide" a player counts as for getting hit
local PLAYER_HEIGHT = 5         -- feet to top of head
local KNOCK_SIDEWAYS = 75       -- push in the direction the bar is moving
local KNOCK_OUTWARD = 45        -- push away from the center (toward the edge)
local KNOCK_UP = 45             -- pop up into the air
local TUMBLE_TIME = 1.2         -- seconds you flop around after a hit
------------------------------------------------------------------

local maps = workspace:WaitForChild("Maps")

-- total angle (degrees) the bar has turned t seconds after it started
local function turnedAt(t, s0, acc, maxS)
	if t <= 0 then return 0 end
	local tc = (maxS - s0) / acc -- time when it reaches top speed
	if t < tc then
		return s0 * t + 0.5 * acc * t * t
	end
	return s0 * tc + 0.5 * acc * tc * tc + maxS * (t - tc)
end

local function barAngle(map, now)
	local start = map:GetAttribute("SpinStart") or 0
	local a0 = map:GetAttribute("StartAngle") or 0
	if start == 0 then return a0 end
	local deg = turnedAt(now - start, map:GetAttribute("StartSpeed") or 60, map:GetAttribute("Accel") or 1, map:GetAttribute("MaxSpeed") or 200)
	return a0 + (map:GetAttribute("Dir") or 1) * math.rad(deg)
end

-- wrap an angle into -pi..pi
local function wrap(a)
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local lastAngle = nil
local tumbleUntil = 0

local function knock(root, hum, angle, dir, center)
	tumbleUntil = os.clock() + TUMBLE_TIME
	-- the bar points along (cos a, 0, -sin a); it moves along the derivative of that
	local sideways = Vector3.new(-math.sin(angle), 0, -math.cos(angle)) * dir
	local flat = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
	local outward = flat.Magnitude > 0.1 and flat.Unit or sideways
	hum.PlatformStand = true -- go limp so you tumble instead of landing on your feet
	root.AssemblyLinearVelocity = sideways * KNOCK_SIDEWAYS + outward * KNOCK_OUTWARD + Vector3.new(0, KNOCK_UP, 0)
	root.AssemblyAngularVelocity = Vector3.new(math.random(-15, 15), math.random(-15, 15), math.random(-15, 15))
	task.delay(TUMBLE_TIME, function()
		if hum.Parent then hum.PlatformStand = false end
	end)
end

RunService.RenderStepped:Connect(function()
	local map = maps:FindFirstChild("SpinBar")
	if not map then return end
	local now = workspace:GetServerTimeNow()
	local angle = barAngle(map, now)
	local center = map:GetAttribute("Center")
	local barY = map:GetAttribute("BarY")

	-- 1) spin the bar on my screen
	local bar = map:FindFirstChild("Bar")
	-- (the Bar model's pivot is its upright center point - don't give it a PrimaryPart,
	--  or it would pivot around the tilted collar and the bar would point down)
	if bar then
		bar:PivotTo(CFrame.new(center.X, barY, center.Z) * CFrame.Angles(0, angle, 0))
	end

	-- 2) did it hit me? (only while I'm in the round and the bar is moving)
	local prev = lastAngle or angle
	lastAngle = angle
	if not player:GetAttribute("SpinBarAlive") or (map:GetAttribute("SpinStart") or 0) == 0 then return end
	if os.clock() < tumbleUntil then return end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return end

	local barR = map:GetAttribute("BarRadius")
	local barLen = map:GetAttribute("BarLength")
	-- height check: are my feet below the top of the bar (and my head above its bottom)?
	local feet = root.Position.Y - root.Size.Y / 2 - hum.HipHeight
	if feet > barY + barR or feet + PLAYER_HEIGHT < barY - barR then return end
	-- distance from the center: is the bar long enough to reach me?
	local dx, dz = root.Position.X - center.X, root.Position.Z - center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	if r < 2.5 or r > barLen + PLAYER_RADIUS then return end
	-- angle check: did the bar sweep across me since last frame? (works even when it's super fast)
	local dir = map:GetAttribute("Dir") or 1
	local me = math.atan2(-dz, dx)
	local margin = math.atan((barR + PLAYER_RADIUS) / r)
	local swept = (angle - prev) * dir          -- how far it moved this frame (positive)
	local rel = wrap((me - prev) * dir)         -- where I am relative to where the bar was
	if swept >= 0 and swept < math.pi and rel >= -margin and rel <= swept + margin then
		knock(root, hum, angle, dir, center)
	end
end)

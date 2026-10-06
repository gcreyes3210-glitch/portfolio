-- Fades Hex Spleef tiles on this player's screen.
-- The server (Modes.HexSpleef) puts a "FallAt" time on a tile when someone steps on it.
-- From then until FallAt, this script fades the tile away SMOOTHLY (no flicker, no sudden pop at the end):
-- it turns paler and more see-through the whole time, slowly at first and faster near the end.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

------------------------------------------------------------------
-- SETTINGS
local FADE_TIME = 2.5        -- should match TILE_FADE_TIME in Modes.HexSpleef
local MAX_FADE = 1           -- how see-through a tile is at the moment it drops (1 = completely gone: no pop)
local FADE_CURVE = 1.6       -- 1 = fades at a steady speed; bigger = stays visible longer, then goes quickly
local FLICKER_LAST = 0       -- seconds of flicker at the end (0 = none: a smooth fade)
local FADE_COLOR = Color3.new(1, 1, 1) -- tiles turn whiter as they fade
------------------------------------------------------------------

local fading = {}     -- [tile] = true while fading
local baseColor = {}  -- [part] = its normal color

local function parts(tile)
	local list = {}
	for _, p in tile:GetChildren() do
		if p:IsA("BasePart") then
			if not baseColor[p] then baseColor[p] = p.Color end
			table.insert(list, p)
		end
	end
	return list
end

-- back to normal (new round)
local function restore(tile)
	fading[tile] = nil
	for _, p in parts(tile) do
		p.Color = baseColor[p]
		if p.CanCollide then p.Transparency = 0 end
	end
end

local function watch(tile)
	parts(tile) -- remember the starting colors
	local function update()
		if tile:GetAttribute("FallAt") then
			fading[tile] = true
		else
			restore(tile)
		end
	end
	tile:GetAttributeChangedSignal("FallAt"):Connect(update)
	update()
end

CollectionService:GetInstanceAddedSignal("HexTile"):Connect(watch)
CollectionService:GetInstanceRemovedSignal("HexTile"):Connect(function(tile)
	fading[tile] = nil
end)
for _, tile in CollectionService:GetTagged("HexTile") do
	watch(tile)
end

RunService.RenderStepped:Connect(function()
	local now = workspace:GetServerTimeNow()
	for tile in fading do
		local fallAt = tile:GetAttribute("FallAt")
		if not fallAt or not tile.Parent then
			fading[tile] = nil
		else
			local left = fallAt - now
			local t = math.clamp(1 - left / FADE_TIME, 0, 1)   -- 0 = just stepped on, 1 = gone
			local transparency = (t ^ FADE_CURVE) * MAX_FADE
			if left <= FLICKER_LAST and left > 0 and math.floor(now * 10) % 2 == 0 then
				transparency = math.min(1, transparency + 0.2) -- quick flicker = warning!
			end
			if left <= 0 then transparency = 1 end
			for _, p in parts(tile) do
				p.Transparency = transparency
				p.Color = baseColor[p]:Lerp(FADE_COLOR, t * 0.6)
			end
			if left <= 0 then fading[tile] = nil end
		end
	end
end)

-- GLASS BRIDGE on your screen:
--  * the panel (small, top-right): what to do / "hurry!" / "you made it!", a progress bar across the
--    bridge with a dot for YOU, the time left, and how many made it across
--  * ticks in the last 5 seconds
-- Reads what ServerScriptService.Modes.GlassBridge publishes:
--   player attributes: GlassPlayer, GlassOut, GlassFinished (your place)
--   map attributes:    GlassEnds (server time), GlassOnBridge, GlassAcross, GlassTotal; and the map's StartZ / FinishZ
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local CREAM = Color3.fromRGB(240, 248, 255)
local INK = Color3.fromRGB(34, 40, 90)
local ICE = Color3.fromRGB(80, 150, 230)
local HURRY = Color3.fromRGB(245, 130, 40)
local WIN = Color3.fromRGB(70, 185, 95)
local TICK_SOUND = "rbxasset://sounds/button.wav"

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 12) }, o) end
local function outline(o, t) new("UIStroke", { Color = INK, Thickness = t or 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
local function text(parent, props)
	local l = new("TextLabel", { BackgroundTransparency = 1, Font = FONT, TextScaled = true, TextColor3 = Color3.new(1, 1, 1), TextStrokeColor3 = INK, TextStrokeTransparency = 0.1 }, parent)
	for k, v in props do l[k] = v end
	return l
end

local function getMap()
	local maps = workspace:FindFirstChild("Maps")
	return maps and maps:FindFirstChild("GlassBridge")
end

------------------------------------------------------------------ the panel
local gui = new("ScreenGui", { Name = "GlassBridgeUI", ResetOnSpawn = false, Enabled = false }, player:WaitForChild("PlayerGui"))
local panel = new("Frame", { Size = UDim2.fromOffset(360, 124), BackgroundColor3 = CREAM }, gui)
require(ReplicatedStorage:WaitForChild("CornerHUD")).dock(panel) -- small, top-right
corner(panel, 22); outline(panel, 3)

local chip = new("Frame", { Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(340, 52), BackgroundColor3 = ICE }, panel)
corner(chip, 16); outline(chip, 3)
local chipText = text(chip, { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 1, -12), Text = "" })

-- progress across the bridge: left = start ledge, right = finish
local barBack = new("Frame", { Position = UDim2.fromOffset(12, 70), Size = UDim2.fromOffset(336, 16), BackgroundColor3 = Color3.fromRGB(210, 225, 245) }, panel)
corner(barBack, 8)
local barFill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(150, 210, 255) }, barBack)
corner(barFill, 8)
text(barBack, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -2, 0.5, 0), Size = UDim2.fromOffset(16, 16), Text = "🏁", ZIndex = 3 })
local me = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = Color3.fromRGB(255, 220, 70), ZIndex = 4 }, barBack)
corner(me, 9); outline(me, 2)
local infoText = text(panel, { Position = UDim2.fromOffset(12, 92), Size = UDim2.new(1, -24, 0, 24), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = INK, TextStrokeTransparency = 1, Text = "" })

local function uiSound(id, volume, speed)
	local s = new("Sound", { SoundId = id, Volume = volume or 0.5, PlaybackSpeed = speed or 1 }, gui)
	s:Play()
	Debris:AddItem(s, 2)
end

------------------------------------------------------------------ every frame
local lastTick = nil
RunService.RenderStepped:Connect(function()
	local map = getMap()
	local playing = player:GetAttribute("GlassPlayer") == true and player:GetAttribute("GlassOut") ~= true
	gui.Enabled = playing and map ~= nil
	if not gui.Enabled then return end

	local now = workspace:GetServerTimeNow()
	local ends = map:GetAttribute("GlassEnds") or 0
	local left = ends > 0 and math.max(0, ends - now) or nil
	local place = player:GetAttribute("GlassFinished")
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local startZ = map:GetAttribute("StartZ") or 0
	local finishZ = map:GetAttribute("FinishZ") or 1
	local progress = root and math.clamp((root.Position.Z - startZ) / (finishZ - startZ), 0, 1) or 0
	if place then progress = 1 end

	if place then
		chip.BackgroundColor3 = WIN
		chipText.Text = "🎉 You made it across!"
	elseif not left then
		chip.BackgroundColor3 = ICE
		chipText.Text = "🌉 Get ready..."
	elseif left <= 20 then
		chip.BackgroundColor3 = HURRY:Lerp(Color3.fromRGB(230, 70, 50), 0.5 + 0.5 * math.sin(os.clock() * 8))
		chipText.Text = "⏰ Hurry! " .. math.ceil(left) .. "s left!"
		local whole = math.ceil(left)
		if whole <= 5 and whole >= 1 and whole ~= lastTick then
			lastTick = whole
			uiSound(TICK_SOUND, 0.5, 1 + (5 - whole) * 0.1)
		end
	else
		chip.BackgroundColor3 = ICE
		chipText.Text = "🌉 Jump! Half the glass breaks!"
	end

	barFill.Size = UDim2.fromScale(progress, 1)
	me.Position = UDim2.fromScale(math.clamp(progress, 0.02, 0.94), 0.5)

	local timeText = left and string.format("⏱ %d:%02d", math.floor(left) // 60, math.floor(left) % 60) or "⏱ --"
	infoText.Text = timeText .. "  •  🏁 " .. (map:GetAttribute("GlassAcross") or 0) .. " across  •  🙂 " .. (map:GetAttribute("GlassOnBridge") or 0) .. " on the bridge"
end)

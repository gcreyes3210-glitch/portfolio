-- The skill check for Tug of War: a red needle spins around a circle.
-- Press SPACE (or tap the button) while the needle is inside the white box to pull.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local event = ReplicatedStorage:WaitForChild("TugOfWarEvent")

------------------------------------------------------------------
-- SETTINGS
local NEEDLE_SPEED = 300   -- degrees per second
local ZONE_SIZE = 26       -- how wide the target box is at the start, in degrees (was 34)
local ZONE_SHRINK = 1      -- the box gets this many degrees smaller after every good pull...
local MIN_ZONE = 18        -- ...but never smaller than this
local GRACE = 2            -- extra degrees of forgiveness on each side of the box
local MISS_LOCKOUT = 0.6   -- seconds you can't try again after a miss
local RADIUS = 110         -- circle size in pixels
------------------------------------------------------------------

local player = Players.LocalPlayer
local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- build the UI
local gui = Instance.new("ScreenGui")
gui.Name = "SkillCheck"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local dial = Instance.new("Frame")
dial.AnchorPoint = Vector2.new(0.5, 1)
dial.Position = UDim2.new(0.5, 0, 1, -40)
dial.Size = UDim2.fromOffset(RADIUS * 2, RADIUS * 2)
dial.BackgroundColor3 = Color3.fromRGB(12, 16, 26)
dial.BackgroundTransparency = 0.25
dial.Parent = gui
Instance.new("UICorner", dial).CornerRadius = UDim.new(1, 0)
local ring = Instance.new("UIStroke", dial)
ring.Color = Color3.new(1, 1, 1)
ring.Thickness = 3

local function holder()
	local h = Instance.new("Frame")
	h.Size = UDim2.fromScale(1, 1)
	h.BackgroundTransparency = 1
	h.Parent = dial
	return h -- rotating this spins its children around the circle's center
end

local zoneHolder = holder()
local zone = Instance.new("Frame")
zone.AnchorPoint = Vector2.new(0.5, 0.5)
zone.Position = UDim2.new(0.5, 0, 0, 0)
local zoneSize = ZONE_SIZE
local function sizeZone() zone.Size = UDim2.fromOffset(2 * math.pi * RADIUS * zoneSize / 360, 18) end
sizeZone()
zone.BackgroundColor3 = Color3.new(1, 1, 1)
zone.BackgroundTransparency = 0.75
zone.Parent = zoneHolder
Instance.new("UICorner", zone).CornerRadius = UDim.new(0, 4)
local zoneStroke = Instance.new("UIStroke", zone)
zoneStroke.Color = Color3.new(1, 1, 1)
zoneStroke.Thickness = 3

local needleHolder = holder()
local needle = Instance.new("Frame")
needle.AnchorPoint = Vector2.new(0.5, 0)
needle.Position = UDim2.new(0.5, 0, 0, -6)
needle.Size = UDim2.new(0, 5, 0.5, 6)
needle.BackgroundColor3 = Color3.fromRGB(235, 45, 45)
needle.BorderSizePixel = 0
needle.Parent = needleHolder
Instance.new("UICorner", needle).CornerRadius = UDim.new(1, 0)

local button = Instance.new("TextButton")
button.AnchorPoint = Vector2.new(0.5, 0.5)
button.Position = UDim2.fromScale(0.5, 0.5)
button.Size = UDim2.fromOffset(130, 46)
button.BackgroundColor3 = Color3.new(0, 0, 0)
button.Text = touch and "TAP" or "Space"
button.TextColor3 = Color3.fromRGB(170, 170, 170)
button.Font = Enum.Font.GothamBold
button.TextSize = 30
button.AutoButtonColor = false
button.Parent = dial
Instance.new("UICorner", button).CornerRadius = UDim.new(0, 10)
local bStroke = Instance.new("UIStroke", button)
bStroke.Color = Color3.new(1, 1, 1)
bStroke.Thickness = 3
bStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

local feedback = Instance.new("TextLabel")
feedback.AnchorPoint = Vector2.new(0.5, 1)
feedback.Position = UDim2.new(0.5, 0, 0, -8)
feedback.Size = UDim2.fromOffset(240, 40)
feedback.BackgroundTransparency = 1
feedback.Font = Enum.Font.GothamBlack
feedback.TextSize = 32
feedback.Text = ""
feedback.TextStrokeTransparency = 0
feedback.Parent = dial

-- the game
local active = false
local needleAngle, zoneAngle = 0, 180
local lockedUntil = 0

local function newZone()
	-- put the next box at least 100 degrees ahead of the needle
	zoneAngle = (needleAngle + math.random(100, 300)) % 360
	zoneHolder.Rotation = zoneAngle
	sizeZone()
end

local function flash(text, color)
	feedback.Text = text
	feedback.TextColor3 = color
	ring.Color = color
	task.delay(0.25, function()
		ring.Color = Color3.new(1, 1, 1)
		if feedback.Text == text then feedback.Text = "" end
	end)
end

local function attempt()
	if not active or os.clock() < lockedUntil then return end
	local diff = math.abs((needleAngle - zoneAngle + 540) % 360 - 180)
	if diff <= zoneSize / 2 + GRACE then
		event:FireServer("Pull")
		flash("PULL!", Color3.fromRGB(80, 255, 120))
		zoneSize = math.max(MIN_ZONE, zoneSize - ZONE_SHRINK)
		newZone()
	else
		flash("MISS", Color3.fromRGB(255, 70, 70))
		lockedUntil = os.clock() + MISS_LOCKOUT
	end
end

local function onAction(_, state)
	if state == Enum.UserInputState.Begin then attempt() end
	return Enum.ContextActionResult.Sink -- Space pulls instead of jumping
end
button.Activated:Connect(attempt)

RunService.RenderStepped:Connect(function(dt)
	if not active then return end
	needleAngle = (needleAngle + NEEDLE_SPEED * dt) % 360
	needleHolder.Rotation = needleAngle
	button.TextColor3 = os.clock() < lockedUntil and Color3.fromRGB(90, 90, 90) or Color3.fromRGB(170, 170, 170)
end)

event.OnClientEvent:Connect(function(message)
	if message == "Start" then
		active = true
		needleAngle = 0
		zoneSize = ZONE_SIZE -- fresh round, full-size box again
		newZone()
		gui.Enabled = true
		ContextActionService:BindActionAtPriority("TugPull", onAction, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
	elseif message == "Stop" then
		active = false
		gui.Enabled = false
		ContextActionService:UnbindAction("TugPull")
	end
end)

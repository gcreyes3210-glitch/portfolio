-- KING OF THE HILL score panel (small, top-right, only while you're playing King of the Hill).
-- Reads what ServerScriptService.Modes.KingOfTheHill publishes:
--   player attributes: KothPlayer (playing?), KothScore (your points), KothZone ("king" / "shared" / nil)
--   map attributes:    KothKing, KothLeader, KothLeaderScore, KothTarget, KothDouble
-- Also: spins the giant crown over the hill, and makes you stumble over when you get bonked.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local CREAM = Color3.fromRGB(255, 248, 236)
local INK = Color3.fromRGB(64, 44, 84)
local GOLD = Color3.fromRGB(255, 196, 40)
local RED = Color3.fromRGB(240, 80, 70)
local PURPLE = Color3.fromRGB(120, 60, 170)

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 12) }, o) end
local function outline(o, t) new("UIStroke", { Color = INK, Thickness = t or 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
local function text(parent, props)
	local l = new("TextLabel", { BackgroundTransparency = 1, Font = FONT, TextScaled = true, TextColor3 = Color3.new(1, 1, 1), TextStrokeColor3 = INK, TextStrokeTransparency = 0.2 }, parent)
	for k, v in props do l[k] = v end
	return l
end

------------------------------------------------------------------ the panel
local gui = new("ScreenGui", { Name = "KingHillUI", ResetOnSpawn = false, Enabled = false }, player:WaitForChild("PlayerGui"))
local panel = new("Frame", { Size = UDim2.fromOffset(380, 128), BackgroundColor3 = CREAM }, gui)
require(ReplicatedStorage:WaitForChild("CornerHUD")).dock(panel) -- small, top-right
corner(panel, 22); outline(panel, 3)

-- what's happening to YOU right now
local chip = new("Frame", { Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 0, 38), BackgroundColor3 = PURPLE }, panel)
corner(chip, 14); outline(chip, 3)
local stateText = text(chip, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 1, -8), Text = "⛰️ CLIMB TO THE CROWN!" })

-- your points out of the target
local bar = new("Frame", { Position = UDim2.fromOffset(10, 56), Size = UDim2.new(1, -20, 0, 28), BackgroundColor3 = Color3.fromRGB(236, 228, 242), ClipsDescendants = true }, panel)
corner(bar, 14); outline(bar, 3)
local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = GOLD, BorderSizePixel = 0 }, bar)
corner(fill, 14)
local scoreText = text(bar, { Size = UDim2.fromScale(1, 1), Text = "YOU: 0 / 100", ZIndex = 2 })

-- who's winning
local leaderText = text(panel, { Position = UDim2.fromOffset(12, 92), Size = UDim2.new(1, -110, 0, 26), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = INK, TextStrokeTransparency = 1, Text = "" })
local double = new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 90), Size = UDim2.fromOffset(90, 30), BackgroundColor3 = RED, Visible = false }, panel)
corner(double, 12); outline(double, 3)
text(double, { Position = UDim2.fromOffset(4, 3), Size = UDim2.new(1, -8, 1, -6), Text = "⚡ x2" })

local function getMap()
	local maps = workspace:FindFirstChild("Maps")
	return maps and maps:FindFirstChild("KingOfTheHill")
end

local shownScore = -1
local function update()
	local map = getMap()
	gui.Enabled = player:GetAttribute("KothPlayer") == true and map ~= nil
	if not gui.Enabled then return end
	local target = map:GetAttribute("KothTarget") or 100
	local myScore = player:GetAttribute("KothScore") or 0
	local zone = player:GetAttribute("KothZone")
	local kingName = map:GetAttribute("KothKing") or ""
	local doubleOn = map:GetAttribute("KothDouble") == true
	local rate = doubleOn and 2 or 1

	if zone == "king" then
		chip.BackgroundColor3 = GOLD
		stateText.Text = "👑 YOU'RE THE KING!  +" .. (3 * rate) .. "/s"
	elseif zone == "shared" then
		chip.BackgroundColor3 = RED
		stateText.Text = "⚔️ SHARED HILL  +" .. rate .. "/s  - BONK THEM!"
	elseif kingName ~= "" then
		chip.BackgroundColor3 = PURPLE
		stateText.Text = "👑 " .. kingName .. " is King - knock them off!"
	else
		chip.BackgroundColor3 = PURPLE
		stateText.Text = "⛰️ CLIMB TO THE CROWN!"
	end

	scoreText.Text = "YOU: " .. myScore .. " / " .. target
	if myScore ~= shownScore then
		shownScore = myScore
		TweenService:Create(fill, TweenInfo.new(0.25), { Size = UDim2.fromScale(math.clamp(myScore / target, 0, 1), 1) }):Play()
	end
	local leader = map:GetAttribute("KothLeader") or ""
	if leader == "" then
		leaderText.Text = "🥇 Leader: nobody yet"
	elseif leader == player.DisplayName then
		leaderText.Text = "🥇 You're winning!"
	else
		leaderText.Text = "🥇 " .. leader .. ": " .. (map:GetAttribute("KothLeaderScore") or 0)
	end
	double.Visible = doubleOn
end

task.spawn(function()
	while true do
		update()
		task.wait(0.15)
	end
end)

------------------------------------------------------------------ bonked: stumble over for a moment
local function watchCharacter(character)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not (root and humanoid) then return end
	root.ChildAdded:Connect(function(child)
		if child.Name ~= "KothKnock" then return end
		humanoid:ChangeState(Enum.HumanoidStateType.FallingDown)
		task.delay(0.8, function()
			if humanoid.Parent and humanoid:GetState() == Enum.HumanoidStateType.FallingDown then
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	end)
end
player.CharacterAdded:Connect(watchCharacter)
if player.Character then task.spawn(watchCharacter, player.Character) end

------------------------------------------------------------------ the giant crown over the hill slowly spins and bobs
local statue, home = nil, nil
RunService.RenderStepped:Connect(function()
	if not (statue and statue.Parent) then
		local map = getMap()
		local summit = map and map:FindFirstChild("Summit")
		statue = summit and summit:FindFirstChild("CrownStatue")
		home = statue and statue.PrimaryPart and statue:GetPivot()
		if not home then statue = nil return end
	end
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - home.Position).Magnitude > 700 then return end
	local t = os.clock()
	statue:PivotTo(CFrame.new(home.Position + Vector3.new(0, math.sin(t * 1.2) * 2, 0)) * CFrame.Angles(0, t * 0.6, 0))
end)

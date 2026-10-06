-- UI KIT: the look every WIN or DIE menu shares ("Mix" style: dark bold panels + bright colors).
-- MenuUI builds all its windows out of these pieces, so changing a color or font here changes everything.
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Kit = {}

------------------------------------------------------------------ colors + fonts
Kit.C = {
	BG = Color3.fromRGB(30, 28, 40),        -- window background
	HEADER = Color3.fromRGB(21, 19, 29),    -- window title bar
	CARD = Color3.fromRGB(46, 43, 60),      -- item cards
	CARD_EDGE = Color3.fromRGB(70, 66, 90),
	TRACK = Color3.fromRGB(16, 15, 22),     -- empty part of progress bars
	TEXT = Color3.new(1, 1, 1),
	SUB = Color3.fromRGB(196, 190, 214),    -- small grey text
	INK = Color3.fromRGB(18, 16, 26),       -- text outlines
	GOLD = Color3.fromRGB(255, 205, 70),
	PRICE = Color3.fromRGB(245, 204, 88),   -- yellow price pills
	RED = Color3.fromRGB(214, 44, 44),
	GREEN = Color3.fromRGB(96, 214, 110),
	TEAL = Color3.fromRGB(88, 204, 192),
	BLUE = Color3.fromRGB(80, 160, 255),
	PINK = Color3.fromRGB(255, 110, 170),
	PURPLE = Color3.fromRGB(170, 100, 255),
	ORANGE = Color3.fromRGB(255, 150, 50),
	GRAY = Color3.fromRGB(96, 92, 112),
	ROBUX = Color3.fromRGB(80, 200, 100),
}
local C = Kit.C
Kit.HEAD = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)   -- titles, buttons
Kit.BODY = Font.fromEnum(Enum.Font.FredokaOne)                                          -- friendly text

------------------------------------------------------------------ basics
function Kit.new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props or {} do o[k] = v end
	o.Parent = parent
	return o
end
local new = Kit.new
function Kit.corner(o, r) return new("UICorner", { CornerRadius = r and UDim.new(0, r) or UDim.new(0.5, 0) }, o) end
function Kit.stroke(o, color, t, transp)
	return new("UIStroke", { Color = color or C.INK, Thickness = t or 3, Transparency = transp or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
function Kit.lighten(c, a) return c:Lerp(Color3.new(1, 1, 1), a) end
function Kit.darken(c, a) return c:Lerp(Color3.new(0, 0, 0), a) end
function Kit.tween(o, t, props, style, dir)
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

-- a text label; font = Kit.HEAD (default) or Kit.BODY
function Kit.label(parent, props)
	local l = new("TextLabel", {
		BackgroundTransparency = 1, FontFace = Kit.HEAD, TextColor3 = C.TEXT, TextScaled = true,
		TextStrokeColor3 = C.INK, TextStrokeTransparency = 0.35,
	}, parent)
	for k, v in props do l[k] = v end
	return l
end

------------------------------------------------------------------ sounds (menu clicks go in the UI sound group)
Kit.SOUNDS = {
	click = "rbxassetid://88442833509532",
	buy = "rbxassetid://101396758527961",
	fanfare = "rbxassetid://4612374393",
	error = "rbxassetid://124387798635805",
	open = "rbxassetid://88442833509532",
}
function Kit.soundGroup(name)
	local g = SoundService:FindFirstChild(name)
	if not g then g = new("SoundGroup", { Name = name, Volume = 1 }, SoundService) end
	return g
end
function Kit.play(which, volume)
	local id = Kit.SOUNDS[which] or which
	local s = new("Sound", { SoundId = id, Volume = volume or 0.6, SoundGroup = Kit.soundGroup("MenuSounds") }, SoundService)
	SoundService:PlayLocalSound(s)
	task.delay(4, function() s:Destroy() end)
end

------------------------------------------------------------------ squishy buttons
function Kit.bounce(b)
	local s = new("UIScale", {}, b)
	b.MouseEnter:Connect(function() Kit.tween(s, 0.12, { Scale = 1.05 }) end)
	b.MouseLeave:Connect(function() Kit.tween(s, 0.12, { Scale = 1 }) end)
	b.MouseButton1Down:Connect(function() Kit.tween(s, 0.08, { Scale = 0.92 }) end)
	b.MouseButton1Up:Connect(function() Kit.tween(s, 0.2, { Scale = 1 }, Enum.EasingStyle.Back) end)
	return s
end

-- a chunky game button: bright face, lighter shine on top, darker lip underneath
function Kit.button(parent, o)
	local b = new("TextButton", {
		Text = "", AutoButtonColor = false, BackgroundColor3 = Kit.darken(o.color, 0.35),
		Position = o.pos or UDim2.new(), Size = o.size or UDim2.fromOffset(160, 50), AnchorPoint = o.anchor or Vector2.zero,
		LayoutOrder = o.order or 0, ZIndex = o.z or 6,
	}, parent)
	Kit.corner(b, o.radius or 12)
	local face = new("Frame", { Size = UDim2.new(1, 0, 1, -5), BackgroundColor3 = o.color, ZIndex = b.ZIndex }, b)
	Kit.corner(face, o.radius or 12)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Kit.lighten(o.color, 0.15), o.color) }, face)
	local shine = new("Frame", { Position = UDim2.new(0, 10, 0, 5), Size = UDim2.new(1, -20, 0, 5), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.55, ZIndex = b.ZIndex + 1 }, face)
	Kit.corner(shine)
	local text = Kit.label(face, {
		Text = o.text or "", Position = UDim2.new(0, 8, 0, 6), Size = UDim2.new(1, -16, 1, -12), ZIndex = b.ZIndex + 2,
		TextColor3 = o.textColor or C.TEXT, TextStrokeTransparency = o.textColor and 1 or 0.3,
	})
	if o.icon then
		text.Position = UDim2.new(0, 44, 0, 6); text.Size = UDim2.new(1, -52, 1, -12)
		Kit.label(face, { Text = o.icon, Position = UDim2.new(0, 8, 0, 6), Size = UDim2.new(0, 32, 1, -12), TextStrokeTransparency = 1, ZIndex = b.ZIndex + 2 })
	end
	Kit.bounce(b)
	if o.onClick then
		b.Activated:Connect(function()
			Kit.play("click", 0.4)
			o.onClick(b)
		end)
	end
	return b, text, face
end

------------------------------------------------------------------ coins + Robux icons
function Kit.coin(parent, props)
	local c = new("Frame", { BackgroundColor3 = C.GOLD, ZIndex = 8 }, parent)
	for k, v in props do c[k] = v end
	Kit.corner(c); Kit.stroke(c, Color3.fromRGB(190, 130, 20), 2)
	Kit.label(c, { Size = UDim2.fromScale(1, 1), Text = "C", TextColor3 = Color3.fromRGB(190, 120, 20), TextStrokeTransparency = 1, ZIndex = c.ZIndex + 1 })
	return c
end
-- the Robux hexagon: a dark rounded shape with an outlined square inside (drawn, so it always loads)
function Kit.robux(parent, props, color)
	local holder = new("Frame", { BackgroundTransparency = 1, ZIndex = 8 }, parent)
	for k, v in props do holder[k] = v end
	local ink = color or C.INK
	local outer = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.72, 0.72), Rotation = 45, BackgroundTransparency = 1, ZIndex = holder.ZIndex }, holder)
	Kit.corner(outer, 5); Kit.stroke(outer, ink, 3)
	local inner = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.3, 0.3), BackgroundColor3 = ink, ZIndex = holder.ZIndex }, holder)
	Kit.corner(inner, 3)
	return holder
end

-- a yellow price pill: kind "coins" or "robux" (or "text" for things like OWNED / SOON)
function Kit.pricePill(parent, o)
	local color = o.color or C.PRICE
	local b = new("TextButton", {
		Text = "", AutoButtonColor = false, BackgroundColor3 = color, Position = o.pos, Size = o.size or UDim2.fromOffset(150, 44),
		AnchorPoint = o.anchor or Vector2.zero, ZIndex = o.z or 8,
	}, parent)
	Kit.corner(b); Kit.stroke(b, Kit.darken(color, 0.45), 3)
	local hasIcon = o.kind == "coins" or o.kind == "robux"
	if o.kind == "coins" then
		Kit.coin(b, { Position = UDim2.new(0, 6, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.new(0, 30, 0, 30), ZIndex = b.ZIndex + 1 })
	elseif o.kind == "robux" then
		Kit.robux(b, { Position = UDim2.new(0, 6, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.new(0, 32, 0, 32), ZIndex = b.ZIndex + 1 })
	end
	local t = Kit.label(b, {
		Text = tostring(o.text), Position = UDim2.new(0, hasIcon and 42 or 10, 0, 7), Size = UDim2.new(1, hasIcon and -52 or -20, 1, -14),
		TextColor3 = o.textColor or C.INK, TextStrokeTransparency = 1, ZIndex = b.ZIndex + 1,
	})
	Kit.bounce(b)
	if o.onClick then b.Activated:Connect(function() o.onClick(b) end) end
	return b, t
end

------------------------------------------------------------------ round icon medallion (like an achievement badge)
function Kit.medallion(parent, o)
	local size = o.size or 90
	local m = new("Frame", { Size = UDim2.fromOffset(size, size), Position = o.pos or UDim2.new(), AnchorPoint = o.anchor or Vector2.zero,
		BackgroundColor3 = o.color, ZIndex = o.z or 7 }, parent)
	Kit.corner(m)
	Kit.stroke(m, o.ring or Color3.fromRGB(235, 235, 245), math.max(3, size // 22))
	new("UIGradient", { Rotation = 45, Color = ColorSequence.new(Kit.lighten(o.color, 0.3), Kit.darken(o.color, 0.25)) }, m)
	local inner = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.78, 0.78),
		BackgroundTransparency = 0.85, BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = m.ZIndex }, m)
	Kit.corner(inner)
	Kit.label(m, { Text = o.icon or "?", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.48), Size = UDim2.fromScale(0.58, 0.58),
		TextStrokeTransparency = 1, ZIndex = m.ZIndex + 1, TextTransparency = o.dim and 0.45 or 0 })
	if o.tier then
		Kit.label(m, { Text = o.tier, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2), Size = UDim2.new(0.7, 0, 0.28, 0),
			TextStrokeTransparency = 0, ZIndex = m.ZIndex + 2, Rotation = -6 })
	end
	if o.dim then m.BackgroundColor3 = Kit.darken(o.color, 0.35) end
	return m
end

------------------------------------------------------------------ progress bar ("2 / 7")
function Kit.progress(parent, o)
	local track = new("Frame", { Position = o.pos, Size = o.size, BackgroundColor3 = C.TRACK, ZIndex = o.z or 7 }, parent)
	Kit.corner(track)
	local frac = o.goal > 0 and math.clamp(o.value / o.goal, 0, 1) or 0
	local fill = new("Frame", { Size = UDim2.fromScale(frac, 1), BackgroundColor3 = o.color or C.TEAL, Visible = frac > 0, ZIndex = track.ZIndex + 1 }, track)
	Kit.corner(fill)
	if frac > 0 and frac < 0.08 then fill.Size = UDim2.new(0, 14, 1, 0) end -- a sliver still shows
	Kit.label(track, { Text = o.text or (o.value .. " / " .. o.goal), Position = UDim2.new(0, 0, 0, 3), Size = UDim2.new(1, 0, 1, -6),
		TextStrokeTransparency = 0.2, ZIndex = track.ZIndex + 2 })
	return track
end

-- section heading with a line after it ("GAME PASSES ───────")
function Kit.section(parent, textStr, order, color)
	local f = new("Frame", { Size = UDim2.new(1, -8, 0, 40), BackgroundTransparency = 1, LayoutOrder = order }, parent)
	local l = Kit.label(f, { Text = textStr, Size = UDim2.new(0, 0, 1, -6), Position = UDim2.fromOffset(4, 3), AutomaticSize = Enum.AutomaticSize.X,
		TextScaled = false, TextSize = 30, TextColor3 = color or C.GOLD, TextStrokeTransparency = 0.2, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7 })
	new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.new(0.5, 0, 0, 3), BackgroundColor3 = C.CARD_EDGE, BorderSizePixel = 0, ZIndex = 7 }, f)
	return f, l
end

------------------------------------------------------------------ WINDOWS
function Kit.fitScale(w, h)
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	-- leave room at the top for the round status bar
	return math.clamp(math.min(vp.X / ((w or 900) + 60), (vp.Y - 140) / (h or 600)), 0.35, 1)
end

-- a big dark window with a title bar and a red X. Returns a table:
--   w.frame, w.body (content area below the title), w.title (label), w.show(), w.hide(), w.isOpen()
function Kit.window(gui, o)
	local W, H = o.width or 900, o.height or 580
	local frame = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 36), Size = UDim2.fromOffset(W, H),
		BackgroundColor3 = C.BG, Visible = false, ZIndex = 5 }, gui)
	Kit.corner(frame, 18); Kit.stroke(frame, C.INK, 4)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Kit.lighten(C.BG, 0.04), Kit.darken(C.BG, 0.15)) }, frame)
	-- faint pattern of little icons in the background (like the screenshots)
	local pattern = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 5 }, frame)
	for row = 0, 6 do
		for col = 0, 10 do
			Kit.label(pattern, { Text = o.patternIcon or "★", Position = UDim2.fromOffset(col * 90 + (row % 2) * 45, 90 + row * 80), Size = UDim2.fromOffset(40, 40),
				TextTransparency = 0.94, TextStrokeTransparency = 1, Rotation = (row * 17 + col * 29) % 40 - 20, ZIndex = 5 })
		end
	end
	local header = new("Frame", { Size = UDim2.new(1, 0, 0, 84), BackgroundColor3 = C.HEADER, ZIndex = 6 }, frame)
	Kit.corner(header, 18)
	new("Frame", { Position = UDim2.new(0, 0, 1, -18), Size = UDim2.new(1, 0, 0, 18), BackgroundColor3 = C.HEADER, BorderSizePixel = 0, ZIndex = 6 }, header)
	new("Frame", { Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = o.color, BorderSizePixel = 0, BackgroundTransparency = 0.3, ZIndex = 6 }, header)
	local title = Kit.label(header, { Text = o.title, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.new(0.6, 0, 1, -12),
		TextColor3 = o.color, TextStrokeTransparency = 0, ZIndex = 7 })
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Kit.lighten(o.color, 0.35), o.color) }, title)
	local x = new("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(64, 64),
		BackgroundColor3 = C.RED, Text = "", AutoButtonColor = false, ZIndex = 8 }, header)
	Kit.corner(x, 10); Kit.stroke(x, Kit.darken(C.RED, 0.45), 3)
	Kit.label(x, { Text = "X", Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 1, -16), TextColor3 = C.INK, TextStrokeTransparency = 1, ZIndex = 9 })
	Kit.bounce(x)
	local body = new("Frame", { Position = UDim2.fromOffset(20, 100), Size = UDim2.new(1, -40, 1, -116), BackgroundTransparency = 1, ZIndex = 6 }, frame)
	local scale = new("UIScale", {}, frame)

	local w = { frame = frame, body = body, title = title, header = header, closeButton = x, onClose = nil }
	function w.isOpen() return frame.Visible end
	function w.show()
		local target = Kit.fitScale(W, H)
		if not frame.Visible then
			frame.Visible = true
			scale.Scale = target * 0.75
			Kit.tween(scale, 0.25, { Scale = target }, Enum.EasingStyle.Back)
			Kit.play("open", 0.35)
		else
			scale.Scale = target
		end
	end
	function w.hide()
		if not frame.Visible then return end
		Kit.tween(scale, 0.1, { Scale = Kit.fitScale(W, H) * 0.85 }).Completed:Once(function() frame.Visible = false end)
		if w.onClose then w.onClose() end
	end
	function w.rescale() if frame.Visible then scale.Scale = Kit.fitScale(W, H) end end
	x.Activated:Connect(function() Kit.play("click", 0.4); w.hide() end)
	return w
end

-- a row of big tabs ("PASSES + FUN", "EMOTES"...). tabs = { { id, label, icon, color } }
-- returns set(id) to highlight one, and buttons[id] = { button, badge }
function Kit.tabRow(parent, tabs, onPick, o)
	o = o or {}
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, o.height or 70), Position = o.pos or UDim2.new(), BackgroundTransparency = 1, ZIndex = 6 }, parent)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, o.gap or 12), SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = o.align or Enum.HorizontalAlignment.Left, VerticalAlignment = Enum.VerticalAlignment.Center }, row)
	local buttons = {}
	local count = #tabs
	local width = o.width or math.floor(((o.total or 860) - (count - 1) * (o.gap or 12)) / count)
	for i, t in tabs do
		local b = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(width, (o.height or 70) - 6), LayoutOrder = i,
			BackgroundColor3 = C.GRAY, ZIndex = 6 }, row)
		Kit.corner(b, 12)
		local face = new("Frame", { Size = UDim2.new(1, 0, 1, -6), BackgroundColor3 = C.GRAY, ZIndex = 6 }, b)
		Kit.corner(face, 12)
		local grad = new("UIGradient", { Rotation = 90 }, face)
		local shine = new("Frame", { Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -24, 0, 5), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.6, ZIndex = 7 }, face)
		Kit.corner(shine)
		local hasIcon = t.icon and t.icon ~= ""
		if hasIcon then
			Kit.label(face, { Text = t.icon, Position = UDim2.new(0, 10, 0, 8), Size = UDim2.new(0, 40, 1, -14), TextStrokeTransparency = 1, ZIndex = 7 })
		end
		local l = Kit.label(face, { Text = t.label, Position = UDim2.new(0, hasIcon and 54 or 10, 0, 9), Size = UDim2.new(1, hasIcon and -62 or -20, 1, -16), ZIndex = 7, TextStrokeTransparency = 0.2 })
		local badge = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -6, 0, 4), Size = UDim2.fromOffset(28, 28),
			BackgroundColor3 = Color3.fromRGB(235, 60, 60), FontFace = Kit.HEAD, TextScaled = true, TextColor3 = C.TEXT, Text = "!", Visible = false, ZIndex = 9 }, b)
		Kit.corner(badge); Kit.stroke(badge, C.TEXT, 2)
		Kit.bounce(b)
		b.Activated:Connect(function() Kit.play("click", 0.35); onPick(t.id) end)
		buttons[t.id] = { button = b, face = face, grad = grad, label = l, badge = badge, color = t.color }
	end
	local function set(id)
		for tid, x in buttons do
			local on = tid == id
			local col = on and x.color or C.GRAY
			x.face.BackgroundColor3 = col
			x.button.BackgroundColor3 = Kit.darken(col, 0.4)
			x.grad.Color = ColorSequence.new(Kit.lighten(col, on and 0.25 or 0.1), col)
			x.label.TextColor3 = on and C.TEXT or Kit.lighten(C.SUB, 0.2)
		end
	end
	return set, buttons, row
end

------------------------------------------------------------------ HUD pieces for scripts other than MenuUI
-- a big square HUD button with a name under it (the same look as MenuUI's SHOP / INVENTORY buttons).
-- returns the button, its red dot (hidden) and the holder frame
function Kit.hudButton(parent, icon, name, color, order)
	local holder = new("Frame", { Name = name, Size = UDim2.fromOffset(86, 104), BackgroundTransparency = 1, LayoutOrder = order }, parent)
	local b = new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = Kit.darken(color, 0.4), Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(70, 74) }, holder)
	Kit.corner(b, 18)
	local face = new("Frame", { Size = UDim2.new(1, 0, 1, -5), BackgroundColor3 = color }, b)
	Kit.corner(face, 18); Kit.stroke(face, C.INK, 3)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Kit.lighten(color, 0.3), color) }, face)
	local shine = new("Frame", { Position = UDim2.new(0, 10, 0, 6), Size = UDim2.new(1, -20, 0, 6), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.5 }, face)
	Kit.corner(shine)
	Kit.label(face, { Text = icon, Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -24, 1, -22), TextStrokeTransparency = 1 })
	Kit.label(holder, { Text = name, Position = UDim2.fromOffset(-4, 76), Size = UDim2.new(1, 8, 0, 24), TextStrokeTransparency = 0 })
	Kit.bounce(b)
	local dot = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(76, 4), Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = Color3.fromRGB(235, 60, 60), FontFace = Kit.HEAD, TextScaled = true, TextColor3 = C.TEXT, Text = "!", Visible = false, ZIndex = 3 }, holder)
	Kit.corner(dot); Kit.stroke(dot, C.TEXT, 2)
	new("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3) }, dot)
	return b, dot, holder
end

-- a small pill for MenuUI's top row (next to Settings / Emotes). returns the button, its text label and its outline
function Kit.topPill(parent, name, icon, text, order, width)
	local b = new("TextButton", { Name = name, AutoButtonColor = false, Text = "", BackgroundColor3 = C.BG, BackgroundTransparency = 0.1, Size = UDim2.fromOffset(width or 110, 40), LayoutOrder = order }, parent)
	Kit.corner(b)
	local edge = Kit.stroke(b, C.INK, 3)
	Kit.label(b, { Text = icon, Position = UDim2.fromOffset(9, 6), Size = UDim2.fromOffset(28, 28), TextStrokeTransparency = 1 })
	local t = Kit.label(b, { Text = text, Position = UDim2.fromOffset(42, 8), Size = UDim2.new(1, -52, 1, -16), FontFace = Kit.BODY, TextXAlignment = Enum.TextXAlignment.Left })
	Kit.bounce(b)
	return b, t, edge
end

-- OTHER SCRIPTS' WINDOWS: call this once with your window (from Kit.window) and a key ("season"...). It makes
-- your window close when any other window opens, close during rounds (unless keepInRound), and returns open() / toggle().
function Kit.shareWindow(menuGui, key, win, onOpen, keepInRound)
	local signal = menuGui:WaitForChild("WindowOpened")
	local player = game:GetService("Players").LocalPlayer
	local function open()
		signal:Fire(key)
		win.show()
		if onOpen then onOpen() end
	end
	-- any script can open this window with  MenuUI.WindowOpened:Fire("open:" .. key)   (e.g. "open:season")
	signal.Event:Connect(function(k)
		if k == "open:" .. key then
			if not win.isOpen() then open() end
		elseif k ~= key then
			win.hide()
		end
	end)
	player:GetAttributeChangedSignal("InRound"):Connect(function()
		if player:GetAttribute("InRound") and not keepInRound then win.hide() end
	end)
	local cam = workspace.CurrentCamera
	if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(function() win.rescale() end) end
	local function toggle()
		if win.isOpen() then win.hide() else open() end
	end
	return open, toggle
end

return Kit

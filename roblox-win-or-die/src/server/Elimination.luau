-- ELIMINATION GAMES: a second way to play a whole game. Instead of "first to 5 wins", the WORST players of
-- every round are cut until only a few are left - and those few play the Final Showdown for the game.
--   * Every 3rd game on a server is an Elimination game (two classic games, then one of these).
--   * Win the round (or be on the winning team) = you're SAFE.
--   * Everyone else is ranked: knocked out earliest = worst, then the lowest score, and about a third of the
--     players still alive are cut. Cut players watch the rest of the game (ghost tricks, predictions and the
--     twist vote all still work for them) and play again in the next game.
--   * 3 or fewer left = the FINAL SHOWDOWN on the Champion's Ring. Its winner wins the game.
--   * Players who join in the middle of an Elimination game watch until the next game starts.
-- RoundManager asks this module a few questions at fixed moments (prepare / lineup / roundEnded / gameOver);
-- everything else about a round is exactly the same as in a classic game.
-- On screen: StarterPlayerScripts.EliminationClient reads these from ReplicatedStorage.Status:
--   GameFormat ("Elimination" or nil), ElimLeft, ElimStart, ElimRound, ElimFinal, ElimCut (JSON, each round)
--   and each player's attribute ElimState: "Alive" / "Out" (nil = not part of this game).
-- TESTING: select RoundManager and set the attribute ForceFormat = "Elimination" (every game is one, even
--   alone) or "Classic" (never). REMOVE it before publishing!
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")

------------------------------------------------------------------
-- SETTINGS (change these freely)
local EVERY = 3            -- every 3rd game is an Elimination game (0 = never)
local MIN_PLAYERS = 4      -- fewer players than this when the game starts = a classic game instead
local CUT_SHARE = 0.33     -- about this share of the players still alive is cut each round (always at least 1)
local FINAL_AT = 3         -- this many players (or fewer) left = the Final Showdown
local MAX_ROUNDS = 7       -- safety: after this many rounds the next one is the final, whoever is left
local COINS_SURVIVE = 5    -- for everyone who survives a cut
local CHAMPION_COINS = 100 -- only used when the champion wins by being the last one left (everyone else quit);
                           -- a normal win is paid by RoundManager (COINS_FOR_PLACE)
local FINALE_MAP = "FinalShowdown"
------------------------------------------------------------------

local status = ReplicatedStorage:WaitForChild("Status")
local roundManager = script.Parent:WaitForChild("RoundManager")
local Config = require(ReplicatedStorage:WaitForChild("ExtrasConfig"))

-- (loaded when first needed: some of these modules load RoundManager's other helpers)
local function lib(name, folder)
	local parent = folder and script.Parent:FindFirstChild(folder) or script.Parent
	local m = parent and parent:FindFirstChild(name)
	if not m then return nil end
	local ok, mod = pcall(require, m)
	return ok and mod or nil
end
local function toast(text, good, list)
	local Net = lib("Net", "Extras")
	if Net then Net.toast(text, good, list) end
end

local Elim = {}
local gameCount = 0     -- games started on this server
local inGame = false    -- a game (of either kind) is running
local format = "Classic"
local started = false   -- the players of this Elimination game have been fixed (its first round began)
local alive = {}        -- players still in it
local cutOrder = {}     -- everyone cut so far, first cut first
local roster = {}       -- [player] = true for everyone who started this game
local roundNo = 0
local isFinal = false
local serial = 0

local function forced()
	local f = roundManager:GetAttribute("ForceFormat")
	return (f == "Elimination" or f == "Classic") and f or nil
end

local function names(list)
	local out = {}
	for _, p in list do table.insert(out, p.DisplayName) end
	return out
end

local function publish()
	local on = inGame and format == "Elimination"
	status:SetAttribute("GameFormat", on and "Elimination" or nil)
	status:SetAttribute("ElimLeft", on and started and #alive or nil)
	status:SetAttribute("ElimRound", on and started and roundNo or nil)
	status:SetAttribute("ElimFinal", on and isFinal or nil)
	local aliveSet = {}
	for _, p in alive do aliveSet[p] = true end
	for _, p in Players:GetPlayers() do
		local state = nil
		if on and started then state = aliveSet[p] and "Alive" or (roster[p] and "Out" or nil) end
		p:SetAttribute("ElimState", state)
	end
end

local function reset()
	started, isFinal, roundNo = false, false, 0
	alive, cutOrder, roster = {}, {}, {}
	status:SetAttribute("ElimStart", nil)
	status:SetAttribute("ElimCut", nil)
end

-- tell every screen what the cut was: { s = serial, out = {names}, ids = {userIds}, left = n, final = bool, round = n }
local function announce(cut)
	serial += 1
	local ids = {}
	for _, p in cut do table.insert(ids, p.UserId) end
	status:SetAttribute("ElimCut", HttpService:JSONEncode({ s = serial, out = names(cut), ids = ids, left = #alive, final = isFinal, round = roundNo }))
end

local function remove(list, player)
	local i = table.find(list, player)
	if i then table.remove(list, i) end
end

------------------------------------------------------------------ what RoundManager calls
-- top of every lobby countdown. If no game is running, a new one starts here: classic or Elimination?
function Elim.prepare(practice)
	if inGame then return end
	inGame = true
	gameCount += 1
	reset()
	local f = forced()
	if practice or f == "Classic" then
		format = "Classic"
	elseif f == "Elimination" then
		format = "Elimination"
	else
		format = (EVERY > 0 and gameCount % EVERY == 0) and "Elimination" or "Classic"
	end
	publish()
end

function Elim.active()
	return inGame and format == "Elimination"
end

-- the lobby countdown's words (nil = RoundManager's usual ones)
function Elim.label(newGame)
	if not Elim.active() then return nil end
	if not started then return "☠️ ELIMINATION game starts in" end
	if #alive < 2 then return nil end -- (the game is ending: the usual words)
	if #alive <= FINAL_AT or roundNo >= MAX_ROUNDS then return "☠️ FINAL SHOWDOWN starts in" end
	return "☠️ Next elimination round in"
end

-- a game ended (RoundManager calls it for classic games too, and when a host presses NEW GAME)
function Elim.gameOver()
	inGame = false
	format = "Classic"
	reset()
	publish()
end

local function finaleMap()
	local maps = workspace:FindFirstChild("Maps")
	local map = maps and maps:FindFirstChild(FINALE_MAP)
	if not map or map:GetAttribute("Broken") then return nil end
	local modes = script.Parent:FindFirstChild("Modes")
	if not (modes and modes:FindFirstChild(map:GetAttribute("Mode") or "")) then return nil end
	return map
end

-- the last player left wins without a round (everyone else quit or fell asleep)
local function crownByDefault(player)
	local PlayerData, Stats, Levels = lib("PlayerData"), lib("Stats"), lib("Levels")
	if PlayerData then PlayerData.addCoins(player, CHAMPION_COINS, nil, "Elimination") end
	if Levels and Levels.XP_WIN_GAME then pcall(Levels.add, player, Levels.XP_WIN_GAME) end
	if Stats then pcall(Stats.gameWon, player) end
	local quest = ServerStorage:FindFirstChild("QuestEvent")
	if quest then quest:Fire(player, "WinGame", 1) end
	toast("👑 " .. player.DisplayName .. " is the last one standing and wins the Elimination game!", true)
end

local function clearWins()
	for _, p in Players:GetPlayers() do
		local ls = p:FindFirstChild("leaderstats")
		local w = ls and ls:FindFirstChild("Wins")
		if w then w.Value = 0 end
	end
end

-- right before a round's map is chosen. candidates = everyone who could play (alive, not AFK).
-- Returns finaleMap (or nil for a normal round) and the players of this round.
-- If the Elimination game can't go on (too few players), it quietly becomes / starts a classic game and
-- Elim.active() is false afterwards - RoundManager checks that.
function Elim.lineup(candidates, again)
	if not Elim.active() then return nil, nil end
	if not started then
		if #candidates < MIN_PLAYERS and forced() ~= "Elimination" then
			format = "Classic" -- (the game counter moved on, so the one after next is tried again)
			publish()
			toast("Not enough players for an Elimination game - this one is first to " .. tostring(status:GetAttribute("WinsToWin") or 5) .. " wins!", true)
			return nil, nil
		end
		started = true
		alive = table.clone(candidates)
		for _, p in alive do roster[p] = true end
		status:SetAttribute("ElimStart", #alive)
	end
	-- still alive but not here to play (left, or AFK in the lobby)? You're out.
	local here = {}
	for _, p in candidates do here[p] = true end
	local dropped = {}
	for i = #alive, 1, -1 do
		local p = alive[i]
		if not here[p] then
			table.remove(alive, i)
			table.insert(cutOrder, p)
			if p.Parent then table.insert(dropped, p) end
		end
	end
	if #dropped > 0 then toast("💤 " .. table.concat(names(dropped), ", ") .. (#dropped == 1 and " wasn't ready and is" or " weren't ready and are") .. " out of the Elimination game.", false) end
	-- nobody left, or one player left after at least one round: the game is over without another round
	-- (a brand-new game with a single player only happens while testing with ForceFormat: let it play)
	if #alive == 0 or (#alive == 1 and roundNo > 0) then
		if alive[1] then crownByDefault(alive[1]) end
		clearWins()
		Elim.gameOver()
		if not again then
			Elim.prepare(false) -- straight into the next game (this round is its first)
			return Elim.lineup(candidates, true)
		end
		return nil, nil
	end
	isFinal = roundNo > 0 and (#alive <= FINAL_AT or roundNo >= MAX_ROUNDS)
	publish()
	if isFinal then return finaleMap(), table.clone(alive) end -- (no finale map? then a normal game decides it)
	return nil, table.clone(alive)
end

-- worst first. Uses what Extras.Tracker saw: who was knocked out and when, and the mode's own score numbers.
local function rankLosers(losers, skip)
	local Tracker = lib("Tracker", "Extras")
	local r = Tracker and Tracker.current()
	local scores, low = nil, false
	if r then
		local def = (Config.MODE_AWARDS[r.modeName] or {})[1]
		if def and r.scores[def.attr] and next(r.scores[def.attr]) then scores, low = r.scores[def.attr], def.low == true end
	end
	local key = {}
	for _, p in losers do
		local o = r and r.out[p]
		if (skip and skip[p]) or not p.Parent or (o and (o.afk or o.left)) then
			key[p] = { 0, 0 }                       -- fell asleep / left: worst of all
		elseif o and o.knocked then
			key[p] = { 1, o.t }                     -- knocked out: the earlier, the worse
		elseif o and o.finished then
			key[p] = { 3, -o.t }                    -- finished (escaped, crossed the line): the sooner, the better
		elseif scores and scores[p] then
			key[p] = { 2, low and -scores[p] or scores[p] } -- still in at the end: lowest score is worst
		else
			key[p] = { 2, math.random() * 0.001 }   -- nothing to tell them apart: luck of the draw
		end
	end
	table.sort(losers, function(a, b)
		if key[a][1] ~= key[b][1] then return key[a][1] < key[b][1] end
		return key[a][2] < key[b][2]
	end)
	return losers
end

-- a round of an Elimination game just ended (wins and coins are already given out).
-- Returns the CHAMPION when that was the last round, otherwise nil.
function Elim.roundEnded(players, winners, skip)
	if not Elim.active() or not started then return nil end
	roundNo += 1
	local winnerSet = {}
	for _, p in winners or {} do winnerSet[p] = true end
	local losers = {}
	for _, p in players do
		if table.find(alive, p) and not winnerSet[p] then table.insert(losers, p) end
	end
	rankLosers(losers, skip)
	local cut = {}
	local champion = nil
	if isFinal then
		-- the final: its winner takes the game (no winner? the one who lasted longest does)
		for _, p in winners or {} do
			if table.find(alive, p) and p.Parent then champion = p break end
		end
		if not champion then
			for i = #losers, 1, -1 do
				if losers[i].Parent then champion = table.remove(losers, i) break end
			end
		end
		for _, p in losers do
			if p ~= champion then table.insert(cut, p) end
		end
		for _, p in winners or {} do -- (a team final: the other winners are runners-up)
			if p ~= champion and table.find(alive, p) and not table.find(cut, p) then table.insert(cut, p) end
		end
	else
		local n = #alive
		local want = math.clamp(math.floor(n * CUT_SHARE + 0.5), 1, math.max(1, n - 2))
		if n <= 2 then want = 1 end
		for i = 1, math.min(want, #losers) do table.insert(cut, losers[i]) end
	end
	for _, p in cut do
		remove(alive, p)
		table.insert(cutOrder, p)
	end
	if champion then alive = { champion } end
	if not isFinal and #alive == 1 then champion = alive[1] end
	if not champion then
		local PlayerData = lib("PlayerData")
		for _, p in alive do
			if PlayerData and p.Parent and table.find(players, p) then PlayerData.addCoins(p, COINS_SURVIVE, nil, "Elimination") end
		end
	end
	announce(cut)
	publish()
	return champion
end

-- the final standings for the awards ceremony: the champion, then everyone else, last cut first
function Elim.ranking(champion)
	local list = {}
	if champion and champion.Parent then table.insert(list, champion) end
	for _, p in alive do
		if p ~= champion and p.Parent then table.insert(list, p) end
	end
	for i = #cutOrder, 1, -1 do
		local p = cutOrder[i]
		if p.Parent and not table.find(list, p) then table.insert(list, p) end
	end
	return list
end

Players.PlayerRemoving:Connect(function(p) roster[p] = nil end)

return Elim

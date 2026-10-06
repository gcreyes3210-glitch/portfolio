-- Coins and cosmetics for each player.
--   Coins:     leaderstats.Coins (so they show on the player list)
--   Owned:     BoolValues inside player.OwnedCosmetics
--   Equipped:  attributes like Equipped_Hat = "Crown"
--   Rewards:   the Rewards Market's saved tables (daily streak, used codes, quest progress).
--              Other scripts get them with PlayerData.getSaved(player, "daily") and change them in place.
-- All of it is saved with DataStoreService. Saving only works in a PUBLISHED game with
-- "Enable Studio Access to API Services" on (Game Settings > Security); otherwise coins
-- still work, they just reset when you leave.
--
-- HOW SAVING IS KEPT SAFE (so nobody loses coins or things they bought):
--   * RETRIES: Roblox's save service sometimes fails for a moment. Every load and save is tried a few times.
--   * SESSION LOCK: while you're in a server, your save is marked "in use by server X". If you jump to another
--     server (the practice portal, an update, rejoining fast), the new server WAITS for the old one to finish
--     saving before it loads - so it can never load an old copy and then overwrite the new one.
--     If the old server crashed, the lock runs out by itself (LOCK_EXPIRES) or is taken over after a short wait.
--   * A server that has lost the lock never writes again (it would be overwriting newer data).
--   * SHUTDOWN: when a server closes, it waits until every player's save has actually finished.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "PlayerData_v1"
local AUTOSAVE_EVERY = 120 -- seconds (each autosave also renews the session lock)
local LOAD_TRIES = 4       -- attempts when Roblox's save service has a hiccup
local SAVE_TRIES = 3
local LOCK_EXPIRES = 600   -- a lock older than this belongs to a server that crashed
local LOCK_WAIT_TRIES = 8  -- how many times to wait for another server to finish saving...
local LOCK_WAIT = 3        -- ...and how long each wait is (8 x 3s = 24s at most, then the lock is taken over)
local PREMIUM_BONUS = 0.2  -- Roblox Premium members earn this much extra (0.2 = +20%) on coins they EARN
local SERVER_ID = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false))
local CATEGORIES = { "Hat", "Trail", "Aura", "Win", "Ride", "Pet", "Out" } -- Out = knock-out effects (ServerScriptService.OutEffects)
-- saved tables other scripts own: daily/codes/quests = RewardsServer, boost = Boost (charges + on/off),
-- receipts = MonetizationServer (Robux purchases already handed out, so one is never given twice),
-- stats = Stats (lifetime wins / rounds played / modes won / badges / achievements / title),
-- settings = ProfileServer (volume sliders and toggles from the Settings window)
-- snacks = SnackServer (how many of each Snack Bar snack you carry)
-- xp = Levels (total XP earned, which decides your level)
-- onboard = Extras.Social (welcome tour done? + how many times you've seen each game's how-to card)
-- social = Extras.Social (friends you've been rewarded for inviting)
-- season = SeasonPass (this season's XP + which rewards were claimed)
-- analytics = Analytics (which first-time steps were already reported)
-- trades = TradeServer (a short history of your trades)
-- plus = Ranks / LobbyHunt / ServerPerks (weekly bone hunt, gifted passes + gift credits, weekly-board reward, notification ask)
-- halloween = HalloweenEvent (how much candy you have)
local EXTRA_FIELDS = { "plus", "daily", "codes", "quests", "boost", "receipts", "stats", "settings", "snacks", "xp", "onboard", "social", "season", "analytics", "trades", "trolls", "halloween" }
local catalogById = {}
for _, item in require(ReplicatedStorage:WaitForChild("Cosmetics")) do catalogById[item.id] = item end

local store
local ok, err = pcall(function() store = DataStoreService:GetDataStore(STORE_NAME) end)
if not ok then warn("Saving is off: " .. tostring(err)) end

local PlayerData = {}
local canSave = {} -- only save players whose data loaded fine, so a failed load never wipes a save
local extras = {} -- extras[player] = { daily = {...}, codes = {...}, quests = {...} }
local pendingSave = {}
local saving = {} -- a save is running for this player right now (one at a time)

-- ANALYTICS (ServerScriptService.Analytics) is optional and loaded a moment later, because it also uses this module
local Analytics = nil
task.spawn(function()
	local m = script.Parent:WaitForChild("Analytics", 15)
	if m then
		local okA, a = pcall(require, m)
		if okA then Analytics = a end
	end
end)

local function key(player) return "player_" .. player.UserId end
local function coinsOf(player)
	local ls = player:FindFirstChild("leaderstats")
	return ls and ls:FindFirstChild("Coins")
end

-- run fn up to `tries` times, waiting a little longer after each failure (1s, 2s, 4s...)
local function retry(tries, fn)
	local lastErr
	for attempt = 1, tries do
		local results = table.pack(pcall(fn))
		if results[1] then return true, table.unpack(results, 2, results.n) end
		lastErr = results[2]
		-- Studio with "API Services" switched off can never save: don't waste 7 seconds retrying on every playtest
		local msg = tostring(lastErr)
		if string.find(msg, "StudioAccessToApisNotAllowed", 1, true) or string.find(msg, "API access is not enabled", 1, true)
			or string.find(msg, "Studio access to APIs is not allowed", 1, true) then
			break
		end
		if attempt < tries then task.wait(2 ^ (attempt - 1)) end
	end
	return false, lastErr
end

-- LOAD + take the session lock. Returns ok, data. ok = false means "couldn't load": nothing will be saved.
local function loadLocked(player)
	local k = key(player)
	for attempt = 1, LOCK_WAIT_TRIES do
		local blocked = false
		local okLoad, result = retry(LOAD_TRIES, function()
			return store:UpdateAsync(k, function(old)
				old = old or {}
				local lock = old._lock
				local takeOver = attempt == LOCK_WAIT_TRIES
				if type(lock) == "table" and lock.id ~= SERVER_ID and os.time() - (lock.t or 0) < LOCK_EXPIRES and not takeOver then
					blocked = true
					return nil -- another server is still saving this player: change nothing, try again in a moment
				end
				blocked = false
				old._lock = { id = SERVER_ID, t = os.time() }
				return old
			end)
		end)
		if not okLoad then return false, result end
		if not blocked then return true, result or {} end
		if not player.Parent then return false, "left" end
		task.wait(LOCK_WAIT)
	end
	return false, "locked"
end

-- give the lock back without changing the data (the player left before their data was even used)
local function releaseLock(player)
	pcall(function()
		store:UpdateAsync(key(player), function(old)
			if type(old) ~= "table" or type(old._lock) ~= "table" or old._lock.id ~= SERVER_ID then return nil end
			old._lock = nil
			return old
		end)
	end)
end

function PlayerData.setup(player)
	local leaderstats = player:WaitForChild("leaderstats")
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = leaderstats
	local owned = Instance.new("Folder")
	owned.Name = "OwnedCosmetics"
	owned.Parent = player

	local data
	if store then
		local okLoad, result = loadLocked(player)
		if okLoad then
			data = result
			if not player.Parent then -- they left while it was loading: hand the lock straight back
				releaseLock(player)
				return
			end
			canSave[player] = true
		elseif result ~= "left" then
			warn("Couldn't load data for " .. player.Name .. " (coins won't save this session): " .. tostring(result))
			player:SetAttribute("SaveOff", true)
			-- tell them, so they don't play for an hour thinking it counts
			task.delay(8, function()
				local openMenu = ReplicatedStorage:FindFirstChild("OpenMenu")
				if player.Parent and openMenu and not RunService:IsStudio() then
					openMenu:FireClient(player, "Toast", "⚠️ Your save couldn't be loaded, so progress won't be saved right now. Rejoin in a minute to fix it!", false)
				end
			end)
		end
	end
	data = data or {}
	coins.Value = data.coins or 0
	for _, id in data.owned or {} do
		if not owned:FindFirstChild(id) then
			local v = Instance.new("BoolValue")
			v.Name = id
			v.Value = true
			v.Parent = owned
		end
	end
	for category, id in data.equipped or {} do
		player:SetAttribute("Equipped_" .. category, id)
	end
	-- old saves don't have these yet; they just start empty
	extras[player] = {}
	for _, field in EXTRA_FIELDS do
		extras[player][field] = type(data[field]) == "table" and data[field] or {}
	end
	-- SAFETY NET: a saved table that is NOT in EXTRA_FIELDS (a new feature someone forgot to list) is loaded too.
	-- Without this it was saved when you left but thrown away when you came back (found Oct 6: Halloween candy).
	for field, value in data do
		if type(value) == "table" and extras[player][field] == nil and field ~= "owned" and field ~= "equipped" and field ~= "_lock" then
			extras[player][field] = value
		end
	end
	player:SetAttribute("DataLoaded", true)
end

-- Saves the player. release = true also gives up the session lock (they're leaving this server).
-- Returns true when it's safely saved (MonetizationServer checks this for Robux purchases).
function PlayerData.save(player, release)
	if not canSave[player] then return end
	while saving[player] do task.wait(0.1) end -- one save at a time per player
	if not canSave[player] then return end
	saving[player] = true
	local data = { coins = coinsOf(player) and coinsOf(player).Value or 0, owned = {}, equipped = {} }
	local ownedFolder = player:FindFirstChild("OwnedCosmetics")
	for _, v in ownedFolder and ownedFolder:GetChildren() or {} do table.insert(data.owned, v.Name) end
	for _, c in CATEGORIES do data.equipped[c] = player:GetAttribute("Equipped_" .. c) end
	for field, t in extras[player] or {} do data[field] = t end
	local lostLock = false
	local okSave, e = retry(SAVE_TRIES, function()
		store:UpdateAsync(key(player), function(old)
			local lock = type(old) == "table" and old._lock
			if type(lock) == "table" and lock.id ~= SERVER_ID then
				lostLock = true
				return nil -- another server owns this save now: never overwrite it
			end
			lostLock = false
			data._lock = (not release) and { id = SERVER_ID, t = os.time() } or nil
			return data
		end)
	end)
	saving[player] = nil
	if lostLock then
		canSave[player] = nil
		warn("Save skipped for " .. player.Name .. ": another server has their data now.")
		return false
	end
	if not okSave then
		warn("Save failed for " .. player.Name .. ": " .. tostring(e))
		return false
	end
	if release then canSave[player] = nil end -- lock given back: this server is done with their save
	return true
end

-- waits until the player's save has loaded (returns false if they left first)
function PlayerData.waitLoaded(player)
	while player.Parent and not player:GetAttribute("DataLoaded") do
		player:GetAttributeChangedSignal("DataLoaded"):Wait()
	end
	return player.Parent ~= nil
end

-- one of the saved reward tables ("daily", "codes", "quests"); change it in place and it gets saved
function PlayerData.getSaved(player, field)
	local e = extras[player]
	if not e then return nil end
	e[field] = e[field] or {}
	return e[field]
end

-- save a few seconds from now (for important moments like redeeming a code); many calls = one save
function PlayerData.saveSoon(player)
	if pendingSave[player] then return end
	pendingSave[player] = true
	task.delay(6, function()
		pendingSave[player] = nil
		if player.Parent then PlayerData.save(player) end
	end)
end

-- coins earned by playing. The 2x Coins game pass (player attribute Coins2x, set by MonetizationServer)
-- doubles them, and Roblox Premium members (attribute Premium, set by ServerScriptService.PremiumPerk) get
-- PREMIUM_BONUS on top. noBonus = true for coins that were BOUGHT (coin packs), so those never grow.
-- source = an optional short word for the analytics ("Round", "Quest", "Season"...).
-- Returns how many coins were actually given.
function PlayerData.addCoins(player, amount, noBonus, source)
	local c = coinsOf(player)
	if not c then return 0 end
	if not noBonus and amount > 0 then
		local mult = player:GetAttribute("Coins2x") and 2 or 1
		-- SERVER COIN BOOST (ServerScriptService.ServerPerks): someone bought 2x coins for EVERYONE on this server for a while
		local boostUntil = workspace:GetAttribute("CoinBoostUntil")
		if type(boostUntil) == "number" and workspace:GetServerTimeNow() < boostUntil then mult += 1 end
		if player:GetAttribute("Premium") then mult += PREMIUM_BONUS end
		amount = math.floor(amount * mult + 0.5)
	end
	c.Value += amount
	if Analytics and amount ~= 0 then Analytics.coins(player, amount, noBonus and "Bought" or (source or "Gameplay")) end
	return amount
end
PlayerData.PREMIUM_BONUS = PREMIUM_BONUS

-- NOT ENOUGH COINS: pop up Roblox's purchase window for a coin pack from Monetization.COIN_OFFERS (the $4.99
-- pack, or the $9.99 one if the player is short by more than it gives). If they're short on Robux too,
-- Roblox's own window offers them the Robux to buy it.
local MarketplaceService = game:GetService("MarketplaceService")
local money = require(ReplicatedStorage:WaitForChild("Monetization"))
local lastOffer = {}
function PlayerData.offerCoins(player, need)
	if os.clock() - (lastOffer[player] or -99) < 3 then return end -- no double pop-ups
	lastOffer[player] = os.clock()
	local packs = {}
	for _, p in money.PRODUCTS do
		local offered = not money.COIN_OFFERS or table.find(money.COIN_OFFERS, p.id)
		if p.kind == "Coins" and p.id and p.id ~= 0 and offered then table.insert(packs, p) end
	end
	table.sort(packs, function(a, b) return a.amount < b.amount end)
	local pick = packs[#packs] -- the biggest one if nothing covers it
	for _, p in packs do
		if p.amount >= (need or 0) then pick = p break end
	end
	if pick and pick.id and pick.id ~= 0 then
		if Analytics then Analytics.event(player, "CoinOfferShown", pick.amount) end
		task.delay(0.35, function()
			if player.Parent then pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, player, pick.id) end
		end)
	end
end
Players.PlayerRemoving:Connect(function(p) lastOffer[p] = nil end)

-- take coins for a purchase. Not enough = false, and (unless noOffer) the coin pack pops up.
-- sku = an optional name of what was bought, for the analytics ("TopHat", "GamePick"...).
function PlayerData.spend(player, amount, noOffer, sku)
	local c = coinsOf(player)
	if c and c.Value >= amount then
		c.Value -= amount
		if Analytics and amount > 0 then Analytics.spent(player, amount, sku) end
		return true
	end
	if c and not noOffer and player:GetAttribute("DataLoaded") then PlayerData.offerCoins(player, amount - c.Value) end
	return false
end

function PlayerData.owns(player, id)
	local item = catalogById[id]
	if item and item.free then return true end                            -- free starter emotes
	if item and item.vip then return player:GetAttribute("VIP") == true end -- VIP items come with the pass
	local owned = player:FindFirstChild("OwnedCosmetics")
	return owned and owned:FindFirstChild(id) ~= nil
end

function PlayerData.grant(player, id)
	local folder = player:FindFirstChild("OwnedCosmetics")
	if not folder or folder:FindFirstChild(id) then return end
	local v = Instance.new("BoolValue")
	v.Name = id
	v.Value = true
	v.Parent = folder
end

-- take an item away again (only trading does this)
function PlayerData.revoke(player, id)
	local folder = player:FindFirstChild("OwnedCosmetics")
	local v = folder and folder:FindFirstChild(id)
	if v then v:Destroy() end
	local item = catalogById[id]
	if item and player:GetAttribute("Equipped_" .. item.category) == id then
		player:SetAttribute("Equipped_" .. item.category, nil)
	end
end

function PlayerData.canSave(player) return canSave[player] == true end

Players.PlayerRemoving:Connect(function(player)
	PlayerData.save(player, true) -- final save + give the session lock back, so the next server can load at once
	canSave[player] = nil
	extras[player] = nil
	pendingSave[player] = nil
	saving[player] = nil
end)
-- THE SERVER IS CLOSING (an update, or everyone left): save everybody and WAIT until every save is done.
game:BindToClose(function()
	local pending = 0
	for _, player in Players:GetPlayers() do
		pending += 1
		task.spawn(function()
			PlayerData.save(player, true)
			pending -= 1
		end)
	end
	local limit = RunService:IsStudio() and 4 or 25 -- Roblox gives a closing server 30 seconds
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < limit do task.wait(0.1) end
end)
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_EVERY)
		for _, player in Players:GetPlayers() do
			task.spawn(PlayerData.save, player)
			task.wait(0.5) -- spread the saves out so they don't all hit Roblox at the same moment
		end
	end
end)

return PlayerData

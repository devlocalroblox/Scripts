--[[
	ServerScriptService/Match
	Used in Luau Skill Role Applications
	Handles the full server-side for a Tower Defense game prototype
	Scripted by Local

  Note:
  - Because Luau Skill Role Applications look at a single script, I kept all logic directly in here.
  - This was designed to be a prototype to demonstrate Roblox API knowledge

  Main things I focused on in this script:
	- Keeping the game server-authoritative, with the client only sending requests through RemoteEvents (this should always be the approach for core gameplay logic)
	- Validating important instances upfront with helper functions like mustGet and mustModel to make debugging a lot easier (bug fixing becomes way faster)
	- Using metatables to keep enemy behavior and state handling cleaner (avoids messy global logic and keeps enemy functions organized)
	- Running enemy movement, projectiles, and tower logic through Heartbeat (keeps updates frame based and consistent)
	- Tracking path progress so towers can target enemies that are closer to the end (this is key for tower defenses)
	- Using a session id system so old round threads/coroutines can safely stop (prevents leftover wave logic or projectiles from previous rounds)
	- Validating tower placement on the server instead of trusting the client (prevents exploiters from spoofing placements)
	- Keeping enemy and tower stats in config tables so they're easy to tweak (makes balancing specific stats or what not much easier later)
	- Using TweenService for smoother enemy health bar updates (looks much better than instantly snapping UI values)
	- Splitting the logic clearly between enemies, towers, projectiles, and wave flow (keeps the system easier to maintain and expand, no one wants to deal with messy code)
]]

-- fetch services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- safe way to grab instances without the script silently dying later. if somethings missing, we want to know immediately 
local function mustGet(parent, name, className)
	local object = parent:FindFirstChild(name)

	if not object then
		object = parent:WaitForChild(name, 10)
	end

	if not object then
		warn("Missing: " .. parent:GetFullName() .. "." .. name)
		-- using error stops the script right away. we should hard stop here so we don't end up failing somewhere deeper and make debugging harder
		error("Script stopped")
	end

	if className and not object:IsA(className) then
		warn("Unexpected class for " .. object:GetFullName() .. ". Expected " .. className)
		error("Script stopped")
	end

	return object
end

-- same idea as mustGet but specifically for models, and we also check that the model actually has a PrimaryPart set.
-- pivoting a model without one throws weird errors, so we should catch it here
local function mustModel(parent, name)
	local model = mustGet(parent, name, "Model")

	if not model.PrimaryPart then
		warn("Model is missing PrimaryPart: " .. model:GetFullName())
		error("Script stopped")
	end

	return model
end
-- mustGet and mustModel always come in handy if you're missing something or if something has the wrong class etc
-- you can catch it right away in output instead of having to search for the problem

-- grab all the remotes we need. these are fired from the client and handled here (server-side)
local remotes = mustGet(ReplicatedStorage, "Remotes", "Folder")
local placeTowerRemote = mustGet(remotes, "PlaceTower", "RemoteEvent")
local startRoundRemote = mustGet(remotes, "StartRound", "RemoteEvent")
local roundStateRemote = mustGet(remotes, "RoundState", "RemoteEvent")
-- note for remotes: clients never control progression. real logic is handled here (server-side), client only uses remotes for requests.

-- template folders in ReplicatedStorage
-- enemies and towers are cloned from here at runtime
local enemiesFolder = mustGet(ReplicatedStorage, "Enemies", "Folder")
local towersFolder = mustGet(ReplicatedStorage, "Towers", "Folder")
local assetsFolder = mustGet(ReplicatedStorage, "Assets", "Folder")

-- pre-fetch all the enemy/tower templates so we're not doing FindFirstChild every spawn
local enemyTemplates = {
	Noob = mustModel(enemiesFolder, "Noob"),
	Zombie = mustModel(enemiesFolder, "Zombie"),
	c00lkidd = mustModel(enemiesFolder, "c00lkidd"),
}

local towerTemplates = {
	Common = mustModel(towersFolder, "Common"),
	Rare = mustModel(towersFolder, "Rare"),
	Epic = mustModel(towersFolder, "Epic"),
	Legendary = mustModel(towersFolder, "Legendary"),
	Mythical = mustModel(towersFolder, "Mythical"),
}

-- UI overhead billboard for enemies (the health bar that floats above them)
local enemyOverheadTemplate = assetsFolder:WaitForChild("EnemyOverhead")

-- the projectile part that visually flies toward enemies when a tower shoots
local projectileTemplate = assetsFolder:WaitForChild("Projectile")

-- path and placement stuff from workspace
local waypointsFolder = mustGet(Workspace, "Waypoints", "Folder")
local placementsFolder = mustGet(Workspace, "Placements", "Folder")

-- grab every waypoint. enemies walk from Spawn -> Waypoint1 -> ... -> Waypoint6 -> End
local spawnPart = mustGet(waypointsFolder, "Spawn", "BasePart")
local waypoint1 = mustGet(waypointsFolder, "Waypoint1", "BasePart")
local waypoint2 = mustGet(waypointsFolder, "Waypoint2", "BasePart")
local waypoint3 = mustGet(waypointsFolder, "Waypoint3", "BasePart")
local waypoint4 = mustGet(waypointsFolder, "Waypoint4", "BasePart")
local waypoint5 = mustGet(waypointsFolder, "Waypoint5", "BasePart")
local waypoint6 = mustGet(waypointsFolder, "Waypoint6", "BasePart")
local endPart = mustGet(waypointsFolder, "End", "BasePart")

-- tower placement pads, indexed 1-7
local pads = {}

for i = 1, 7 do
	pads[i] = mustGet(placementsFolder, "Pad" .. i, "BasePart")
end

-- all tower stats in one place.
-- cost is what the player pays (cash $), damage is per projectile hit, firerate is seconds between shots (lower = faster)
local towerStats = {
	Common = {
		Cost = 100,
		Damage = 1,
		FireRate = 1,
	},
	Rare = {
		Cost = 250,
		Damage = 3,
		FireRate = 0.85,
	},
	Epic = {
		Cost = 1000,
		Damage = 5,
		FireRate = 0.75,
	},
	Legendary = {
		Cost = 2500,
		Damage = 10,
		FireRate = 0.65,
	},
	Mythical = {
		Cost = 5000,
		Damage = 20,
		FireRate = 0.5,
	},
}

-- enemy stats. BaseDamage is how much they deal to the base if they reach the end
local enemyStats = {
	Noob = {
		Health = 5,
		Reward = 100,
		Speed = 5,
		BaseDamage = 10,
	},
	Zombie = {
		Health = 20,
		Reward = 500,
		Speed = 7,
		BaseDamage = 25,
	},
	c00lkidd = {
		Health = 50,
		Reward = 1000,
		Speed = 9,
		BaseDamage = 50,
	},
}

-- the order enemies are introduced, one enemy type per wave
local waveOrder = {
	"Noob",
	"Zombie",
	"c00lkidd",
}
-- note: usually i would have these configs as seperate modules and what not for better scalability, but in this case i had to keep everything visible in one place.

local baseMaxHealth = 100 -- the health of the player's base
local startingCash = 100 -- how much cash ($) the player starts with
local defaultTowerRange = 20 -- studs, same for all towers right now
local enemiesPerWave = 10 -- how many enemies spawn every wave
local enemySpawnDelay = 3 -- seconds between each enemy spawning within a wave
local waveBreakTime = 5 -- short breather between waves
local healthTweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ordered list of the path parts so we can iterate them cleanly
local pathParts = {
	spawnPart, waypoint1, waypoint2, waypoint3, waypoint4, waypoint5, waypoint6, endPart,
}

-- precompute the world positions of every path node and how far along the total path each node sits 
-- this lets us cheaply figure out how far an enemy has left to travel (used for tower targeting -- shoot the one closest to the end)
local pathPoints = {}
local pathProgress = {0}
local totalPathLength = 0

for i, part in ipairs(pathParts) do
	pathPoints[i] = part.Position - part.CFrame.UpVector * (part.Size.Y * 0.5)

	if i > 1 then
		totalPathLength += (pathPoints[i] - pathPoints[i - 1]).Magnitude
		pathProgress[i] = totalPathLength
	end
end

-- single player game, so we just track whoever joined as the round player
local roundPlayer = nil
local currentWave = 0
local cash = startingCash
local baseHealth = baseMaxHealth
local roundRunning = false
local resetting = false

-- sessionId increments every reset/player-leave so that any lingering coroutines from a previous round can detect that theyre stale and bail out
local sessionId = 0

-- active lookup tables, keyed by the model instance
local activeEnemies = {}
local activeTowers = {}
local activeProjectiles = {}
local padUsage = {} -- which pad a tower is sitting on, so we can block double-placement

-- enemy objects use a metatable so we can call methods on them like enemy:TakeDamage()
local enemyMt = {}
enemyMt.__index = enemyMt

-- declared here because finishMatch and the wave runner reference each other
local finishMatch

-- helper; returns the round player only if theyre still in the game
local function getRoundPlayer()
	if roundPlayer and roundPlayer.Parent == Players then
		return roundPlayer
	end

	return nil
end

-- wrapper so we dont have to nil check the player every time we want to send a state update
local function sendState(packet)
	local player = getRoundPlayer()

	if not player then
		return
	end

	roundStateRemote:FireClient(player, packet)
end

local function clampBaseHealth(value)
	if value < 0 then
		return 0
	end

	if value > baseMaxHealth then
		return baseMaxHealth
	end

	return value
end

-- always update the server variable AND push the new value to the client in one call
local function setCash(value)
	cash = value

	sendState({
		Type = "Cash",
		Cash = cash,
	})
end

local function addCash(amount)
	setCash(cash + amount)
end

local function setWave(waveNumber)
	currentWave = waveNumber

	sendState({
		Type = "Wave",
		Wave = currentWave,
	})
end

-- setBaseHealth handles the loss condition too. if it hits 0, we end the match right here
local function setBaseHealth(value)
	baseHealth = clampBaseHealth(value)

	sendState({
		Type = "BaseHealth",
		Current = baseHealth,
		Maximum = baseMaxHealth,
	})

	if baseHealth <= 0 then
		finishMatch("Loss")
	end
end

-- disables all physics/collision on a model's parts
-- since we're moving everything manually with PivotTo, we dont want roblox physics interfering or touching events firing
local function prepModel(model)
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanTouch = false
			item.Massless = true
		end
	end
end

-- figures out how high the model's pivot sits above its own bottom edge.
-- we use this so that when we place a model at a ground position, the feet actually touch the ground instead of the pivot floating
local function getPivotOffset(model)
	local pivot = model:GetPivot()
	local boundsCf, boundsSize = model:GetBoundingBox()
	local bottomY = boundsCf.Position.Y - boundsSize.Y * 0.5

	return pivot.Position.Y - bottomY
end

-- builds a CFrame from a position + the axis vectors of a basis CFrame.
-- good when we want to inherit orientation from a pad or waypoint
local function cframeFrom(position, basis)
	return CFrame.fromMatrix(position, basis.XVector, basis.YVector, basis.ZVector)
end

-- removes a projectile from the world and the active table
local function clearProjectile(projectilePart)
	local data = activeProjectiles[projectilePart]

	if not data then
		return
	end

	if data.Part and data.Part.Parent then
		data.Part:Destroy()
	end

	activeProjectiles[projectilePart] = nil
end

-- remove  all the projectiles from the world
local function clearAllProjectiles()
	for projectilePart in pairs(activeProjectiles) do
		clearProjectile(projectilePart)
	end
end

-- resets pad occupied flags so theyre available for the next round
local function resetPads()
	for _, pad in ipairs(pads) do
		pad:SetAttribute("Occupied", false)
	end
end

-- updates the floating health bar above an enemy.
-- uses a tween on the fill bar so the health drain looks smooth instead of snapping
function enemyMt:UpdateOverhead()
	if not self.Overhead then
		return
	end

	local nameLabel = self.Overhead:FindFirstChild("Name")
	local healthFrame = self.Overhead:FindFirstChild("Health")

	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = self.Type
	end

	if not healthFrame then
		return
	end

	local amountLabel = healthFrame:FindFirstChild("Amount")
	local fill = healthFrame:FindFirstChild("Fill")

	if amountLabel and amountLabel:IsA("TextLabel") then
		amountLabel.Text = "Health: " .. self.Health .. "/" .. self.MaxHealth
	end

	if fill and fill:IsA("Frame") then
		-- cancel any in progress tween before starting a new one, otherwise rapid hits stack up and the bar gets out of sync
		if self.FillTween then
			self.FillTween:Cancel()
		end

		self.FillTween = TweenService:Create(fill, healthTweenInfo, {
			Size = UDim2.new(self.Health / self.MaxHealth, 0, 1, 0),
		})

		self.FillTween:Play()
	end
end

-- cleans up an enemy and damages the base.
-- the Removed flag is checked everywhere so nothing tries to double destroy
function enemyMt:Destroy(hitBase)
	if self.Removed then
		return
	end

	self.Removed = true
	activeEnemies[self.Model] = nil

	if self.FillTween then
		self.FillTween:Cancel()
		self.FillTween = nil
	end

	if self.Overhead and self.Overhead.Parent then
		self.Overhead:Destroy()
	end

	if self.Model and self.Model.Parent then
		self.Model:Destroy()
	end

	-- hitBase is false when killed by a tower (player gets the reward instead), true when they walk off the end of the path
	if hitBase then
		setBaseHealth(baseHealth - self.BaseDamage)
	end
end

function enemyMt:TakeDamage(amount)
	if self.Removed then
		return
	end

	self.Health -= amount

	if self.Health < 0 then
		self.Health = 0
	end

	self:UpdateOverhead()

	if self.Health <= 0 then
		addCash(self.Reward)
		self:Destroy(false)
	end
end

-- builds and parents the overhead BillboardGui for an enemy
-- we validate the expected hierarchy here so bad template setups fail loudly
local function buildEnemyOverhead(model, enemyName)
	local overhead = enemyOverheadTemplate:Clone()
	overhead.Adornee = model.PrimaryPart
	overhead.Parent = Workspace

	local nameLabel = overhead:FindFirstChild("Name")
	local healthFrame = overhead:FindFirstChild("Health")

	if not nameLabel or not nameLabel:IsA("TextLabel") or not healthFrame then
		warn("Problem with nameLabel or healthFrame; missing or wrong name")
		error("Script stopped")
	end

	local amountLabel = healthFrame:FindFirstChild("Amount")
	local fill = healthFrame:FindFirstChild("Fill")

	if not amountLabel or not amountLabel:IsA("TextLabel") or not fill or not fill:IsA("Frame") then
		warn("Problem with amountLabel or fill; missing or wrong name")
		error("Script stopped")
	end

	nameLabel.Text = enemyName
	amountLabel.Text = ""
	fill.Size = UDim2.new(1, 0, 1, 0) --  start full

	return overhead
end

-- creates a new enemy at the spawn point, sets up its data, and registers it
local function spawnEnemy(enemyName, enemySession)
	local template = enemyTemplates[enemyName]
	local stats = enemyStats[enemyName]

	if not template or not stats then
		return nil
	end

	local model = template:Clone()
	prepModel(model)
	model.Parent = Workspace

	-- place the model so its feet sit on the spawn part surface
	local offset = getPivotOffset(model)
	local ground = spawnPart.Position - spawnPart.CFrame.UpVector * (spawnPart.Size.Y * 0.5)
	local pivotPos = ground + Vector3.new(0, offset, 0)
	model:PivotTo(cframeFrom(pivotPos, spawnPart.CFrame))

	local enemy = setmetatable({
		Model = model,
		Type = enemyName,
		Health = stats.Health,
		MaxHealth = stats.Health,
		Reward = stats.Reward,
		Speed = stats.Speed,
		BaseDamage = stats.BaseDamage,
		GroundPosition = ground, -- the enemy's feet position on the path
		VerticalOffset = offset, -- cached so we dont recompute every frame
		NodeIndex = 1, -- which path node we're currently walking toward
		RemainingDistance = totalPathLength, -- used by towers to pick the most advanced target
		SessionId = enemySession,-- lets heartbeat skip enemies from old sessions
		Removed = false,
		Overhead = buildEnemyOverhead(model, enemyName),
		FillTween = nil,
	}, enemyMt)

	enemy:UpdateOverhead()
	activeEnemies[model] = enemy

	-- print("spawned", enemyName, "session", enemySession)
	return enemy
end

-- returns the world position the tower's pivot should sit at above its pad
local function getTowerPivot(tower)
	return tower.Pad.Position - tower.Pad.CFrame.UpVector * (tower.Pad.Size.Y * 0.5) + tower.Pad.CFrame.UpVector * tower.VerticalOffset
end

-- finds the enemy within range that is the furthest along the path (closest to the end).
-- lowest RemainingDistance means they've traveled the most
local function getBestTarget(tower)
	local bestEnemy = nil
	local bestRemainingDistance = math.huge
	local origin = tower.Model.PrimaryPart.Position

	for _, enemy in pairs(activeEnemies) do

		if enemy.Removed then
			continue
		end

		local primary = enemy.Model.PrimaryPart

		if primary then
			local distance = (primary.Position - origin).Magnitude

			if distance <= tower.Range and enemy.RemainingDistance < bestRemainingDistance then
				bestRemainingDistance = enemy.RemainingDistance
				bestEnemy = enemy
			end
		end
	end

	return bestEnemy
end

-- spawns a projectile part and registers it in activeProjectiles.
-- the actual movement happens in stepProjectiles each heartbeat
local function fireProjectile(tower, enemy)
	local primary = tower.Model.PrimaryPart

	if not primary then
		return
	end

	local projectile = projectileTemplate:Clone()
	projectile.Anchored = true
	projectile.CanCollide = false
	projectile.CanTouch = false
	projectile.Massless = true
	projectile.Parent = Workspace

	-- spawn slightly in front of and above the tower barrel so it doesn't clip through
	local startPos = primary.Position + primary.CFrame.LookVector * 1.5 + Vector3.new(0, 0.4, 0)
	projectile.CFrame = CFrame.lookAt(startPos, enemy.Model.PrimaryPart.Position)

	activeProjectiles[projectile] = {
		Part = projectile,
		Target = enemy,
		Damage = tower.Damage,
		Speed = 60, -- projectile speed in studs
		Position = startPos,
		SessionId = tower.SessionId,
	}
end

-- wipe all enemies without giving base damage -- used on reset/cleanup
local function clearEnemies()
	for _, enemy in pairs(activeEnemies) do
		enemy:Destroy(false)
	end

	table.clear(activeEnemies)
end

-- destroy all tower models and clear tracking tables
local function clearTowers()
	for _, tower in pairs(activeTowers) do
		if tower.Model and tower.Model.Parent then
			tower.Model:Destroy()
		end
	end

	table.clear(activeTowers)
	table.clear(padUsage)
end

-- full state reset between rounds. bumping sessionId invalidates everything currently running (coroutines, projectiles, etc.) before we start fresh
local function resetMatch()
	sessionId += 1
	roundRunning = false
	resetting = false
	currentWave = 0
	baseHealth = baseMaxHealth

	-- make sure the player doesnt start with less than $100 they can buy a tower
	if cash < startingCash then
		cash = startingCash
	end

	clearAllProjectiles()
	clearEnemies()
	clearTowers()
	resetPads()

	sendState({
		Type = "Reset",
		Cash = cash,
		BaseHealth = baseHealth,
		BaseMaximum = baseMaxHealth,
		Wave = currentWave,
	})
end

-- called when the round ends in either a win or loss
-- sends the result to the client and schedules a reset after a short delay so the player can see it
function finishMatch(resultType)
	--print("finishMatch called:", resultType, "- wave:", currentWave)
	if resetting then
		return  -- already finishing, dont double trigger
	end

	resetting = true
	roundRunning = false

	sendState({
		Type = "Result",
		Result = resultType,
		Wave = currentWave,
	})

	local thisSession = sessionId

	task.spawn(function()
		task.wait(3)

		-- if the session changed while we were waiting (player left and rejoined, etc.)
		-- then resetMatch was already called elsewhere, so dont do it again
		if thisSession ~= sessionId then
			return
		end

		resetMatch()
	end)
end

-- the main wave loop. runs in its own thread so it can yield between waves without blocking the heartbeat
local function runWaves()
	local thisSession = sessionId

	task.spawn(function()
		task.wait(5)  -- small grace period at round start for the player to place towers

		if thisSession ~= sessionId or not roundRunning or resetting then
			return
		end
		for waveIndex, enemyName in ipairs(waveOrder) do
			if thisSession ~= sessionId or not roundRunning or resetting then
				return
			end

			setWave(waveIndex)

			-- spawn all enemies for this wave one at a time with a delay between each
			for spawnIndex = 1, enemiesPerWave do
				if thisSession ~= sessionId or not roundRunning or resetting then
					return
				end

				spawnEnemy(enemyName, thisSession)

				if spawnIndex < enemiesPerWave then
					task.wait(enemySpawnDelay)
				end
			end

			-- wait for all enemies of this wave to be dead or gone before moving on
			while thisSession == sessionId and roundRunning and not resetting and next(activeEnemies) do
				task.wait(0.2)
			end

			if thisSession ~= sessionId or not roundRunning or resetting then
				return
			end

			-- short break before the next wave (skip it after the last wave)
			if waveIndex < #waveOrder then
				task.wait(waveBreakTime)
			end
		end

		-- if we made it through every wave and the round is still going, player wins
		if thisSession == sessionId and roundRunning and not resetting then
			finishMatch("Win")
		end
	end)
end

-- validates the placement request before actually doing anything.
-- all the failure cases send a reason back so the client can give useful feedback
local function placeTower(player, pad, towerName)
	if player ~= getRoundPlayer() then
		return
	end

	if not roundRunning or resetting then
		sendState({
			Type = "PlacementResult",
			Success = false,
			Reason = "Closed",
		})

		return
	end

	-- make sure pad is a real BasePart that actually lives under Placements so that the client cant just spoof parts
	if typeof(pad) ~= "Instance" or not pad:IsA("BasePart") or not pad:IsDescendantOf(placementsFolder) then
		sendState({
			Type = "PlacementResult",
			Success = false,
			Reason = "Pad",
		})

		return
	end

	local stats = towerStats[towerName]
	local template = towerTemplates[towerName]

	if not stats or not template then
		sendState({
			Type = "PlacementResult",
			Success = false,
			Reason = "Tower",
		})

		return
	end

	-- check both our server side padUsage table AND the attribute, just to be safe
	if padUsage[pad] or pad:GetAttribute("Occupied") then
		sendState({
			Type = "PlacementResult",
			Success = false,
			Reason = "Occupied",
		})

		return
	end

	if cash < stats.Cost then
		sendState({
			Type = "PlacementResult",
			Success = false,
			Reason = "Cash",
		})

		return
	end
	-- print("placing", towerName, "on", pad.Name, "- cash remaining:", cash - stats.Cost)

	-- all checks passed, actually place the tower
	local model = template:Clone()
	prepModel(model)
	model.Parent = Workspace

	local offset = getPivotOffset(model)
	local pivotPos = pad.Position + pad.CFrame.UpVector * (offset - pad.Size.Y * 0.5)
	local restCf = cframeFrom(pivotPos, pad.CFrame) -- saved so the tower can snap back when idle

	model:PivotTo(restCf)

	local tower = {
		Model = model,
		Type = towerName,
		Pad = pad,
		Damage = stats.Damage,
		FireRate = stats.FireRate,
		NextShot = 0, -- os.clock() timestamp for when this tower can fire again
		VerticalOffset = offset,
		RestCFrame = restCf,
		Range = defaultTowerRange,
		SessionId = sessionId,
	}

	activeTowers[model] = tower
	padUsage[pad] = tower
	pad:SetAttribute("Occupied", true)

	setCash(cash - stats.Cost)

	sendState({
		Type = "PlacementResult",
		Success = true,
		Tower = towerName,
		Pad = pad.Name,
	})
end

local function startRound(player)
	if player ~= getRoundPlayer() then
		return
	end

	if roundRunning or resetting then
		return
	end

	roundRunning = true
	resetting = false

	-- push fresh state to the client before kicking off waves
	setWave(0)
	setBaseHealth(baseHealth)
	setCash(cash)

	sendState({
		Type = "RoundStarted",
	})

	runWaves()
end

-- moves every active enemy along the path by however far they can travel in dt seconds.
-- we walk segment by segment so enemies dont skip over corners on high framerates
local function stepEnemies(dt)
	for _, enemy in pairs(activeEnemies) do
		if enemy.Removed or enemy.SessionId ~= sessionId then
			continue
		end

		local primary = enemy.Model.PrimaryPart

		if not primary then
			continue
		end


		local moveLeft = enemy.Speed * dt
		local ground = enemy.GroundPosition
		local nodeIndex = enemy.NodeIndex

		while moveLeft > 0 and nodeIndex < #pathPoints do
			local nextPoint = pathPoints[nodeIndex + 1]
			local offset = nextPoint - ground
			local distance = offset.Magnitude

			if distance <= 0.0001 then
				-- already at this node, just advance to the next one
				ground = nextPoint
				nodeIndex += 1
			elseif moveLeft >= distance then
				-- can reach and pass this node in one step
				ground = nextPoint
				moveLeft -= distance
				nodeIndex += 1
			else
				-- partway to the next node, move what we can and stop
				ground += offset.Unit * moveLeft
				moveLeft = 0
			end
		end

		enemy.GroundPosition = ground
		enemy.NodeIndex = nodeIndex

		-- reached or passed the end node, they get through and damage the base
		if nodeIndex >= #pathPoints then
			enemy:Destroy(true)
			continue
		end

		-- update how far they still have to go (for tower targeting priority)
		local segmentStart = pathPoints[nodeIndex]
		local segmentProgress = (ground - segmentStart).Magnitude
		local traveled = pathProgress[nodeIndex] + segmentProgress
		enemy.RemainingDistance = totalPathLength - traveled

		-- rotate the model to face the next waypoint, keeping it flat on the ground
		local facingTarget = pathPoints[nodeIndex + 1]
		local facing = facingTarget - ground
		local flatFacing = Vector3.new(facing.X, 0, facing.Z)
		local pivotPos = ground + Vector3.new(0, enemy.VerticalOffset, 0)

		if flatFacing.Magnitude > 0.001 then
			enemy.Model:PivotTo(CFrame.lookAt(pivotPos, pivotPos + flatFacing))
		else
			-- flat direction is basically zero (shouldnt happen on a normal path but just in case)
			enemy.Model:PivotTo(cframeFrom(pivotPos, enemy.Model:GetPivot()))
		end
	end
end

-- moves projectiles toward their target. if they get close enough this frame they deal damage immediately and clean themselves up
local function stepProjectiles(dt)
	for projectilePart, projectile in pairs(activeProjectiles) do
		if projectile.SessionId ~= sessionId then
			clearProjectile(projectilePart)
			continue
		end

		local target = projectile.Target

		-- if the target died before we arrived, just remove the projectile
		if not target or target.Removed or not target.Model.PrimaryPart then
			clearProjectile(projectilePart)
			continue
		end

		local targetPos = target.Model.PrimaryPart.Position
		local toTarget = targetPos - projectile.Position
		local distance = toTarget.Magnitude
		local travel = projectile.Speed * dt

		if distance <= travel then
			-- close enough to count as a hit this frame
			projectile.Part.CFrame = CFrame.new(targetPos)
			target:TakeDamage(projectile.Damage)
			clearProjectile(projectilePart)
		else
			local direction = toTarget.Unit
			local nextPos = projectile.Position + direction * travel
			projectile.Position = nextPos
			projectile.Part.CFrame = CFrame.lookAt(nextPos, nextPos + direction)
		end
	end
end

-- handles tower aiming and shooting. uses os.clock() for timestamps so fire rate is fps independent regardless of what the dt happens to be
local function stepTowers(now)
	for _, tower in pairs(activeTowers) do
		if tower.SessionId ~= sessionId then
			continue
		end

		if not tower.Model.Parent or not tower.Model.PrimaryPart then
			continue
		end

		local target = getBestTarget(tower)

		if not target then
			-- no enemies in range, snap back to the resting orientation
			tower.Model:PivotTo(tower.RestCFrame)
			continue
		end

		-- rotate to face the target, but keep the tower level (ignore the Y difference)
		local towerPos = getTowerPivot(tower)
		local enemyPos = target.Model.PrimaryPart.Position
		local lookPos = Vector3.new(enemyPos.X, towerPos.Y, enemyPos.Z)

		tower.Model:PivotTo(CFrame.lookAt(towerPos, lookPos))

		if now >= tower.NextShot then
			tower.NextShot = now + tower.FireRate
			fireProjectile(tower, target)
		end
	end
end

-- the main game loop, runs every physics step.
-- we skip everything if a reset is in progress to avoid touching half destroyed state
RunService.Heartbeat:Connect(function(dt)
	if resetting then
		return
	end

	stepEnemies(dt)
	stepProjectiles(dt)
	stepTowers(os.clock())
end)

-- only one player per server so whoever joins first is the round player
Players.PlayerAdded:Connect(function(player)
	if roundPlayer then
		return
	end

	roundPlayer = player
	resetMatch()
end)

-- clean up everything when the player leaves so the server is in a valid state if somehow another player joins after (but with single player that shouldnt happen)
Players.PlayerRemoving:Connect(function(player)
	if player ~= roundPlayer then
		return
	end

	roundPlayer = nil
	sessionId += 1 -- invalidate any running coroutines
	roundRunning = false
	resetting = false
	clearAllProjectiles()
	clearEnemies()
	clearTowers()
	resetPads()
	cash = startingCash
	baseHealth = baseMaxHealth
	currentWave = 0
end)

placeTowerRemote.OnServerEvent:Connect(placeTower)
startRoundRemote.OnServerEvent:Connect(startRound)

-- handle the edge case where a player was already in the server when this script ran (eg after a hot reload in studio)
local existingPlayers = Players:GetPlayers()

if existingPlayers[1] then
	roundPlayer = existingPlayers[1]
	resetMatch()
else
	resetPads() -- no player yet, but make sure pads are cleared so theyre ready
end

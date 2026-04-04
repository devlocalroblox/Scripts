--[[
	ServerScriptService/Main
	Handles all server-side logic for my world building system project
	Scripted by Local
	
	RoDevs & HiddenDevs Luau Skill Role Application
	Github Script Example
	Portfolio piece
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

-- nice helper for debugging; if something is missing we want to know quickly at server start.
local function Get(parent, name)
	local item = parent:WaitForChild(name, 3) -- 3 second delay helps incase an asset is late or what not

	if item then
		return item
	end

	warn(string.format("Missing %s under %s", name, parent:GetFullName()))

	return nil
end

local Shared = Get(ReplicatedStorage, "Shared")
local Mirrored = Get(ReplicatedStorage, "ReplicatedStorage")
local Assets = Get(ReplicatedStorage, "Assets")
local Baseplate = Get(Workspace, "Baseplate")
local World = Get(ServerScriptService, "World")
local Core = Get(ServerScriptService, "Core")

if not Shared or not Mirrored or not Assets or not Baseplate or not World or not Core then
	return
end

local config = Get(Shared, "Config")
local types = Get(Shared, "Types")
local grid = Get(World, "Grid")
local ownership = Get(World, "Ownership")
local commands = Get(World, "Commands")
local queue = Get(World, "Queue")
local playerData = Get(Core, "PlayerData")

if not config or not types or not grid or not ownership or not commands or not queue or not playerData then
	return
end

local Config = require(config)
local Types = require(types)
local GridLib = require(grid)
local OwnershipLib = require(ownership)
local CommandsLib = require(commands)
local QueueLib = require(queue)
local PlayerData = require(playerData)

type BlockId = Types.BlockId
type BuildAction = Types.BuildAction
type CellRecord = Types.CellRecord
type GridCell = Types.GridCell
type ChunkRef = Types.ChunkRef
type CellSnapshot = Types.CellSnapshot
type WorldMeta = Types.WorldMeta
type SessionMeta = Types.SessionMeta

-- PlacementRecord is what actually gets stored in command history for undo purposes.
-- we keep a snapshot of everything the placement looked like at the time so that we can verify nothing changed before allowing an undo (see checkCommand)
type PlacementRecord = {
	Id: string,
	Kind: "Place",
	Key: string,
	Cell: GridCell,
	Block: BlockId,
	Rotation: number,
	Cost: number,
	OwnerUserId: number,
	PlacedAt: number,
	ChunkKey: string,
}

-- per-player security state; tokens refill over time (rate limiter), score decays too.
type Guard = {
	Tokens: number,
	TokenStamp: number,
	Score: number,
	ScoreStamp: number,
	BlockedUntil: number, -- BlockedUntil is a hard gate; we dont process ANY actions until the clock passes it
	Rejects: number,
	Accepts: number,
	Reasons: { [string]: number },
}

-- everything about a build/remove/undo attempt lives in one table so functions dont need a bunch of individual parameters threaded through them
type Mutation = {
	Id: string,
	Kind: "Place" | "Remove" | "Undo" | "SessionClear",
	Player: Player,
	UserId: number,
	Record: CellRecord,
	Chunk: ChunkRef,
	Cost: number,
	Refund: number,
	DropKey: string?,
	Command: PlacementRecord?,
}

type Action = {
	Kind: "Place" | "Remove" | "Undo",
	Data: { [string]: any }?,
}

local function Ok(value)
	return { ok = true, value = value }
end

local function Err(reason: string)
	return { ok = false, reason = reason }
end

require(Mirrored)

local remotes = Get(Mirrored, "Remotes")

if not remotes then
	return
end

local events = Get(remotes, "Events")
local functions = Get(remotes, "Functions")

if not events or not functions then
	return
end

local action = Get(events, Config.Remotes.Action)
local state = Get(events, Config.Remotes.State)
local bootstrap = Get(functions, Config.Remotes.Bootstrap)

if not action or not state or not bootstrap then
	return
end

-- pre validate all block assets at startup. way better to crash here than to find out mid session that some block is missing or what not
local Blocks = {}

for i = 1, #Config.BlockOrder do
	local blockName = Config.BlockOrder[i]
	local info = Config.Blocks[blockName]
	local asset = Get(Assets, info.Asset)

	if not asset or not asset:IsA("BasePart") then
		warn(string.format("Asset %s is missing or not a BasePart", info.Asset))

		return
	end

	Blocks[blockName] = asset
end

local Grid = GridLib.new(Baseplate, Config.Grid.CellSize, Config.Grid.Height)
local Ownership = OwnershipLib.new()
local Commands = CommandsLib.new()

-- session id tags every mutation and replication packet so clients can discard stale stuff if they reconnect. also useful for debugging in logs
local sessionId = HttpService:GenerateGUID(false)
local sessionStart = Workspace:GetServerTimeNow()
local mutationCount = 0
local worldSequence = 0 -- increments every time we fire a patch to clients

-- this gets sent to clients on bootstrap so they know exactly what the world looks like and what rules apply (reach limit, chunk size, bounds, etc.)
local worldMeta: WorldMeta = {
	CellSize = Config.Grid.CellSize,
	Height = Config.Grid.Height,
	Reach = Config.Grid.MaxReach,
	ChunkSize = Config.Build.ChunkSize,
	Bounds = {
		XMin = Grid.XMin,
		XMax = Grid.XMax,
		YMin = 0,
		YMax = Config.Grid.Height - 1,
		ZMin = Grid.ZMin,
		ZMax = Grid.ZMax,
	},
	TopY = Grid.TopY,
}

local guards: { [Player]: Guard } = {}
local statDirty = {} -- players whose stats need pushing this frame
local statScheduled = false
local buckets = {} -- chunk key -> pending patch items

local function nextMutationId(player)
	mutationCount += 1

	return string.format("%d:%d", player.UserId, mutationCount)
end

local function chunkKey(x, y, z)
	return string.format("%d,%d,%d", x, y, z)
end

local function chunkFromValues(x, y, z): ChunkRef
	local size = worldMeta.ChunkSize
	local cx = math.floor(x / size)
	local cy = math.floor(y / size)
	local cz = math.floor(z / size)

	return {
		Key = chunkKey(cx, cy, cz),
		X = cx,
		Y = cy,
		Z = cz,
	}
end

local function chunkFromCell(cell): ChunkRef
	return chunkFromValues(cell.X, cell.Y, cell.Z)
end

-- lazily creates an audit entry on first access. the token/score refill logic runs here so callers always get a fresh view of the current state
local function getGuard(player)
	local now = os.clock()
	local guard = guards[player]

	if not guard then
		guard = {
			Tokens = Config.Build.ActionBurst,
			TokenStamp = now,
			Score = 0,
			ScoreStamp = now,
			BlockedUntil = 0,
			Rejects = 0,
			Accepts = 0,
			Reasons = {},
		}

		guards[player] = guard
		--print("Guard: new audit created for", player.Name)

		return guard
	end

	-- refill tokens based on elapsed time since we last checked
	local tokenElapsed = now - guard.TokenStamp

	if tokenElapsed > 0 then
		guard.Tokens = math.min(Config.Build.ActionBurst, guard.Tokens + tokenElapsed * Config.Build.ActionRate)
		guard.TokenStamp = now
	end

	-- suspicion score naturally goes down so a player who made a few mistakes doesnt stay blocked forever
	local scoreElapsed = now - guard.ScoreStamp

	if scoreElapsed > 0 then
		guard.Score = math.max(0, guard.Score - scoreElapsed * Config.Security.ScoreDecay)
		guard.ScoreStamp = now
	end

	return guard
end

-- bump suspicion score and potentially block the player. 
-- the reason codes get counted individually so we can see patterns in logs (eg someone spamming PlaceBounds)
local function flagPlayer(player, code, weight)
	if weight <= 0 then
		return
	end

	local audit = getGuard(player)
	local now = os.clock()
	local count = (audit.Reasons[code] or 0) + 1

	audit.Reasons[code] = count
	audit.Rejects += 1
	audit.Score += weight
	audit.ScoreStamp = now

	if audit.Score >= Config.Security.HardBlockScore then
		audit.BlockedUntil = math.max(audit.BlockedUntil, now + Config.Security.HardBlockTime)
	elseif audit.Score >= Config.Security.SoftBlockScore then
		audit.BlockedUntil = math.max(audit.BlockedUntil, now + Config.Security.SoftBlockTime)
	end

	-- only warn every x rejections so the output isnt flooded
	if count % Config.Security.RepeatWarn == 0 then
		warn(string.format("Suspicious traffic %s x%d from %s", code, count, player.Name))
	end
end

-- small relief on successful actions, this way legitimate players who sometimes hit edge cases dont get score unfairly
local function unflag(player)
	local audit = getGuard(player)

	audit.Accepts += 1
	audit.Score = math.max(0, audit.Score - Config.Security.SuccessRelief)
	audit.ScoreStamp = os.clock()
end

-- consumes one token. if the bucket is empty or the player is blocked, rejects the action.
local function takeToken(player)
	local audit = getGuard(player)
	local now = os.clock()

	if audit.BlockedUntil > now then
		--print("Token: player", player.Name, "is blocked, ignoring action")
		return false
	end

	if audit.Tokens < 1 then
		flagPlayer(player, "Burst", Config.Security.BurstWeight)

		return false
	end

	audit.Tokens -= 1

	return true
end

local function sendStats(player)
	local cash = PlayerData.Get(player, "Cash") or 0

	state:FireClient(player, {
		Kind = "Stats",
		Cash = cash,
		PlacedCount = Ownership:Count(player.UserId),
		CanUndo = Commands:Has(player.UserId),
		HistoryDepth = Commands:Count(player.UserId),
	})
end

-- deferred batch flush so we dont fire stats to the client multiple times in the same frame
-- if 5 things change at once (cash, ownership, history) the player only gets one update
local function pushStats()
	statScheduled = false

	local pending = statDirty
	statDirty = {}

	for player in pairs(pending) do
		if player.Parent == Players then
			sendStats(player)
		end
	end
end

local function markStats(player)
	if not player then
		return
	end

	statDirty[player] = true

	if statScheduled then
		return
	end

	statScheduled = true
	task.defer(pushStats)
end

-- collects pending patch items per chunk and fires one combined packet to all clients (batching)
local function pushChunks(chunkKeys)
	local packed = {}
	local seen = {}

	for i = 1, #chunkKeys do
		local key = chunkKeys[i]

		if not seen[key] then
			seen[key] = true

			local bucket = buckets[key]

			if bucket then
				bucket.Pending = false

				if #bucket.Items > 0 then
					local items = bucket.Items
					bucket.Items = {} -- clear before handing off so new items dont get swept into this flush
					packed[#packed + 1] = {
						Chunk = bucket.Chunk,
						Items = items,
					}
				end
			end
		end
	end

	if #packed == 0 then
		return
	end

	worldSequence += 1

	state:FireAllClients({
		Kind = "Patch",
		SessionId = sessionId,
		Sequence = worldSequence,
		Regions = packed,
	})
end

-- QueueLib handles the time windowed batching. we just hand it the flush function and it calls us back at the right intervals
local updateQueue = QueueLib.new(pushChunks, Config.Build.ReplicationWindow, Config.Build.RegionBatch)

local function getChunkPatch(chunk)
	local bucket = buckets[chunk.Key]

	if bucket then
		return bucket
	end

	bucket = {
		Chunk = chunk,
		Items = {},
		Pending = false,
	}

	buckets[chunk.Key] = bucket

	return bucket
end

-- queues an add/remove item for the chunk that contains this record
local function sendPatch(kind, record, chunk)
	local bucket = getChunkPatch(chunk)

	if kind == "Add" then
		bucket.Items[#bucket.Items + 1] = {
			Kind = "Add",
			Cell = Grid:SnapshotRecord(record),
		}
	else
		bucket.Items[#bucket.Items + 1] = {
			Kind = "Remove",
			Key = record.Key,
		}
	end
	-- Pending flag makes sure we dont push the same chunk key to the queue multiple times
	if bucket.Pending then
		return
	end

	bucket.Pending = true
	updateQueue:Push(chunk.Key)
end

-- groups a flat list of cell snapshots into per chunk buckets for the bootstrap response.
-- same structure the live patch system uses so the client can handle both the same way
local function chunkCells(cells)
	local grouped = {}
	local order = {}

	for i = 1, #cells do
		local cell: CellSnapshot = cells[i]
		local chunk = chunkFromValues(cell.X, cell.Y, cell.Z)
		local bucket = grouped[chunk.Key]

		if not bucket then
			bucket = {
				Chunk = chunk,
				Items = {},
			}

			grouped[chunk.Key] = bucket
			order[#order + 1] = chunk.Key
		end

		bucket.Items[#bucket.Items + 1] = {
			Kind = "Add",
			Cell = cell,
		}
	end

	local regions = {}

	for i = 1, #order do
		regions[#regions + 1] = grouped[order[i]]
	end

	return regions
end

-- wire up stat refreshes to the things that can change them.
Ownership.OnChanged:Connect(function(userId)
	markStats(Players:GetPlayerByUserId(userId))
end)

Commands.OnChanged:Connect(function(userId)
	markStats(Players:GetPlayerByUserId(userId))
end)

PlayerData.CashChanged:Connect(function(player)
	markStats(player)
end)
-- doing it through signals means we dont have to scatter markStats() calls everywhere

PlayerData.Start()

-- these three helpers (getCell, normalizeCell, checkBlock) are input sanitization. 
-- they reject anything that isnt exactly what we expect and flag the player if the data looks off
local function getCell(value)
	local num = tonumber(value)

	if num == nil then
		return nil
	end

	local rounded = math.round(num)

	-- reject if the value isnt already snapped to an integer cell coordinate.
	-- floating point cell coords from a client are a red flag
	if math.abs(num - rounded) > 0.001 then
		return nil
	end

	return rounded
end

local function normalizeCell(player, data)
	if type(data) ~= "table" then
		flagPlayer(player, "CellPacket", Config.Security.MalformedWeight)

		return nil
	end

	local x = getCell(data.X)
	local y = getCell(data.Y)
	local z = getCell(data.Z)

	if x == nil or y == nil or z == nil then
		flagPlayer(player, "CellShape", Config.Security.NonsenseWeight)

		return nil
	end

	return Vector3int16.new(x, y, z)
end

local function checkBlock(player, raw)
	if type(raw) ~= "string" then
		flagPlayer(player, "BlockShape", Config.Security.MalformedWeight)

		return nil
	end

	if Config.Blocks[raw] then
		return raw
	end

	flagPlayer(player, "BlockName", Config.Security.NonsenseWeight)

	return nil
end

-- snaps the rotation to the nearest 90 degree increment and rejects anything that doesnt cleanly divide (0/90/180/270; no free rotation)
local function snapRotation(player, raw)
	local value = tonumber(raw)

	if value == nil then
		flagPlayer(player, "RotationShape", Config.Security.MalformedWeight)

		return nil
	end

	local turns = math.round(value / 90)
	local snapped = turns * 90

	if math.abs(value - snapped) > 0.001 then
		flagPlayer(player, "RotationValue", Config.Security.NonsenseWeight)

		return nil
	end

	local wrapped = turns % 4

	if wrapped < 0 then
		wrapped += 4
	end

	return wrapped * 90
end

-- thin wrapper that validates the envelope shape before we try to dig into data
local function toAction(player, raw): Action?
	if type(raw) ~= "table" then
		flagPlayer(player, "ActionShape", Config.Security.MalformedWeight)

		return nil
	end

	local kind = raw.Kind
	
	-- undo doesnt carry any data so we handle it separately
	if kind == "Undo" then
		return {
			Kind = "Undo",
		}
	end

	if kind == "Place" or kind == "Remove" then
		if type(raw.Data) ~= "table" then
			flagPlayer(player, "ActionData", Config.Security.MalformedWeight)

			return nil
		end

		return {
			Kind = kind,
			Data = raw.Data,
		}
	end

	flagPlayer(player, "ActionKind", Config.Security.NonsenseWeight)

	return nil
end

local function getRoot(player)
	-- HumanoidRootPart first, PrimaryPart as fallback for edge cases (custom rigs, etc)
	local character = player.Character

	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		return root
	end

	local primary = character.PrimaryPart

	if primary and primary:IsA("BasePart") then
		return primary
	end

	return nil -- returning nil is fine; callers check it
end

-- server side reach check. clients already enforce this visually but we cant trust that
local function withinReach(player, position)
	local root = getRoot(player)

	if not root then
		return false
	end
	
	-- using squared distance avoids a sqrt which matters when this runs on every action
	local offset = root.Position - position
	local distSq = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
	local reach = worldMeta.Reach

	if distSq <= reach * reach then
		return true
	end

	return false
end

-- slightly smaller than the full cell size so blocks that are touching each other at the edge dont fail the overlap check
local boxSize = Vector3.new(Config.Grid.CellSize - Config.Build.PlacementPadding, Config.Grid.CellSize - Config.Build.PlacementPadding, Config.Grid.CellSize - Config.Build.PlacementPadding)

-- checks whether the target cell is physically clear before committing a placement.
-- the tricky part is excluding things we know are allowed; the player's own character, the baseplate, and any block thats already sitting at the exact same cell key
local function cellClear(player, cell, position, rotation)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.MaxParts = 32

	if player.Character then
		params.FilterDescendantsInstances = { player.Character }
	else
		params.FilterDescendantsInstances = {}
	end

	local frame = CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
	local hits = Workspace:GetPartBoundsInBox(frame, boxSize, params)

	-- if we're hitting the cap something is very wrong; treat it as blocked and log it so we know to raise the limit or investigate
	if #hits >= 32 then
		warn(string.format("World System cellClear hit MaxParts cap at %s for %s", tostring(cell), player.Name))
		return false
	end

	local targetKey = Grid:Key(cell)

	if #hits == 0 then
		return true
	end

	for i = 1, #hits do
		local hit = hits[i]

		if hit == Baseplate then
			continue
		end

		if CollectionService:HasTag(hit, Config.Build.Tag) then
			if hit:GetAttribute("GridKey") == targetKey then
				return false
			end

			continue
		end

		if player.Character and hit:IsDescendantOf(player.Character) then
			continue
		end

		if hit.CanCollide then
			return false
		end
	end

	return true
end

-- clones the block asset, sets all the attributes the client needs for hover/selection, tags it so our overlap checks can identify it, then parents it to workspace.
-- record.Part is set here so anything down that holds the record can reach the part
local function makePart(record, mutationId, chunk)
	if not Blocks[record.Block] then
		return Err(string.format("makePart: no asset for block '%s'", record.Block))
	end

	local part = Blocks[record.Block]:Clone()
	part.Name = record.Block
	part.Anchored = true
	part.CanTouch = false
	part.CanQuery = true
	part.CFrame = CFrame.new(record.Position) * CFrame.Angles(0, math.rad(record.Rotation), 0)
	part:SetAttribute("GridKey", record.Key)
	part:SetAttribute("GridX", record.Cell.X)
	part:SetAttribute("GridY", record.Cell.Y)
	part:SetAttribute("GridZ", record.Cell.Z)
	part:SetAttribute("OwnerUserId", record.OwnerUserId)
	part:SetAttribute("Block", record.Block)
	part:SetAttribute("Rotation", record.Rotation)
	part:SetAttribute("PlacedAt", record.PlacedAt)
	part:SetAttribute("MutationId", mutationId)
	part:SetAttribute("ChunkKey", chunk.Key)
	CollectionService:AddTag(part, Config.Build.Tag)
	part.Parent = Workspace
	record.Part = part

	return Ok(part)
end

local function wipePart(part)
	if not part then
		return
	end

	if part.Parent then
		CollectionService:RemoveTag(part, Config.Build.Tag)
		part:Destroy()
	end
end

-- loads the player's datastore profile if it isnt already loaded (wait up to 10s because datastore can take a moment when you join).
local function loadProfile(player)
	if not PlayerData.IsReady(player) then
		PlayerData.Load(player)
	end

	if PlayerData.IsReady(player) then
		return true
	end

	local profile = PlayerData.Await(player, 10)

	if profile then
		return true
	end

	return false -- returning false means the player cant build yet; we just silently drop the action
end

-- builds a Mutation for a place action after running every check that can fail. returns nil on any failure; the caller just ignores it
local function PlaceMutation(player, data)
	local blockName = checkBlock(player, data.Block)

	if not blockName then
		return nil
	end

	local cell = normalizeCell(player, data)

	if not cell then
		return nil
	end

	if not Grid:Contains(cell) then
		flagPlayer(player, "PlaceBounds", Config.Security.BoundsWeight)

		return nil
	end

	if Grid:Get(cell) then
		flagPlayer(player, "PlaceOccupied", Config.Security.CollisionWeight)

		return nil
	end

	local worldPos = Grid:ToWorld(cell)

	if not withinReach(player, worldPos) then
		flagPlayer(player, "PlaceReach", Config.Security.RangeWeight)
		
		return nil
	end

	local rotation = snapRotation(player, data.Rotation)

	if rotation == nil then
		return nil
	end

	local info = Config.Blocks[blockName]
	local cash = PlayerData.Get(player, "Cash")

	if cash == nil then
		return nil
	end

	if cash < info.Cost then
		return nil
	end

	if not cellClear(player, cell, worldPos, rotation) then
		flagPlayer(player, "PlaceCollision", Config.Security.CollisionWeight)

		return nil
	end

	local record: CellRecord = {
		Key = Grid:Key(cell),
		Cell = cell,
		Position = worldPos,
		Block = blockName,
		OwnerUserId = player.UserId,
		Rotation = rotation,
		PlacedAt = Workspace:GetServerTimeNow(),
		Part = nil,
	}

	local chunk = chunkFromCell(cell)
	local command: PlacementRecord = {
		Id = nextMutationId(player),
		Kind = "Place",
		Key = record.Key,
		Cell = cell,
		Block = blockName,
		Rotation = rotation,
		Cost = info.Cost,
		OwnerUserId = player.UserId,
		PlacedAt = record.PlacedAt,
		ChunkKey = chunk.Key,
	}

	return {
		Id = command.Id,
		Kind = "Place",
		Player = player,
		UserId = player.UserId,
		Record = record,
		Chunk = chunk,
		Cost = info.Cost,
		Refund = 0,
		Command = command,
	}
end

local function removeMutation(player, data)
	local cell = normalizeCell(player, data)

	if not cell then
		return nil
	end

	if not Grid:Contains(cell) then
		flagPlayer(player, "RemoveBounds", Config.Security.BoundsWeight)

		return nil
	end

	local record = Grid:Get(cell)

	if not record then
		flagPlayer(player, "RemoveMissing", Config.Security.CollisionWeight)

		return nil
	end

	-- ownership check here is important, players shouldnt be able to send a remove request for a block someone else placed
	if record.OwnerUserId ~= player.UserId then
		flagPlayer(player, "RemoveOwner", Config.Security.OwnershipWeight)

		return nil
	end

	if not withinReach(player, record.Position) then
		flagPlayer(player, "RemoveReach", Config.Security.RangeWeight)

		return nil
	end

	return {
		Id = nextMutationId(player),
		Kind = "Remove",
		Player = player,
		UserId = player.UserId,
		Record = record,
		Chunk = chunkFromCell(record.Cell),
		Cost = 0,
		Refund = Config.Build.RemoveRefund and Config.Blocks[record.Block].Cost or 0,
		DropKey = record.Key,
	}
end

-- verifies the command snapshot still matches whats actually in the grid.
-- if anything changed (someone else moved it, corrupted state, etc.) we discard the command and skip past it in undoMutation instead of undoing something we shouldnt
local function checkCommand(command, record)
	if record.Key ~= command.Key then
		return false
	end

	if record.OwnerUserId ~= command.OwnerUserId then
		return false
	end

	if record.Block ~= command.Block then
		return false
	end

	if record.Rotation ~= command.Rotation then
		return false
	end

	if math.abs(record.PlacedAt - command.PlacedAt) > 0.001 then
		return false
	end

	return true
end

-- walks backward through the command stack until it finds a command thats still valid.
local function undoMutation(player)
	while true do
		local command = Commands:Peek(player.UserId)

		if not command then
			return nil
		end

		local record = Grid:GetByKey(command.Key)
		
		-- stale commands (block was already removed, moved, etc.) get discarded silently
		if not record then
			Commands:Discard(player.UserId, command.Key)
			--print("Undo: stale command discarded for", player.Name, "key:", command.Key)

			continue
		end

		if not checkCommand(command, record) then
			Commands:Discard(player.UserId, command.Key)
			--print("Undo: stale command discarded for", player.Name, "key:", command.Key)
			
			continue
		end

		return {
			Id = nextMutationId(player),
			Kind = "Undo",
			Player = player,
			UserId = player.UserId,
			Record = record,
			Chunk = chunkFromCell(record.Cell),
			Cost = 0,
			Refund = Config.Build.UndoRefund and command.Cost or 0,
			DropKey = command.Key,
		}
	end
end

-- was experimenting with a lightweight validation pass before committing mutations
-- idea was to separate "can this happen" from "do the commit", but ended up folding it into the mutation builders

--local function validatePlacement(player, record, cost)
--	if not player or not record then
--		return false
--	end

--	if cost < 0 then
--		return false
--	end

--	local existing = Grid:Get(record.Cell)
--	if existing then
--		return false
--	end

--	return true
--end


-- commits a placement.
-- each step is rolled back if any later step fails so we never end up with partial state (charged but not inserted, inserted but no part, etc.)
local function placement(mutation)
	local player = mutation.Player
	local charged = false
	local inserted = false
	local newPart = nil
	local ownershipAdded = false
	local historyAdded = false

	if mutation.Cost > 0 then
		local paid = PlayerData.Remove(player, "Cash", mutation.Cost)

		if not paid then
			return false
		end

		charged = true
	end
	-- print("Placement: Committing block", mutation.Record.Block, "at", tostring(mutation.Record.Cell), "for", player.Name)
	
	if not Grid:Set(mutation.Record) then
		if charged then
			PlayerData.Add(player, "Cash", mutation.Cost)
		end

		return false
	end
	
	--print("Placement: Inserted block", mutation.Record.Block, "at", tostring(mutation.Record.Cell), "for", player.Name)
	inserted = true
	
	-- pcall because makePart touches workspace 
	-- if something goes wrong there, we want to roll back cleanly instead of leaving a ghost record in the grid
	local result = makePart(mutation.Record, mutation.Id, mutation.Chunk)

	if not result.ok then
		warn(string.format("World System placement failed: %s (mutation %s)", result.reason, mutation.Id))
		Grid:Remove(mutation.Record.Cell)

		if charged then
			PlayerData.Add(player, "Cash", mutation.Cost)
		end

		return false
	end

	newPart = result.value

	local ownOk, ownErr = pcall(function()
		Ownership:Add(mutation.UserId, mutation.Record.Key)
	end)

	if not ownOk then
		warn(string.format("World System ownership add failed: %s (mutation %s)", tostring(ownErr), mutation.Id))
		wipePart(newPart)
		Grid:Remove(mutation.Record.Cell)

		if charged then
			PlayerData.Add(player, "Cash", mutation.Cost)
		end

		return false
	end

	ownershipAdded = true

	local pushOk = true

	if mutation.Command then
		pushOk = pcall(function()
			Commands:Push(mutation.UserId, mutation.Command)
		end)
	end

	if not pushOk then
		if ownershipAdded then
			Ownership:Remove(mutation.UserId, mutation.Record.Key)
		end

		wipePart(newPart)
		Grid:Remove(mutation.Record.Cell)

		if charged then
			PlayerData.Add(player, "Cash", mutation.Cost)
		end

		return false
	end

	historyAdded = mutation.Command ~= nil

	sendPatch("Add", mutation.Record, mutation.Chunk)

	if historyAdded or ownershipAdded or charged then
		markStats(player)
	end

	unflag(player)

	return true
end

local function removeBlock(mutation)
	local removed = Grid:Remove(mutation.Record.Cell)

	if not removed then
		return false
	end

	-- reassign Record to the version Grid:Remove returns. it carries the part reference we need
	mutation.Record = removed
	--print("Remove: Cleared", removed.Block, "at", removed.Key, "owner:", mutation.UserId)
	wipePart(removed.Part)
	Ownership:Remove(removed.OwnerUserId, removed.Key)

	if mutation.DropKey then
		Commands:Discard(mutation.UserId, mutation.DropKey)
	end

	if mutation.Refund > 0 then
		PlayerData.Add(mutation.Player, "Cash", mutation.Refund)
	end

	sendPatch("Remove", removed, mutation.Chunk)
	markStats(mutation.Player)
	unflag(mutation.Player)

	return true
end

-- cleans up everything a player placed when they leave.
local function wipePlayer(player)
	-- snapshot the keys first so removeBlock cant invalidate the iterator
	local keys = table.clone(Ownership:List(player.UserId))
	--print("Wipe: cleaning up", #keys, "blocks for", player.Name)
	
	for _, key in keys do
		local record = Grid:GetByKey(key)

		if not record then
			continue
		end

		local mutation = {
			Id = nextMutationId(player),
			Kind = "Remove",
			Player = player,
			UserId = player.UserId,
			Record = record,
			Chunk = chunkFromCell(record.Cell),
			Cost = 0,
			Refund = 0,
			DropKey = record.Key,
		}

		local ok = removeBlock(mutation)

		if not ok then
			warn(string.format("World System wipePlayer failed to remove key %s for %s", key, player.Name))
		end
	end

	Commands:Clear(player.UserId)
	guards[player] = nil
	statDirty[player] = nil
end

-- packages up everything the client needs to reconstruct the world from scratch.
-- called once per player on join, after that they stay in sync via patches
local function getBoostrap(player)
	if not loadProfile(player) then
		return nil
	end

	local snapshot = Grid:Snapshot()
	local session: SessionMeta = {
		Id = sessionId,
		OpenedAt = sessionStart,
		ServerTime = Workspace:GetServerTimeNow(),
		Sequence = worldSequence,
		UndoRefund = Config.Build.UndoRefund,
		RemoveRefund = Config.Build.RemoveRefund,
	}

	return {
		Kind = "Bootstrap",
		World = worldMeta,
		Session = session,
		Regions = chunkCells(snapshot),
		Cash = PlayerData.Get(player, "Cash") or 0,
		PlacedCount = Ownership:Count(player.UserId),
		CanUndo = Commands:Has(player.UserId),
	}
end

bootstrap.OnServerInvoke = function(player)
	return getBoostrap(player)
end

action.OnServerEvent:Connect(function(player, rawAction: BuildAction)
	if not loadProfile(player) then
		return
	end

	local request = toAction(player, rawAction)

	if not request then
		return
	end

	-- token check runs before any game logic so a burst attacker gets blocked
	if not takeToken(player) then
		return
	end

	local mutation

	if request.Kind == "Place" then
		mutation = PlaceMutation(player, request.Data)
	elseif request.Kind == "Remove" then
		mutation = removeMutation(player, request.Data)
	else
		mutation = undoMutation(player)
	end

	if not mutation then
		return
	end

	-- if the commit fails here its probably a race (two clients on the same cell at once). flag it lightly instead of ignoring it
	local ok
	
	if mutation.Kind == "Place" then
		ok = placement(mutation)
	else
		ok = removeBlock(mutation)
	end

	if not ok then
		flagPlayer(player, "CommitRace", Config.Security.CollisionWeight)
	end
end)

local function onPlayerAdded(player)
	loadProfile(player)
end

local function onPlayerRemoving(player)
	wipePlayer(player)
	PlayerData.Unload(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- handle players who were already in the server when this script ran (studio playtests, hot reloads, etc)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

--[[
	Version: 1.0
	Worktime: 4 days
	
	Todo (for future versions):
	- Singleplayer & multiplayer
	- Persistent world saving (still needs to be properly planned, would apply to singleplayer)
	- Block limit per player (just for extra showcase, most likely not permanent)
	- Admin wipe command
	- Chunk-based loading (when theres a lot of blocks, clients dont get a full snapshot right on join)
]]

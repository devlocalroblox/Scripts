--[[
	Profile - Custom DataStore Session Manager
	Made by Local

	This is a session-locking DataStore wrapper. The core idea is simple:
	- When you load a player's data, this module "claims" it with a lease so no other server can write to it at the same time. 
	- When the player leaves, the lease is released and the data is saved one final time.

	The module is designed around three main objects:
	1. Store - created once per DataStore, holds config and manages all sessions
	2. Session - represents an active (or read only) claim on a specific key
	3. Profile - the public facing module table; entry point for everything

	Quick usage:
	
	local ProfileStore = require(...)
	local Store = ProfileStore.New("PlayerData", { Coins = 0 })

	-- in PlayerAdded:
	local session = Store:Load(player.UserId)
	if session then
	    session.Data.Coins += 10
	    session:EndSession()
	end

	Things to keep in mind:
	- Profile.Data must only contain types that can serialize to JSON (no Instances, no Vector3, no functions, no mixed/gapped arrays)
	- Session methods like :Mutate() are NOT safe across yields; always check :IsActive() again after any task.wait() or async call
	- The mock store (Store.Mock) is fully isolated from real DataStore data, useful for testing without touching live keys

	Signals exposed at the module level:
	- Profile.OnError(message, storeName, key)
	- Profile.OnCritical(isCritical)
	- Profile.OnState(newState)
	
	Worktime: 7 days
--]]

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- simple signal implementation
-- supports Connect, Fire, Wait, and Disconnect
local Signal = {}
Signal.__index = Signal

local Link = {}
Link.__index = Link

function Signal.new()
	local self = {
		head = nil,
		count = 0,
	}
	setmetatable(self, Signal)
	return self
end

function Link:Disconnect()
	if self.live ~= true then
		return
	end

	self.live = false
	local sig = self.signal
	sig.count -= 1

	-- if we're at the head just move it forward, otherwise walk the list
	if sig.head == self then
		sig.head = self.next
	else
		local node = sig.head
		while node ~= nil do
			if node.next == self then
				node.next = self.next
				break
			end
			node = node.next
		end
	end
end

function Signal:Connect(fn)
	if type(fn) ~= "function" then
		error("Signal:Connect expected function")
	end

	local link = {
		next = self.head,
		live = true,
		listener = fn,
		signal = self,
	}
	setmetatable(link, Link)

	self.head = link
	self.count += 1

	return link
end

function Signal:GetListenerCount()
	return self.count
end

-- fires all live listeners in separate threads so one erroring handler doesnt kill others
function Signal:Fire(...)
	local node = self.head
	while node ~= nil do
		if node.live == true then
			task.spawn(node.listener, ...)
		end
		node = node.next
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local link

	link = self:Connect(function(...)
		link:Disconnect()
		task.spawn(function(...)
			local ok, msg = coroutine.resume(thread, ...)
			if ok ~= true then
				error(msg)
			end
		end, ...)
	end)

	return coroutine.yield()
end

-- deep copies any value; handles circular references via the seen table
local function copyAny(value, seen)
	if type(value) ~= "table" then
		return value
	end

	if seen == nil then
		seen = {}
	elseif seen[value] ~= nil then
		return seen[value]
	end

	local clone = {}
	seen[value] = clone

	for k, v in pairs(value) do
		clone[copyAny(k, seen)] = copyAny(v, seen)
	end

	return clone
end

-- fills in missing keys from base into target, used for applying the store template to loaded data
local function fillMissing(target, base)
	if type(target) ~= "table" or type(base) ~= "table" then
		return
	end

	for k, v in pairs(base) do
		local has = target[k]
		if has == nil then
			target[k] = copyAny(v)
		elseif type(has) == "table" and type(v) == "table" then
			fillMissing(has, v)
		end
	end
end

-- deep equality check, also handles circular refs
local function sameData(a, b, seen)
	if a == b then
		return true
	end

	if type(a) ~= type(b) then
		return false
	end

	if type(a) ~= "table" then
		return false
	end

	if seen == nil then
		seen = {}
	elseif seen[a] == b then
		return true
	end

	seen[a] = b

	for k, av in pairs(a) do
		if sameData(av, b[k], seen) ~= true then
			return false
		end
	end

	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end

	return true
end

local function pathJoin(base, key)
	if base == "" then
		return tostring(key)
	end
	return base .. "." .. tostring(key)
end

-- walks two data snapshots and collects a list of paths that changed.
-- stops early once we hit maxCount to avoid insane diffs on bulk mutations
local function diffData(before, after, base, list, maxCount)
	if #list >= maxCount then
		return
	end

	local beforeType = type(before)
	local afterType = type(after)

	if beforeType ~= afterType then
		local point = base
		if point == "" then
			point = "*"
		end
		table.insert(list, {
			Path = point,
			Value = copyAny(after),
		})
		return
	end

	if afterType ~= "table" then
		if before ~= after then
			local point = base
			if point == "" then
				point = "*"
			end
			table.insert(list, {
				Path = point,
				Value = copyAny(after),
			})
		end
		return
	end

	local seen = {}
	for k, v in pairs(after) do
		seen[k] = true
		diffData(before[k], v, pathJoin(base, k), list, maxCount)
		if #list >= maxCount then
			return
		end
	end

	-- anything in before thats gone in after needs to be marked as removed
	for k in pairs(before) do
		if seen[k] ~= true then
			local point = pathJoin(base, k)
			table.insert(list, {
				Path = point,
				Value = nil,
			})
			if #list >= maxCount then
				return
			end
		end
	end
end

-- keeps an array from going past a length by removing from the front
local function trimArray(arr, amount)
	if amount <= 0 then
		return
	end

	while #arr > amount do
		table.remove(arr, 1)
	end
end

-- cleans up a userId list; deduplicates, strips non integers
local function normalizeUserIds(list)
	local out = {}
	local seen = {}

	if type(list) ~= "table" then
		return out
	end

	for _, userId in ipairs(list) do
		if type(userId) == "number" and userId % 1 == 0 then
			if seen[userId] ~= true then
				seen[userId] = true
				table.insert(out, userId)
			end
		end
	end

	return out
end

-- schema type constructors
-- these just build description tables; actual validation happens in checkRule
local Types = {}

function Types.Any()
	return {
		kind = "any",
	}
end

function Types.Number(min, max)
	return {
		kind = "number",
		min = min,
		max = max,
	}
end

function Types.Integer(min, max)
	return {
		kind = "integer",
		min = min,
		max = max,
	}
end

function Types.String(minLen, maxLen)
	return {
		kind = "string",
		minLen = minLen,
		maxLen = maxLen,
	}
end

function Types.Boolean()
	return {
		kind = "boolean",
	}
end

function Types.Enum(values)
	return {
		kind = "enum",
		values = values,
	}
end

-- Optional wraps another rule and allows nil, returning fallback if provided
function Types.Optional(rule, fallback)
	return {
		kind = "optional",
		rule = rule,
		fallback = fallback,
	}
end

function Types.Array(rule, maxLen)
	return {
		kind = "array",
		rule = rule,
		maxLen = maxLen,
	}
end

function Types.Map(rule, maxLen)
	return {
		kind = "map",
		rule = rule,
		maxLen = maxLen,
	}
end

-- keepUnknown = true means extra keys not in shape are preserved instead of stripped
function Types.Object(shape, keepUnknown)
	return {
		kind = "object",
		shape = shape,
		keepUnknown = keepUnknown,
	}
end

function Types.Literal(value)
	return {
		kind = "literal",
		value = value,
	}
end

function Types.Custom(fn)
	return {
		kind = "custom",
		check = fn,
	}
end

local function isRule(rule)
	if type(rule) ~= "table" then
		return false
	end
	if type(rule.kind) ~= "string" then
		return false
	end
	return true
end

-- allows shorthand: a plain table becomes Object, a function becomes Custom, anything else becomes Literal
local function parseRule(rule)
	if isRule(rule) == true then
		return rule
	end

	if type(rule) == "table" then
		return Types.Object(rule, true)
	end

	if type(rule) == "function" then
		return Types.Custom(rule)
	end

	return Types.Literal(rule)
end

local function issue(issues, path, msg)
	table.insert(issues, {
		Path = path,
		Message = msg,
	})
end

-- the main validation/sanitization workhorse
-- returns (cleanedValue, wasValid)
-- when sanitize=true it tries to fix bad values instead of just flagging them
local function checkRule(rule, value, path, issues, sanitize)
	local kind = rule.kind

	if kind == "any" then
		return copyAny(value), true
	end

	if kind == "optional" then
		if value == nil then
			if rule.fallback ~= nil then
				return copyAny(rule.fallback), true
			end
			return nil, true
		end
		return checkRule(parseRule(rule.rule), value, path, issues, sanitize)
	end

	if kind == "number" then
		if type(value) ~= "number" then
			issue(issues, path, "Expected number")
			if sanitize == true then
				return 0, false
			end
			return value, false
		end
		local num = value
		if type(rule.min) == "number" and num < rule.min then
			issue(issues, path, "Number below min")
			if sanitize == true then
				num = rule.min
			end
		end
		if type(rule.max) == "number" and num > rule.max then
			issue(issues, path, "Number above max")
			if sanitize == true then
				num = rule.max
			end
		end
		return num, true
	end

	if kind == "integer" then
		if type(value) ~= "number" or value % 1 ~= 0 then
			issue(issues, path, "Expected integer")
			if sanitize == true then
				local fallback = 0
				if type(value) == "number" then
					fallback = math.floor(value + 0.5)
				end
				if type(rule.min) == "number" and fallback < rule.min then
					fallback = rule.min
				end
				if type(rule.max) == "number" and fallback > rule.max then
					fallback = rule.max
				end
				return fallback, false
			end
			return value, false
		end
		local num = value
		if type(rule.min) == "number" and num < rule.min then
			issue(issues, path, "Integer below min")
			if sanitize == true then
				num = rule.min
			end
		end
		if type(rule.max) == "number" and num > rule.max then
			issue(issues, path, "Integer above max")
			if sanitize == true then
				num = rule.max
			end
		end
		return num, true
	end

	if kind == "string" then
		if type(value) ~= "string" then
			issue(issues, path, "Expected string")
			if sanitize == true then
				return "", false
			end
			return value, false
		end
		local text = value
		local size = #text
		if type(rule.minLen) == "number" and size < rule.minLen then
			issue(issues, path, "String too short")
		end
		if type(rule.maxLen) == "number" and size > rule.maxLen then
			issue(issues, path, "String too long")
			if sanitize == true then
				text = string.sub(text, 1, rule.maxLen)
			end
		end
		return text, true
	end

	if kind == "boolean" then
		if type(value) ~= "boolean" then
			issue(issues, path, "Expected boolean")
			if sanitize == true then
				return false, false
			end
			return value, false
		end
		return value, true
	end

	if kind == "enum" then
		local values = rule.values
		local okEnum = false
		if type(values) == "table" then
			for _, item in ipairs(values) do
				if item == value then
					okEnum = true
					break
				end
			end
		end
		if okEnum ~= true then
			issue(issues, path, "Unexpected enum value")
			if sanitize == true and type(values) == "table" then
				return values[1], false
			end
			return value, false
		end
		return value, true
	end

	if kind == "literal" then
		if value ~= rule.value then
			issue(issues, path, "Expected literal")
			if sanitize == true then
				return copyAny(rule.value), false
			end
			return value, false
		end
		return value, true
	end

	if kind == "array" then
		local arr = value
		if type(arr) ~= "table" then
			issue(issues, path, "Expected array")
			if sanitize == true then
				return {}, false
			end
			return value, false
		end
		local out = {}
		local okAll = true
		local child = parseRule(rule.rule)
		local maxLen = rule.maxLen
		for i, item in ipairs(arr) do
			if type(maxLen) == "number" and i > maxLen then
				issue(issues, path, "Array too long")
				okAll = false
				break
			end
			local piece, valid = checkRule(child, item, pathJoin(path, i), issues, sanitize)
			out[i] = piece
			if valid ~= true then
				okAll = false
			end
		end
		return out, okAll
	end

	if kind == "map" then
		local map = value
		if type(map) ~= "table" then
			issue(issues, path, "Expected map")
			if sanitize == true then
				return {}, false
			end
			return value, false
		end
		local out = {}
		local validAll = true
		local child = parseRule(rule.rule)
		local maxLen = rule.maxLen
		local count = 0
		for k, item in pairs(map) do
			count += 1
			if type(maxLen) == "number" and count > maxLen then
				issue(issues, path, "Map too large")
				validAll = false
				break
			end
			local piece, good = checkRule(child, item, pathJoin(path, k), issues, sanitize)
			out[k] = piece
			if good ~= true then
				validAll = false
			end
		end
		return out, validAll
	end

	if kind == "object" then
		local obj = value
		if type(obj) ~= "table" then
			issue(issues, path, "Expected object")
			if sanitize == true then
				obj = {}
			else
				return value, false
			end
		end

		local out = {}
		local validAll = true
		local shape = rule.shape or {}
		local keepUnknown = rule.keepUnknown
		if keepUnknown == nil then
			keepUnknown = true
		end

		if keepUnknown == true then
			for k, item in pairs(obj) do
				out[k] = copyAny(item)
			end
		end

		for k, childRule in pairs(shape) do
			local piece, good = checkRule(parseRule(childRule), obj[k], pathJoin(path, k), issues, sanitize)
			if piece ~= nil or obj[k] ~= nil then
				out[k] = piece
			else
				out[k] = nil
			end
			if good ~= true then
				validAll = false
			end
		end

		return out, validAll
	end

	if kind == "custom" then
		if type(rule.check) ~= "function" then
			issue(issues, path, "Invalid custom rule")
			return value, false
		end
		local ok, a, b = pcall(rule.check, value)
		if ok ~= true then
			issue(issues, path, "Custom rule errored")
			return value, false
		end
		if a == false then
			issue(issues, path, "Custom validation failed")
			if sanitize == true and b ~= nil then
				return copyAny(b), false
			end
			return value, false
		end
		if type(a) == "table" then
			return copyAny(a), true
		end
		if b ~= nil then
			return copyAny(b), true
		end
		return copyAny(value), true
	end

	issue(issues, path, "Unknown rule")
	return copyAny(value), false
end

-- per key mutex using BindableEvents
-- this ensures UpdateAsync calls for the same key dont overlap, which would cause the second call to read stale data before the first one writes
local lockByKey = {}

local function waitQueue(key)
	local record = lockByKey[key]
	if record == nil then
		record = {
			busy = false,
			waiting = {},
		}
		lockByKey[key] = record
	end

	if record.busy == true then
		local gate = Instance.new("BindableEvent")
		table.insert(record.waiting, gate)
		gate.Event:Wait()
		gate:Destroy()
	end

	record.busy = true
	local live = true

	-- returns an unlock function; call this when your work is done
	return function()
		if live ~= true then
			return
		end
		live = false

		local nextGate = table.remove(record.waiting, 1)
		if nextGate ~= nil then
			nextGate:Fire()
		else
			lockByKey[key] = nil
		end
	end
end

-- wraps raw DataStore key info into a consistent shape regardless of backend
local function makeKeyInfo(entry)
	local userIds = normalizeUserIds(entry.UserIds)
	local meta = copyAny(entry.MetaTags or {})
	local createdAt = entry.CreatedAt or 0
	local updatedAt = entry.UpdatedAt or 0
	local version = tostring(entry.Version or 0)

	return {
		CreatedTime = createdAt,
		UpdatedTime = updatedAt,
		Version = version,
		GetMetadata = function()
			return copyAny(meta)
		end,
		GetUserIds = function()
			return copyAny(userIds)
		end,
	}
end

-- in memory store used when mock = true or Studio has no DataStore access
-- data lives only for the duration of the session
local memoryBucket = {}

local function getMemoryBucket(storeName)
	local bucket = memoryBucket[storeName]
	if bucket == nil then
		bucket = {
			values = {},
			versions = {},
			counter = 0,
			createdAt = {},
		}
		memoryBucket[storeName] = bucket
	end
	return bucket
end

-- the mock adapter mirrors the real DataStore adapters interface so everything above this layer doesn't need to know which one its using
local function makeMemoryAdapter(storeName)
	local bucket = getMemoryBucket(storeName)
	local adapter = {}

	function adapter:read(key, version)
		if version ~= nil then
			local list = bucket.versions[key]
			if type(list) == "table" then
				for i = #list, 1, -1 do
					local item = list[i]
					if tostring(item.Version) == tostring(version) then
						return true, copyAny(item.Value), makeKeyInfo(item), nil
					end
				end
			end
			return true, nil, nil, nil
		end

		local value = bucket.values[key]
		if value == nil then
			return true, nil, nil, nil
		end

		local versions = bucket.versions[key] or {}
		local latest = versions[#versions]
		if latest == nil then
			return true, copyAny(value), nil, nil
		end

		return true, copyAny(value), makeKeyInfo(latest), nil
	end

	function adapter:update(key, edit)
		local old = copyAny(bucket.values[key])
		local latestEntry
		local list = bucket.versions[key]
		if type(list) == "table" then
			latestEntry = list[#list]
		end
		local keyInfo = latestEntry and makeKeyInfo(latestEntry) or nil

		local ok, newValue, userIds, metaTags = pcall(edit, old, keyInfo)
		if ok ~= true then
			return false, nil, nil, newValue
		end

		local nextValue = old
		if newValue ~= nil then
			nextValue = newValue
		end

		bucket.counter += 1
		local createdAt = bucket.createdAt[key]
		if createdAt == nil then
			createdAt = os.time()
			bucket.createdAt[key] = createdAt
		end

		local entry = {
			Version = bucket.counter,
			Value = copyAny(nextValue),
			UserIds = normalizeUserIds(userIds),
			MetaTags = copyAny(metaTags or {}),
			CreatedAt = createdAt,
			UpdatedAt = os.time(),
		}

		bucket.values[key] = copyAny(nextValue)
		local versionList = bucket.versions[key]
		if versionList == nil then
			versionList = {}
			bucket.versions[key] = versionList
		end
		table.insert(versionList, entry)
		-- only keep the last 80 versions to avoid memory growing forever
		trimArray(versionList, 80)

		return true, copyAny(nextValue), makeKeyInfo(entry), nil
	end

	function adapter:remove(key)
		bucket.values[key] = nil
		bucket.versions[key] = nil
		bucket.createdAt[key] = nil
		return true, nil
	end

	return adapter
end

-- live DataStore adapter, wraps the Roblox API calls with consistent return values
local function makeDataAdapter(storeName, scope)
	local dataStore = DataStoreService:GetDataStore(storeName, scope)
	local adapter = {}

	function adapter:read(key, version)
		if version ~= nil and dataStore.GetVersionAsync ~= nil then
			local ok, value, info = pcall(function()
				return dataStore:GetVersionAsync(key, version)
			end)
			if ok == true then
				return true, value, info, nil
			end
			return false, nil, nil, value
		end

		local ok, value, info = pcall(function()
			return dataStore:GetAsync(key)
		end)
		if ok == true then
			return true, value, info, nil
		end
		return false, nil, nil, value
	end

	function adapter:update(key, edit)
		local observedInfo
		local ok, value = pcall(function()
			return dataStore:UpdateAsync(key, function(old, keyInfo)
				observedInfo = keyInfo
				local newValue, userIds, metaTags = edit(old, keyInfo)
				return newValue, userIds, metaTags
			end)
		end)

		if ok == true then
			return true, value, observedInfo, nil
		end

		return false, nil, nil, value
	end

	function adapter:remove(key)
		local ok, err = pcall(function()
			dataStore:RemoveAsync(key)
		end)
		if ok == true then
			return true, nil
		end
		return false, err
	end

	return adapter
end

-- safe option reader with fallback; checks both PascalCase and camelCase variants
local function pick(opts, a, b, fallback)
	if type(opts) ~= "table" then
		return fallback
	end
	local value = opts[a]
	if value == nil and b ~= nil then
		value = opts[b]
	end
	if value == nil then
		return fallback
	end
	return value
end

local function cleanNumber(num, fallback, minValue)
	if type(num) ~= "number" then
		return fallback
	end
	if num ~= num then
		return fallback
	end
	if minValue ~= nil and num < minValue then
		return minValue
	end
	return num
end

-- normalizes user provided config into a clean internal config table.
-- also enforces a relationship between autoSaveInterval and leaseSeconds so saves always happen before the lease can expire
local function normalizeConfig(opts)
	local config = {
		autoSaveInterval = cleanNumber(pick(opts, "AutoSaveInterval", "autoSaveInterval", 120), 120, 10),
		leaseSeconds = cleanNumber(pick(opts, "LeaseSeconds", "leaseSeconds", 120), 120, 15),
		staleSeconds = cleanNumber(pick(opts, "StaleSeconds", "staleSeconds", 480), 480, 60),
		loadRetry = cleanNumber(pick(opts, "LoadRetry", "loadRetry", 6), 6, 1),
		firstRetry = cleanNumber(pick(opts, "FirstRetry", "firstRetry", 2), 2, 0.1),
		startTimeout = cleanNumber(pick(opts, "StartTimeout", "startTimeout", 120), 120, 5),
		stealAfter = cleanNumber(pick(opts, "StealAfter", "stealAfter", 45), 45, 5),
		maxMessages = cleanNumber(pick(opts, "MaxMessages", "maxMessages", 400), 400, 20),
		maxJournal = cleanNumber(pick(opts, "MaxJournal", "maxJournal", 120), 120, 10),
		maxDirtyPerMutation = cleanNumber(pick(opts, "MaxDirtyPerMutation", "maxDirtyPerMutation", 120), 120, 20),
		saveRetries = cleanNumber(pick(opts, "SaveRetries", "saveRetries", 4), 4, 0),
		saveBackoff = cleanNumber(pick(opts, "SaveBackoff", "saveBackoff", 1.2), 1.2, 0),
		validate = pick(opts, "Validate", "validate", false) == true,
		sanitize = pick(opts, "Sanitize", "sanitize", true) == true,
		rejectInvalidSaves = pick(opts, "RejectInvalidSaves", "rejectInvalidSaves", true) == true,
		validateOnSave = pick(opts, "ValidateOnSave", "validateOnSave", true) == true,
		validateOnMutate = pick(opts, "ValidateOnMutate", "validateOnMutate", false) == true,
		schema = pick(opts, "Schema", "schema", nil),
		schemaVersion = cleanNumber(pick(opts, "SchemaVersion", "schemaVersion", 1), 1, 1),
		migrations = pick(opts, "Migrations", "migrations", nil),
		repair = pick(opts, "RepairProfile", "repair", nil),
		fault = pick(opts, "Fault", "fault", nil),
		scope = pick(opts, "Scope", "scope", nil),
		mock = pick(opts, "Mock", "mock", false) == true,
		requestRelease = pick(opts, "RequestRelease", "requestRelease", true) == true,
	}

	-- if auto save is too infrequent relative to lease length, force it shorter, otherwise we could lose ownership before ever saving
	if config.autoSaveInterval < config.leaseSeconds * 0.4 then
		config.autoSaveInterval = math.max(config.leaseSeconds * 0.4, 10)
	end

	return config
end

-- takes raw DataStore data and coerces it into a normalized document structure
-- also handles legacy ProfileService field names for backwards compatibility
local function normalizeDoc(store, raw)
	local template = store.template
	local doc = {
		Data = {},
		Meta = {
			CreatedAt = os.time(),
			UpdatedAt = os.time(),
			SchemaVersion = store.config.schemaVersion,
			SessionLoadCount = 0,
			LeaseNonce = 0,
			MessageId = 0,
			Lease = nil,
		},
		RobloxMeta = {},
		UserIds = {},
		Messages = {},
	}

	if type(raw) == "table" then
		if type(raw.Data) == "table" then
			doc.Data = copyAny(raw.Data)
		end

		local oldMeta = raw.Meta
		if type(oldMeta) ~= "table" then
			oldMeta = raw.MetaData
		end

		if type(oldMeta) == "table" then
			doc.Meta.CreatedAt = cleanNumber(oldMeta.CreatedAt or oldMeta.ProfileCreateTime, doc.Meta.CreatedAt, 0)
			doc.Meta.UpdatedAt = cleanNumber(oldMeta.UpdatedAt or oldMeta.LastUpdate, doc.Meta.UpdatedAt, 0)
			doc.Meta.SchemaVersion = cleanNumber(oldMeta.SchemaVersion, doc.Meta.SchemaVersion, 1)
			doc.Meta.SessionLoadCount = cleanNumber(oldMeta.SessionLoadCount, 0, 0)
			doc.Meta.LeaseNonce = cleanNumber(oldMeta.LeaseNonce, 0, 0)
			doc.Meta.MessageId = cleanNumber(oldMeta.MessageId, 0, 0)

			local lease = oldMeta.Lease
			if type(lease) == "table" then
				doc.Meta.Lease = {
					Id = lease.Id,
					Place = lease.Place,
					Job = lease.Job,
					Nonce = cleanNumber(lease.Nonce, 0, 0),
					Until = cleanNumber(lease.Until, 0, 0),
					StartedAt = cleanNumber(lease.StartedAt, 0, 0),
				}
			elseif type(oldMeta.ActiveSession) == "table" then
				-- convert old ProfileService session format into our lease format
				local active = oldMeta.ActiveSession
				local place = active.Place or active[1]
				local job = active.Job or active[2]
				local unique = active.Id or active[3]
				local leaseId = tostring(place) .. ":" .. tostring(job) .. ":" .. tostring(unique)
				doc.Meta.Lease = {
					Id = leaseId,
					Place = place,
					Job = job,
					Nonce = cleanNumber(doc.Meta.LeaseNonce, 0, 0),
					Until = cleanNumber(doc.Meta.UpdatedAt + store.config.leaseSeconds, os.time(), 0),
					StartedAt = cleanNumber(doc.Meta.UpdatedAt, os.time(), 0),
				}
			end
		end

		if type(raw.RobloxMeta) == "table" then
			doc.RobloxMeta = copyAny(raw.RobloxMeta)
		elseif type(raw.RobloxMetaData) == "table" then
			doc.RobloxMeta = copyAny(raw.RobloxMetaData)
		end

		doc.UserIds = normalizeUserIds(raw.UserIds)

		if type(raw.Messages) == "table" then
			for _, row in ipairs(raw.Messages) do
				if type(row) == "table" then
					local id = row.Id
					local stamp = cleanNumber(row.At, os.time(), 0)
					local data = row.Data
					if id ~= nil then
						table.insert(doc.Messages, {
							Id = id,
							At = stamp,
							Data = copyAny(data),
						})
					end
				end
			end
		elseif type(raw.GlobalUpdates) == "table" then
			-- ProfileService GlobalUpdates format compatibility
			local updates = raw.GlobalUpdates[2]
			if type(updates) == "table" then
				for _, row in ipairs(updates) do
					if type(row) == "table" then
						local id = row[1]
						local data = row[#row]
						if id ~= nil then
							table.insert(doc.Messages, {
								Id = id,
								At = doc.Meta.UpdatedAt,
								Data = copyAny(data),
							})
						end
					end
				end
			end
		end
	end

	if type(template) == "table" then
		fillMissing(doc.Data, template)
	end

	-- make sure MessageId reflects the highest id we actually have
	local topId = doc.Meta.MessageId
	for _, msg in ipairs(doc.Messages) do
		local asNum = tonumber(msg.Id)
		if asNum ~= nil and asNum > topId then
			topId = asNum
		end
	end
	doc.Meta.MessageId = topId

	return doc
end

local Store = {}
Store.__index = Store

local Session = {}
Session.__index = Session

local Profile = {}
Profile.__index = Profile

-- Types is exposed so users can build schemas without needing a separate import
Profile.Types = Types
Profile.State = "NotReady"
Profile.IsClosing = false
Profile.IsCritical = false
Profile.OnError = Signal.new()
Profile.OnCritical = Signal.new()
Profile.OnState = Signal.new()

local issueTimes = {}
local liveStores = {}

-- runtimeId uniquely identifies this specific server instance used as part of lease IDs so we can tell which server owns a profile
local runtimeId = tostring(game.PlaceId) .. ":" .. tostring(game.JobId) .. ":" .. HttpService:GenerateGUID(false)
local boundShutdown = false

-- counts errors within a rolling 120s window; flips IsCritical if too many pile up
local function markIssue()
	local now = os.clock()
	table.insert(issueTimes, now)
	while true do
		local first = issueTimes[1]
		if first == nil then
			break
		end
		if now - first > 120 then
			table.remove(issueTimes, 1)
		else
			break
		end
	end
	if Profile.IsCritical ~= true and #issueTimes >= 6 then
		Profile.IsCritical = true
		Profile.OnCritical:Fire(true)
	end
end

local function setState(nextState)
	if Profile.State == nextState then
		return
	end
	Profile.State = nextState
	Profile.OnState:Fire(nextState)
end

function Store:touchError(key, err)
	markIssue()
	self.metrics.errors += 1
	self.errorSignal:Fire(tostring(err), key)
	Profile.OnError:Fire(tostring(err), self.name, key)
end

-- fault injection for Studio testing; controlled by the Fault config option.
-- only runs in Studio so theres no risk of accidentally leaving it on in production
function Store:applyFault(stage)
	if RunService:IsStudio() ~= true then
		return true
	end

	local fault = self.config.fault
	if type(fault) ~= "table" then
		return true
	end

	local live = fault.Enabled
	if live == nil then
		live = fault.enabled
	end
	if live ~= true then
		return true
	end

	local minDelay = cleanNumber(fault.DelayMin or fault.delayMin, 0, 0)
	local maxDelay = cleanNumber(fault.DelayMax or fault.delayMax, 0, 0)
	if maxDelay > 0 then
		local span = math.max(maxDelay - minDelay, 0)
		local extra = if span > 0 then math.random() * span else 0
		task.wait(minDelay + extra)
	end

	local chance = cleanNumber(fault.FailChance or fault.failChance, 0, 0)
	if stage == "Load" then
		chance = cleanNumber(fault.LoadFailChance or fault.loadFailChance, chance, 0)
	elseif stage == "Save" then
		chance = cleanNumber(fault.SaveFailChance or fault.saveFailChance, chance, 0)
	end

	if chance > 0 and math.random() < chance then
		return false, "Injected fault " .. stage
	end

	return true
end

-- wraps adapter:update with queueing and fault injection.
-- the per key queue is the main thing preventing race conditions between concurrent saves
function Store:updateRaw(key, edit)
	local turnId = self.name .. ":" .. tostring(self.isMock) .. ":" .. key
	local release = waitQueue(turnId)

	local pass, reason = self:applyFault("Save")
	if pass ~= true then
		release()
		return false, nil, nil, reason
	end

	local ok, value, info, err = self.adapter:update(key, edit)
	release()

	if ok ~= true then
		self:touchError(key, err)
		return false, nil, nil, err
	end

	return true, value, info, nil
end

function Store:readRaw(key, version)
	local pass, reason = self:applyFault("Load")
	if pass ~= true then
		return false, nil, nil, reason
	end

	local ok, value, info, err = self.adapter:read(key, version)
	if ok ~= true then
		self:touchError(key, err)
		return false, nil, nil, err
	end

	return true, value, info, nil
end

-- publishes a MessagingService message to other servers holding sessions for the same store.
-- if messaging fails we just set messageDead and stop trying instead of spamming errors
function Store:publish(kind, key, payload)
	if self.isMock == true then
		return
	end
	if self.messageDead == true then
		return
	end

	local message = {
		kind = kind,
		store = self.name,
		key = key,
		payload = payload,
		from = runtimeId,
		at = os.time(),
	}

	local ok = pcall(function()
		MessagingService:PublishAsync(self.channel, message)
	end)
	if ok ~= true then
		self.messageDead = true
	end
end

function Store:subscribeMessages()
	if self.isMock == true then
		return
	end
	if self.subscription ~= nil then
		return
	end
	if self.messageDead == true then
		return
	end

	local ok, sub = pcall(function()
		return MessagingService:SubscribeAsync(self.channel, function(packet)
			local body = packet.Data
			if type(body) ~= "table" then
				return
			end
			-- ignore messages we sent ourselves
			if body.from == runtimeId then
				return
			end
			local key = body.key
			if type(key) ~= "string" then
				return
			end
			local session = self.sessionsByKey[key]
			if session == nil then
				return
			end
			if session:IsActive() ~= true then
				return
			end

			if body.kind == "release" then
				-- another server is asking us to release this session
				local target = body.payload and body.payload.target
				if target ~= nil and target ~= session.leaseId then
					return
				end
				task.spawn(function()
					session:EndSession("External")
				end)
			elseif body.kind == "nudge" then
				-- a message was written to this key; pull it on next save
				session.needsPull = true
			end
		end)
	end)

	if ok == true then
		self.subscription = sub
	else
		self.messageDead = true
	end
end

-- adds a session to the auto save rotation and subscribes to MessagingService if not already
function Store:addAuto(session)
	self.sessionsByKey[session.Key] = session
	table.insert(self.autoList, session)
	self.metrics.active = #self.autoList
	if #self.autoList == 1 then
		self.lastAuto = os.clock()
		self.autoIndex = 1
	end
	self:subscribeMessages()
end

function Store:removeAuto(session)
	if self.sessionsByKey[session.Key] == session then
		self.sessionsByKey[session.Key] = nil
	end
	local idx = table.find(self.autoList, session)
	if idx ~= nil then
		table.remove(self.autoList, idx)
		if idx < self.autoIndex then
			self.autoIndex -= 1
		end
		if self.autoIndex < 1 then
			self.autoIndex = 1
		end
		if self.autoIndex > #self.autoList then
			self.autoIndex = 1
		end
	end
	self.metrics.active = #self.autoList
end

-- moves a session to the end of the auto-save list, delaying its next auto save.
-- called after a manual save so we dont immediately auto save something that was just saved.
function Store:moveToTail(session)
	local idx = table.find(self.autoList, session)
	if idx == nil then
		return
	end
	table.remove(self.autoList, idx)
	table.insert(self.autoList, session)
	if self.autoIndex > #self.autoList then
		self.autoIndex = 1
	end
end

function Store:runValidation(data)
	if self.config.validate ~= true then
		return copyAny(data), true, {}
	end
	if self.schema == nil then
		return copyAny(data), true, {}
	end

	local issues = {}
	local clean, ok = checkRule(self.schema, copyAny(data), "", issues, self.config.sanitize)
	if clean == nil then
		clean = {}
	end
	return clean, ok, issues
end

-- runs the migration chain from the stored schema version up to the target version
-- each migration is a function registered with Store:RegisterMigration
function Store:runMigrations(data, meta, key)
	local target = cleanNumber(self.config.schemaVersion, 1, 1)
	local current = cleanNumber(meta.SchemaVersion, 1, 1)
	local audit = {}

	if current > target then
		-- data is from a newer version than this code knows about, just clamp it
		meta.SchemaVersion = target
		return data, audit, true, nil
	end

	while current < target do
		local job = self.migrations[current]
		if type(job) ~= "function" then
			return data, audit, false, "Missing migration " .. tostring(current)
		end

		local since = os.clock()
		local ok, nextData = pcall(job, data, {
			fromVersion = current,
			toVersion = current + 1,
			key = key,
			store = self.name,
		})
		if ok ~= true then
			return data, audit, false, nextData
		end

		if type(nextData) == "table" then
			data = nextData
		end

		table.insert(audit, {
			From = current,
			To = current + 1,
			Took = os.clock() - since,
		})

		current += 1
	end

	meta.SchemaVersion = target
	return data, audit, true, nil
end

function Store:sendReleasePing(key, lease)
	if type(lease) ~= "table" then
		return
	end
	if lease.Id == nil then
		return
	end
	self:publish("release", key, {
		target = lease.Id,
	})
end

-- checks that the given lease was actually claimed by this session (same id and nonce)
-- the nonce prevents an old lease entry from being mistaken for a current one
function Session:isOwner(lease)
	if type(lease) ~= "table" then
		return false
	end
	if lease.Id ~= self.leaseId then
		return false
	end
	if cleanNumber(lease.Nonce, -1, -1) ~= cleanNumber(self.leaseNonce, -2, -2) then
		return false
	end
	return true
end

function Session:recordJournal(entry)
	table.insert(self.journal, entry)
	trimArray(self.journal, self.Store.config.maxJournal)
end

function Session:markDirty(path, value)
	local key = tostring(path)
	if self.dirty[key] ~= true then
		self.dirty[key] = true
		self.dirtyCount += 1
		self.Store.metrics.dirtyPaths += 1
	end
	self.pendingSave = true
	self.dirtySignal:Fire(key, copyAny(value))
end

-- ingests a list of messages, deduplicating by id, then tries to drain the inbox
function Session:ingestMessages(messages)
	local queued = false
	for _, msg in ipairs(messages) do
		local id = msg.Id
		if id ~= nil then
			local key = tostring(id)
			if self.seenMessages[key] ~= true then
				self.seenMessages[key] = true
				table.insert(self.inbox, {
					Id = id,
					At = cleanNumber(msg.At, os.time(), 0),
					Data = copyAny(msg.Data),
				})
				queued = true
			end
		end
	end
	if queued == true then
		self:drainInbox()
	end
end

-- tries to process pending messages through registered handlers.
-- messages without a handler stay in the inbox until one is added
function Session:drainInbox()
	if #self.inbox == 0 then
		return
	end

	local remaining = {}
	for _, msg in ipairs(self.inbox) do
		local done = false

		local function ack()
			if done ~= true then
				done = true
				self.pendingAck[tostring(msg.Id)] = true
			end
		end

		if #self.messageHandlers == 0 then
			table.insert(remaining, msg)
		else
			local used = false
			for _, fn in ipairs(self.messageHandlers) do
				local ok, err = pcall(fn, copyAny(msg.Data), ack)
				if ok ~= true then
					self.Store:touchError(self.Key, "MessageHandler " .. tostring(err))
				end
				if done == true then
					used = true
					self.messageSignal:Fire(copyAny(msg.Data))
					break
				end
			end
			if used ~= true then
				table.insert(remaining, msg)
			end
		end
	end
	self.inbox = remaining
end

-- a session is only "active" if its still in the store's session map
-- this double check matters because the session could be released externally
function Session:IsActive()
	if self.active ~= true then
		return false
	end
	if self.Store.sessionsByKey[self.Key] ~= self then
		return false
	end
	return true
end

function Session:OnRelease(fn)
	return self.releaseSignal:Connect(fn)
end

function Session:OnDirty(fn)
	return self.dirtySignal:Connect(fn)
end

function Session:OnSave(fn)
	return self.saveSignal:Connect(fn)
end

function Session:OnAfterSave(fn)
	return self.afterSaveSignal:Connect(fn)
end

function Session:OnMessage(fn)
	return self.messageSignal:Connect(fn)
end

-- registers a message handler and immediately tries to process any already queued messages
function Session:MessageHandler(fn)
	if type(fn) ~= "function" then
		error("MessageHandler expected function")
	end
	table.insert(self.messageHandlers, fn)
	self:drainInbox()

	local live = true
	return {
		Disconnect = function()
			if live ~= true then
				return
			end
			live = false
			local idx = table.find(self.messageHandlers, fn)
			if idx ~= nil then
				table.remove(self.messageHandlers, idx)
			end
		end,
	}
end

-- fills in any missing template keys; also marks the data dirty so the fill gets saved
function Session:Reconcile()
	if type(self.Store.template) == "table" then
		fillMissing(self.Data, self.Store.template)
		self:markDirty("*", self.Data)
	end
end

function Session:AddUserId(userId)
	if type(userId) ~= "number" then
		return
	end
	if userId % 1 ~= 0 then
		return
	end
	for _, item in ipairs(self.UserIds) do
		if item == userId then
			return
		end
	end
	table.insert(self.UserIds, userId)
	self:markDirty("UserIds", self.UserIds)
end

function Session:RemoveUserId(userId)
	if type(userId) ~= "number" then
		return
	end
	if userId % 1 ~= 0 then
		return
	end
	local idx = table.find(self.UserIds, userId)
	if idx ~= nil then
		table.remove(self.UserIds, idx)
		self:markDirty("UserIds", self.UserIds)
	end
end

-- applies a function to session.Data and tracks what changed.
-- if the function returns false, the mutation is rolled back.
-- if validateOnMutate is enabled, the data is also checked against the schema.
function Session:Mutate(name, fn)
	if self:IsActive() ~= true then
		return false, "Inactive"
	end
	if type(fn) ~= "function" then
		error("Mutate expected function")
	end

	local label = name
	if type(label) ~= "string" then
		label = "Mutation"
	end

	local before = copyAny(self.Data)
	local startAt = os.clock()
	local ok, a, b = pcall(fn, self.Data)

	if ok ~= true then
		self.Data = before
		self:recordJournal({
			Id = HttpService:GenerateGUID(false),
			At = os.time(),
			Name = label,
			Ok = false,
			Err = tostring(a),
			Took = os.clock() - startAt,
		})
		return false, tostring(a)
	end

	if a == false then
		self.Data = before
		self:recordJournal({
			Id = HttpService:GenerateGUID(false),
			At = os.time(),
			Name = label,
			Ok = false,
			Err = tostring(b or "Rejected"),
			Took = os.clock() - startAt,
		})
		return false, b
	end

	if self.Store.config.validateOnMutate == true then
		local fixed, valid = self.Store:runValidation(self.Data)
		if valid ~= true then
			self.Data = before
			self:recordJournal({
				Id = HttpService:GenerateGUID(false),
				At = os.time(),
				Name = label,
				Ok = false,
				Err = "ValidationFailed",
				Took = os.clock() - startAt,
			})
			return false, "ValidationFailed"
		end
		self.Data = fixed
	end

	local dirty = {}
	diffData(before, self.Data, "", dirty, self.Store.config.maxDirtyPerMutation)
	if #dirty == 0 then
		self:recordJournal({
			Id = HttpService:GenerateGUID(false),
			At = os.time(),
			Name = label,
			Ok = true,
			Paths = {},
			Took = os.clock() - startAt,
		})
		return true
	end

	local pathList = {}
	for _, row in ipairs(dirty) do
		self:markDirty(row.Path, row.Value)
		table.insert(pathList, row.Path)
	end

	self.unsavedMutations += 1

	self:recordJournal({
		Id = HttpService:GenerateGUID(false),
		At = os.time(),
		Name = label,
		Ok = true,
		Paths = pathList,
		Took = os.clock() - startAt,
	})

	return true
end

-- alias for Mutate; kept for familiarity if youre coming from a transaction based mental model
function Session:Transaction(name, fn)
	return self:Mutate(name, fn)
end

function Session:Inspect()
	return {
		Key = self.Key,
		Active = self:IsActive(),
		DirtyCount = self.dirtyCount,
		UnsavedMutations = self.unsavedMutations,
		LastSaveAt = self.lastSaveAt,
		SessionLoadCount = self.SessionLoadCount,
		SchemaVersion = self.SchemaVersion,
		MessageQueue = #self.inbox,
		Journal = copyAny(self.journal),
	}
end

function Session:Save(reason)
	return self.Store:saveSession(self, reason or "Manual", false)
end

function Session:EndSession(reason)
	return self.Store:saveSession(self, reason or "Manual", true)
end

-- only valid for read only sessions (loaded via Store:Get)
-- forces a write even though we dont hold a lease
function Session:SetAsync()
	if self.readOnly ~= true then
		return false, "Only read-only sessions can call SetAsync"
	end
	return self.Store:overwrite(self.Key, self.Data, self.UserIds, self.RobloxMetaData, self.Meta, "SetAsync")
end

-- the main save path; handles both regular saves and session ending saves
-- queues concurrent calls so they dont step on each other, retries on failure
function Store:saveSession(session, reason, release)
	if type(session) ~= "table" then
		return false, "BadSession"
	end
	if session.Store ~= self then
		return false, "StoreMismatch"
	end
	if session.readOnly == true then
		return false, "ReadOnly"
	end

	local active = session:IsActive()
	if active ~= true and release ~= true then
		return false, "Inactive"
	end

	-- if a save is already running for this session, queue behind it
	local lock = session.saveLock
	if lock == true then
		local gate = Instance.new("BindableEvent")
		table.insert(session.saveQueue, gate)
		gate.Event:Wait()
		gate:Destroy()
	end
	session.saveLock = true
	self.pendingSaveJobs += 1
	self.metrics.pendingSaves = self.pendingSaveJobs

	session.saveSignal:Fire(reason)

	local try = 0
	local keepTrying = true
	local waitTime = self.config.saveBackoff
	local finalErr = nil

	while keepTrying == true do
		local lost = false
		local blockSave = false
		local blockIssues = nil
		local seenMessages = nil
		local writeStarted = os.clock()

		local ok, raw, keyInfo, err = self:updateRaw(session.Key, function(old)
			local doc = normalizeDoc(self, old)
			local meta = doc.Meta
			local lease = meta.Lease

			-- verify we still own this key before writing; another server could have stolen it
			local owns = session:isOwner(lease)
			if owns ~= true then
				lost = true
				seenMessages = doc.Messages
				return doc, doc.UserIds, doc.RobloxMeta
			end

			local nextData = copyAny(session.Data)
			if self.config.validate == true and self.config.validateOnSave == true then
				local fixed, valid, issues = self:runValidation(nextData)
				nextData = fixed
				if valid ~= true and self.config.rejectInvalidSaves == true then
					blockSave = true
					blockIssues = issues
					return doc, doc.UserIds, doc.RobloxMeta
				end
			end

			session.Data = nextData
			doc.Data = nextData
			doc.UserIds = normalizeUserIds(session.UserIds)
			doc.RobloxMeta = copyAny(session.RobloxMetaData)

			local nextMeta = copyAny(meta)
			nextMeta.UpdatedAt = os.time()
			nextMeta.SchemaVersion = session.SchemaVersion or self.config.schemaVersion
			nextMeta.SessionLoadCount = session.SessionLoadCount
			nextMeta.LeaseNonce = session.leaseNonce
			nextMeta.MessageId = cleanNumber(nextMeta.MessageId, 0, 0)

			if release == true then
				-- clear the lease so other servers can pick this up immediately
				nextMeta.Lease = nil
				nextMeta.LastReleaseReason = reason
			else
				nextMeta.Lease = {
					Id = session.leaseId,
					Place = game.PlaceId,
					Job = game.JobId,
					Nonce = session.leaseNonce,
					Until = os.time() + self.config.leaseSeconds,
					StartedAt = session.startedAt,
				}
			end

			-- rebuild message list, dropping anything the session has acknowledged
			local nextMessages = {}
			for _, msg in ipairs(doc.Messages) do
				local key = tostring(msg.Id)
				if session.pendingAck[key] ~= true then
					table.insert(nextMessages, msg)
				end
			end

			if #session.outbox > 0 then
				for _, msg in ipairs(session.outbox) do
					nextMeta.MessageId += 1
					table.insert(nextMessages, {
						Id = nextMeta.MessageId,
						At = os.time(),
						Data = copyAny(msg),
					})
				end
				session.outbox = {}
			end

			trimArray(nextMessages, self.config.maxMessages)

			doc.Meta = nextMeta
			doc.Messages = nextMessages
			seenMessages = nextMessages
			return doc, doc.UserIds, doc.RobloxMeta
		end)

		if ok == true then
			self.metrics.totalSaveTime += os.clock() - writeStarted
			self.metrics.saveCount += 1

			if blockSave == true then
				finalErr = "ValidationFailed"
				if type(blockIssues) == "table" then
					session.lastValidationIssues = blockIssues
				end
				keepTrying = false
			elseif lost == true then
				-- another server took ownership while we were saving; end the session here
				finalErr = "LostLease"
				keepTrying = false
				session.active = false
				self:removeAuto(session)
				session.releaseSignal:Fire("External")
			else
				session.LastSavedData = copyAny(session.Data)
				session.Meta = normalizeDoc(self, raw).Meta
				session.KeyInfo = keyInfo
				session.lastSaveAt = os.clock()
				session.pendingSave = false
				session.unsavedMutations = 0
				session.dirty = {}
				session.dirtyCount = 0
				session.pendingAck = {}
				session.afterSaveSignal:Fire(copyAny(session.LastSavedData))

				if type(seenMessages) == "table" then
					session:ingestMessages(seenMessages)
				end

				if reason ~= "Auto" then
					self:moveToTail(session)
				end

				if release == true then
					session.active = false
					self:removeAuto(session)
					session.releaseSignal:Fire(reason)
				end

				keepTrying = false
			end
		else
			finalErr = err
			if try >= self.config.saveRetries then
				keepTrying = false
			else
				try += 1
				self.metrics.saveRetries += 1
				task.wait(waitTime)
				waitTime = math.max(waitTime * 1.7, 0.1)
			end
		end
	end

	self.pendingSaveJobs -= 1
	self.metrics.pendingSaves = self.pendingSaveJobs

	-- unblock the next queued save for this session
	session.saveLock = false
	local nextGate = table.remove(session.saveQueue, 1)
	if nextGate ~= nil then
		nextGate:Fire()
	end

	if finalErr ~= nil then
		if finalErr ~= "ValidationFailed" and finalErr ~= "LostLease" then
			self:touchError(session.Key, finalErr)
		end
		self.metrics.saveFail += 1
		return false, finalErr
	end

	return true
end

-- forcefully writes data to a key without owning a session lease
-- intended for admin tooling or SetAsync on read only sessions
function Store:overwrite(key, data, userIds, robloxMeta, meta, reason)
	local ok, _, _, err = self:updateRaw(key, function(old)
		local doc = normalizeDoc(self, old)
		doc.Data = copyAny(data)
		doc.UserIds = normalizeUserIds(userIds)
		doc.RobloxMeta = copyAny(robloxMeta or {})
		local nextMeta = copyAny(doc.Meta)
		if type(meta) == "table" then
			for k, v in pairs(meta) do
				nextMeta[k] = copyAny(v)
			end
		end
		nextMeta.UpdatedAt = os.time()
		nextMeta.LastSetReason = reason
		nextMeta.Lease = nil
		doc.Meta = nextMeta
		return doc, doc.UserIds, doc.RobloxMeta
	end)

	if ok ~= true then
		return false, err
	end

	return true
end

-- builds a Session object from a normalized doc
-- active=true means the session holds a lease and will autosave
-- active=false gives a read-only view that can only be written via SetAsync
function Store:buildSession(key, doc, keyInfo, leaseId, leaseNonce, active)
	local data = copyAny(doc.Data)
	local saveShadow = copyAny(data)
	local meta = copyAny(doc.Meta)

	local session = {
		Key = key,
		Data = data,
		LastSavedData = saveShadow,
		Store = self,
		Meta = meta,
		RobloxMetaData = copyAny(doc.RobloxMeta),
		UserIds = normalizeUserIds(doc.UserIds),
		KeyInfo = keyInfo,
		SessionLoadCount = cleanNumber(meta.SessionLoadCount, 0, 0),
		SchemaVersion = cleanNumber(meta.SchemaVersion, self.config.schemaVersion, 1),
		Session = nil,
		FirstSessionTime = cleanNumber(meta.CreatedAt, os.time(), 0),
		leaseId = leaseId,
		leaseNonce = leaseNonce,
		startedAt = os.time(),
		active = active == true,
		readOnly = active ~= true,
		saveLock = false,
		saveQueue = {},
		dirty = {},
		dirtyCount = 0,
		unsavedMutations = 0,
		lastSaveAt = os.clock(),
		pendingSave = false,
		needsPull = false,
		messageHandlers = {},
		seenMessages = {},
		pendingAck = {},
		inbox = {},
		outbox = {},
		journal = {},
		lastValidationIssues = nil,
		releaseSignal = Signal.new(),
		saveSignal = Signal.new(),
		afterSaveSignal = Signal.new(),
		dirtySignal = Signal.new(),
		messageSignal = Signal.new(),
	}
	setmetatable(session, Session)

	if active == true then
		local lease = doc.Meta.Lease
		if type(lease) == "table" then
			session.Session = {
				PlaceId = lease.Place,
				JobId = lease.Job,
			}
		end
	end

	session:ingestMessages(doc.Messages)
	return session
end

-- attempts to claim ownership of a DataStore key for this server.
-- will retry until it succeeds, the timeout is hit, or the server shuts down.
-- handles conflicts with other servers through lease expiry or forced steal
function Store:Load(key, opts)
	if Profile.IsClosing == true or self.closing == true then
		return nil
	end
	if type(key) ~= "string" then
		error("Load expected key string")
	end

	-- if the session is already active on this server just return it
	local current = self.sessionsByKey[key]
	if current ~= nil and current:IsActive() == true then
		return current
	end

	local forceFlag = false
	local stealFlag = false
	local timeout = self.config.startTimeout
	local requestRelease = self.config.requestRelease
	local cancelFn = nil

	if type(opts) == "table" then
		if opts.ForceLoad == true or opts.Force == true then
			forceFlag = true
		end
		if opts.Steal == true then
			stealFlag = true
		end
		if type(opts.Timeout) == "number" then
			timeout = math.max(opts.Timeout, 2)
		end
		if opts.RequestRelease == false then
			requestRelease = false
		end
		if type(opts.Cancel) == "function" then
			cancelFn = opts.Cancel
		end
	end

	local startAt = os.clock()
	local loadTries = 0
	local leaseId = runtimeId .. ":" .. HttpService:GenerateGUID(false)
	local leaseNonce = 0
	local lockedBy = nil
	local acquired = false
	local gotDoc = nil
	local gotInfo = nil
	local usedSteal = false
	local usedStale = false

	while Profile.IsClosing ~= true and self.closing ~= true do
		if type(cancelFn) == "function" then
			local okCancel, stop = pcall(cancelFn)
			if okCancel == true and stop == true then
				return nil
			end
		end

		if os.clock() - startAt > timeout then
			self.metrics.loadTimeout += 1
			return nil
		end

		loadTries += 1
		-- after stealAfter seconds we just take the session
		local forceNow = forceFlag or stealFlag
		if os.clock() - startAt >= self.config.stealAfter then
			forceNow = true
		end

		local takeNow = false
		local seenLock = nil
		local localSteal = false
		local localStale = false

		local ok, raw, info = self:updateRaw(key, function(old)
			local doc = normalizeDoc(self, old)
			local meta = doc.Meta
			local lease = meta.Lease
			local now = os.time()
			local stale = false

			if type(lease) == "table" then
				local untilAt = cleanNumber(lease.Until, 0, 0)
				local lastBeat = cleanNumber(meta.UpdatedAt, 0, 0)
				-- lease is stale if its past its Until time or hasnt been touched recently
				if untilAt <= now then
					stale = true
				end
				if now - lastBeat >= self.config.staleSeconds then
					stale = true
				end
			end

			local own = false
			if type(lease) == "table" and lease.Id == leaseId then
				own = true
			end

			if lease == nil or own == true or stale == true or forceNow == true then
				local nextNonce = cleanNumber(meta.LeaseNonce, 0, 0) + 1
				meta.LeaseNonce = nextNonce
				meta.SessionLoadCount = cleanNumber(meta.SessionLoadCount, 0, 0) + 1
				meta.UpdatedAt = now
				if cleanNumber(meta.CreatedAt, -1, 0) < 0 then
					meta.CreatedAt = now
				end
				meta.Lease = {
					Id = leaseId,
					Place = game.PlaceId,
					Job = game.JobId,
					Nonce = nextNonce,
					Until = now + self.config.leaseSeconds,
					StartedAt = now,
				}
				takeNow = true
				leaseNonce = nextNonce
				if lease ~= nil and own ~= true then
					if stale == true then
						localStale = true
					else
						localSteal = true
					end
				end
			else
				seenLock = copyAny(lease)
			end

			return doc, doc.UserIds, doc.RobloxMeta
		end)

		if ok == true then
			gotDoc = normalizeDoc(self, raw)
			gotInfo = info
			if takeNow == true then
				acquired = true
				if localSteal == true then
					usedSteal = true
				end
				if localStale == true then
					usedStale = true
				end
				break
			end
			lockedBy = seenLock
		end

		-- ping the owning server and ask it to release
		if requestRelease == true and lockedBy ~= nil then
			self:sendReleasePing(key, lockedBy)
		end

		local delay = self.config.loadRetry
		if loadTries == 1 then
			delay = self.config.firstRetry
		end
		self.metrics.lockWait += delay
		task.wait(delay)
	end

	if acquired ~= true then
		return nil
	end

	local doc = gotDoc
	local data = copyAny(doc.Data)
	local migrationsRan = {}

	local migrated, audit, migOk, migErr = self:runMigrations(data, doc.Meta, key)
	if migOk ~= true then
		local repair = self.config.repair
		if type(repair) == "function" then
			local okRepair, fixed = pcall(repair, copyAny(doc), {
				key = key,
				reason = "MigrationFailed",
				error = migErr,
				store = self.name,
			})
			if okRepair == true and type(fixed) == "table" then
				doc = normalizeDoc(self, fixed)
				migrated = copyAny(doc.Data)
				audit = {}
			else
				self:touchError(key, "MigrationFailed " .. tostring(migErr))
				return nil
			end
		else
			self:touchError(key, "MigrationFailed " .. tostring(migErr))
			return nil
		end
	end
	migrationsRan = audit
	doc.Data = migrated

	local cleanData, valid, issues = self:runValidation(doc.Data)
	if valid ~= true then
		self.metrics.validationFail += 1
		local repair = self.config.repair
		if type(repair) == "function" then
			local okRepair, fixed = pcall(repair, copyAny(doc), {
				key = key,
				reason = "ValidationFailed",
				issues = issues,
				store = self.name,
			})
			if okRepair == true and type(fixed) == "table" then
				doc = normalizeDoc(self, fixed)
				cleanData = copyAny(doc.Data)
			end
		end
	end
	doc.Data = cleanData

	local session = self:buildSession(key, doc, gotInfo, leaseId, leaseNonce, true)
	session.migrationAudit = migrationsRan
	session.lastValidationIssues = issues

	-- if validation or migrations touched the data, make sure it gets saved soon
	if type(issues) == "table" and #issues > 0 then
		session.pendingSave = true
		session:markDirty("*", session.Data)
	end
	if #migrationsRan > 0 then
		session.pendingSave = true
		session:markDirty("SchemaVersion", session.SchemaVersion)
	end

	self:addAuto(session)
	self.metrics.loadCount += 1
	if usedSteal == true then
		self.metrics.lockSteal += 1
	end
	if usedStale == true then
		self.metrics.staleRecover += 1
	end

	return session
end

Store.StartSessionAsync = Store.Load

-- read only load; does not claim a lease, will not auto save.
-- useful for admin panels or checking data without interrupting an active session
function Store:Get(key, version)
	if type(key) ~= "string" then
		error("Get expected key string")
	end
	local ok, raw, info = self:readRaw(key, version)
	if ok ~= true then
		return nil
	end
	local doc = normalizeDoc(self, raw)
	local data = copyAny(doc.Data)
	local cleanData = data
	if self.config.validate == true then
		local checked = self:runValidation(data)
		cleanData = checked
	end
	doc.Data = cleanData
	local session = self:buildSession(key, doc, info, "", 0, false)
	return session
end

Store.GetAsync = Store.Get

-- appends a message to a keys message list and nudges any active session on another server
function Store:MessageAsync(key, payload)
	if type(key) ~= "string" then
		error("MessageAsync expected key string")
	end

	local sentId = nil
	local ok, raw, _, err = self:updateRaw(key, function(old)
		local doc = normalizeDoc(self, old)
		local meta = doc.Meta
		meta.MessageId = cleanNumber(meta.MessageId, 0, 0) + 1
		sentId = meta.MessageId
		table.insert(doc.Messages, {
			Id = sentId,
			At = os.time(),
			Data = copyAny(payload),
		})
		trimArray(doc.Messages, self.config.maxMessages)
		doc.Meta = meta
		return doc, doc.UserIds, doc.RobloxMeta
	end)

	if ok ~= true then
		self:touchError(key, err)
		return false
	end

	self.metrics.messagesSent += 1

	-- if the target session is local, deliver immediately without waiting for next save
	local session = self.sessionsByKey[key]
	if session ~= nil and session:IsActive() == true then
		local msgDoc = normalizeDoc(self, raw)
		session:ingestMessages(msgDoc.Messages)
	end

	self:publish("nudge", key, {
		Id = sentId,
	})

	return true
end

-- permanently deletes a key; will refuse if the key currently has an active session
function Store:RemoveAsync(key)
	if type(key) ~= "string" then
		error("RemoveAsync expected key string")
	end

	local session = self.sessionsByKey[key]
	if session ~= nil and session:IsActive() == true then
		return false
	end

	local ok, err = self.adapter:remove(key)
	if ok ~= true then
		self:touchError(key, err)
		return false
	end

	return true
end

function Store:RegisterMigration(fromVersion, fn)
	if type(fromVersion) ~= "number" or fromVersion % 1 ~= 0 then
		error("RegisterMigration expects integer version")
	end
	if type(fn) ~= "function" then
		error("RegisterMigration expects function")
	end
	self.migrations[fromVersion] = fn
	return self
end

function Store:GetStats()
	local avgSave = 0
	if self.metrics.saveCount > 0 then
		avgSave = self.metrics.totalSaveTime / self.metrics.saveCount
	end
	return {
		Store = self.name,
		ActiveSessions = self.metrics.active,
		LoadCount = self.metrics.loadCount,
		SaveCount = self.metrics.saveCount,
		SaveFail = self.metrics.saveFail,
		LoadTimeout = self.metrics.loadTimeout,
		AvgSaveSeconds = avgSave,
		LockWaitSeconds = self.metrics.lockWait,
		LockSteal = self.metrics.lockSteal,
		StaleRecover = self.metrics.staleRecover,
		SaveRetries = self.metrics.saveRetries,
		PendingSaves = self.metrics.pendingSaves,
		DirtyPaths = self.metrics.dirtyPaths,
		ValidationFail = self.metrics.validationFail,
		MessagesSent = self.metrics.messagesSent,
		Errors = self.metrics.errors,
	}
end

function Store:Inspect(key)
	if type(key) == "string" then
		local session = self.sessionsByKey[key]
		if session ~= nil then
			return session:Inspect()
		end
		return nil
	end

	local all = {}
	for k, session in pairs(self.sessionsByKey) do
		all[k] = session:Inspect()
	end
	return {
		Stats = self:GetStats(),
		Sessions = all,
	}
end

-- drives the auto save loop; called every heartbeat.
-- distributes saves evenly across the interval instead of saving everything at once
function Store:stepAuto()
	if self.closing == true then
		return
	end

	local count = #self.autoList
	if count == 0 then
		return
	end

	local now = os.clock()
	local slot = self.config.autoSaveInterval / count
	if slot < 0.5 then
		slot = 0.5
	end

	while now - self.lastAuto >= slot do
		self.lastAuto += slot
		if self.autoIndex < 1 or self.autoIndex > #self.autoList then
			self.autoIndex = 1
		end
		local session = self.autoList[self.autoIndex]
		self.autoIndex += 1
		if self.autoIndex > #self.autoList then
			self.autoIndex = 1
		end
		if session ~= nil and session:IsActive() == true then
			task.spawn(function()
				self:saveSession(session, "Auto", false)
			end)
		end
	end
end

-- saves and releases all active sessions; called on server shutdown.
-- has a 28 second hard limit to stay within Roblox's BindToClose budget
function Store:closeStore(shutdownReason)
	if self.closing == true then
		return
	end
	self.closing = true

	local batch = {}
	for _, session in ipairs(self.autoList) do
		table.insert(batch, session)
	end

	local waiting = 0
	for _, session in ipairs(batch) do
		if session:IsActive() == true then
			waiting += 1
			task.spawn(function()
				self:saveSession(session, shutdownReason, true)
				waiting -= 1
			end)
		end
	end

	local limit = os.clock() + 28
	while waiting > 0 and os.clock() < limit do
		task.wait()
	end
end

local function buildStore(storeName, template, opts, isMock)
	local config = normalizeConfig(opts)
	if isMock == true then
		config.mock = true
	end

	local schema = nil
	if config.schema ~= nil then
		schema = parseRule(config.schema)
	end

	local adapter = nil
	if config.mock == true then
		adapter = makeMemoryAdapter(storeName)
	else
		adapter = makeDataAdapter(storeName, config.scope)
	end

	local store = {
		name = storeName,
		template = copyAny(template or {}),
		config = config,
		adapter = adapter,
		isMock = config.mock,
		closing = false,
		schema = schema,
		migrations = {},
		sessionsByKey = {},
		autoList = {},
		autoIndex = 1,
		lastAuto = os.clock(),
		pendingSaveJobs = 0,
		-- MessagingService topic is truncated to 80 chars (Roblox limit)
		channel = string.sub("ProfileV2_" .. storeName, 1, 80),
		messageDead = false,
		subscription = nil,
		errorSignal = Signal.new(),
		metrics = {
			active = 0,
			loadCount = 0,
			saveCount = 0,
			saveFail = 0,
			loadTimeout = 0,
			totalSaveTime = 0,
			lockWait = 0,
			lockSteal = 0,
			staleRecover = 0,
			saveRetries = 0,
			pendingSaves = 0,
			dirtyPaths = 0,
			validationFail = 0,
			messagesSent = 0,
			errors = 0,
		},
	}
	setmetatable(store, Store)

	if type(config.migrations) == "table" then
		for version, fn in pairs(config.migrations) do
			if type(version) == "number" and type(fn) == "function" then
				store.migrations[version] = fn
			end
		end
	end

	return store
end

-- Profile.New is the main entry point
-- creates both a real store and a paired mock store so you can test without touching live data
function Profile.New(storeName, template, opts)
	if type(storeName) ~= "string" then
		error("Profile.New expected store name string")
	end
	if template ~= nil and type(template) ~= "table" then
		error("Profile.New expected template table")
	end

	local store = buildStore(storeName, template, opts, false)
	local mockStore = buildStore(storeName .. "_mock", template, opts, true)

	store.Mock = mockStore
	mockStore.Mock = mockStore

	table.insert(liveStores, store)
	table.insert(liveStores, mockStore)

	return store
end

function Profile.GetStats()
	local all = {}
	for _, store in ipairs(liveStores) do
		if store.isMock ~= true then
			table.insert(all, store:GetStats())
		end
	end
	return {
		State = Profile.State,
		IsCritical = Profile.IsCritical,
		StoreStats = all,
	}
end

function Profile.SetState(state)
	if type(state) ~= "string" then
		return
	end
	setState(state)
end

-- in Studio we do a quick DataStore write to figure out if we actually have API access.
-- this determines whether Load uses the real DataStore or the in-memory mock.
if RunService:IsStudio() == true then
	task.spawn(function()
		local ok, err = pcall(function()
			local checkStore = DataStoreService:GetDataStore("ProfileRuntimeCheck")
			checkStore:SetAsync("ProfileRuntimeCheck", os.time())
		end)
		if ok == true then
			setState("Access")
		else
			if string.find(tostring(err), "ConnectFail", 1, true) ~= nil then
				setState("NoInternet")
			else
				setState("NoAccess")
			end
		end
	end)
else
	setState("Access")
end

-- heartbeat drives the auto save loop and cleans up the issue time queue
RunService.Heartbeat:Connect(function()
	for _, store in ipairs(liveStores) do
		if store.isMock ~= true then
			store:stepAuto()
		end
	end

	local now = os.clock()
	while true do
		local first = issueTimes[1]
		if first == nil then
			break
		end
		if now - first > 120 then
			table.remove(issueTimes, 1)
		else
			break
		end
	end

	-- clear critical state if issues have settled down
	if Profile.IsCritical == true and #issueTimes <= 1 then
		Profile.IsCritical = false
		Profile.OnCritical:Fire(false)
	end
end)

-- only bind once even if the module is required multiple times
if boundShutdown ~= true then
	boundShutdown = true
	game:BindToClose(function()
		Profile.IsClosing = true
		for _, store in ipairs(liveStores) do
			if store.isMock ~= true then
				store:closeStore("Shutdown")
			end
		end
	end)
end

return Profile

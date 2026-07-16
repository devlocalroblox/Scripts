-- [ ReplicatedStorage/SlimeModules/Body ]

--[[

  [ SOFT BODY PHYSICS ]

	- This module handles the soft body physics simulation for a squishy slime.
	- Features rolling, squishing, bouncing, wall collisions, shape recoveries, etc.
	- This is directly inspired off of Slime Physics Sandbox. Overall recreated as close as possible.
	- https://www.roblox.com/games/81553461944480/Slime-Physics-Sandbox
	
	Made by local (DevLocal)
	
	6/1/2026

--]]

-- // SERVICES
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- // MODULES
local SlimeModules = ReplicatedStorage:WaitForChild("SlimeModules")

-- Requires
local Config = require(SlimeModules:WaitForChild("Config"))
local Icosphere = require(SlimeModules:WaitForChild("Icosphere"))

-- // CONFIG SHORTCUTS
local Slime = Config.Slime
local Physics = Config.Physics

-- // INSTANCE PATHS
local Baseplate = Workspace:WaitForChild("Baseplate") :: BasePart

-- // VOLUME CLAMP CONFIG
local volumeSoftCompliance = 0.0001 -- Softer correction
local volumeHardCompliance = 0 -- Hard stop
local volumeRampWidth = 0.05 -- How quickly it ramps up
local volumeMaxDelta = 0.6 -- Cap huge corrections
local collisionSkin = 0.03 -- Tiny gap between surfaces

-- // MODULE
local Body = {}
Body.__index = Body

-- // ONE PHYSICS POINT ON THE SLIME MESH
type Vertex = {
	index: number,
	pos: Vector3,
	prevPos: Vector3,
	acc: Vector3,
	restLocal: Vector3,
}

-- // EDGES KEEP NEARBY VERTICES FROM DRIFTING TOO FAR APART
type Edge = {
	v1: Vertex,
	v2: Vertex,
	restLength: number,
}

-- // BUILDS THE SLIME BODY FROM THE ICOSPHERE POINTS
function Body.new(folder: Folder, startPosition: Vector3, raycastParams: RaycastParams)
	
	-- Overlap checks reuse the same ignore list as raycasts
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = raycastParams.FilterDescendantsInstances
	overlapParams.RespectCanCollide = true
	
	-- Rest points are the original round shape
	local restPoints, faces = Icosphere.Build(Slime.Radius, Slime.IcosphereSubdivisions)
	
	-- Make sure all triangles face outward before the volume math uses them
	for _, face in faces do
		if not Icosphere.PointsOutward(restPoints, face) then
			face[2], face[3] = face[3], face[2]
		end
	end
	
	-- Live vertices start at their rest positions
	local vertices = table.create(#restPoints)
	
	-- prevPos starts the same to fix slime velocity on spawn
	for i = 1, #restPoints do
		local rest = restPoints[i]
		local pos = startPosition + rest
		vertices[i] = {
			index = i,
			pos = pos, -- No initial velocity
			prevPos = pos,
			acc = Vector3.zero,
			restLocal = rest,
		}
	end
	
	-- Invisible ball used by the rest of the system
	-- Simply gives the slime a single object to attach stuff like cameras, nameplates, etc
	local pickPart = Instance.new("Part")
	pickPart.Name = "SoftBodyPick"
	pickPart.Shape = Enum.PartType.Ball
	pickPart.Size = Vector3.one * Slime.Radius * 2.4
	pickPart.Transparency = 1
	pickPart.Anchored = true
	pickPart.CanCollide = false
	pickPart.CanTouch = false
	pickPart.CanQuery = false
	pickPart.CastShadow = false
	pickPart.CFrame = CFrame.new(startPosition)
	pickPart.Parent = folder
	
	-- Top of the baseplate
	local baseY = Baseplate.Position.Y + Baseplate.Size.Y * 0.5
	
	-- State for the whole soft body sim
	local self = setmetatable({
		Folder = folder,
		RaycastParams = raycastParams,
		OverlapParams = overlapParams,
		RestPoints = restPoints,
		Faces = faces,
		Vertices = vertices,
		StructuralEdges = {} :: { Edge },
		BendingEdges = {} :: { Edge },
		RestVolume = 0,
		VolumeSign = 1,
		VolumeGradients = table.create(#vertices),
		Accumulator = 0,
		RollingCFrame = CFrame.new(),
		LastRollCOM = startPosition,
		LastCOM = startPosition,
		COMSpeed = 0,
		Grounded = false,
		GroundNormal = Vector3.yAxis,
		GroundPoint = Vector3.new(0, baseY, 0),
		BaseplateY = baseY,
		PickPart = pickPart,
	}, Body)

	self:buildTopology() -- Build the spring lists AFTER the vertices exist
	
	-- Saves the starting volume for the clamp to compare against later
	local restVolume = Icosphere.SignedVolume(restPoints, faces)
	if restVolume < 0 then
		self.VolumeSign = -1
		self.RestVolume = -restVolume
	else
		self.RestVolume = restVolume
	end
	
	-- The center values start synced (bug prevention)
	self.LastCOM = self:GetCOM()
	self.LastRollCOM = self.LastCOM
	pickPart.CFrame = CFrame.new(self.LastCOM)

	return self
end

-- // TURNS THE SLIME MESH INTO SPRINGS | HOLDS THE SLIME TOGETHER
function Body:buildTopology()
	
	-- Keeps track of which spring links already exist
	local structuralUsed: { [string]: boolean } = {}
	local bendingUsed: { [string]: boolean } = {}
	local adjacency = table.create(#self.Vertices)
	
	-- Give each vertex its own neighbor list
	for i = 1, #self.Vertices do
		adjacency[i] = {} -- Only needed when building bending edges
	end
	
	-- Same key no matter which direction the edge is read from
	local function edgeKey(a: number, b: number): string
		if a > b then
			a, b = b, a
		end

		return `{a}|{b}`
	end
	
	-- adds the main springs along the mesh faces
	local function addStructural(a: number, b: number)
		local key = edgeKey(a, b)
		
		if structuralUsed[key] then
			return
		end

		structuralUsed[key] = true -- mark first, then store the actual edge data

		local v1 = self.Vertices[a]
		local v2 = self.Vertices[b]
		self.StructuralEdges[#self.StructuralEdges + 1] = {
			v1 = v1,
			v2 = v2,
			restLength = (v1.pos - v2.pos).Magnitude,
		}

		adjacency[a][#adjacency[a] + 1] = b
		adjacency[b][#adjacency[b] + 1] = a
	end
	
	-- adds the extra springs which help the slime keep its shape
	local function addBending(a: number, b: number)
		if a == b then -- Prevents connecting a point to itself
			return
		end

		local key = edgeKey(a, b)
		if bendingUsed[key] or structuralUsed[key] then -- Skip duplicates and direct edges
			return
		end

		bendingUsed[key] = true -- Mark first then store the actual edge data

		local v1 = self.Vertices[a]
		local v2 = self.Vertices[b]
		self.BendingEdges[#self.BendingEdges + 1] = {
			v1 = v1,
			v2 = v2,
			restLength = (v1.pos - v2.pos).Magnitude,
		}
	end
	
	-- Each triangle gives 3 main spring edges
	for i = 1, #self.Faces do
		local face = self.Faces[i] -- Three vertex indices
		addStructural(face[1], face[2])
		addStructural(face[2], face[3])
		addStructural(face[3], face[1])
	end
	
	-- 2nd pass finds wider links for bending springs
	for i = 1, #self.Vertices do
		local direct = adjacency[i] -- Direct neighbors of this vertex
		local seen: { [number]: boolean } = {} -- Direct neighbors dont need bending springs
		
		-- Direct neighbors are skipped so bending stays separate
		for j = 1, #direct do
			local directIndex = direct[j] -- Neighbor touching this vertex
			seen[directIndex] = true -- Mark direct neighbor
		end

		for j = 1, #direct do
			local directIndex = direct[j]
			local neighbors = adjacency[directIndex] -- Neighbors of the neighbor

			for k = 1, #neighbors do
				local neighbor = neighbors[k] -- Possible wider link
				if neighbor ~= i and not seen[neighbor] then -- Not itself or a direct edge
					addBending(i, neighbor)
				end
			end
		end
	end
	
	-- Make sure each live point still knows where it belongs in the rest shape
	for i = 1, #self.Vertices do
		self.Vertices[i].restLocal = self.RestPoints[i]
	end
end

-- // AVERAGE POSITION OF EVERY POINT IN THE SLIME | SLIME CENTER
function Body:GetCOM(): Vector3
	local total = Vector3.zero -- Sum of all the vertex positions

	for _, vertex in self.Vertices do
		total += vertex.pos -- Add this point to the average
	end

	return total / #self.Vertices -- Final center point
end

-- // GIVES THE RENDERER THE CURRENT MESH POINTS
function Body:GetVertexPositions(): { Vector3 }
	local positions = table.create(#self.Vertices)

	for i, vertex in self.Vertices do
		positions[i] = vertex.pos
	end

	return positions
end

-- // SHIFTS PREVIOUS POSITIONS TO FAKE AN INSTANT VELOCITY CHANGE
function Body:ApplyDeltaV(deltaV: Vector3)
	local shift = deltaV * Physics.FixedDt -- Convert velocity change to position offset

	for _, vertex in self.Vertices do
		vertex.prevPos -= shift -- Verlet reads this as a new velocity
	end
end

-- // QUEUES OUTSIDE FORCES FOR THE NEXT PHYSICS STEP
function Body:AddAcceleration(acceleration: Vector3)
	for _, vertex in self.Vertices do
		vertex.acc += acceleration
	end
end

-- // CHECKS WHAT FLOOR THE SLIME IS ON
function Body:refreshGround()
	local com = self:GetCOM()
	local distance = Slime.Radius * 1.35 -- Short ray below the slime
	local result = Workspace:Raycast(com, Vector3.new(0, -distance, 0), self.RaycastParams)

	if result and result.Normal.Y > 0.4 then -- Ignore steep walls
		self.Grounded = true -- Found a usable floor
		self.GroundNormal = result.Normal.Unit -- Floor angle
		self.GroundPoint = result.Position -- Point on the floor
		return
	end
	
	-- Fallback to the baseplate if the ray doesn't hit anything
	self.Grounded = false
	self.GroundNormal = Vector3.yAxis
	self.GroundPoint = Vector3.new(com.X, self.BaseplateY, com.Z)
end

-- // PULLS THE MAIN MESH EDGES BACK TOWARDS REST LENGTHS
function Body:solveStructuralSprings()
	for i = 1, #self.StructuralEdges do
		local edge = self.StructuralEdges[i] -- One main spring
		local v1 = edge.v1
		local v2 = edge.v2
		local delta = v2.pos - v1.pos -- Direction between points
		local length = delta.Magnitude -- Current distance

		if length > 0 then
			local diff = (length - edge.restLength) / length -- How far from rest length
			local correction = delta * 0.5 * diff -- Split the fix between both points
			v1.pos += correction -- Move one side
			v2.pos -= correction -- Move the other side
		end
	end
end

-- // SOFTER SPRINGS THAT STOP THE SLIME FROM FOLDING IN TOO MUCH
function Body:solveBendingSprings()
	local stiffness = Physics.BendingStiffness -- How strong bending springs are
	if stiffness == 0 then
		return
	end
	
	-- Prevent stretched corners from snapping too hard
	local cornerSoftening = Physics.CornerSoftening
	for i = 1, #self.BendingEdges do
		local edge = self.BendingEdges[i]
		local v1 = edge.v1
		local v2 = edge.v2
		local delta = v2.pos - v1.pos
		local length = delta.Magnitude

		if length > 0 then
			local stretchRatio = length / edge.restLength -- 1 means normal length
			local cornerFactor = if stretchRatio <= 1 then 1 else 1 / (1 + (stretchRatio - 1) * cornerSoftening) -- Softer when overstretched
			local diff = (length - edge.restLength) / length
			local correction = delta * 0.5 * diff * stiffness * cornerFactor
			v1.pos += correction
			v2.pos -= correction
		end
	end
end

-- The enclosed volume of the slime mesh
function Body:computeCurrentVolume(): number
	local volume = 0
	for i = 1, #self.Faces do
		local face = self.Faces[i]
		local a = self.Vertices[face[1]].pos -- Triangle point 1
		local b = self.Vertices[face[2]].pos -- Triangle point 2
		local c = self.Vertices[face[3]].pos -- Triangle point 3
		volume += a:Dot(b:Cross(c)) -- Count this triangle towards the slime volume
	end

	return (volume / 6) * self.VolumeSign -- Fixes the sign based on the triangle winding
end

-- // PREVENTS THE SLIME FROM GETTING OVERLY CRUSHED
function Body:solveVolumeClamp(dt: number)
	if not Physics.VolumeClampEnabled then
		return
	end

	local currentVolume = self:computeCurrentVolume() -- Current volume
	local minVolume = self.RestVolume * Physics.MinVolumeRatio -- Smallest allowed size
	local maxVolume = self.RestVolume * Physics.MaxVolumeRatio -- Biggest allowed size
	local targetVolume = currentVolume -- Only changes if the volume is outside the allowed range

	if currentVolume < minVolume then
		targetVolume = minVolume -- Push it back up
	elseif currentVolume > maxVolume then
		targetVolume = maxVolume -- Push it back down
	else
		return
	end

	local volumeRatio = currentVolume / self.RestVolume -- Compare against the starting size
	local outsideAmount = 0 -- How far past the safe range

	if volumeRatio < Physics.MinVolumeRatio then
		outsideAmount = Physics.MinVolumeRatio - volumeRatio -- Below the min
	elseif volumeRatio > Physics.MaxVolumeRatio then
		outsideAmount = volumeRatio - Physics.MaxVolumeRatio -- Above the max
	end

	local t = math.clamp(outsideAmount / volumeRampWidth, 0, 1) -- Farther out means stronger correction
	local compliance = volumeSoftCompliance + (volumeHardCompliance - volumeSoftCompliance) * t -- Blend soft to hard
	local alpha = math.max(compliance, 0) / (dt * dt) -- Scale the softness by the step time
	
	-- Few small pushes look smoother than one big shove
	for _ = 1, Physics.VolumeClampIterations do
		currentVolume = self:computeCurrentVolume()
		local errorAmount = currentVolume - targetVolume -- How much volume to fix

		if math.abs(errorAmount) <= 1e-6 then -- Close enough
			break
		end
	
		-- Reset the push direction for each vertex
		for i = 1, #self.Vertices do
			self.VolumeGradients[i] = Vector3.zero
		end

		for i = 1, #self.Faces do
			local face = self.Faces[i]
			local i1 = face[1] -- Vertex index 1
			local i2 = face[2] -- Vertex index 2
			local i3 = face[3] -- Vertex index 3

			local a = self.Vertices[i1].pos
			local b = self.Vertices[i2].pos
			local c = self.Vertices[i3].pos

			self.VolumeGradients[i1] += b:Cross(c) * (self.VolumeSign / 6) -- Push direction for point 1
			self.VolumeGradients[i2] += c:Cross(a) * (self.VolumeSign / 6) -- Push direction for point 2
			self.VolumeGradients[i3] += a:Cross(b) * (self.VolumeSign / 6) -- Push direction for point 3
		end

		local sum = 0 -- Total gradient strength
		for i = 1, #self.VolumeGradients do
			local gradient = self.VolumeGradients[i]
			sum += gradient:Dot(gradient) -- Squared length
		end

		local denom = sum + alpha -- Alpha softens the correction
		if denom < 1e-9 then
			break
		end

		local lambda = errorAmount / denom -- Correction amount
		for i = 1, #self.VolumeGradients do
			local gradient = self.VolumeGradients[i]
			local correction = gradient * lambda -- Push for this vertex
			local magnitude = correction.Magnitude -- Cap check
			if magnitude > volumeMaxDelta and magnitude > 0 then
				correction *= volumeMaxDelta / magnitude -- Stop huge jumps
			end

			self.Vertices[i].pos -= correction -- Apply the volume fix
		end
	end
end

-- // STOP VERTICES FROM GOING BELOW THE FLOOR
function Body:solveGround()
	local normal = self.Grounded and self.GroundNormal or Vector3.yAxis -- Floor direction
	local point = if self.Grounded then self.GroundPoint else Vector3.new(0, self.BaseplateY, 0) -- Floor point
	local bounce = Physics.Bounce -- How much the slime bounces back
	local friction = Physics.Friction * Physics.EnergyAbsorb -- Slows down sliding after the bounce

	for _, vertex in self.Vertices do
		local signedDistance = (vertex.pos - point):Dot(normal)
		if signedDistance < 0 then -- Vertex is below the floor
			local velocity = vertex.pos - vertex.prevPos -- Verlet velocity
			local projected = vertex.pos - normal * signedDistance -- Place back on the floor
			local normalVelocity = normal * velocity:Dot(normal) -- Velocity into the floor
			local tangentVelocity = velocity - normalVelocity -- The sideways velocity
			local newVelocity = -normalVelocity * bounce + tangentVelocity * (1 - friction) -- Bounce up, slow sideways

			vertex.pos = projected -- Corrected position
			vertex.prevPos = projected - newVelocity -- Keep adjusted velocity
		end
	end
end

-- // PUSHES ONE VERTEX OUT OF A SURFACE AND ADJUSTS ITS VELOCITY
function Body:applyCollisionResponse(vertex: Vertex, point: Vector3, normal: Vector3)
	local projected = point + normal * collisionSkin -- Tiny offset so it doesn't sit inside a wall
	local velocity = vertex.pos - vertex.prevPos
	local normalSpeed = velocity:Dot(normal) -- Speed into / out of surface
	local normalVelocity = normal * normalSpeed
	local tangentVelocity = velocity - normalVelocity
	local friction = Physics.Friction * Physics.EnergyAbsorb
	local bouncedNormalVelocity = if normalSpeed < 0 then -normalVelocity * Physics.Bounce else normalVelocity -- Only bounce when moving in
	local newVelocity = bouncedNormalVelocity + tangentVelocity * (1 - friction)

	vertex.pos = projected
	vertex.prevPos = projected - newVelocity
end

-- // CATCHES FAST MOVEMENTS
function Body:solveRaycastCollisions()
	for _, vertex in self.Vertices do
		local delta = vertex.pos - vertex.prevPos -- Movement from the last physics step
		if delta.Magnitude > 0.001 then
			local result = Workspace:Raycast(vertex.prevPos, delta, self.RaycastParams) 
			if result and result.Instance:IsA("BasePart") and result.Instance.CanCollide then -- Hit a solid part
				self:applyCollisionResponse(vertex, result.Position, result.Normal.Unit)
			end
		end
	end
end

-- // PUSHES SLIME POINTS OUT OF THE NEARBY PARTS
function Body:solvePartCollisions()
	if not Physics.CollisionEnabled then 
		return
	end

	local com = self:GetCOM()
	local nearbyParts = Workspace:GetPartBoundsInRadius(com, Slime.Radius * 2.4, self.OverlapParams) -- Broad collision check
	if #nearbyParts == 0 then -- Nothing close; do raycasts
		self:solveRaycastCollisions()
		return
	end

	for _, part in nearbyParts do -- Check each nearby part
		if part.CanCollide then -- Ignore non solid parts
			local halfSize = part.Size * 0.5 -- Box extents
			local cframe = part.CFrame -- Part transform

			for _, vertex in self.Vertices do
				local localPos = cframe:PointToObjectSpace(vertex.pos) --  Move the point into the parts space
				local xPen = halfSize.X - math.abs(localPos.X) -- Overlap on X
				local yPen = halfSize.Y - math.abs(localPos.Y) -- Overlap on Y
				local zPen = halfSize.Z - math.abs(localPos.Z) -- Overlap on Z

				if xPen >= 0 and yPen >= 0 and zPen >= 0 then

					if xPen <= yPen and xPen <= zPen then -- Push out through the closest side

						local sign = if localPos.X >= 0 then 1 else -1 -- Which side of the box
						local normalObject = Vector3.new(sign, 0, 0) -- Normal while still in part space
						local projectedObject = Vector3.new(sign * halfSize.X, localPos.Y, localPos.Z) -- Normal while still in part space
						local normal = cframe:VectorToWorldSpace(normalObject).Unit -- Convert the normal back to world space
						local point = cframe:PointToWorldSpace(projectedObject) -- Convert the pushout point back too
						self:applyCollisionResponse(vertex, point, normal)

					elseif yPen <= zPen then -- Y side is closest

						local sign = if localPos.Y >= 0 then 1 else -1 -- Top or bottom side
						local normalObject = Vector3.new(0, sign, 0) -- Normal for this side of the part
						local projectedObject = Vector3.new(localPos.X, sign * halfSize.Y, localPos.Z) -- Closest spot on this side
						local normal = cframe:VectorToWorldSpace(normalObject).Unit
						local point = cframe:PointToWorldSpace(projectedObject)
						self:applyCollisionResponse(vertex, point, normal)

					else -- Z side is closest
						local sign = if localPos.Z >= 0 then 1 else -1
						local normalObject = Vector3.new(0, 0, sign)
						local projectedObject = Vector3.new(localPos.X, localPos.Y, sign * halfSize.Z)
						local normal = cframe:VectorToWorldSpace(normalObject).Unit
						local point = cframe:PointToWorldSpace(projectedObject)
						self:applyCollisionResponse(vertex, point, normal)

					end
				end
			end
		end
	end

	self:solveRaycastCollisions()
end

-- // UPDATES THE ROLLING ROTATION | BASED ON HOW FAR THE CENTER MOVED
function Body:updateRolling(com: Vector3)
	local flatDelta = Vector3.new(com.X - self.LastRollCOM.X, 0, com.Z - self.LastRollCOM.Z) -- Only horizontal movement rolls
	local magnitude = flatDelta.Magnitude -- Horizontal travel distance

	if magnitude < 0.0001 then -- Barely moved
		self.LastRollCOM = com -- Remember center for next roll check
		return
	end

	local axis = Vector3.yAxis:Cross(flatDelta.Unit) -- Roll axis
	if axis.Magnitude < 0.0001 then -- No useful roll axis
		self.LastRollCOM = com
		return
	end

	local angle = magnitude / Slime.Radius -- Distance over radius gives the roll amount
	self.RollingCFrame = CFrame.fromAxisAngle(axis.Unit, angle) * self.RollingCFrame -- Add this frames roll
	self.LastRollCOM = com
end

-- // GENTLY PULLS POINTS BACK
function Body:solveShape(com: Vector3)
	local stiffness = Physics.ShapeStiffness -- How strongly it returns to round
	if stiffness <= 0 then
		return
	end

	for _, vertex in self.Vertices do
		local target = com + self.RollingCFrame:VectorToWorldSpace(vertex.restLocal) -- Where this point wants to be
		vertex.pos = vertex.pos:Lerp(target, stiffness) -- Soft return not snap
	end
end

-- // RUN THE SLIME PHYSICS STEP
function Body:Step(dt: number): number
	self.Accumulator += dt -- Leftover frame time gets carried into fixed steps
	local stepped = 0 -- Fixed steps used this frame
	local simulatedTime = 0 -- Total time actually simulated
	local fixedDt = Physics.FixedDt -- Stable physics timestep
	local fixedDtSquared = fixedDt * fixedDt -- Used by verlet acceleration

	while self.Accumulator >= fixedDt and stepped < Physics.MaxSubSteps do
		local gravity = Vector3.new(0, -Physics.Gravity, 0) -- Downward force
		local damping = Physics.Damping -- Small energy loss

		for _, vertex in self.Vertices do
			local oldPosition = vertex.pos -- Needed for verlet velocity
			local velocity = (vertex.pos - vertex.prevPos) * damping
			local acceleration = gravity + vertex.acc -- Gravity plus queued forces

			vertex.pos = vertex.pos + velocity + acceleration * fixedDtSquared -- Verlet integer
			vertex.prevPos = oldPosition -- Current becomes prev next frame
			vertex.acc = Vector3.zero -- Forces get applied like once per step
		end

		local speed = self.COMSpeed -- Faster movement gets a few extra solver passes
		local iterations = if speed < 5 then 4
			elseif speed > 60 then 8 -- More passes when moving fast
			else math.floor(4 + 4 * ((speed - 5) / 55) + 0.5)

		for _ = 1, iterations do
			self:solveStructuralSprings()
			self:solveBendingSprings() 
		end

		self:solveVolumeClamp(fixedDt) -- Keep volume in range
		self:solveGround() -- Floor collision

		local com = self:GetCOM()
		self:updateRolling(com)
		self:solveShape(com) -- Restore the round rolling shape
		self:solvePartCollisions() -- World collisions

		self.Accumulator -= fixedDt -- Remove the time we just simulated
		stepped += 1 -- Count the step
		simulatedTime += fixedDt -- Used for speed calculation
	end

	local com = self:GetCOM()
	self.PickPart.CFrame = CFrame.new(com) -- Keep the helper part centered

	if simulatedTime > 0 then
		self.COMSpeed = (com - self.LastCOM).Magnitude / simulatedTime -- Center speed this frame
	else
		self.COMSpeed = 0 -- No fixed step ran
	end

	self.LastCOM = com -- Save for next speed check
	self:refreshGround() -- Prep ground info for the next step

	return simulatedTime -- Lets caller know how much time was simulated
end

return Body

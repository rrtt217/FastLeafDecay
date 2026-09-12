-- FastLeafDecay - fast leaf decay for the Cuberite Minecraft server
-- Copyright 2026 FastLeafDecay contributors
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Portions of this file are derived from Cuberite (https://cuberite.org),
-- Copyright 2011-2025 Cuberite Contributors, Apache-2.0 - see the NOTICE file.

-- decay.lua
-- Core of the FastLeafDecay plugin.
--
-- Cuberite already implements leaf decay: cBlockLeavesHandler::OnUpdate() runs a
-- breadth-first search over leaves (up to LEAVES_CHECK_DISTANCE = 6 steps) and drops the
-- block when no log is reachable.  The cost of that implementation is that the search is
-- performed once per leaves block, each time reading a 13 x 13 x 13 area, and that the
-- checks are spread over several ticks through the block-update queue.
--
-- This file replaces that with a single pass: the connected leaves component is walked
-- once, and a multi-source BFS seeded from every leaves block that touches a log computes
-- the distance to the nearest log for all blocks of the component at the same time.
-- Leaves that cannot reach a log within MaxDistance steps are then dropped.
--
-- The traversal and the BFS follow exactly the same connectivity rules as the vanilla /
-- Cuberite check, so the set of leaves that is dropped is the same as with native decay,
-- only with far fewer block reads.
--
-- Two delivery modes for the drop itself:
--   Gradual = false  everything is dropped inside the hook call (instant, can look abrupt)
--   Gradual = true   the orphaned leaves are queued and dropped in batches of
--                    LeavesPerBatch every DecayIntervalTicks, in the order the traversal
--                    found them (roughly from the broken log outwards), which reads as the
--                    canopy crumbling away.

--- Value stored in the block cache for a coordinate whose chunk is not loaded.
local FLD_UNKNOWN = -1

local FLD_LEAF_TYPES =
{
	[E_BLOCK_LEAVES]     = true,
	[E_BLOCK_NEW_LEAVES] = true,
}

local FLD_LOG_TYPES =
{
	[E_BLOCK_LOG]     = true,
	[E_BLOCK_NEW_LOG] = true,
}

local FLD_NEIGHBOURS =
{
	{ 1,  0,  0},
	{-1,  0,  0},
	{ 0,  1,  0},
	{ 0, -1,  0},
	{ 0,  0,  1},
	{ 0,  0, -1},
}


--- Returns true if a_BlockType is a leaves block type.
function FLD_IsLeaf(a_BlockType)
	return FLD_LEAF_TYPES[a_BlockType] == true
end


--- Returns true if a_BlockType is a log block type.
function FLD_IsLog(a_BlockType)
	return FLD_LOG_TYPES[a_BlockType] == true
end


-- Blocks a vine cannot attach to, mirroring cBlockVinesHandler::IsBlockAttachable().
local FLD_VINE_UNATTACHABLE =
{
	[E_BLOCK_CHEST]                 = true,
	[E_BLOCK_ENDER_CHEST]           = true,
	[E_BLOCK_GLASS]                 = true,
	[E_BLOCK_PISTON]                = true,
	[E_BLOCK_PISTON_EXTENSION]      = true,
	[E_BLOCK_REDSTONE_REPEATER_OFF] = true,
	[E_BLOCK_REDSTONE_REPEATER_ON]  = true,
	[E_BLOCK_STAINED_GLASS]         = true,
	[E_BLOCK_STICKY_PISTON]         = true,
	[E_BLOCK_TRAPPED_CHEST]         = true,
}

-- The four horizontal sides a vine can attach to, with the meta bit that selects them.
local FLD_VINE_SIDES =
{
	{ 0,  1, 1},  -- south (ZP)
	{-1,  0, 2},  -- west  (XM)
	{ 0, -1, 4},  -- north (ZM)
	{ 1,  0, 8},  -- east  (XP)
}


--- Bit test that also works on Lua 5.1 (Cuberite has no bitwise operators).
local function FLD_HasMetaBit(a_Meta, a_Bit)
	return (math.floor(a_Meta / a_Bit) % 2) == 1
end


--- Mirror of cBlockVinesHandler::IsBlockAttachable().
local function FLD_IsVineAttachable(a_BlockType)
	if FLD_VINE_UNATTACHABLE[a_BlockType] then
		return false
	end
	return cBlockInfo:IsSolid(a_BlockType) == true
end


--- Mirror of cBlockVinesHandler::GetMaxMeta(): can this vine still stay where it is?
-- Cuberite's own handler has a hole here: it returns VINE_UNCHANGED as soon as
-- "vineMeta & maxMeta == vineMeta", which is always true once the meta has been reduced to
-- 0.  A vine that lost its side attachments but was still held by a solid block above
-- (leaves are solid!) therefore ends up with meta 0 and can never be destroyed by a later
-- neighbour change - this is what leaves floating vines behind after the canopy is gone.
local function FLD_VineSupported(a_World, a_X, a_Y, a_Z)
	local IsValid, BlockType, Meta = a_World:GetBlockInfo(Vector3i(a_X, a_Y, a_Z))
	if (not IsValid) or (BlockType ~= E_BLOCK_VINES) then
		return false
	end

	-- Sides the vine still claims and that are attachable:
	for Index = 1, 4 do
		local Side = FLD_VINE_SIDES[Index]
		if FLD_HasMetaBit(Meta, Side[3]) then
			local Ok, OtherType = a_World:GetBlockInfo(Vector3i(a_X + Side[1], a_Y, a_Z + Side[2]))
			if Ok and FLD_IsVineAttachable(OtherType) then
				return true
			end
		end
	end

	if (a_Y >= 255) then
		return true
	end

	local Ok, AboveType, AboveMeta = a_World:GetBlockInfo(Vector3i(a_X, a_Y + 1, a_Z))
	if (not Ok) then
		return true  -- unknown chunk: better to leave the vine alone
	end
	if FLD_IsVineAttachable(AboveType) then
		return true
	end
	if (AboveType == E_BLOCK_VINES) then
		-- A vine hangs from the vine above wherever the two share a side bit:
		for Index = 1, 4 do
			local Side = FLD_VINE_SIDES[Index]
			if FLD_HasMetaBit(Meta, Side[3]) and FLD_HasMetaBit(AboveMeta, Side[3]) then
				return true
			end
		end
	end
	return false
end


--- Removes the vines around a block that just disappeared if they lost their support.
-- The search follows any vine it removes, so a whole hanging chain is cleaned up.
local function FLD_CleanVines(a_World, a_X, a_Y, a_Z)
	local Todo = {{a_X, a_Y, a_Z}}
	local Guard = 0
	while (#Todo > 0) and (Guard < 512) do
		Guard = Guard + 1
		local Pos = table.remove(Todo)
		for Index = 1, 6 do
			local Offset = FLD_NEIGHBOURS[Index]
			local X = Pos[1] + Offset[1]
			local Y = Pos[2] + Offset[2]
			local Z = Pos[3] + Offset[3]
			if (Y >= 0) and (Y <= 255) then
				local IsValid, BlockType = a_World:GetBlockInfo(Vector3i(X, Y, Z))
				if IsValid and (BlockType == E_BLOCK_VINES) and (not FLD_VineSupported(a_World, X, Y, Z)) then
					-- Matches the native handler: the vine is destroyed, not dropped.
					a_World:SetBlock(Vector3i(X, Y, Z), E_BLOCK_AIR, 0)
					Todo[#Todo + 1] = {X, Y, Z}
				end
			end
		end
	end
end


--- Drops a list of leaves (tables with X / Y / Z fields).
-- a_Verify re-reads every block first, for leaves that sat in the gradual-decay queue
-- while the world kept changing; a leaf that is already gone or replaced is skipped.
-- Returns the number of blocks actually dropped.
local function FLD_DropLeaves(a_World, a_Leaves, a_Verify)
	local DropItems = FLD_Config.DropItems
	local CleanVines = FLD_Config.CleanFloatingVines
	local Dropped = 0
	for Index = 1, #a_Leaves do
		local Leaf = a_Leaves[Index]
		local Ok = true
		if a_Verify then
			local IsValid, BlockType = a_World:GetBlockInfo(Vector3i(Leaf.X, Leaf.Y, Leaf.Z))
			Ok = IsValid and FLD_IsLeaf(BlockType)
		end
		if Ok then
			-- DropBlockAsPickups() runs the normal block handler, so the vanilla drops
			-- (sapling / stick / apple) and HOOK_BLOCK_TO_PICKUPS still apply.  It also
			-- goes through cChunk::SetBlock, which queues the neighbour updates that make
			-- vines, torches and the like re-check their support.
			if DropItems then
				a_World:DropBlockAsPickups(Vector3i(Leaf.X, Leaf.Y, Leaf.Z))
			else
				a_World:SetBlock(Vector3i(Leaf.X, Leaf.Y, Leaf.Z), E_BLOCK_AIR, 0)
			end
			Dropped = Dropped + 1
			if CleanVines then
				FLD_CleanVines(a_World, Leaf.X, Leaf.Y, Leaf.Z)
			end
		end
	end
	return Dropped
end


--- Clears the native "needs a decay check" bit (meta 0x08) on the leaves that survived a
-- pass.  Removing their orphaned neighbours makes the block-update queue ask the native
-- handler for a (13 x 13 x 13) decay check on each of them; they are already known to be in
-- reach of a log, so the bit can be dropped instead.
local function FLD_ClearCheckBits(a_World, a_Leaves)
	for Index = 1, #a_Leaves do
		local Leaf = a_Leaves[Index]
		local IsValid, BlockType, Meta = a_World:GetBlockInfo(Vector3i(Leaf.X, Leaf.Y, Leaf.Z))
		if IsValid and FLD_IsLeaf(BlockType) and (Meta >= 8) then
			a_World:SetBlockMeta(Vector3i(Leaf.X, Leaf.Y, Leaf.Z), Meta - 8)
		end
	end
end


--- Task run once per DecayIntervalTicks while leaves are queued for gradual decay.
function FLD_ProcessPending(a_World)
	local Pending = (FLD_Pending ~= nil) and FLD_Pending[a_World] or nil
	if (Pending == nil) or (FLD_Config == nil) then
		return
	end

	local Config = FLD_Config
	local Queue = Pending.Queue

	-- Take the next batch, oldest first, so the canopy crumbles outwards from the log.
	local Batch = {}
	local Count = 0
	while (Count < Config.LeavesPerBatch) and (Pending.Head <= #Queue) do
		Batch[#Batch + 1] = Queue[Pending.Head]
		Pending.Head = Pending.Head + 1
		Count = Count + 1
	end

	if (#Batch > 0) then
		FLD_Stats.LeavesDropped = FLD_Stats.LeavesDropped + FLD_DropLeaves(a_World, Batch, true)
	end

	if (Pending.Head > #Queue) then
		-- Everything is gone; the survivors can finally have their check bit cleared.
		if (Config.ClearNativeCheckBit) and (#Pending.Survivors > 0) then
			FLD_ClearCheckBits(a_World, Pending.Survivors)
		end
		Pending.Queue = {}
		Pending.Survivors = {}
		Pending.Head = 1
		Pending.Scheduled = false
		FLD_Pending[a_World] = nil
		return
	end

	a_World:ScheduleTask(Config.DecayIntervalTicks, FLD_ProcessPending)
end


--- Drops every leaves block reachable from a_Seeds that cannot reach a log within
-- FLD_Config.MaxDistance leaves steps.
-- a_CenterX/Y/Z only bounds the search and indexes the visited set; the caller passes the
-- position of the removed log or the explosion center.
-- Returns the number of leaves that were dropped (instant mode) or queued (gradual mode)
-- and the number of scanned leaves, or nil plus a reason string when the pass was aborted
-- (the world was left untouched in that case).
function FLD_ProcessLeaves(a_World, a_CenterX, a_CenterY, a_CenterZ, a_Seeds)
	local Config = FLD_Config
	local MaxDistance = Config.MaxDistance
	local MaxScan = Config.MaxScan
	local MaxRadius = Config.MaxRadius

	-- Per-call block cache, keyed by absolute coordinates so that every block is read at
	-- most once, no matter how often the traversal touches it.
	local Cache = {}
	local function ReadBlock(a_X, a_Y, a_Z)
		local Column = Cache[a_X]
		if (Column == nil) then
			Column = {}
			Cache[a_X] = Column
		end
		local Row = Column[a_Y]
		if (Row == nil) then
			Row = {}
			Column[a_Y] = Row
		end
		local Value = Row[a_Z]
		if (Value == nil) then
			local IsValid, BlockType = a_World:GetBlockInfo(Vector3i(a_X, a_Y, a_Z))
			if IsValid then
				Value = BlockType
			else
				Value = FLD_UNKNOWN
			end
			Row[a_Z] = Value
		end
		return Value
	end

	local LeafList = {}
	local LeafIndex = {}
	local Queue = {}
	local QueueHead = 1
	local ScanCount = 0

	-- Packs coordinates relative to the center into one integer.  MaxRadius is capped at
	-- 63 at configuration time, so the packed value stays well inside Lua's integer range.
	local function KeyOf(a_X, a_Y, a_Z)
		return ((a_X - a_CenterX + 64) * 128 + (a_Z - a_CenterZ + 64)) * 256 + a_Y
	end

	local function InRange(a_X, a_Y, a_Z)
		return (a_Y >= 0) and (a_Y <= 255)
			and (math.abs(a_X - a_CenterX) <= MaxRadius)
			and (math.abs(a_Z - a_CenterZ) <= MaxRadius)
			and (math.abs(a_Y - a_CenterY) <= MaxRadius)
	end

	local function AddLeaf(a_X, a_Y, a_Z)
		local Key = KeyOf(a_X, a_Y, a_Z)
		local Existing = LeafIndex[Key]
		if (Existing ~= nil) then
			return Existing
		end
		ScanCount = ScanCount + 1
		if (ScanCount > MaxScan) then
			return nil
		end
		local Index = #LeafList + 1
		LeafList[Index] =
		{
			X = a_X,
			Y = a_Y,
			Z = a_Z,
			NeighbourLeaves = {},
			TouchesLog = false,
		}
		LeafIndex[Key] = Index
		Queue[#Queue + 1] = Index
		return Index
	end

	-- Seed the traversal with the leaves the caller already knows about.
	for _, Seed in ipairs(a_Seeds) do
		if (not InRange(Seed[1], Seed[2], Seed[3])) then
			return nil, "leaves spread too far"
		end
		if (AddLeaf(Seed[1], Seed[2], Seed[3]) == nil) then
			return nil, "too many leaves"
		end
	end

	-- Phase 1: walk the connected leaves component and remember, per leaf, which of its
	-- neighbours are leaves of this component and whether any neighbour is a log.
	while (QueueHead <= #Queue) do
		local Leaf = LeafList[Queue[QueueHead]]
		QueueHead = QueueHead + 1
		for Neighbour = 1, 6 do
			local Offset = FLD_NEIGHBOURS[Neighbour]
			local X = Leaf.X + Offset[1]
			local Y = Leaf.Y + Offset[2]
			local Z = Leaf.Z + Offset[3]
			if (not InRange(X, Y, Z)) then
				return nil, "leaves spread too far"
			end
			local BlockType = ReadBlock(X, Y, Z)
			if (BlockType == FLD_UNKNOWN) then
				return nil, "unloaded chunk"
			end
			if FLD_IsLeaf(BlockType) then
				local Index = AddLeaf(X, Y, Z)
				if (Index == nil) then
					return nil, "too many leaves"
				end
				Leaf.NeighbourLeaves[Neighbour] = Index
			elseif FLD_IsLog(BlockType) then
				Leaf.TouchesLog = true
			end
		end
	end

	-- Phase 2: multi-source BFS.  Leaves next to a log survive with distance 1; the
	-- distance is then propagated through the component, which is exactly the search the
	-- native handler performs for each individual block.
	local Distance = {}
	local DistQueue = {}
	local DistHead = 1
	for Index = 1, #LeafList do
		if LeafList[Index].TouchesLog then
			Distance[Index] = 1
			DistQueue[#DistQueue + 1] = Index
		end
	end
	while (DistHead <= #DistQueue) do
		local Index = DistQueue[DistHead]
		DistHead = DistHead + 1
		local Current = Distance[Index]
		if (Current < MaxDistance) then
			local Leaf = LeafList[Index]
			for Neighbour = 1, 6 do
				local Other = Leaf.NeighbourLeaves[Neighbour]
				if (Other ~= nil) and (Distance[Other] == nil) then
					Distance[Other] = Current + 1
					DistQueue[#DistQueue + 1] = Other
				end
			end
		end
	end

	-- Collect the leaves that are out of reach of any log.
	local Orphans = {}
	local Survivors = {}
	for Index = 1, #LeafList do
		local Leaf = LeafList[Index]
		if (Distance[Index] == nil) then
			if Config.DecayPlacedLeaves then
				Orphans[#Orphans + 1] = Leaf
			else
				-- Meta bit 0x04 marks player-placed (persistent) leaves.
				local Meta = a_World:GetBlockMeta(Vector3i(Leaf.X, Leaf.Y, Leaf.Z))
				if ((Meta % 8) < 4) then
					Orphans[#Orphans + 1] = Leaf
				end
			end
		elseif Config.ClearNativeCheckBit then
			Survivors[#Survivors + 1] = Leaf
		end
	end

	local Scanned = #LeafList
	if (#Orphans == 0) then
		return 0, Scanned
	end

	if Config.Gradual then
		local Pending = FLD_Pending[a_World]
		if (Pending == nil) then
			Pending = {Queue = {}, Head = 1, Survivors = {}, Scheduled = false}
			FLD_Pending[a_World] = Pending
		end
		for _, Leaf in ipairs(Orphans) do
			Pending.Queue[#Pending.Queue + 1] = {X = Leaf.X, Y = Leaf.Y, Z = Leaf.Z}
		end
		for _, Leaf in ipairs(Survivors) do
			Pending.Survivors[#Pending.Survivors + 1] = Leaf
		end
		if (not Pending.Scheduled) then
			Pending.Scheduled = true
			a_World:ScheduleTask(Config.DecayIntervalTicks, FLD_ProcessPending)
		end
	else
		FLD_Stats.LeavesDropped = FLD_Stats.LeavesDropped + FLD_DropLeaves(a_World, Orphans, false)
		if (#Survivors > 0) then
			FLD_ClearCheckBits(a_World, Survivors)
		end
	end

	return #Orphans, Scanned
end


--- Handles a log that has just been removed at the given position.  Only leaves that are
-- adjacent to the removed log can be orphaned by it, so those are used as the seeds.
function FLD_ProcessRemovedLog(a_World, a_X, a_Y, a_Z)
	if (a_World == nil) or (FLD_Config == nil) or (not FLD_Config.Enabled) then
		return nil, "disabled"
	end
	if FLD_Busy[a_World] then
		return nil, "already processing this world"
	end

	local Seeds = {}
	for Neighbour = 1, 6 do
		local Offset = FLD_NEIGHBOURS[Neighbour]
		local X = a_X + Offset[1]
		local Y = a_Y + Offset[2]
		local Z = a_Z + Offset[3]
		if (Y >= 0) and (Y <= 255) then
			local IsValid, BlockType = a_World:GetBlockInfo(Vector3i(X, Y, Z))
			if (not IsValid) then
				return nil, "unloaded chunk"
			end
			if FLD_IsLeaf(BlockType) then
				Seeds[#Seeds + 1] = {X, Y, Z}
			end
		end
	end
	if (#Seeds == 0) then
		return 0, 0
	end

	FLD_Busy[a_World] = true
	local Dropped, Scanned = FLD_ProcessLeaves(a_World, a_X, a_Y, a_Z, Seeds)
	FLD_Busy[a_World] = nil
	return Dropped, Scanned
end


--- Handles an explosion that may have removed logs, by seeding the decay pass with the
-- leaves found in a cube around the explosion center.
function FLD_ProcessExplosion(a_World, a_X, a_Y, a_Z, a_Size)
	if (a_World == nil) or (FLD_Config == nil) or (not FLD_Config.Enabled) then
		return nil, "disabled"
	end

	local Radius = math.floor(a_Size + FLD_Config.ExplosionRadiusBoost)
	if (Radius > FLD_Config.ExplosionMaxRadius) then
		Radius = FLD_Config.ExplosionMaxRadius
	end
	if (Radius < 1) then
		Radius = 1
	end

	local Seeds = {}
	local MinY = math.max(a_Y - Radius, 0)
	local MaxY = math.min(a_Y + Radius, 255)
	for Y = MinY, MaxY do
		for Z = a_Z - Radius, a_Z + Radius do
			for X = a_X - Radius, a_X + Radius do
				local IsValid, BlockType = a_World:GetBlockInfo(Vector3i(X, Y, Z))
				if (not IsValid) then
					return nil, "unloaded chunk"
				end
				if FLD_IsLeaf(BlockType) then
					Seeds[#Seeds + 1] = {X, Y, Z}
				end
			end
		end
	end
	if (#Seeds == 0) then
		return 0, 0
	end

	if FLD_Busy[a_World] then
		return nil, "already processing this world"
	end
	FLD_Busy[a_World] = true
	local Dropped, Scanned = FLD_ProcessLeaves(a_World, a_X, a_Y, a_Z, Seeds)
	FLD_Busy[a_World] = nil
	return Dropped, Scanned
end

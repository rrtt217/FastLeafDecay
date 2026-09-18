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

-- tests/decay_test.lua
-- Offline unit test for FastLeafDecay.
--
-- Runs decay.lua against a mock cWorld (a plain Lua table of blocks) and drives the same
-- self-test that the in-game console command "fldtest" uses, plus a few extra cases that
-- are hard to stage inside a live world (player-placed leaves, no-drop mode, safety-valve
-- aborts).
--
-- Usage (from the plugin folder):
--     lua tests/decay_test.lua
--     luajit tests/decay_test.lua      -- Lua 5.1 compatibility (Cuberite uses 5.1.4)
--
-- Exit code 0 when every check passed, 1 otherwise.

-- ---------------------------------------------------------------------------
-- Block type constants (the real ones come from Cuberite)
-- ---------------------------------------------------------------------------

E_BLOCK_AIR        = 0
E_BLOCK_STONE      = 1
E_BLOCK_LOG        = 17
E_BLOCK_LEAVES     = 18
E_BLOCK_GLASS      = 20
E_BLOCK_STICKY_PISTON = 29
E_BLOCK_PISTON     = 33
E_BLOCK_PISTON_EXTENSION = 34
E_BLOCK_CHEST      = 54
E_BLOCK_REDSTONE_REPEATER_OFF = 93
E_BLOCK_REDSTONE_REPEATER_ON  = 94
E_BLOCK_STAINED_GLASS = 95
E_BLOCK_VINES      = 106
E_BLOCK_ENDER_CHEST = 130
E_BLOCK_TRAPPED_CHEST = 146
E_BLOCK_NEW_LOG    = 162
E_BLOCK_NEW_LEAVES = 161

--- Mock for cBlockInfo:IsSolid(), which the vine support check uses.  Cuberite reports
--- leaves and logs as solid; air and vines are not.
cBlockInfo =
{
	IsSolid = function(_, a_BlockType)
		return (a_BlockType ~= E_BLOCK_AIR) and (a_BlockType ~= E_BLOCK_VINES)
	end,
}

--- Mock for the cVector3i constructor.
function Vector3i(a_X, a_Y, a_Z)
	return {X = a_X, Y = a_Y, Z = a_Z}
end


-- ---------------------------------------------------------------------------
-- Mock world
-- ---------------------------------------------------------------------------

local Blocks = {}      -- "x,y,z" -> {Type = ..., Meta = ...}
local Drops = {}       -- list of pickups produced by DropBlockAsPickups
local Scheduled = {}   -- functions queued through World:ScheduleTask
local InvalidAt = nil  -- optional coordinate (as "x,y,z") reported as an unloaded chunk

local World = {}

local function Cell(a_X, a_Y, a_Z)
	local Key = a_X .. "," .. a_Y .. "," .. a_Z
	local Block = Blocks[Key]
	if (Block == nil) then
		Block = {Type = E_BLOCK_AIR, Meta = 0}
		Blocks[Key] = Block
	end
	return Block
end

local function ResetWorld()
	Blocks = {}
	Drops = {}
	Scheduled = {}
	InvalidAt = nil
end

--- Runs every task queued by the plugin, newest batch first, like the world tick would.
local function PumpScheduledTasks(a_MaxRounds)
	local Rounds = 0
	local MaxRounds = a_MaxRounds or 1000
	while (#Scheduled > 0) and (Rounds < MaxRounds) do
		Rounds = Rounds + 1
		local Task = table.remove(Scheduled, 1)
		Task.Fn(World)
	end
	return Rounds
end

function World:GetBlockInfo(a_Pos)
	local Key = a_Pos.X .. "," .. a_Pos.Y .. "," .. a_Pos.Z
	if (Key == InvalidAt) then
		return false, 0, 0, 0, 0
	end
	local Block = Cell(a_Pos.X, a_Pos.Y, a_Pos.Z)
	return true, Block.Type, Block.Meta, 15, 15
end

function World:GetBlockMeta(a_Pos)
	return Cell(a_Pos.X, a_Pos.Y, a_Pos.Z).Meta
end

function World:SetBlockMeta(a_Pos, a_Meta)
	Cell(a_Pos.X, a_Pos.Y, a_Pos.Z).Meta = a_Meta
end

function World:SetBlock(a_Pos, a_BlockType, a_Meta)
	local Block = Cell(a_Pos.X, a_Pos.Y, a_Pos.Z)
	Block.Type = a_BlockType
	Block.Meta = a_Meta or 0
end

function World:DropBlockAsPickups(a_Pos)
	local Block = Cell(a_Pos.X, a_Pos.Y, a_Pos.Z)
	Drops[#Drops + 1] = {X = a_Pos.X, Y = a_Pos.Y, Z = a_Pos.Z, Type = Block.Type}
	Block.Type = E_BLOCK_AIR
	Block.Meta = 0
	return true
end

--- Chunks are always "loaded" in the mock, so the callback runs synchronously.
function World:PrepareChunk(a_ChunkX, a_ChunkZ, a_Callback)
	if (a_Callback ~= nil) then
		a_Callback(a_ChunkX, a_ChunkZ)
	end
end

--- Tasks are only recorded; the test pumps them with PumpScheduledTasks().
function World:ScheduleTask(a_DelayTicks, a_Fn)
	Scheduled[#Scheduled + 1] = {Fn = a_Fn, Delay = a_DelayTicks}
end

function World:GetSpawnX() return 8 end
function World:GetSpawnZ() return 8 end

cRoot =
{
	Get = function()
		return {GetDefaultWorld = function() return World end}
	end,
}


-- ---------------------------------------------------------------------------
-- Log capture
-- ---------------------------------------------------------------------------

local LogLines = {}
LOG = function(a_Message)
	LogLines[#LogLines + 1] = tostring(a_Message)
end


-- ---------------------------------------------------------------------------
-- Load the plugin under test
-- ---------------------------------------------------------------------------

local ScriptPath = (arg and arg[0]) or "tests/decay_test.lua"
local ScriptDir = ScriptPath:match("^(.*)[/\\][^/\\]*$") or "."
local PluginDir = ScriptDir .. "/.."

FLD_Config =
{
	Enabled             = true,
	MaxDistance         = 6,
	MaxScan             = 4096,
	MaxRadius           = 32,
	DropItems           = true,
	DecayPlacedLeaves   = false,
	ClearNativeCheckBit = true,
	Debug               = false,
	Gradual             = false,
	DecayIntervalTicks  = 1,
	LeavesPerBatch      = 1,
	CleanFloatingVines  = true,
	EnableOnPlayerBreak = true,
	EnableOnExplosion   = false,
	ExplosionRadiusBoost = 2,
	ExplosionMaxRadius  = 8,
}
FLD_Busy = {}
FLD_Pending = {}
FLD_Stats =
{
	Passes          = 0,
	LeavesQueued    = 0,
	LeavesDropped   = 0,
	LeavesCancelled = 0,
	LeavesScanned   = 0,
	Aborts          = 0,
}

dofile(PluginDir .. "/decay.lua")
dofile(PluginDir .. "/selftest.lua")


-- ---------------------------------------------------------------------------
-- Tiny assertion helpers
-- ---------------------------------------------------------------------------

local Passed = 0
local Failed = 0

local function Check(a_Name, a_Ok, a_Detail)
	if a_Ok then
		Passed = Passed + 1
		print(string.format("PASS: %s%s", a_Name, a_Detail and (" (" .. a_Detail .. ")") or ""))
	else
		Failed = Failed + 1
		print(string.format("FAIL: %s%s", a_Name, a_Detail and (" (" .. a_Detail .. ")") or ""))
	end
end

local function SetBlock(a_X, a_Y, a_Z, a_Type, a_Meta)
	World:SetBlock(Vector3i(a_X, a_Y, a_Z), a_Type, a_Meta)
end

local function GetBlock(a_X, a_Y, a_Z)
	return select(2, World:GetBlockInfo(Vector3i(a_X, a_Y, a_Z)))
end

local function CountLeaves(a_X1, a_Y1, a_Z1, a_X2, a_Y2, a_Z2)
	local Count = 0
	for Y = a_Y1, a_Y2 do
		for Z = a_Z1, a_Z2 do
			for X = a_X1, a_X2 do
				if FLD_IsLeaf(GetBlock(X, Y, Z)) then
					Count = Count + 1
				end
			end
		end
	end
	return Count
end


-- ---------------------------------------------------------------------------
-- 1) the shipped in-game self-test
-- ---------------------------------------------------------------------------

ResetWorld()
LogLines = {}
FLD_HandleSelfTest({})

local SawSummary = false
for _, Line in ipairs(LogLines) do
	local PassName = Line:match("selftest PASS: ([^(]+)")
	if (PassName ~= nil) then
		Check("in-game selftest: " .. PassName:gsub("%s+$", ""), true)
	end
	local FailName = Line:match("selftest FAIL: ([^(]+)")
	if (FailName ~= nil) then
		Check("in-game selftest: " .. FailName:gsub("%s+$", ""), false, Line)
	end
	local Done, Total = Line:match("selftest finished: (%d+)/(%d+) passed")
	if (Done ~= nil) then
		SawSummary = true
		Check("in-game selftest summary", Done == Total, Done .. "/" .. Total)
	end
end
Check("in-game selftest produced a summary", SawSummary)


-- ---------------------------------------------------------------------------
-- 2) player-placed (persistent) leaves
-- ---------------------------------------------------------------------------

local function StageTwoLeaves()
	ResetWorld()
	SetBlock(100, 100, 100, E_BLOCK_LOG, 0)
	SetBlock(101, 100, 100, E_BLOCK_LEAVES, 4)  -- player-placed
	SetBlock(99, 100, 100, E_BLOCK_LEAVES, 0)   -- natural
	SetBlock(100, 100, 100, E_BLOCK_AIR, 0)     -- the log is gone
end

StageTwoLeaves()
local Dropped = FLD_ProcessRemovedLog(World, 100, 100, 100)
Check("player-placed leaves are kept", FLD_IsLeaf(GetBlock(101, 100, 100)),
	"block type " .. tostring(GetBlock(101, 100, 100)))
Check("natural orphaned leaves are dropped", GetBlock(99, 100, 100) == E_BLOCK_AIR,
	"block type " .. tostring(GetBlock(99, 100, 100)))
Check("only the natural leaf counted", Dropped == 1, "dropped " .. tostring(Dropped))

StageTwoLeaves()
FLD_Config.DecayPlacedLeaves = true
Dropped = FLD_ProcessRemovedLog(World, 100, 100, 100)
Check("DecayPlacedLeaves=true drops them too", Dropped == 2, "dropped " .. tostring(Dropped))
FLD_Config.DecayPlacedLeaves = false


-- ---------------------------------------------------------------------------
-- 3) DropItems=false
-- ---------------------------------------------------------------------------

StageTwoLeaves()
Drops = {}
FLD_Config.DropItems = false
Dropped = FLD_ProcessRemovedLog(World, 100, 100, 100)
Check("DropItems=false removes the block", GetBlock(99, 100, 100) == E_BLOCK_AIR)
Check("DropItems=false still reports the dropped leaf", Dropped == 1, "dropped " .. tostring(Dropped))
Check("DropItems=false spawns no pickups", #Drops == 0, #Drops .. " pickups")
FLD_Config.DropItems = true


-- ---------------------------------------------------------------------------
-- 4) an untouched tree must not lose anything
-- ---------------------------------------------------------------------------

ResetWorld()
-- A trunk with a canopy around its top; break a middle log, nothing may be orphaned.
for Y = 100, 104 do
	SetBlock(200, Y, 200, E_BLOCK_LOG, 0)
end
for dx = -1, 1 do
	for dz = -1, 1 do
		if (dx ~= 0) or (dz ~= 0) then
			SetBlock(200 + dx, 103, 200 + dz, E_BLOCK_LEAVES, 0)
			SetBlock(200 + dx, 104, 200 + dz, E_BLOCK_LEAVES, 0)
		end
	end
end
SetBlock(200, 102, 200, E_BLOCK_AIR, 0)
Dropped = FLD_ProcessRemovedLog(World, 200, 102, 200)
local Canopy = CountLeaves(199, 103, 199, 201, 104, 201)
Check("removing an inner log keeps the canopy", (Dropped == 0) and (Canopy == 16),
	"dropped " .. tostring(Dropped) .. ", " .. Canopy .. " leaves")


-- ---------------------------------------------------------------------------
-- 5) safety valves
-- ---------------------------------------------------------------------------

ResetWorld()
for i = 1, 20 do
	SetBlock(300 + i, 100, 300, E_BLOCK_LEAVES, 0)
end
SetBlock(300, 100, 300, E_BLOCK_LOG, 0)
SetBlock(301, 100, 300, E_BLOCK_LEAVES, 0)
SetBlock(300, 100, 300, E_BLOCK_AIR, 0)
FLD_Config.MaxScan = 4
local Result, Reason = FLD_ProcessRemovedLog(World, 300, 100, 300)
Check("MaxScan aborts a huge component", (Result == nil) and (Reason == "too many leaves"), tostring(Reason))
FLD_Config.MaxScan = 4096

ResetWorld()
SetBlock(400, 100, 400, E_BLOCK_LOG, 0)
SetBlock(401, 100, 400, E_BLOCK_LEAVES, 0)
SetBlock(400, 100, 400, E_BLOCK_AIR, 0)
InvalidAt = "402,100,400"   -- the BFS will walk into this unloaded block
Result, Reason = FLD_ProcessRemovedLog(World, 400, 100, 400)
Check("unloaded chunks abort the pass", (Result == nil) and (Reason == "unloaded chunk"), tostring(Reason))
InvalidAt = nil


-- ---------------------------------------------------------------------------
-- 6) gradual mode
-- ---------------------------------------------------------------------------

StageTwoLeaves()
Drops = {}
Scheduled = {}
FLD_Config.Gradual = true
FLD_Config.DecayIntervalTicks = 1
FLD_Config.LeavesPerBatch = 1

Dropped = FLD_ProcessRemovedLog(World, 100, 100, 100)
Check("gradual mode reports the queued leaves", Dropped == 1, "queued " .. tostring(Dropped))
Check("gradual mode does not drop inside the hook", GetBlock(99, 100, 100) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(99, 100, 100)))
Check("gradual mode scheduled a task", #Scheduled == 1, #Scheduled .. " tasks")

local Rounds = PumpScheduledTasks(50)
Check("gradual mode drains the queue", GetBlock(99, 100, 100) == E_BLOCK_AIR,
	"block type " .. tostring(GetBlock(99, 100, 100)))
Check("gradual mode removes one leaf per batch", Rounds == 1, Rounds .. " batches")
Check("gradual mode leaves nothing scheduled", #Scheduled == 0, #Scheduled .. " tasks")

-- A batch larger than the queue still drains everything in one scheduled call.
StageTwoLeaves()
Scheduled = {}
Drops = {}
FLD_Config.LeavesPerBatch = 100
FLD_ProcessRemovedLog(World, 100, 100, 100)
PumpScheduledTasks(50)
Check("gradual mode honours a large batch", GetBlock(99, 100, 100) == E_BLOCK_AIR)
Check("gradual mode keeps dropping until empty", #Scheduled == 0, #Scheduled .. " tasks")

-- Leaves that disappear while they sit in the queue must not be dropped twice.
StageTwoLeaves()
Scheduled = {}
Drops = {}
FLD_Config.LeavesPerBatch = 1
FLD_ProcessRemovedLog(World, 100, 100, 100)
SetBlock(99, 100, 100, E_BLOCK_AIR, 0)   -- someone else removed it first
PumpScheduledTasks(50)
Check("gradual mode never double-drops a leaf", #Drops == 0, #Drops .. " pickups")

FLD_Config.Gradual = false
FLD_Config.LeavesPerBatch = 1


-- ---------------------------------------------------------------------------
-- 7) vines left floating by the decayed canopy
-- ---------------------------------------------------------------------------

-- A leaf that is orphaned by the removed log, with a meta-0 vine hanging under it.  The
-- vine is only held up by the leaf (leaves are "solid" for vine attachment), so Cuberite
-- itself leaves it floating; the plugin has to clean it up.
ResetWorld()
SetBlock(10, 12, 10, E_BLOCK_LOG, 0)
SetBlock(11, 12, 10, E_BLOCK_LEAVES, 0)
SetBlock(11, 11, 10, E_BLOCK_VINES, 0)
SetBlock(10, 12, 10, E_BLOCK_AIR, 0)
Dropped = FLD_ProcessRemovedLog(World, 10, 12, 10)
Check("orphaned leaf is dropped", (GetBlock(11, 12, 10) == E_BLOCK_AIR) and (Dropped == 1),
	"block type " .. tostring(GetBlock(11, 12, 10)) .. ", dropped " .. tostring(Dropped))
Check("meta-0 vine under the leaf is cleaned up", GetBlock(11, 11, 10) == E_BLOCK_AIR,
	"block type " .. tostring(GetBlock(11, 11, 10)))

-- A vine whose meta still claims an attachable side must survive.
ResetWorld()
SetBlock(20, 12, 20, E_BLOCK_LOG, 0)
SetBlock(21, 12, 20, E_BLOCK_LEAVES, 0)
SetBlock(21, 11, 20, E_BLOCK_VINES, 1)   -- claims the south side
SetBlock(21, 11, 21, E_BLOCK_STONE, 0)   -- ...which is a stone block
SetBlock(20, 12, 20, E_BLOCK_AIR, 0)
FLD_ProcessRemovedLog(World, 20, 12, 20)
Check("vine with a surviving side attachment is kept", GetBlock(21, 11, 20) == E_BLOCK_VINES,
	"block type " .. tostring(GetBlock(21, 11, 20)))

-- A chain of meta-0 vines is cleaned up all the way down.
ResetWorld()
SetBlock(30, 12, 30, E_BLOCK_LOG, 0)
SetBlock(31, 12, 30, E_BLOCK_LEAVES, 0)
SetBlock(31, 11, 30, E_BLOCK_VINES, 0)
SetBlock(31, 10, 30, E_BLOCK_VINES, 0)
SetBlock(31,  9, 30, E_BLOCK_VINES, 0)
SetBlock(30, 12, 30, E_BLOCK_AIR, 0)
FLD_ProcessRemovedLog(World, 30, 12, 30)
Check("a hanging vine chain is cleaned up", (GetBlock(31, 11, 30) == E_BLOCK_AIR)
	and (GetBlock(31, 10, 30) == E_BLOCK_AIR) and (GetBlock(31, 9, 30) == E_BLOCK_AIR),
	"vine types " .. tostring(GetBlock(31, 11, 30)) .. "/" .. tostring(GetBlock(31, 10, 30))
	.. "/" .. tostring(GetBlock(31, 9, 30)))

-- With the cleanup turned off the vine must be left alone.
ResetWorld()
SetBlock(40, 12, 40, E_BLOCK_LOG, 0)
SetBlock(41, 12, 40, E_BLOCK_LEAVES, 0)
SetBlock(41, 11, 40, E_BLOCK_VINES, 0)
SetBlock(40, 12, 40, E_BLOCK_AIR, 0)
FLD_Config.CleanFloatingVines = false
Dropped = FLD_ProcessRemovedLog(World, 40, 12, 40)
Check("CleanFloatingVines=false still drops the leaf",
	(GetBlock(41, 12, 40) == E_BLOCK_AIR) and (Dropped == 1),
	"block type " .. tostring(GetBlock(41, 12, 40)) .. ", dropped " .. tostring(Dropped))
Check("CleanFloatingVines=false keeps the vine", GetBlock(41, 11, 40) == E_BLOCK_VINES,
	"block type " .. tostring(GetBlock(41, 11, 40)))
FLD_Config.CleanFloatingVines = true


-- ---------------------------------------------------------------------------
-- 8) a log placed back inside the decay window cancels the queued leaves
-- ---------------------------------------------------------------------------

ResetWorld()
Scheduled = {}
Drops = {}
FLD_Stats.LeavesCancelled = 0
FLD_Config.Gradual = true
FLD_Config.DecayIntervalTicks = 1
FLD_Config.LeavesPerBatch = 1

SetBlock(50, 12, 50, E_BLOCK_LOG, 0)
SetBlock(51, 12, 50, E_BLOCK_LEAVES, 0)
SetBlock(52, 12, 50, E_BLOCK_LEAVES, 0)
SetBlock(50, 12, 50, E_BLOCK_AIR, 0)
Dropped = FLD_ProcessRemovedLog(World, 50, 12, 50)
Check("both orphaned leaves are queued", Dropped == 2, "queued " .. tostring(Dropped))

-- Put the log back before the queue drains.
SetBlock(50, 12, 50, E_BLOCK_LOG, 0)
FLD_ProcessPlacedLog(World, 50, 12, 50)
PumpScheduledTasks(50)
Check("placing the log back keeps the near leaf", GetBlock(51, 12, 50) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(51, 12, 50)))
Check("placing the log back keeps the far leaf", GetBlock(52, 12, 50) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(52, 12, 50)))
Check("cancelled leaves are counted", FLD_Stats.LeavesCancelled == 2,
	tostring(FLD_Stats.LeavesCancelled))
Check("nothing was dropped after cancelling", #Drops == 0, #Drops .. " pickups")

-- Only the reconnected component is cancelled; an unrelated queue entry still decays.
ResetWorld()
Scheduled = {}
Drops = {}
FLD_Config.LeavesPerBatch = 1
SetBlock(60, 12, 60, E_BLOCK_LOG, 0)
SetBlock(61, 12, 60, E_BLOCK_LEAVES, 0)
SetBlock(70, 12, 70, E_BLOCK_LOG, 0)
SetBlock(71, 12, 70, E_BLOCK_LEAVES, 0)
SetBlock(60, 12, 60, E_BLOCK_AIR, 0)
SetBlock(70, 12, 70, E_BLOCK_AIR, 0)
FLD_ProcessRemovedLog(World, 60, 12, 60)
FLD_ProcessRemovedLog(World, 70, 12, 70)
SetBlock(60, 12, 60, E_BLOCK_LOG, 0)
FLD_ProcessPlacedLog(World, 60, 12, 60)
PumpScheduledTasks(50)
Check("reconnected leaf survives", GetBlock(61, 12, 60) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(61, 12, 60)))
Check("unrelated queued leaf still decays", GetBlock(71, 12, 70) == E_BLOCK_AIR,
	"block type " .. tostring(GetBlock(71, 12, 70)))

-- A log placed when nothing is queued must be a no-op.
ResetWorld()
Scheduled = {}
SetBlock(80, 12, 80, E_BLOCK_LOG, 0)
Check("placing a log with an empty queue is a no-op", FLD_ProcessPlacedLog(World, 80, 12, 80) == 0)
Check("no task is scheduled for a no-op", #Scheduled == 0, #Scheduled .. " tasks")

FLD_Config.Gradual = false


-- ---------------------------------------------------------------------------
-- 9) merged canopies: two trees whose leaves form one connected component
-- ---------------------------------------------------------------------------

-- Log A - leaf chain 101..109 - log B.  Chopping A must leave the far end of the chain
-- standing, because it is still within 6 leaves steps of B.
ResetWorld()
Drops = {}
Scheduled = {}
SetBlock(100, 12, 100, E_BLOCK_LOG, 0)
for x = 101, 109 do
	SetBlock(x, 12, 100, E_BLOCK_LEAVES, 0)
end
SetBlock(110, 12, 100, E_BLOCK_LOG, 0)
SetBlock(111, 12, 100, E_BLOCK_LEAVES, 0)   -- the neighbour tree's own leaf
SetBlock(110, 13, 100, E_BLOCK_LEAVES, 0)   -- ... and one above its trunk

SetBlock(100, 12, 100, E_BLOCK_AIR, 0)      -- chop tree A
Dropped = FLD_ProcessRemovedLog(World, 100, 12, 100)
Check("merged canopy: only the leaves out of reach of the other tree drop", Dropped == 3,
	"dropped " .. tostring(Dropped))
Check("leaf 7 steps from the other trunk drops", GetBlock(103, 12, 100) == E_BLOCK_AIR,
	"block type " .. tostring(GetBlock(103, 12, 100)))
Check("leaf 6 steps from the other trunk survives", GetBlock(104, 12, 100) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(104, 12, 100)))
Check("the other tree's own leaves are untouched",
	(GetBlock(111, 12, 100) == E_BLOCK_LEAVES) and (GetBlock(110, 13, 100) == E_BLOCK_LEAVES),
	tostring(GetBlock(111, 12, 100)) .. "/" .. tostring(GetBlock(110, 13, 100)))

-- Once the second trunk falls too, the whole merged canopy has to go.
SetBlock(110, 12, 100, E_BLOCK_AIR, 0)
Dropped = FLD_ProcessRemovedLog(World, 110, 12, 100)
local Remaining = 0
for x = 100, 112 do
	for y = 11, 14 do
		if GetBlock(x, y, 100) == E_BLOCK_LEAVES then
			Remaining = Remaining + 1
		end
	end
end
Check("after both trunks fall the merged canopy is gone", Remaining == 0,
	Remaining .. " leaves left, dropped " .. tostring(Dropped))

-- Two 5x5 canopies merged sideways (trunks 4 apart, the canopies share the x = 202
-- column): chopping one trunk keeps every leaf the other trunk can still reach.
ResetWorld()
Drops = {}
SetBlock(200, 12, 200, E_BLOCK_LOG, 0)
SetBlock(204, 12, 200, E_BLOCK_LOG, 0)
for dx = -2, 2 do
	for dz = -2, 2 do
		if ((math.abs(dx) < 2) or (math.abs(dz) < 2)) and not ((dx == 0) and (dz == 0)) then
			SetBlock(200 + dx, 12, 200 + dz, E_BLOCK_LEAVES, 0)
			SetBlock(204 + dx, 12, 200 + dz, E_BLOCK_LEAVES, 0)
		end
	end
end
Check("merged sideways: the canopies are one component",
	(GetBlock(202, 12, 200) == E_BLOCK_LEAVES) and (GetBlock(198, 12, 200) == E_BLOCK_LEAVES))

SetBlock(200, 12, 200, E_BLOCK_AIR, 0)      -- chop the left trunk
Dropped = FLD_ProcessRemovedLog(World, 200, 12, 200)
Check("merged sideways: the leaf 2 steps from the right trunk survives",
	GetBlock(202, 12, 200) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(202, 12, 200)))
Check("merged sideways: the far left leaf drops", GetBlock(198, 12, 200) == E_BLOCK_AIR,
	"block type " .. tostring(GetBlock(198, 12, 200)))
local RightLeaves = 0
for dx = -2, 2 do
	for dz = -2, 2 do
		if GetBlock(204 + dx, 12, 200 + dz) == E_BLOCK_LEAVES then
			RightLeaves = RightLeaves + 1
		end
	end
end
Check("merged sideways: the neighbour's canopy is untouched", RightLeaves == 20,
	RightLeaves .. " right-tree leaves, dropped " .. tostring(Dropped))

-- A component that spreads past MaxRadius must abort instead of guessing.
ResetWorld()
SetBlock(300, 12, 400, E_BLOCK_LOG, 0)
for x = 301, 360 do
	SetBlock(x, 12, 400, E_BLOCK_LEAVES, 0)
end
SetBlock(300, 12, 400, E_BLOCK_AIR, 0)
local SavedRadius = FLD_Config.MaxRadius
FLD_Config.MaxRadius = 16
local RadiusResult, RadiusReason = FLD_ProcessRemovedLog(World, 300, 12, 400)
Check("a component spreading past MaxRadius aborts",
	(RadiusResult == nil) and (RadiusReason == "leaves spread too far"), tostring(RadiusReason))
Check("an aborted pass drops nothing", GetBlock(301, 12, 400) == E_BLOCK_LEAVES,
	"block type " .. tostring(GetBlock(301, 12, 400)))
FLD_Config.MaxRadius = SavedRadius


-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print("")
print(string.format("decay_test: %d passed, %d failed", Passed, Failed))
os.exit(Failed == 0 and 0 or 1)

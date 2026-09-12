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

-- selftest.lua
-- Console-only self-test for FastLeafDecay, bound as the console command "fldtest".
--
-- It builds two synthetic layouts high above the spawn chunk (out of the way of any real
-- terrain), runs the decay pass on them and checks the result against the expected one:
--
--   1. a full tree: removing the bottom log must leave the canopy alone, chopping the
--      rest of the trunk must take every leaves block with it;
--   2. a distance boundary: two logs separated by a chain of seven leaves.  After the
--      near log is removed, the leaf seven steps away from the far log must decay while
--      the one six steps away must survive (the vanilla limit is 6).
--
-- Results are printed to the server log; nothing is returned to the caller.
-- The spawn chunk is force-loaded with World:PrepareChunk(), so the test also works on a
-- freshly started server without any players online.


local FLD_SELFTEST_TREE_Y = 230
local FLD_SELFTEST_DISTANCE_Y = 205


--- Fills the inclusive block box with a_BlockType.
local function BuildBox(a_World, a_X1, a_Y1, a_Z1, a_X2, a_Y2, a_Z2, a_BlockType, a_Meta)
	for Y = a_Y1, a_Y2 do
		for Z = a_Z1, a_Z2 do
			for X = a_X1, a_X2 do
				a_World:SetBlock(Vector3i(X, Y, Z), a_BlockType, a_Meta)
			end
		end
	end
end


--- Counts the leaves blocks inside the inclusive block box.
local function CountLeaves(a_World, a_X1, a_Y1, a_Z1, a_X2, a_Y2, a_Z2)
	local Count = 0
	for Y = a_Y1, a_Y2 do
		for Z = a_Z1, a_Z2 do
			for X = a_X1, a_X2 do
				local IsValid, BlockType = a_World:GetBlockInfo(Vector3i(X, Y, Z))
				if IsValid and FLD_IsLeaf(BlockType) then
					Count = Count + 1
				end
			end
		end
	end
	return Count
end


--- Test 1: a complete tree.
local function TestTree(a_World, a_X, a_Y, a_Z)
	local Results = {}
	local function Check(a_Name, a_Ok, a_Detail)
		Results[#Results + 1] = {Name = a_Name, Ok = a_Ok, Detail = a_Detail}
	end

	BuildBox(a_World, a_X - 3, a_Y - 2, a_Z - 3, a_X + 3, a_Y + 10, a_Z + 3, E_BLOCK_AIR, 0)

	-- Canopy first, trunk afterwards, so the trunk column overwrites the leaves there.
	for dy = 2, 4 do
		for dx = -2, 2 do
			for dz = -2, 2 do
				if ((math.abs(dx) < 2) or (math.abs(dz) < 2)) and ((dx ~= 0) or (dz ~= 0)) then
					a_World:SetBlock(Vector3i(a_X + dx, a_Y + dy, a_Z + dz), E_BLOCK_LEAVES, 0)
				end
			end
		end
	end
	for dx = -1, 1 do
		for dz = -1, 1 do
			if (dx ~= 0) or (dz ~= 0) then
				a_World:SetBlock(Vector3i(a_X + dx, a_Y + 5, a_Z + dz), E_BLOCK_LEAVES, 0)
			end
		end
	end
	BuildBox(a_World, a_X, a_Y, a_Z, a_X, a_Y + 5, a_Z, E_BLOCK_LOG, 0)

	local Before = CountLeaves(a_World, a_X - 2, a_Y + 2, a_Z - 2, a_X + 2, a_Y + 5, a_Z + 2)
	Check("tree canopy built", Before == 68, Before .. " leaves (expected 68)")

	-- Removing the bottom log must not orphan anything.
	a_World:SetBlock(Vector3i(a_X, a_Y, a_Z), E_BLOCK_AIR, 0)
	local Dropped = FLD_ProcessRemovedLog(a_World, a_X, a_Y, a_Z)
	local AfterFirst = CountLeaves(a_World, a_X - 2, a_Y + 2, a_Z - 2, a_X + 2, a_Y + 5, a_Z + 2)
	Check("bottom log does not orphan the canopy",
		(Dropped == 0) and (AfterFirst == Before),
		"dropped " .. tostring(Dropped) .. ", " .. AfterFirst .. " leaves left")

	-- Chopping the rest of the trunk must drop the whole canopy on the last log.
	for Y = a_Y + 1, a_Y + 5 do
		a_World:SetBlock(Vector3i(a_X, Y, a_Z), E_BLOCK_AIR, 0)
		FLD_ProcessRemovedLog(a_World, a_X, Y, a_Z)
	end
	local After = CountLeaves(a_World, a_X - 2, a_Y + 2, a_Z - 2, a_X + 2, a_Y + 5, a_Z + 2)
	Check("chopped trunk drops the whole canopy", After == 0, After .. " leaves left")

	BuildBox(a_World, a_X - 3, a_Y - 2, a_Z - 3, a_X + 3, a_Y + 10, a_Z + 3, E_BLOCK_AIR, 0)
	return Results
end


--- Test 2: the 6-steps distance boundary.
local function TestDistance(a_World, a_X, a_Y, a_Z)
	local Results = {}
	local function Check(a_Name, a_Ok, a_Detail)
		Results[#Results + 1] = {Name = a_Name, Ok = a_Ok, Detail = a_Detail}
	end

	BuildBox(a_World, a_X - 1, a_Y - 2, a_Z - 1, a_X + 1, a_Y + 10, a_Z + 1, E_BLOCK_AIR, 0)

	-- Log A, seven leaves above it, log B on top of the chain.
	a_World:SetBlock(Vector3i(a_X, a_Y, a_Z), E_BLOCK_LOG, 0)
	for Y = a_Y + 1, a_Y + 7 do
		a_World:SetBlock(Vector3i(a_X, Y, a_Z), E_BLOCK_LEAVES, 0)
	end
	a_World:SetBlock(Vector3i(a_X, a_Y + 8, a_Z), E_BLOCK_LOG, 0)

	a_World:SetBlock(Vector3i(a_X, a_Y, a_Z), E_BLOCK_AIR, 0)
	local Dropped = FLD_ProcessRemovedLog(a_World, a_X, a_Y, a_Z)

	local _, Seven = a_World:GetBlockInfo(Vector3i(a_X, a_Y + 1, a_Z))
	local _, Six = a_World:GetBlockInfo(Vector3i(a_X, a_Y + 2, a_Z))
	local _, One = a_World:GetBlockInfo(Vector3i(a_X, a_Y + 7, a_Z))

	Check("leaf 7 steps from the far log decays", Seven == E_BLOCK_AIR, "block type " .. tostring(Seven))
	Check("leaf 6 steps from the far log survives", FLD_IsLeaf(Six), "block type " .. tostring(Six))
	Check("leaf next to the far log survives", FLD_IsLeaf(One), "block type " .. tostring(One))
	Check("exactly one leaf dropped", Dropped == 1, "dropped " .. tostring(Dropped))

	BuildBox(a_World, a_X - 1, a_Y - 2, a_Z - 1, a_X + 1, a_Y + 10, a_Z + 1, E_BLOCK_AIR, 0)
	return Results
end


--- Runs both layouts and reports the results to the log.
-- The measurements below compare block counts right after a decay pass, so the gradual
-- queue is switched off for the duration of the test and restored afterwards.
local function RunSelfTest(a_World, a_BaseX, a_BaseZ)
	local SavedGradual = FLD_Config.Gradual
	FLD_Config.Gradual = false

	local Results = {}
	local function Append(a_List)
		for _, Item in ipairs(a_List) do
			Results[#Results + 1] = Item
		end
	end
	Append(TestTree(a_World, a_BaseX, FLD_SELFTEST_TREE_Y, a_BaseZ))
	Append(TestDistance(a_World, a_BaseX, FLD_SELFTEST_DISTANCE_Y, a_BaseZ))

	FLD_Config.Gradual = SavedGradual

	local Failed = 0
	for _, Item in ipairs(Results) do
		if (not Item.Ok) then
			Failed = Failed + 1
		end
		LOG(string.format("[FastLeafDecay] selftest %s: %s (%s)",
			Item.Ok and "PASS" or "FAIL", Item.Name, Item.Detail or ""))
	end
	LOG(string.format("[FastLeafDecay] selftest finished: %d/%d passed", #Results - Failed, #Results))
end


--- Console command handler: "fldtest".
function FLD_HandleSelfTest(a_Split)
	local World = cRoot:Get():GetDefaultWorld()
	if (World == nil) then
		LOG("[FastLeafDecay] selftest: no default world")
		return true
	end

	-- Stay in the middle of the spawn chunk: chunks are loaded around the spawn, but
	-- crossing a chunk border could hit an unloaded area.
	local BaseX = math.floor(World:GetSpawnX() / 16) * 16 + 8
	local BaseZ = math.floor(World:GetSpawnZ() / 16) * 16 + 8
	local ChunkX = math.floor(BaseX / 16)
	local ChunkZ = math.floor(BaseZ / 16)

	-- A freshly started server with no players online may not have the spawn chunk loaded
	-- yet, so ask for it explicitly; the callback runs once it is available.
	LOG("[FastLeafDecay] selftest: preparing chunk " .. ChunkX .. " / " .. ChunkZ
		.. " (test area " .. BaseX .. " / " .. BaseZ .. ")")
	World:PrepareChunk(ChunkX, ChunkZ, function()
		local IsValid = World:GetBlockInfo(Vector3i(BaseX, FLD_SELFTEST_TREE_Y + 10, BaseZ))
		if (not IsValid) then
			LOG("[FastLeafDecay] selftest: test chunk is still not loaded, aborting")
			return
		end
		RunSelfTest(World, BaseX, BaseZ)
	end)
	return true
end

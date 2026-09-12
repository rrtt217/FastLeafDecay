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

-- main.lua
-- FastLeafDecay: plugin entry point - configuration, hooks and commands.
--
-- The actual decay pass lives in decay.lua; a console self-test lives in selftest.lua.

local PLUGIN = nil

-- Shared with decay.lua and selftest.lua.  All files of a plugin share one Lua state.
FLD_Config = nil
FLD_Busy = {}
-- Per-world gradual-decay queues: [World] = {Queue, Head, Survivors, Scheduled}
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


-- Values used when settings.ini is missing a key (or cannot be read at all).
local DEFAULT_CONFIG =
{
	-- [General]
	Enabled             = true,
	MaxDistance         = 6,
	MaxScan             = 4096,
	MaxRadius           = 32,
	DropItems           = true,
	DecayPlacedLeaves   = false,
	ClearNativeCheckBit = true,
	Debug               = false,
	Gradual             = true,
	DecayIntervalTicks  = 2,
	LeavesPerBatch      = 6,
	CleanFloatingVines  = true,

	-- [Features]
	EnableOnPlayerBreak  = true,
	EnableOnExplosion    = false,
	ExplosionRadiusBoost = 2,
	ExplosionMaxRadius   = 8,
}


--- Parses a human-written boolean ("true", "1", "yes", ...).  cIniFile:GetValueSetB() is
-- unreliable in this build, so the raw string is parsed here.
local function ParseBool(a_Value, a_Default)
	if (a_Value == nil) then
		return a_Default
	end
	local Value = string.lower(tostring(a_Value))
	if (Value == "1") or (Value == "true") or (Value == "yes") or (Value == "on") then
		return true
	end
	if (Value == "0") or (Value == "false") or (Value == "no") or (Value == "off") then
		return false
	end
	return a_Default
end


--- (Re)reads settings.ini and publishes the result as the global FLD_Config.
local function LoadConfig(a_Plugin)
	local Ini = cIniFile()
	local Path = a_Plugin:GetLocalFolder() .. "/settings.ini"
	if (not Ini:ReadFile(Path)) then
		LOG("[FastLeafDecay] cannot read " .. Path .. ", using built-in defaults")
	end

	-- cIniFile stores key names verbatim, so a line written as "Key = value" is stored
	-- under the name "Key " and a plain lookup of "Key" misses it.  Accept both spellings.
	local MissingMarker = "\1fastleafdecay-missing\1"
	local function RawValue(a_Group, a_Key, a_Default)
		local Value = Ini:GetValue(a_Group, a_Key, MissingMarker)
		if (Value ~= MissingMarker) then
			return Value
		end
		Value = Ini:GetValue(a_Group, a_Key .. " ", MissingMarker)
		if (Value ~= MissingMarker) then
			return Value
		end
		return a_Default
	end

	local function Bool(a_Group, a_Key)
		return ParseBool(RawValue(a_Group, a_Key, tostring(DEFAULT_CONFIG[a_Key])), DEFAULT_CONFIG[a_Key])
	end

	local function Num(a_Group, a_Key, a_Min, a_Max)
		local Value = tonumber(RawValue(a_Group, a_Key, tostring(DEFAULT_CONFIG[a_Key])))
		if (Value == nil) then
			Value = DEFAULT_CONFIG[a_Key]
		end
		Value = math.floor(Value)
		if (Value < a_Min) then
			Value = a_Min
		end
		if (Value > a_Max) then
			Value = a_Max
		end
		return Value
	end

	local Config =
	{
		Enabled             = Bool("General", "Enabled"),
		MaxDistance         = Num("General", "MaxDistance", 1, 32),
		MaxScan             = Num("General", "MaxScan", 64, 100000),
		-- Capped at 63: the traversal packs relative coordinates into integers.
		MaxRadius           = Num("General", "MaxRadius", 4, 63),
		DropItems           = Bool("General", "DropItems"),
		DecayPlacedLeaves   = Bool("General", "DecayPlacedLeaves"),
		ClearNativeCheckBit = Bool("General", "ClearNativeCheckBit"),
		Debug               = Bool("General", "Debug"),
		Gradual             = Bool("General", "Gradual"),
		DecayIntervalTicks  = Num("General", "DecayIntervalTicks", 1, 200),
		LeavesPerBatch      = Num("General", "LeavesPerBatch", 1, 1000),
		CleanFloatingVines  = Bool("General", "CleanFloatingVines"),

		EnableOnPlayerBreak  = Bool("Features", "EnableOnPlayerBreak"),
		EnableOnExplosion    = Bool("Features", "EnableOnExplosion"),
		ExplosionRadiusBoost = Num("Features", "ExplosionRadiusBoost", 0, 16),
		ExplosionMaxRadius   = Num("Features", "ExplosionMaxRadius", 1, 16),
	}

	FLD_Config = Config
	return Config
end


--- Bookkeeping shared by both hooks.
local function RecordResult(a_Dropped, a_Scanned, a_Reason)
	if (a_Dropped == nil) then
		FLD_Stats.Aborts = FLD_Stats.Aborts + 1
		if FLD_Config.Debug then
			LOG("[FastLeafDecay] decay pass skipped: " .. tostring(a_Reason))
		end
		return
	end
	FLD_Stats.Passes = FLD_Stats.Passes + 1
	FLD_Stats.LeavesQueued = FLD_Stats.LeavesQueued + a_Dropped
	FLD_Stats.LeavesScanned = FLD_Stats.LeavesScanned + (a_Scanned or 0)
	if FLD_Config.Debug and (a_Dropped > 0) then
		LOG("[FastLeafDecay] " .. a_Dropped .. " orphaned leaves (" .. tostring(a_Scanned) .. " scanned)")
	end
end


--- HOOK_PLAYER_BROKEN_BLOCK: the block is already gone, so this is the point at which its
-- neighbouring leaves may have become orphaned.
function FLD_OnPlayerBrokenBlock(a_Player, a_BlockX, a_BlockY, a_BlockZ, a_BlockFace, a_BlockType, a_BlockMeta)
	if (FLD_Config == nil) or (not FLD_Config.Enabled) or (not FLD_Config.EnableOnPlayerBreak) then
		return false
	end
	if (not FLD_IsLog(a_BlockType)) then
		return false
	end

	local World = a_Player:GetWorld()
	local Dropped, Scanned = FLD_ProcessRemovedLog(World, a_BlockX, a_BlockY, a_BlockZ)
	RecordResult(Dropped, Scanned)
	return false
end


--- HOOK_PLAYER_PLACED_BLOCK: putting a log back while leaves are still queued for gradual
-- decay must stop those leaves from being removed.
function FLD_OnPlayerPlacedBlock(a_Player, a_BlockX, a_BlockY, a_BlockZ, a_BlockType, a_BlockMeta)
	if (FLD_Config == nil) or (not FLD_Config.Enabled) or (not FLD_Config.Gradual) then
		return false
	end
	if (not FLD_IsLog(a_BlockType)) then
		return false
	end
	FLD_ProcessPlacedLog(a_Player:GetWorld(), a_BlockX, a_BlockY, a_BlockZ)
	return false
end


--- HOOK_EXPLODED: an explosion may have removed logs; the leaves in its blast area are
-- used as seeds.  Disabled by default ([Features] EnableOnExplosion).
function FLD_OnExploded(a_World, a_ExplosionSize, a_CanCauseFire, a_X, a_Y, a_Z, a_Source, a_SourceData)
	if (FLD_Config == nil) or (not FLD_Config.Enabled) or (not FLD_Config.EnableOnExplosion) then
		return false
	end

	local Dropped, Scanned = FLD_ProcessExplosion(a_World, a_X, a_Y, a_Z, a_ExplosionSize)
	RecordResult(Dropped, Scanned)
	return false
end


--- /fld [stats|reload]
function FLD_HandleCommand(a_Split, a_Player)
	local Sub = string.lower(a_Split[2] or "")

	if (Sub == "reload") then
		if (a_Player ~= nil) and (not a_Player:HasPermission("fastleafdecay.admin")) then
			a_Player:SendMessageFailure("你没有权限重载 FastLeafDecay 配置")
			return true
		end
		LoadConfig(PLUGIN)
		if (a_Player ~= nil) then
			a_Player:SendMessageSuccess("FastLeafDecay 配置已重载")
		end
		LOG("[FastLeafDecay] configuration reloaded")
		return true
	end

	if (Sub == "stats") then
		if (a_Player ~= nil) then
			a_Player:SendMessageInfo(string.format(
				"FastLeafDecay: %d 次腐烂扫描，共掉落 %d 个树叶（扫描 %d 个），被放回原木撤销 %d 个，跳过 %d 次",
				FLD_Stats.Passes, FLD_Stats.LeavesDropped, FLD_Stats.LeavesScanned,
				FLD_Stats.LeavesCancelled, FLD_Stats.Aborts))
		end
		return true
	end

	if (a_Player ~= nil) then
		a_Player:SendMessageInfo("FastLeafDecay 状态：" .. (FLD_Config.Enabled and "已启用" or "已禁用")
			.. "，原木判定距离 " .. FLD_Config.MaxDistance
			.. "，单次扫描上限 " .. FLD_Config.MaxScan
			.. "，掉落物 " .. (FLD_Config.DropItems and "开启" or "关闭")
			.. "，玩家破坏 " .. (FLD_Config.EnableOnPlayerBreak and "开启" or "关闭")
			.. "，爆炸 " .. (FLD_Config.EnableOnExplosion and "开启" or "关闭"))
		a_Player:SendMessageInfo("用法：/fld stats 查看统计，/fld reload 重载配置")
	end
	return true
end


function Initialize(Plugin)
	PLUGIN = Plugin
	Plugin:SetName("FastLeafDecay")
	Plugin:SetVersion(1)

	LoadConfig(Plugin)

	cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_BROKEN_BLOCK, FLD_OnPlayerBrokenBlock)
	cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_PLACED_BLOCK, FLD_OnPlayerPlacedBlock)
	cPluginManager:AddHook(cPluginManager.HOOK_EXPLODED,            FLD_OnExploded)

	-- Register the commands declared in Info.lua (/fld and the fldtest console command).
	dofile(cPluginManager:GetPluginsPath() .. "/InfoReg.lua")
	RegisterPluginInfoCommands()
	RegisterPluginInfoConsoleCommands()

	LOG("[FastLeafDecay] loaded: max distance " .. FLD_Config.MaxDistance
		.. ", player breaks " .. (FLD_Config.EnableOnPlayerBreak and "on" or "off")
		.. ", explosions " .. (FLD_Config.EnableOnExplosion and "on" or "off")
		.. ", gradual " .. (FLD_Config.Gradual and "on" or "off")
		.. " (" .. FLD_Config.LeavesPerBatch .. " leaves / " .. FLD_Config.DecayIntervalTicks .. " ticks)")

	return true
end


function OnDisable()
	LOG("[FastLeafDecay] disabled")
end

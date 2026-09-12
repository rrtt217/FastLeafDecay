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

-- Info.lua
-- Standard Cuberite plugin description (g_PluginInfo).

g_PluginInfo =
{
	Name = "FastLeafDecay",
	Version = "1",
	Date = "2026-09-11",
	Description = [[Makes the leaves left behind by a broken log disappear immediately instead of
waiting for Cuberite's per-block decay checks. When a log is removed, the whole connected
leaves component is walked once and the distance to the nearest remaining log is computed
for every leaves block at the same time; every leaves block that can no longer reach a log
within the vanilla limit (6 leaves blocks) is dropped in a single pass, with the usual
sapling / stick / apple drops.

Logs removed by a player are always handled; logs removed by an explosion can be handled
too ([General] EnableOnExplosion, off by default).]],
	Commands =
	{
		["/fld"] =
		{
			Permission = "fastleafdecay.info",
			HelpString = "显示 FastLeafDecay 状态；fld stats 查看统计；fld reload 重载配置（需要 fastleafdecay.admin）",
			Handler = FLD_HandleCommand,
		},
	},
	ConsoleCommands =
	{
		["fldtest"] =
		{
			HelpString = "运行 FastLeafDecay 自检：在出生点区块的高空中搭建合成树木并验证腐烂结果",
			Handler = FLD_HandleSelfTest,
			ParameterCombinations = {},
		},
	},
	Permissions =
	{
		["fastleafdecay.info"] =
		{
			Description = "允许使用 /fld 查看插件状态与统计",
			RecommendedGroups = { "Default", "Moderator", "Operator", "Admin" },
		},
		["fastleafdecay.admin"] =
		{
			Description = "允许使用 /fld reload 重载 FastLeafDecay 配置",
			RecommendedGroups = { "Operator", "Admin" },
		},
	},
}

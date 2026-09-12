# FastLeafDecay

[Cuberite](https://cuberite.org) 服务器的树叶快速腐烂插件：失去支撑的树叶分批
逐步清除，同时清理树冠消失后悬空的藤蔓。

[English](README.md)

## 特性

- **每根原木只扫一趟** —— 一次遍历整片连通树叶，用多源 BFS 同时算出每片树叶到最近原木的
  距离。存活规则与 Cuberite 自带的 `cBlockLeavesHandler` 一致（6 个树叶步内有原木），
  但方块读取次数少一个数量级。
- **渐进腐烂** —— 分批掉落，不再是整片树冠在一帧内瞬间消失。
- **清理悬空藤蔓** —— 树冠消失后失去支撑的藤蔓一并清除，包括 Cuberite 自己永远不会摧毁的
  meta 0 藤蔓。
- **原生掉落物** —— 树苗/木棍/苹果由服务器自身的方块处理器产生，`HOOK_BLOCK_TO_PICKUPS`
  照常生效。
- **安全阀** —— 组件过大或跨越未加载区块时直接放弃（不修改世界），交还原生腐烂。
- 可选支持爆炸移除的原木。

## 安装

1. 把 `FastLeafDecay` 文件夹放进服务器的 `Plugins/`；
2. 在服务器根目录 `settings.ini` 的 `[Plugins]` 段加上 `FastLeafDecay=1`；
3. 重启服务器（或重载插件）；
4. 可选：授予 `fastleafdecay.info`，例如
   `cRankManager:AddPermissionToGroup("fastleafdecay.info", "Default")`。

## 配置

`settings.ini`：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `Enabled` | true | 总开关 |
| `Gradual` | true | 分批掉落 |
| `DecayIntervalTicks` | 2 | 两批之间的间隔 tick |
| `LeavesPerBatch` | 6 | 每批掉落几片树叶 |
| `MaxDistance` | 6 | 仍算"有支撑"的最大树叶步数 |
| `MaxScan` | 4096 | 单次扫描超过这么多树叶就放弃 |
| `MaxRadius` | 32 | 扩散超过这个半径就放弃 |
| `DropItems` | true | 是否产生正常掉落物 |
| `DecayPlacedLeaves` | false | 是否也清理玩家放置的树叶 |
| `CleanFloatingVines` | true | 清理失去支撑的藤蔓 |
| `ClearNativeCheckBit` | true | 跳过原生重复的腐烂检查 |
| `EnableOnPlayerBreak` | true | 响应玩家破坏的原木 |
| `EnableOnExplosion` | false | 响应爆炸移除的原木 |
| `ExplosionRadiusBoost` / `ExplosionMaxRadius` | 2 / 8 | 爆炸扫描半径 |
| `Debug` | false | 每次腐烂打印一行日志 |

按默认值，68 片树叶的树冠约 1.1 秒掉完。

## 命令

| 命令 | |
| --- | --- |
| `/fld` | 状态（`fastleafdecay.info`） |
| `/fld stats` | 统计 |
| `/fld reload` | 重载 `settings.ini`（`fastleafdecay.admin`） |
| `fldtest`（控制台） | 服务器内自检 |

## 开发

```sh
cd Plugins/FastLeafDecay
lua tests/decay_test.lua        # 34 项离线测试（mock cWorld）
luajit tests/decay_test.lua     # Lua 5.1 兼容性（Cuberite 自带 Lua 5.1.4）
```

```sh
cd /path/to/Cuberite
luacheck Plugins/FastLeafDecay/
```

控制台 `fldtest` 会在运行中的服务器里做同样的检查：在出生点区块搭建两棵合成树并把
PASS/FAIL 写进日志。

## 许可

Apache License 2.0，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

参考了 [Cuberite](https://cuberite.org)（Copyright 2011-2025 Cuberite Contributors，
同为 Apache-2.0）：`NOTICE` 列出了所复刻行为的来源文件；仓库中没有逐字复制 Cuberite 源码。

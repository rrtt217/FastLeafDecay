# FastLeafDecay

Cuberite 插件：原木被破坏后，清除失去支撑的树叶（Fast Leaf Decay），支持**渐进式腐烂**，
并顺带修掉 Cuberite 遗留的**悬空藤蔓**。

## 结论（可行性）

**可行，而且单次判定开销比 Cuberite 自带实现更小。** 这不是"硬做"的功能：

- Cuberite 本身**已经实现**树叶腐烂（`src/Blocks/BlockLeaves.h`）：树叶方块在
  `OnUpdate()` 里做一次最多 6 步的 BFS，够不到原木就掉落。问题是它**逐块**执行，
  每块树叶都要读取一个 `13×13×13` 的区域（2197 次方块读取），而且检查被分散在
  多个 tick 的方块更新队列里，所以看起来"慢慢烂"。
- 本插件只做**一趟**：从一个刚被移除的原木（或爆炸中心）出发，遍历整片连通的树叶，
  再用一次多源 BFS 同时算出每个树叶到最近原木的距离。连 6 步内有原木的保留，
  其余进入掉落队列。连通性规则与原生完全一致，所以"哪些树叶会掉"与原生相同，
  只是读取次数少一个数量级，而且掉落节奏可控。

## 算法

```
原木被移除（HOOK_PLAYER_BROKEN_BLOCK）
   └─ 以它 6 个邻居中的树叶作为种子
        ├─ 阶段 1：BFS 遍历整片连通树叶
        │     每个方块只读一次（按坐标缓存）
        ├─ 阶段 2：多源 BFS（源 = 紧邻原木的树叶，距离 1）
        │     距离 ≤ MaxDistance(6) 的树叶存活，其余记为孤儿
        ├─ 阶段 3：孤儿树叶
        │     Gradual=false → 立刻 World:DropBlockAsPickups()
        │     Gradual=true  → 入队，按 DecayIntervalTicks 每批 LeavesPerBatch 个掉落
        │       （按遍历顺序，大致从断口向外扩散，观感像树冠逐层碎裂）
        ├─ 阶段 4：每掉一个树叶，顺带检查它四周的藤蔓
        │     失去支撑的藤蔓一并清除（见"悬空藤蔓"）
        └─ 阶段 5：队列清空后，清掉存活树叶的"待检查"位(meta 0x08)
              → 省掉原生处理器接下来对它们各做一次 13³ 扫描
```

掉落走的是正常方块处理器（`DropBlockAsPickups`），所以树苗/木棍/苹果掉落与
`HOOK_BLOCK_TO_PICKUPS` 都保持原样；该调用最终走 `cChunk::SetBlock`，
方块更新（邻居通知）也会正常入队。

## 悬空藤蔓（已修）

**不是"没方块更新"** —— 方块更新确实发生了，是 Cuberite 藤蔓处理器自己的一个死角：

```cpp
// src/Blocks/BlockVines.h :: GetMaxMeta()
NIBBLETYPE Common = a_CurrentMeta & MaxMeta;
if (Common != a_CurrentMeta) {
    bool HasTop = IsBlockAttachable(blockAbove);
    if ((Common == 0) && !HasTop) return VINE_LOST_SUPPORT;   // 摧毁
    return Common;
}
return VINE_UNCHANGED;   // ← meta 已经是 0 时永远走这里
```

树叶是"固体"（`cBlockInfo:IsSolid(leaves) == true`），所以藤蔓挂在树叶下方是合法的。
当藤蔓失去侧面附着、仅靠上方树叶支撑时，meta 会被降为 **0**；此后
`Common == a_CurrentMeta == 0`，函数直接返回 `VINE_UNCHANGED`，
**再也不会走到摧毁分支**——树叶消失后藤蔓就永远悬空了。

插件侧的绕行：每掉一个树叶，就检查它 6 个邻居里的藤蔓，用同样的规则
（侧面 meta 位 + 上方可附着方块 + 上方藤蔓 meta）判断是否还有支撑，
没有就移除（与原生一致：直接消失，不掉落物）；移除后再顺着链条往下检查，
所以整串悬空藤蔓会一起清掉。开关：`CleanFloatingVines`。

## 开销

| 场景 | 工作量 |
| --- | --- |
| 破坏一个原木，周围没有树叶 | 6 次 `GetBlockInfo`（快速返回） |
| 破坏一个原木，普通树木（约 100–200 片树叶） | 组件内每个方块 1 次读取 + 每个树叶 6 次邻居判断（命中缓存） |
| 每掉落一片树叶 | 1 次 `DropBlockAsPickups` + 6 次邻居读取（藤蔓检查） |
| 病态情况（玩家搭的巨大树叶块） | `MaxScan` / `MaxRadius` 触发**中止**，不修改世界，交还给原生慢速腐烂 |

两个安全阀（`MaxScan` 默认 4096，`MaxRadius` 默认 32）保证单次事件的开销有硬上限；
块所在 chunk 未加载时同样中止，避免误判。渐进模式把掉落摊到多个 tick，避免一帧内
几百次方块更新的尖峰。

## 文件

- `Info.lua` — 插件元数据、`/fld` 命令、`fldtest` 控制台命令、权限声明
- `main.lua` — 配置读取、钩子注册、命令实现、统计
- `decay.lua` — 核心算法、渐进队列、藤蔓清理
- `selftest.lua` — 控制台自检（`fldtest`）
- `settings.ini` — 配置
- `tests/decay_test.lua` — 纯 Lua 离线单元测试（mock cWorld）

## 配置（settings.ini）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `[General] Enabled` | true | 总开关 |
| `MaxDistance` | 6 | 树叶距原木的最大"树叶步数"，与原生 `LEAVES_CHECK_DISTANCE` 一致 |
| `MaxScan` | 4096 | 单次扫描的树叶上限，超出则中止 |
| `MaxRadius` | 32 | 距被破坏原木的最大扩散半径（4–63），超出则中止 |
| `DropItems` | true | 是否产生正常掉落物 |
| `DecayPlacedLeaves` | false | 是否也清理玩家放置的树叶（meta 0x04） |
| `ClearNativeCheckBit` | true | 清除存活树叶的 meta 0x08，省掉原生重复检查 |
| **`Gradual`** | **true** | 渐进式腐烂；false = 同一 tick 内全部掉落 |
| **`DecayIntervalTicks`** | **2** | 渐进模式：两批之间的间隔 tick（1 tick = 50 ms） |
| **`LeavesPerBatch`** | **6** | 渐进模式：每批掉落几片树叶 |
| **`CleanFloatingVines`** | **true** | 清理因树叶消失而失去支撑的藤蔓 |
| `Debug` | false | 每次腐烂打印一行日志 |
| `[Features] EnableOnPlayerBreak` | true | 响应玩家破坏原木 |
| `EnableOnExplosion` | false | 响应爆炸移除的原木（会额外扫描爆炸区域） |
| `ExplosionRadiusBoost` | 2 | 爆炸扫描半径 = 爆炸强度 + 该值 |
| `ExplosionMaxRadius` | 8 | 爆炸扫描半径硬上限 |

按默认值，一片 68 个树叶的树冠大约 **1.1 秒**内分批掉完（6 片 / 2 tick）。

## 命令

- `/fld` — 显示状态（权限 `fastleafdecay.info`）
- `/fld stats` — 统计腐烂次数 / 已掉落树叶数 / 扫描数 / 中止次数
- `/fld reload` — 重载 `settings.ini`（权限 `fastleafdecay.admin`）
- 控制台 `fldtest` — 在出生点区块高空搭建合成树木并验证腐烂结果（见下）

## 测试

```sh
# 纯 Lua 离线单元测试（mock cWorld，覆盖算法 + 自检 + 边界 + 渐进队列 + 藤蔓 + 安全阀）
cd Plugins/FastLeafDecay
lua tests/decay_test.lua        # 34 checks
luajit tests/decay_test.lua     # Lua 5.1 兼容性（Cuberite 自带 Lua 5.1.4）

# 静态检查
cd /home/david/Cuberite
luacheck Plugins/FastLeafDecay/

# 服务器内自检（会先用 World:PrepareChunk() 强制加载出生点区块）
#   控制台: fldtest
```

## 验证结果

| 项目 | 结果 |
| --- | --- |
| `luacheck Plugins/FastLeafDecay/` | 0 warnings / 0 errors（含 tests/） |
| `cuberite_check` | 无未知类/方法/钩子 |
| 离线单元测试（Lua 5.4 与 LuaJIT 5.1） | 34/34 通过 |
| 服务器内 `fldtest` | **7/7 通过**：树冠 68 片、砍底部原木不掉叶、砍完整棵树后树冠清零、距离 6 存活 / 距离 7 掉落的边界 |
| 端到端 · 渐进腐烂（mineflayer 机器人真实砍树） | 砍掉最后一段原木后：`t+0.00s 48 片 → t+0.25s 23 片 → t+0.50s 0 片`，分批碎裂而非瞬间消失 |
| 端到端 · 藤蔓 | 同一棵树：砍树干时挂在原木上的藤蔓正常掉落；挂在树叶下方、meta 已被降为 0 的藤蔓在树叶腐烂时被插件清除，最终 `vines=0` |

## 已知限制

- 只处理**玩家破坏**（`HOOK_PLAYER_BROKEN_BLOCK`）与**爆炸**（`HOOK_EXPLODED`，默认关闭）
  造成的原木消失；活塞推动等其他途径仍走原生腐烂。
- 组件过大 / 跨越未加载区块时主动放弃（不修改世界），由原生逻辑接管。
- 掉落物由 `World:DropBlockAsPickups()` 产生，因此与原生腐烂/徒手破坏完全一致
  （无工具，故没有精准采集/时运加成——这与原生树叶腐烂相同）。
- 藤蔓清理只针对**被插件移除的树叶的邻居**；其它原因（例如玩家挖掉一整面墙）
  造成的悬空藤蔓仍由 Cuberite 原生逻辑负责，其中 meta 0 的那一类同样会残留
  （服务器自身的 bug，需要上游修复 `cBlockVinesHandler::GetMaxMeta`）。
- 所有方块读写使用向量重载（`GetBlockInfo(Vector3i)` 等），避免 3 数字重载的
  deprecation 警告与堆栈打印。

## 安装

1. 把整个 `FastLeafDecay` 文件夹放进服务器的 `Plugins/` 目录；
2. 在服务器根目录的 `settings.ini` 的 `[Plugins]` 段加上 `FastLeafDecay=1`；
3. 重启服务器（或重载插件）；
4. 可选：把 `fastleafdecay.info` 授权给你想让其使用 `/fld` 的组，
   例如在控制台执行 `rank add ...`，或在插件里用
   `cRankManager:AddPermissionToGroup("fastleafdecay.info", "Default")`。

## 许可

本项目采用 **Apache License 2.0**，见 [LICENSE](LICENSE)。

实现过程中阅读并复刻了 **Cuberite**（<https://cuberite.org>，
Copyright 2011-2025 Cuberite Contributors，同样为 Apache License 2.0）的行为，
具体复刻了哪些文件、哪些规则，见 [NOTICE](NOTICE)：

- `src/Blocks/BlockLeaves.h` —— 树叶存活距离（`LEAVES_CHECK_DISTANCE = 6`）、
  玩家放置树叶的 meta 0x04 位、"待检查"meta 0x08 位、掉落概率；
- `src/Blocks/BlockVines.h` —— 藤蔓的可附着判定与支撑规则（用于清理悬空藤蔓）；
- `src/Chunk.cpp` / `src/Blocks/BlockHandler.cpp` —— 方块更新语义（用于确认
  移除树叶会唤醒藤蔓等依赖方块）。

仓库中没有逐字复制 Cuberite 的源码，只是用 Lua 重新实现了上述行为。

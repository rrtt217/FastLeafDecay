# FastLeafDecay

Fast leaf decay for the [Cuberite](https://cuberite.org) Minecraft server: batches of
orphaned leaves are removed progressively, and vines left floating by the decayed canopy
are cleaned up.

[中文说明](README.zh-CN.md)

## Features

- **One pass per broken log** — walks the connected leaves component once and computes the
  distance to the nearest log for every leaf at the same time (multi-source BFS). Survival
  rule matches Cuberite's own `cBlockLeavesHandler` (a log within 6 leaves steps), with far
  fewer block reads.
- **Gradual removal** — leaves go out in batches instead of vanishing in one frame, and
  **placing a log back inside that window cancels the pending removal** of the leaves it
  reaches again.
- **Floating vine cleanup** — vines that lose their support when the canopy disappears are
  removed, including the meta-0 vines Cuberite itself never destroys.
- **Vanilla drops** — saplings, sticks and apples come from the server's own block handler,
  so `HOOK_BLOCK_TO_PICKUPS` still applies.
- **Safety valves** — oversized or cross-chunk passes abort without touching the world and
  leave the work to native decay.
- Optional explosion support.

## Install

1. Copy the `FastLeafDecay` folder into the server's `Plugins/`.
2. Add `FastLeafDecay=1` to `[Plugins]` in the server's `settings.ini`.
3. Restart the server (or reload plugins).
4. Optional: grant `fastleafdecay.info`, e.g.
   `cRankManager:AddPermissionToGroup("fastleafdecay.info", "Default")`.

## Configuration

`settings.ini` (write `Key=Value` without spaces — Cuberite stores key names verbatim,
so `Key = Value` reads as the key `"Key "`; the plugin also accepts that spelling):

| Key | Default | Meaning |
| --- | --- | --- |
| `Enabled` | true | master switch |
| `Gradual` | true | remove leaves in batches |
| `DecayIntervalTicks` | 2 | ticks between batches |
| `LeavesPerBatch` | 6 | leaves per batch |
| `MaxDistance` | 6 | leaves steps that still count as supported |
| `MaxScan` | 4096 | abort a pass visiting more leaves |
| `MaxRadius` | 32 | abort a pass spreading farther |
| `DropItems` | true | spawn the normal drops |
| `DecayPlacedLeaves` | false | also remove player-placed leaves |
| `CleanFloatingVines` | true | remove vines that lost their support |
| `ClearNativeCheckBit` | true | skip Cuberite's redundant decay re-checks |
| `EnableOnPlayerBreak` | true | react to player-broken logs |
| `EnableOnExplosion` | false | react to logs removed by explosions |
| `ExplosionRadiusBoost` / `ExplosionMaxRadius` | 2 / 8 | explosion scan radius |
| `Debug` | false | log every decay pass |

With the defaults a 68-leaf canopy clears in about 1.1 s.

## Commands

| Command | |
| --- | --- |
| `/fld` | status (`fastleafdecay.info`) |
| `/fld stats` | counters |
| `/fld reload` | reload `settings.ini` (`fastleafdecay.admin`) |
| `fldtest` (console) | self-test inside a live server |

## Development

```sh
cd Plugins/FastLeafDecay
lua tests/decay_test.lua        # 34 offline checks against a mock cWorld
luajit tests/decay_test.lua     # Lua 5.1 compatibility (Cuberite ships Lua 5.1.4)
```

```sh
cd /path/to/Cuberite
luacheck Plugins/FastLeafDecay/
```

The console command `fldtest` runs the equivalent checks in a running server: it builds two
synthetic trees in the spawn chunk and reports PASS/FAIL to the log.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Derived from [Cuberite](https://cuberite.org), Copyright 2011-2025 Cuberite Contributors,
also licensed under Apache-2.0. `NOTICE` lists the Cuberite files whose behaviour was
mirrored; no Cuberite source is copied verbatim.

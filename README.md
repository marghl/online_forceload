# Online Forceload

`online_forceload:forceload` keeps precisely the 16×16×16 mapblock containing
it active while its owner is connected. Each player has a configurable quota.
Only one loader may exist in a mapblock.

## Configuration

Add settings to `minetest.conf`, for example:

```ini
online_forceload.max_blocks_per_player = 5
online_forceload.source_url = https://example.invalid/online_forceload
max_forceloaded_blocks = 200
```

For a public server, replace the example URL with a public download location
for the exact version running on the server. Players can retrieve that URL with
`/online_forceload_source`.

Setting the per-player quota to `0` disables placement and hides the block from
the creative inventory. The engine-wide `max_forceloaded_blocks` limit must be
large enough for all active players and other mods.

## Commands

- `/online_forceloads` lists your loaders and their state.
- `/online_forceload_source` provides license, attribution, and the configured
  source download URL.

Punching a loader displays the exact boundary of its 16×16×16 mapblock for a
few seconds. `online_forceload.display_seconds` controls the duration.

## Origin and license

The implementation is based on the Forceload Block from Techage:
https://github.com/joe7575/techage

Original Techage code copyright © 2019–2025 Joachim Stolberg and Techage
contributors. This independent adaptation and its modifications are copyright
© 2026 marghl and OpenAI Codex contributors.

Code is licensed under GNU AGPL version 3 or later; see `LICENSE.txt` and
`NOTICE.md`. The block texture was generated specifically for this project
with OpenAI ImageGen and is made available under CC0 1.0. The boundary texture
`online_forceload_display.png` comes from Protector Redo by TenPlus1 and remains
under CC BY-SA 3.0; see `LICENSE-protector.txt` and `textures/LICENSE.txt`. No
Techage texture is included.

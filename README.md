# Online Forceload

`online_forceload:forceload` keeps precisely the 16×16×16 mapblock containing
it active while its owner is connected and has the `forceloader` privilege.
Each player has a configurable quota. Multiple loaders belonging to the same
or different owners may share a mapblock. The engine receives only one
forceload request per active mapblock.

## Configuration

Add settings to `minetest.conf`, for example:

```ini
online_forceload.max_blocks_per_player = 5
online_forceload.max_blocks_per_player_per_mapblock = 0
online_forceload.max_registered_blocks = 500
online_forceload.source_url = https://example.invalid/online_forceload
max_forceloaded_blocks = 200
```

For a public server, replace the example URL with a public download location
for the exact version running on the server. Players can retrieve that URL with
`/online_forceload_source`.

Setting the per-player quota to `0` disables placement and hides the block from
the creative inventory. A per-mapblock value of `0` allows a player to place
multiple loaders in one mapblock up to the general player quota; a positive
value adds a separate per-owner, per-mapblock cap. The registry limit includes
offline owners and rejects only new placements when reached; it never deletes
existing loaders. The engine-wide `max_forceloaded_blocks` limit remains the
server-wide active limit shared with other mods.

Grant `forceloader` directly or through a rank mod. With `xp_ranks`, for
example, add it to the Citizen privileges:

```ini
xp_ranks.privileges.citizen = forceloader
```

A loader activates only while its owner is online and still has this privilege.
Revoking it therefore disables the owner's existing loaders without deleting
their nodes or registrations.

## Commands

- `/online_forceloads` lists your loaders and their state.
- `/online_forceload_source` provides license, attribution, and the configured
  source download URL.
- `/online_forceload_admin stats` shows registered loaders and active mapblocks.
- `/online_forceload_admin list [player]` lists all or one player's loaders.
- `/online_forceload_admin remove (x,y,z)` removes a registration and its node.

The administration command requires the `server` privilege.

Punching a loader displays the exact boundary of its 16×16×16 mapblock for a
few seconds. `online_forceload.display_seconds` controls the duration.

Jumpdrive-compatible movers can relocate a loader through its `on_movenode`
callback. Its old transient forceload and registry position are replaced with
the destination state.

## Storage migration

Registrations are stored as one ModStorage record per mapblock. Position,
owner, and mapblock indexes are rebuilt in memory on startup. Registries from
the initial release are migrated automatically; configured limits do not
delete existing registrations during migration.

## Translation checks

Run the static locale validation from the mod directory:

```sh
python3 tests/check_locales.py
lua tests/test_runtime.lua
```

The checks cover catalog completeness and placeholders as well as registry
migration, privileges, shared mapblock activation, limits, and movement.
Translation quality still needs review by speakers of the respective languages.

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

-- Online Forceload
-- Copyright (C) 2019-2025 Joachim Stolberg and Techage contributors
-- Copyright (C) 2025 TenPlus1 (mapblock display code)
-- Copyright (C) 2026 marghl and OpenAI Codex contributors
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Independent adaptation of Techage's basic_machines/forceload.lua:
-- https://github.com/joe7575/techage

local MODNAME = minetest.get_current_modname()
local S = minetest.get_translator(MODNAME)
local storage = minetest.get_mod_storage()
local node_name = MODNAME .. ":forceload"
local storage_prefix = "block:"
local quota = math.max(0, tonumber(minetest.settings:get(
	MODNAME .. ".max_blocks_per_player")) or 5)
local mapblock_quota = math.max(0, tonumber(minetest.settings:get(
	MODNAME .. ".max_blocks_per_player_per_mapblock")) or 0)
local registry_limit = math.max(0, tonumber(minetest.settings:get(
	MODNAME .. ".max_registered_blocks")) or 500)
local display_seconds = math.max(1, tonumber(minetest.settings:get(
	MODNAME .. ".display_seconds")) or 5)

minetest.register_privilege("forceloader", {
	description = S("Can place and operate Online Forceload blocks"),
	give_to_singleplayer = false,
})

-- Persistent records are stored per mapblock. These three in-memory indexes
-- reference the same loader entries and are rebuilt on every server start.
local loaders_by_pos = {}
local blocks = {}
local owners = {}
local registered_count = 0
local active_count = 0

local function copy_pos(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function valid_pos(pos)
	return type(pos) == "table"
		and type(pos.x) == "number" and pos.x == math.floor(pos.x)
		and type(pos.y) == "number" and pos.y == math.floor(pos.y)
		and type(pos.z) == "number" and pos.z == math.floor(pos.z)
end

local function pos_hash(pos)
	-- Keep this numeric. LuaJIT's tostring() rounds large position hashes in
	-- scientific notation, which can make neighbouring nodes share a key.
	return minetest.hash_node_position(pos)
end

local function block_pos(pos)
	return {
		x = math.floor(pos.x / 16) * 16,
		y = math.floor(pos.y / 16) * 16,
		z = math.floor(pos.z / 16) * 16,
	}
end

local function block_hash(pos)
	return pos_hash(block_pos(pos))
end

local function block_storage_key(pos)
	local p = block_pos(pos)
	return storage_prefix .. p.x .. ":" .. p.y .. ":" .. p.z
end

local function block_bounds(pos)
	local minp = block_pos(pos)
	return minp, vector.add(minp, 15)
end

local function block_center(pos)
	return vector.add(block_pos(pos), 7.5)
end

local function get_block(pos, create)
	local hash = block_hash(pos)
	local block = blocks[hash]
	if not block and create then
		block = {
			hash = hash,
			pos = block_pos(pos),
			loaders = {},
			active = false,
		}
		blocks[hash] = block
	end
	return block, hash
end

local function get_owner(name, create)
	local owner = owners[name]
	if not owner and create then
		owner = {loaders = {}, count = 0}
		owners[name] = owner
	end
	return owner
end

local function player_eligible(name)
	return minetest.get_player_by_name(name) ~= nil
		and minetest.check_player_privs(name, {forceloader = true})
end

local function save_block(block)
	local entries = {}
	for _, entry in pairs(block.loaders) do
		entries[#entries + 1] = {
			pos = copy_pos(entry.pos),
			owner = entry.owner,
		}
	end
	table.sort(entries, function(a, b)
		return pos_hash(a.pos) < pos_hash(b.pos)
	end)
	local key = block_storage_key(block.pos)
	storage:set_string(key, #entries > 0 and minetest.serialize(entries) or "")
end

local function index_loader(pos, owner_name)
	if not valid_pos(pos) or type(owner_name) ~= "string" or owner_name == "" then
		return nil, "invalid"
	end
	local hash = pos_hash(pos)
	if loaders_by_pos[hash] then
		return loaders_by_pos[hash], "duplicate"
	end

	local block = get_block(pos, true)
	local owner = get_owner(owner_name, true)
	local entry = {
		pos = copy_pos(pos),
		owner = owner_name,
		pos_hash = hash,
		block_hash = block.hash,
	}
	loaders_by_pos[hash] = entry
	block.loaders[hash] = entry
	owner.loaders[hash] = entry
	owner.count = owner.count + 1
	registered_count = registered_count + 1
	return entry
end

local function unindex_loader(entry)
	loaders_by_pos[entry.pos_hash] = nil
	local block = blocks[entry.block_hash]
	if block then
		block.loaders[entry.pos_hash] = nil
	end
	local owner = owners[entry.owner]
	if owner then
		owner.loaders[entry.pos_hash] = nil
		owner.count = owner.count - 1
		if owner.count == 0 then
			owners[entry.owner] = nil
		end
	end
	registered_count = registered_count - 1
	return block
end

local function count_owned(name)
	local owner = owners[name]
	return owner and owner.count or 0
end

local function count_owned_in_block(name, block)
	local count = 0
	for _, entry in pairs(block.loaders) do
		if entry.owner == name then
			count = count + 1
		end
	end
	return count
end

-- Adapted from Protector Redo's temporary protection-area display (MIT).
local function remove_display(pos)
	for _, object in ipairs(minetest.get_objects_inside_radius(block_center(pos), 0.5)) do
		local entity = object:get_luaentity()
		if entity and entity.name == MODNAME .. ":display" then
			object:remove()
		end
	end
end

local function show_display(pos)
	remove_display(pos)
	minetest.add_entity(block_center(pos), MODNAME .. ":display")
end

local function set_infotext(entry, block)
	local node = minetest.get_node_or_nil(entry.pos)
	if not node or node.name ~= node_name then
		return
	end
	local minp, maxp = block_bounds(entry.pos)
	local status
	if block.active and player_eligible(entry.owner) then
		status = S("Active while @1 is online.", entry.owner)
	elseif block.active then
		status = S("Active through another online owner.")
	elseif player_eligible(entry.owner) then
		status = S("The engine forceload limit has been reached.")
	elseif minetest.get_player_by_name(entry.owner) then
		status = S("Inactive: owner lacks the forceloader privilege.")
	else
		status = S("Inactive: owner is offline.")
	end
	minetest.get_meta(entry.pos):set_string("infotext",
		S("Online Forceload Block") .. "\n" ..
		S("Owner: @1", entry.owner) .. "\n" ..
		S("Mapblock @1 to @2", minetest.pos_to_string(minp),
			minetest.pos_to_string(maxp)) .. "\n" .. status)
end

local function refresh_infotexts(block)
	for _, entry in pairs(block.loaders) do
		set_infotext(entry, block)
	end
end

local function reconcile_block(block)
	local wanted = false
	for _, entry in pairs(block.loaders) do
		if player_eligible(entry.owner) then
			wanted = true
			break
		end
	end

	if wanted and not block.active then
		if minetest.forceload_block(block.pos, true) then
			block.active = true
			active_count = active_count + 1
		else
			refresh_infotexts(block)
			return false
		end
	elseif not wanted and block.active then
		minetest.forceload_free_block(block.pos, true)
		block.active = false
		active_count = active_count - 1
	end
	refresh_infotexts(block)
	return true
end

local function finish_block_update(block)
	save_block(block)
	reconcile_block(block)
	if not next(block.loaders) and not block.active then
		blocks[block.hash] = nil
	end
end

local function remove_loader(pos)
	local entry = loaders_by_pos[pos_hash(pos)]
	if not entry then
		return nil
	end
	local block = unindex_loader(entry)
	finish_block_update(block)
	return entry
end

local function prune_loaded_block(block)
	local removed = false
	local stale = {}
	for _, entry in pairs(block.loaders) do
		local node = minetest.get_node_or_nil(entry.pos)
		if node and node.name ~= node_name then
			stale[#stale + 1] = entry
		end
	end
	for _, entry in ipairs(stale) do
		unindex_loader(entry)
		removed = true
		minetest.log("action", "[online_forceload] removed stale loader at " ..
			minetest.pos_to_string(entry.pos) .. " for " .. entry.owner)
	end
	if removed then
		finish_block_update(block)
	end
	return removed
end

local function reconcile_owner(name)
	local owner = owners[name]
	if not owner then return end
	local affected = {}
	for _, entry in pairs(owner.loaders) do
		affected[entry.block_hash] = true
	end
	for hash in pairs(affected) do
		local block = blocks[hash]
		if block then reconcile_block(block) end
	end
end

local function load_persistent_registry()
	local fields = (storage:to_table() or {}).fields or {}
	local loaded_storage_keys = {}
	for key, value in pairs(fields) do
		if key:sub(1, #storage_prefix) == storage_prefix and value ~= "" then
			local entries = minetest.deserialize(value)
			if type(entries) ~= "table" then
				minetest.log("error", "[online_forceload] invalid registry record: " .. key)
			else
				loaded_storage_keys[key] = true
				for _, entry in pairs(entries) do
					local loaded
					if type(entry) == "table" then
						loaded = index_loader(entry.pos, entry.owner)
					end
					if not loaded then
						minetest.log("error", "[online_forceload] invalid loader in " .. key)
					end
				end
			end
		end
	end

	-- Rewrite valid records under coordinate-based keys. This also migrates
	-- keys produced by older versions that stringified and rounded hashes.
	for key in pairs(loaded_storage_keys) do
		storage:set_string(key, "")
	end
	for _, block in pairs(blocks) do
		save_block(block)
	end

	-- Migrate the pre-2.0 single-table registry. Existing entries are imported
	-- regardless of current quotas; limits only reject new placements.
	local legacy_raw = storage:get_string("positions")
	if legacy_raw ~= "" then
		local legacy = minetest.deserialize(legacy_raw)
		local touched = {}
		if type(legacy) == "table" then
			for _, entry in pairs(legacy) do
				local loaded = type(entry) == "table" and index_loader(entry.pos, entry.owner)
				if loaded then touched[loaded.block_hash] = true end
			end
		else
			minetest.log("error", "[online_forceload] legacy registry is invalid; not deleting it")
			return
		end
		local migrated_blocks = 0
		for hash in pairs(touched) do
			save_block(blocks[hash])
			migrated_blocks = migrated_blocks + 1
		end
		storage:set_string("positions", "")
		minetest.log("action", "[online_forceload] migrated legacy registry to " ..
			tostring(migrated_blocks) .. " mapblock records")
	end
end

load_persistent_registry()

local function tell(name, message)
	minetest.chat_send_player(name, "[Online Forceload] " .. message)
end

local function move_loader(from_pos, to_pos)
	local entry = loaders_by_pos[pos_hash(from_pos)]
	if not entry then
		return
	end

	local old_block = unindex_loader(entry)
	local moved, reason = index_loader(to_pos, entry.owner)
	if not moved or reason then
		-- Preserve the old record if an unexpected position-hash collision occurs.
		index_loader(from_pos, entry.owner)
		minetest.log("error", "[online_forceload] could not move loader from " ..
			minetest.pos_to_string(from_pos) .. " to " .. minetest.pos_to_string(to_pos))
		return
	end
	local new_block = blocks[moved.block_hash]

	if old_block == new_block then
		finish_block_update(new_block)
	else
		finish_block_update(old_block)
		finish_block_update(new_block)
	end
	minetest.log("action", "[online_forceload] moved loader from " ..
		minetest.pos_to_string(from_pos) .. " to " .. minetest.pos_to_string(to_pos))
end

minetest.register_node(node_name, {
	description = S("Online Forceload Block") .. "\n" ..
		S("Keeps this mapblock active while its owner is online."),
	tiles = {"online_forceload_block.png"},
	paramtype = "light",
	sunlight_propagates = true,
	groups = {
		cracky = 1,
		level = 2,
		not_in_creative_inventory = quota == 0 and 1 or 0,
	},
	sounds = default.node_sound_metal_defaults(),
	is_ground_content = false,

	after_place_node = function(pos, placer)
		if not placer or not placer:is_player() then
			minetest.remove_node(pos)
			return true
		end

		local name = placer:get_player_name()
		local existing = loaders_by_pos[pos_hash(pos)]
		if existing and minetest.get_meta(pos):get_string("owner") == existing.owner then
			-- Some placement integrations can invoke after_place_node more than
			-- once. The registry is already correct, so do not repeat side effects
			-- or the activation message.
			minetest.log("warning", "[online_forceload] ignored duplicate placement callback at " ..
				minetest.pos_to_string(pos))
			return
		elseif existing then
			-- A newly placed node with different metadata replaces a stale
			-- registration at the same position.
			local stale_block = unindex_loader(existing)
			finish_block_update(stale_block)
		end
		if not minetest.check_player_privs(name, {forceloader = true}) then
			tell(name, S("You need the forceloader privilege to place this block."))
			minetest.remove_node(pos)
			return true
		end
		if quota == 0 then
			tell(name, S("Your forceload quota is disabled."))
			minetest.remove_node(pos)
			return true
		end
		if count_owned(name) >= quota then
			tell(name, S("Your forceload quota of @1 has been reached.", quota))
			minetest.remove_node(pos)
			return true
		end
		if registered_count >= registry_limit then
			tell(name, S("The global registry limit of @1 forceload blocks has been reached.",
				registry_limit))
			minetest.remove_node(pos)
			return true
		end

		local block = get_block(pos, true)
		prune_loaded_block(block)
		block = get_block(pos, true)
		if mapblock_quota > 0 and count_owned_in_block(name, block) >= mapblock_quota then
			tell(name, S("Your per-mapblock quota of @1 forceload blocks has been reached.",
				mapblock_quota))
			minetest.remove_node(pos)
			return true
		end

		local entry, reason = index_loader(pos, name)
		if not entry or reason then
			minetest.log("error", "[online_forceload] could not register placement at " ..
				minetest.pos_to_string(pos) .. ": " .. tostring(reason))
			minetest.remove_node(pos)
			return true
		end
		minetest.get_meta(pos):set_string("owner", name)
		save_block(block)
		if not reconcile_block(block) then
			unindex_loader(entry)
			finish_block_update(block)
			tell(name, S("The engine forceload limit has been reached."))
			minetest.remove_node(pos)
			return true
		end
		tell(name, S("Forceload block activated (@1/@2).", count_owned(name), quota))
	end,

	can_dig = function(pos, player)
		if not player then return false end
		local owner = minetest.get_meta(pos):get_string("owner")
		local name = player:get_player_name()
		local allowed = name == owner
			or minetest.check_player_privs(name, {protection_bypass = true})
		if not allowed then
			tell(name, S("You may only dig your own forceload block."))
		end
		return allowed
	end,

	after_dig_node = function(pos, oldnode, oldmetadata, digger)
		remove_display(pos)
		remove_loader(pos)
		if digger and digger:is_player() then
			tell(digger:get_player_name(), S("Forceload block removed."))
		end
	end,

	on_blast = function()
		return {}
	end,

	on_punch = function(pos, node, puncher)
		if puncher and puncher:is_player() then show_display(pos) end
	end,

	-- Jumpdrive and other compatible movers call this after copying node data
	-- and metadata, but before clearing the source area.
	on_movenode = move_loader,
})

-- A wielditem entity can render a nodebox larger than one node. Centering it
-- on the mapblock gives an exact, position-independent 16-node boundary.
minetest.register_entity(MODNAME .. ":display", {
	initial_properties = {
		physical = false,
		pointable = false,
		collide_with_objects = false,
		collisionbox = {0, 0, 0, 0, 0, 0},
		visual = "wielditem",
		visual_size = {x = 0.67, y = 0.67},
		textures = {MODNAME .. ":display_node"},
		glow = 10,
		static_save = false,
	},
	timer = 0,
	on_step = function(self, dtime)
		self.timer = self.timer + dtime
		if self.timer > display_seconds then self.object:remove() end
	end,
})

minetest.register_node(MODNAME .. ":display_node", {
	tiles = {"online_forceload_display.png"},
	use_texture_alpha = "clip",
	walkable = false,
	pointable = false,
	diggable = false,
	drawtype = "nodebox",
	node_box = {
		type = "fixed",
		fixed = {
			{-8.05, -8.05, -8.05, -7.95,  8.05,  8.05},
			{ 7.95, -8.05, -8.05,  8.05,  8.05,  8.05},
			{-8.05, -8.05, -8.05,  8.05, -7.95,  8.05},
			{-8.05,  7.95, -8.05,  8.05,  8.05,  8.05},
			{-8.05, -8.05, -8.05,  8.05,  8.05, -7.95},
			{-8.05, -8.05,  7.95,  8.05,  8.05,  8.05},
		},
	},
	selection_box = {type = "fixed", fixed = {0, 0, 0, 0, 0, 0}},
	paramtype = "light",
	groups = {not_in_creative_inventory = 1},
	drop = "",
	on_blast = function() return {} end,
})

if quota > 0 then
	minetest.register_craft({
		output = node_name,
		recipe = {
			{"default:obsidian_glass", "default:mese_crystal", "default:obsidian_glass"},
			{"default:steel_ingot", "default:diamond", "default:steel_ingot"},
			{"default:obsidian_glass", "default:mese_crystal", "default:obsidian_glass"},
		},
	})
end

minetest.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local owner = owners[name]
	if not owner then return end
	local affected = {}
	for _, entry in pairs(owner.loaders) do
		affected[entry.block_hash] = true
		local node = minetest.get_node_or_nil(entry.pos)
		if node and node.name == node_name then
			minetest.get_meta(entry.pos):set_string("owner", name)
		end
	end
	for hash in pairs(affected) do
		local block = blocks[hash]
		if block then
			reconcile_block(block)
			minetest.after(0, function()
				local current = blocks[hash]
				if current then
					minetest.load_area(current.pos, vector.add(current.pos, 15))
					prune_loaded_block(current)
				end
			end)
		end
	end
end)

-- Refresh status and recover a node whose metadata write completed but whose
-- registry write was interrupted. Node metadata is authoritative for owner.
minetest.register_lbm({
	label = "Refresh Online Forceload status",
	name = MODNAME .. ":refresh_status",
	nodenames = {node_name},
	run_at_every_load = true,
	action = function(pos)
		local hash = pos_hash(pos)
		local entry = loaders_by_pos[hash]
		local owner_name = entry and entry.owner
			or minetest.get_meta(pos):get_string("owner")

		if not entry and owner_name ~= "" and quota > 0
				and registered_count < registry_limit
				and count_owned(owner_name) < quota then
			local block = get_block(pos, true)
			if mapblock_quota == 0
					or count_owned_in_block(owner_name, block) < mapblock_quota then
				entry = index_loader(pos, owner_name)
				save_block(block)
				minetest.log("action", "[online_forceload] recovered loader at " ..
					minetest.pos_to_string(pos) .. " for " .. owner_name)
			end
		end

		if entry then
			local block = blocks[entry.block_hash]
			minetest.get_meta(pos):set_string("owner", entry.owner)
			reconcile_block(block)
		end
	end,
})

minetest.register_on_leaveplayer(function(player)
	-- The leaving PlayerRef can still be discoverable during this callback.
	minetest.after(0, reconcile_owner, player:get_player_name())
end)

if minetest.register_on_priv_grant then
	minetest.register_on_priv_grant(function(name, granter, privilege)
		if privilege == "forceloader" then
			minetest.after(0, reconcile_owner, name)
		end
	end)
end

if minetest.register_on_priv_revoke then
	minetest.register_on_priv_revoke(function(name, revoker, privilege)
		if privilege == "forceloader" then
			minetest.after(0, reconcile_owner, name)
		end
	end)
end

minetest.register_on_shutdown(function()
	for _, block in pairs(blocks) do
		if block.active then
			minetest.forceload_free_block(block.pos, true)
			block.active = false
		end
	end
	active_count = 0
end)

minetest.register_chatcommand("online_forceloads", {
	description = S("List your Online Forceload blocks"),
	func = function(name)
		local owner = owners[name]
		if not owner then return true, S("You own no forceload blocks.") end
		local rows = {}
		for _, entry in pairs(owner.loaders) do
			local block = blocks[entry.block_hash]
			local state = block and block.active and S("active") or S("inactive")
			rows[#rows + 1] = minetest.pos_to_string(entry.pos) .. " — " .. state
		end
		table.sort(rows)
		return true, table.concat(rows, "\n")
	end,
})

minetest.register_chatcommand("online_forceload_admin", {
	description = S("Manage Online Forceload blocks"),
	params = "<stats | list [player] | remove (x,y,z)>",
	privs = {server = true},
	func = function(name, param)
		param = param:match("^%s*(.-)%s*$")
		if param == "stats" then
			return true, S("Registered loaders: @1/@2; active mapblocks: @3",
				registered_count, registry_limit, active_count)
		end
		local listed_owner = param:match("^list%s+(.+)$")
		if param == "list" or listed_owner then
			local rows = {}
			for _, entry in pairs(loaders_by_pos) do
				if not listed_owner or entry.owner == listed_owner then
					local block = blocks[entry.block_hash]
					local state = block and block.active and S("active") or S("inactive")
					rows[#rows + 1] = minetest.pos_to_string(entry.pos) .. " — " ..
						entry.owner .. " — " .. state
				end
			end
			table.sort(rows)
			if #rows == 0 then return true, S("No matching forceload blocks.") end
			return true, table.concat(rows, "\n")
		end
		local position_text = param:match("^remove%s+(.+)$")
		if position_text then
			local pos = minetest.string_to_pos(position_text)
			if pos then
				-- Ensure an existing node is removed as well. Otherwise its LBM
				-- would correctly recover the registration the next time it loads.
				minetest.load_area(pos)
				local entry = remove_loader(pos)
				if entry then
					local node = minetest.get_node_or_nil(pos)
					if node and node.name == node_name then minetest.remove_node(pos) end
					return true, S("Removed loader at @1 owned by @2.",
						minetest.pos_to_string(pos), entry.owner)
				end
				return false, S("No registered loader at @1.", minetest.pos_to_string(pos))
			end
		end
		return false, S("Usage: /online_forceload_admin <stats | list [player] | remove (x,y,z)>")
	end,
})

minetest.register_chatcommand("online_forceload_source", {
	description = S("Source and license information for Online Forceload"),
	func = function()
		local notice = S("Licensed under GNU AGPL v3 or later. Based on Techage by Joachim Stolberg and contributors.")
		local url = minetest.settings:get(MODNAME .. ".source_url") or ""
		if url == "" then
			return true, notice .. "\n" ..
				S("No source URL is configured. The server operator must set online_forceload.source_url.")
		end
		return true, notice .. "\n" .. S("Source: @1", url)
	end,
})

minetest.log("action", "[online_forceload] loaded; quota=" .. quota ..
	" mapblock_quota=" .. mapblock_quota ..
	" registry=" .. registered_count .. "/" .. registry_limit)

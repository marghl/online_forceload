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
local quota = math.max(0, tonumber(minetest.settings:get(
	MODNAME .. ".max_blocks_per_player")) or 5)
local display_seconds = math.max(1, tonumber(minetest.settings:get(
	MODNAME .. ".display_seconds")) or 5)

-- positions maps node-position hashes to {pos=..., owner=...}. Forceloads are
-- transient: persistence belongs to this registry, never to the engine.
local positions = minetest.deserialize(storage:get_string("positions")) or {}
local active = {}

local function copy_pos(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function pos_hash(pos)
	return tostring(minetest.hash_node_position(pos))
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

local function block_bounds(pos)
	local minp = block_pos(pos)
	return minp, vector.add(minp, 15)
end

local function block_center(pos)
	local minp = block_pos(pos)
	return vector.add(minp, 7.5)
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

local function save()
	storage:set_string("positions", minetest.serialize(positions))
end

local function player_online(name)
	return minetest.get_player_by_name(name) ~= nil
end

local function count_owned(name)
	local count = 0
	for _, entry in pairs(positions) do
		if entry.owner == name then
			count = count + 1
		end
	end
	return count
end

local function find_in_mapblock(pos)
	local wanted = block_hash(pos)
	for hash, entry in pairs(positions) do
		if block_hash(entry.pos) == wanted then
			-- Placement has loaded this mapblock, so stale entries can be
			-- discarded immediately instead of blocking it forever.
			local node = minetest.get_node_or_nil(entry.pos)
			if node and node.name ~= node_name then
				positions[hash] = nil
				save()
			else
				return hash, entry
			end
		end
	end
end

local function set_infotext(pos, owner, is_active)
	local node = minetest.get_node_or_nil(pos)
	if not node or node.name ~= node_name then
		return
	end
	local minp, maxp = block_bounds(pos)
	local status = is_active and S("Active while @1 is online.", owner)
		or S("Inactive: owner is offline.")
	minetest.get_meta(pos):set_string("infotext",
		S("Online Forceload Block") .. "\n" ..
		S("Owner: @1", owner) .. "\n" ..
		S("Mapblock @1 to @2", minetest.pos_to_string(minp),
			minetest.pos_to_string(maxp)) .. "\n" .. status)
end

local function activate(entry)
	local key = block_hash(entry.pos)
	if active[key] then
		set_infotext(entry.pos, entry.owner, true)
		return true
	end
	if not minetest.forceload_block(entry.pos, true) then
		return false
	end
	active[key] = copy_pos(entry.pos)
	set_infotext(entry.pos, entry.owner, true)
	return true
end

local function deactivate(entry)
	local key = block_hash(entry.pos)
	if active[key] then
		minetest.forceload_free_block(active[key], true)
		active[key] = nil
	end
	set_infotext(entry.pos, entry.owner, false)
end

local function unregister(pos)
	local hash = pos_hash(pos)
	local entry = positions[hash]
	if entry then
		deactivate(entry)
		positions[hash] = nil
		save()
	end
	return entry
end

local function tell(name, message)
	minetest.chat_send_player(name, "[Online Forceload] " .. message)
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
		if find_in_mapblock(pos) then
			tell(name, S("This mapblock already has a forceload block."))
			minetest.remove_node(pos)
			return true
		end

		local entry = {pos = copy_pos(pos), owner = name}
		if not activate(entry) then
			tell(name, S("The engine forceload limit has been reached."))
			minetest.remove_node(pos)
			return true
		end

		positions[pos_hash(pos)] = entry
		minetest.get_meta(pos):set_string("owner", name)
		save()
		tell(name, S("Forceload block activated (@1/@2).", count_owned(name), quota))
	end,

	can_dig = function(pos, player)
		if not player then
			return false
		end
		local owner = minetest.get_meta(pos):get_string("owner")
		local name = player:get_player_name()
		local allowed = name == owner or minetest.check_player_privs(name, {protection_bypass = true})
		if not allowed then
			tell(name, S("You may only dig your own forceload block."))
		end
		return allowed
	end,

	after_dig_node = function(pos, oldnode, oldmetadata, digger)
		remove_display(pos)
		unregister(pos)
		if digger and digger:is_player() then
			tell(digger:get_player_name(), S("Forceload block removed."))
		end
	end,

	on_blast = function()
		-- Avoid bypassing ownership and registry cleanup through explosions.
		return {}
	end,

	on_punch = function(pos, node, puncher)
		if puncher and puncher:is_player() then
			show_display(pos)
		end
	end,
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
		if self.timer > display_seconds then
			self.object:remove()
		end
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
	local dirty = false
	for hash, entry in pairs(positions) do
		if entry.owner == name then
			local node = minetest.get_node_or_nil(entry.pos)
			if node and node.name ~= node_name then
				positions[hash] = nil
				dirty = true
			else
				-- An unloaded node is not evidence that the loader was removed.
				-- The transient forceload itself makes the mapblock active; the
				-- LBM below validates the node when it actually emerges.
				if activate(entry) and node then
					minetest.get_meta(entry.pos):set_string("owner", name)
				end
			end
		end
	end
	if dirty then save() end
end)

-- Refresh status text after crashes and whenever an offline loader's block is
-- loaded naturally by a nearby player.
minetest.register_lbm({
	label = "Refresh Online Forceload status",
	name = MODNAME .. ":refresh_status",
	nodenames = {node_name},
	run_at_every_load = true,
	action = function(pos, node)
		local hash = pos_hash(pos)
		local entry = positions[hash]
		local owner = entry and entry.owner or minetest.get_meta(pos):get_string("owner")

		-- Repair loaders orphaned by an interrupted write, WorldEdit, or the
		-- pre-1.1 login bug. Ownership stored on the node is authoritative.
		if not entry and owner ~= "" and quota > 0 and count_owned(owner) < quota
				and not find_in_mapblock(pos) then
			entry = {pos = copy_pos(pos), owner = owner}
			positions[hash] = entry
			save()
			minetest.log("action", "[online_forceload] recovered loader at " ..
				minetest.pos_to_string(pos) .. " for " .. owner)
		end

		if owner ~= "" then
			if entry and player_online(owner) then
				activate(entry)
			else
				set_infotext(pos, owner, false)
			end
		end
	end,
})

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	for _, entry in pairs(positions) do
		if entry.owner == name then
			deactivate(entry)
		end
	end
end)

minetest.register_on_shutdown(function()
	for _, entry in pairs(positions) do
		deactivate(entry)
	end
	active = {}
end)

minetest.register_chatcommand("online_forceloads", {
	description = S("List your Online Forceload blocks"),
	func = function(name)
		local rows = {}
		for _, entry in pairs(positions) do
			if entry.owner == name then
				local state = active[block_hash(entry.pos)] and S("active") or S("inactive")
				rows[#rows + 1] = minetest.pos_to_string(entry.pos) .. " — " .. state
			end
		end
		table.sort(rows)
		if #rows == 0 then
			return true, S("You own no forceload blocks.")
		end
		return true, table.concat(rows, "\n")
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

minetest.log("action", "[online_forceload] loaded; quota=" .. quota)

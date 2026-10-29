-- Minimal isolated runtime test for registry and activation behavior.

local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/tests/[^/]+$") or "."

local function key(pos)
	return pos.x .. ":" .. pos.y .. ":" .. pos.z
end

local function serialize(value)
	local kind = type(value)
	if kind == "number" or kind == "boolean" then return tostring(value) end
	if kind == "string" then return string.format("%q", value) end
	assert(kind == "table", "unsupported serialized type: " .. kind)
	local parts = {"{"}
	for k, v in pairs(value) do
		parts[#parts + 1] = "[" .. serialize(k) .. "]=" .. serialize(v) .. ","
	end
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

local storage = {fields = {}}
function storage:get_string(name) return self.fields[name] or "" end
function storage:set_string(name, value) self.fields[name] = value end
function storage:to_table() return {fields = self.fields} end

storage.fields.positions = serialize({
	legacy = {pos = {x = -20, y = 0, z = 0}, owner = "legacy"},
})

local settings = {
	["online_forceload.max_blocks_per_player"] = "5",
	["online_forceload.max_blocks_per_player_per_mapblock"] = "2",
	["online_forceload.max_registered_blocks"] = "5",
}
local world = {}
local metadata = {}
local players = {}
local chats = {}
local after_queue = {}
local callbacks = {join = {}, leave = {}, shutdown = {}, grant = {}, revoke = {}}
local registered_nodes = {}
local chatcommands = {}
local forceload_calls = 0
local free_calls = 0

vector = {}
function vector.add(a, b)
	if type(b) == "number" then return {x = a.x + b, y = a.y + b, z = a.z + b} end
	return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z}
end
function vector.subtract(a, b)
	return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

default = {node_sound_metal_defaults = function() return {} end}

minetest = {
	settings = {get = function(_, name) return settings[name] end},
	registered_privileges = {},
}

function minetest.get_current_modname() return "online_forceload" end
function minetest.get_mod_storage() return storage end
function minetest.get_translator()
	return function(text, ...)
		local args = {...}
		return (text:gsub("@(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
	end
end
function minetest.serialize(value) return serialize(value) end
function minetest.deserialize(value)
	local loader = loadstring or load
	local chunk = loader("return " .. value)
	if not chunk then return nil end
	local ok, result = pcall(chunk)
	return ok and result or nil
end
function minetest.hash_node_position(pos)
	return (pos.z + 0x8000) * 0x100000000
		+ (pos.y + 0x8000) * 0x10000
		+ (pos.x + 0x8000)
end
function minetest.register_privilege(name, def) minetest.registered_privileges[name] = def end
function minetest.register_node(name, def) registered_nodes[name] = def end
function minetest.register_entity() end
function minetest.register_craft() end
function minetest.register_lbm(def) callbacks.lbm = def.action end
function minetest.register_chatcommand(name, def) chatcommands[name] = def end
function minetest.register_on_joinplayer(cb) callbacks.join[#callbacks.join + 1] = cb end
function minetest.register_on_leaveplayer(cb) callbacks.leave[#callbacks.leave + 1] = cb end
function minetest.register_on_shutdown(cb) callbacks.shutdown[#callbacks.shutdown + 1] = cb end
function minetest.register_on_priv_grant(cb) callbacks.grant[#callbacks.grant + 1] = cb end
function minetest.register_on_priv_revoke(cb) callbacks.revoke[#callbacks.revoke + 1] = cb end
function minetest.after(_, cb, ...)
	after_queue[#after_queue + 1] = {cb = cb, args = {...}}
end
function minetest.log() end
function minetest.get_objects_inside_radius() return {} end
function minetest.add_entity() return nil end
function minetest.get_node_or_nil(pos) return world[key(pos)] or {name = "air"} end
function minetest.load_area() end
function minetest.remove_node(pos) world[key(pos)] = {name = "air"} end
function minetest.get_meta(pos)
	local hash = key(pos)
	metadata[hash] = metadata[hash] or {}
	return {
		get_string = function(_, name) return metadata[hash][name] or "" end,
		set_string = function(_, name, value) metadata[hash][name] = value end,
	}
end
function minetest.get_player_by_name(name) return players[name] end
function minetest.check_player_privs(name, required)
	local player = players[name]
	local privs = player and player.privs or {}
	for privilege in pairs(required) do
		if not privs[privilege] then return false end
	end
	return true
end
function minetest.forceload_block()
	forceload_calls = forceload_calls + 1
	return true
end
function minetest.forceload_free_block() free_calls = free_calls + 1 end
function minetest.chat_send_player(name, message) chats[#chats + 1] = {name, message} end
function minetest.pos_to_string(pos) return "(" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")" end
function minetest.string_to_pos(text)
	local x, y, z = text:match("^%(([-%d]+),([-%d]+),([-%d]+)%)$")
	return x and {x = tonumber(x), y = tonumber(y), z = tonumber(z)} or nil
end

local function new_player(name, privileged)
	local player = {
		name = name,
		privs = privileged and {forceloader = true} or {},
	}
	function player:is_player() return true end
	function player:get_player_name() return self.name end
	players[name] = player
	return player
end

local function run_after()
	local queue = after_queue
	after_queue = {}
	local unpack_args = table.unpack or unpack
	for _, call in ipairs(queue) do call.cb(unpack_args(call.args)) end
end

local function place(pos, player)
	world[key(pos)] = {name = "online_forceload:forceload"}
	return registered_nodes["online_forceload:forceload"].after_place_node(pos, player)
end

local function assert_equal(actual, expected, label)
	assert(actual == expected, label .. ": expected " .. tostring(expected) ..
		", got " .. tostring(actual))
end

dofile(root .. "/init.lua")

assert_equal(storage:get_string("positions"), "", "legacy registry cleared")
local migrated = false
for name, value in pairs(storage.fields) do
	if name:match("^block:") and value ~= "" then migrated = true end
end
assert(migrated, "legacy registry was not migrated to block storage")

local eve = new_player("eve", false)
place({x = 0, y = 0, z = 0}, eve)
assert_equal(world["0:0:0"].name, "air", "unprivileged placement rejected")
assert_equal(forceload_calls, 0, "unprivileged placement did not forceload")

local alice = new_player("alice", true)
local bob = new_player("bob", true)
local charlie = new_player("charlie", true)
local dave = new_player("dave", true)

place({x = 1, y = 0, z = 0}, alice)
local messages_after_first_placement = #chats
registered_nodes["online_forceload:forceload"].after_place_node(
	{x = 1, y = 0, z = 0}, alice)
assert_equal(#chats, messages_after_first_placement,
	"duplicate placement callback did not repeat activation message")
place({x = 2, y = 0, z = 0}, bob)
assert_equal(forceload_calls, 1, "shared mapblock loaded once")

place({x = 3, y = 0, z = 0}, alice)
assert_equal(world["3:0:0"].name, "online_forceload:forceload",
	"second loader from same owner in mapblock accepted")
assert_equal(forceload_calls, 1, "additional loader did not duplicate engine forceload")
place({x = 4, y = 0, z = 0}, alice)
assert_equal(world["4:0:0"].name, "air", "configurable per-mapblock quota enforced")

place({x = 20, y = 0, z = 0}, charlie)
assert_equal(forceload_calls, 2, "second mapblock loaded")
place({x = 40, y = 0, z = 0}, dave)
assert_equal(world["40:0:0"].name, "air", "global registry limit enforced")

players.alice = nil
for _, cb in ipairs(callbacks.leave) do cb(alice) end
run_after()
assert_equal(free_calls, 0, "shared mapblock retained for second owner")

players.bob = nil
for _, cb in ipairs(callbacks.leave) do cb(bob) end
run_after()
assert_equal(free_calls, 1, "shared mapblock freed after last online owner")

local mover = registered_nodes["online_forceload:forceload"].on_movenode
world["36:0:0"] = world["20:0:0"]
metadata["36:0:0"] = metadata["20:0:0"]
mover({x = 20, y = 0, z = 0}, {x = 36, y = 0, z = 0})
assert_equal(free_calls, 2, "move freed old mapblock")
assert_equal(forceload_calls, 3, "move loaded destination mapblock")

charlie.privs.forceloader = nil
for _, cb in ipairs(callbacks.revoke) do cb("charlie", "admin", "forceloader") end
run_after()
assert_equal(free_calls, 3, "privilege revocation disabled existing loader")
charlie.privs.forceloader = true
for _, cb in ipairs(callbacks.grant) do cb("charlie", "admin", "forceloader") end
run_after()
assert_equal(forceload_calls, 4, "privilege grant re-enabled existing loader")

local ok, stats = chatcommands.online_forceload_admin.func("admin", "stats")
assert(ok and stats:find("5/5", 1, true), "admin stats report registry usage")

print("Runtime validation passed: migration, privileges, shared activation, limits, movement.")

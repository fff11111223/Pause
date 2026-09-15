local mod = get_mod("Pause") -- luacheck: ignore get_mod

-- luacheck: globals Managers ScriptWorld Unit ScriptUnit Vector3 Quaternion ConflictDirector NetworkServer NetworkLookup GenericCharacterStateMachineExtension SimpleInventoryExtension ActionBase

local SnapshotManager = mod:dofile("scripts/mods/Pause/snapshot_manager")

mod.is_paused = false
mod.snapshot_manager = SnapshotManager
mod._paused_player_positions = {}

SnapshotManager:init()

-- Check if currently inside a playable level
mod.is_in_game = function()
	return Managers.world
		and Managers.world:has_world("level_world")
		and Managers.state
		and Managers.state.network
		and Managers.time
		and Managers.time:has_timer("game")
end

-- Check if currently inside the Inn/Keep/Lobby (including all seasonal event variations)
mod.is_in_inn = function()
	local transition = Managers.level_transition_handler
	if not transition then
		return false
	end
	local current_level = transition:get_current_level_key()
	if not current_level then
		return false
	end
	if current_level:find("inn_level") then
		return true
	end
	if rawget(_G, "LevelSettings") and LevelSettings[current_level] and LevelSettings[current_level].hub_level then
		return true
	end
	local game_mode = Managers.state and Managers.state.game_mode
	if game_mode and game_mode.settings and game_mode:settings().key == "inn" then
		return true
	end
	return false
end

-- Safe localization fallback to completely prevent <Invalid string format>
mod.safe_localize = function(self, key, ...)
	local ok, res = pcall(self.localize, self, key, ...)
	if ok and res and not res:find("Invalid string format") then
		return res
	end

	local a1 = tostring(select(1, ...) or "")
	local a2 = tostring(select(2, ...) or "")
	local fallbacks = {
		cannot_restore_in_inn = "在大廳中無法執行戰局快照回溯！請先載入進入該地圖關卡中再執行回溯。",
		cannot_save_in_inn = "在大廳中無法儲存戰局快照！戰局快照僅能在關卡進行中儲存。",
		snapshot_level_mismatch = "快照地圖「" .. a1 .. "」與當前地圖「" .. a2 .. "」不符，無法恢復！",
		snapshot_applied_seed = "快照恢復完成！（地圖 Seed: " .. a1 .. "）。遊戲已自動【暫停定格】以等待隊友連線，全員就緒後請輸入 /unpause 繼續。",
		snapshot_detected_prompt = "偵測到本關卡「" .. a1 .. "」（Seed: " .. a2 .. "）的上次快照記錄！若需接續進度請輸入 /restore_snapshot。",
		player_joined_paused = "玩家「" .. a1 .. "」已在暫停狀態下成功加入並接管角色進場。",
		game_paused = "遊戲已完全定格！重新加入的玩家現在可以安全連線並進場接管角色。",
		game_unpaused = "遊戲已恢復！繼續戰鬥。",
		not_server = "只有房主（Host）可以執行此操作！",
		snapshot_saved = "戰局快照已成功儲存！",
		snapshot_save_failed = "戰局快照儲存失敗。",
		snapshot_not_found = "未找到可讀取的快照檔案。",
	}
	return fallbacks[key] or ("<" .. tostring(key) .. ">")
end

-- Freeze / unfreeze a specific player unit for all clients via native game locomotion RPC
local function _set_unit_locomotion_disabled(unit, disabled)
	if not unit or not Unit.alive(unit) then
		return
	end

	pcall(function()
		local locomotion_ext = ScriptUnit.has_extension(unit, "locomotion_system") and ScriptUnit.extension(unit, "locomotion_system")
		if locomotion_ext then
			-- PlayerHuskLocomotionExtension.update calls self._run_func() while disabled.
			-- Passing nil crashes it, so supply a no-op; nil is fine when re-enabling
			-- (set_disabled false resets lerp data internally, no func needed).
			local safe_run_func = disabled and function() end or nil
			locomotion_ext:set_disabled(disabled, safe_run_func)
		end

		if Managers.player and Managers.player.is_server and Managers.state.network and Managers.state.unit_storage then
			-- During spawn, an alive unit can precede its NetworkUnitStorage entry.
			-- Read the map as a pure readiness check before broadcasting an RPC.
			local go_id = Managers.state.unit_storage.bimap_goid_unit and Managers.state.unit_storage.bimap_goid_unit[unit]
			if go_id and NetworkLookup and NetworkLookup.movement_funcs then
				local movement_func_id = NetworkLookup.movement_funcs.none or 1
				Managers.state.network.network_transmit:send_rpc_clients("rpc_disable_locomotion", go_id, disabled, movement_func_id)
			end
		end
	end)
end

-- Freeze / unfreeze ability cooldown ticking for a unit
local function _set_unit_cooldown_paused(unit, paused)
	if not unit or not Unit.alive(unit) then
		return
	end

	pcall(function()
		local career_ext = ScriptUnit.has_extension(unit, "career_system") and ScriptUnit.extension(unit, "career_system")
		if career_ext then
			if paused then
				career_ext:set_activated_ability_cooldown_paused()
			else
				career_ext:set_activated_ability_cooldown_unpaused()
			end
		end
	end)
end

-- Sync statistic number to clients via native RPC
mod.sync_stat_to_clients = function(peer_id, local_player_id, path_array, value)
	pcall(function()
		if not Managers.state.network or not Managers.state.network:in_game_session() then
			return
		end
		if not NetworkLookup or not NetworkLookup.statistics_path_names then
			return
		end

		local net_path = {}
		for i = 1, #path_array do
			local name = path_array[i]
			local id = NetworkLookup.statistics_path_names[name]
			if not id then
				return -- Cannot networkify this path
			end
			net_path[i] = id
		end

		local val = math.clamp(math.floor(value or 0), 0, 65535)
		local persistent_val = 0

		-- Fatshark's rpc_sync_statistics_number asserts that persistent_value MUST be 0
		-- if the stat does not have a database_name.
		local has_database_name = false
		local def = rawget(_G, "StatisticsDefinitions") and StatisticsDefinitions.player
		if def then
			local cur_def = def
			for i = 1, #path_array do
				if not cur_def then break end
				cur_def = cur_def[path_array[i]]
			end
			if cur_def and cur_def.database_name then
				has_database_name = true
			end
		end

		if not has_database_name then
			local statistics_db = Managers.player and Managers.player:statistics_db()
			local player = Managers.player and Managers.player:player(peer_id, local_player_id)
			if statistics_db and player and statistics_db.statistics then
				local stats_id = player:stats_id()
				local node = statistics_db.statistics[stats_id]
				for i = 1, #path_array do
					if not node then break end
					node = node[path_array[i]]
				end
				if node and node.database_name then
					has_database_name = true
				end
			end
		end

		if has_database_name then
			persistent_val = val
		else
			persistent_val = 0
		end

		Managers.state.network.network_transmit:send_rpc_clients(
			"rpc_sync_statistics_number",
			peer_id,
			local_player_id,
			net_path,
			val,
			persistent_val
		)
	end)
end

mod.set_unit_locomotion_disabled = _set_unit_locomotion_disabled
mod.set_unit_cooldown_paused = _set_unit_cooldown_paused

-- Apply unified pause state (Freezes animations at current frame, disables all attacks, locks movement, freezes CD & buffs)
mod.apply_pause_state = function(self, paused, preserve_positions)
	if not mod.is_in_game() then
		mod.is_paused = false
		return
	end

	local world = Managers.world:world("level_world")
	if not world then
		return
	end

	mod.is_paused = paused

	if paused then
		-- 1. Freeze world animations at current frame (World.update_animations dt=0), physics, and AI
		ScriptWorld.pause(world)
		if Managers.time:has_timer("game") then
			Managers.time:set_local_scale("game", 0)
		end

		-- 2. Lock movement and freeze ability cooldowns for all players
		if not preserve_positions then
			mod._paused_player_positions = {}
		end
		if Managers.player then
			local players = Managers.player:players()
			for _, player in pairs(players) do
				local unit = player.player_unit
				if unit and Unit.alive(unit) then
					if not mod._paused_player_positions[unit] then
						local pos = Unit.world_position(unit, 0)
						local rot = Unit.world_rotation(unit, 0)
						mod._paused_player_positions[unit] = {
							pos = Vector3(pos.x, pos.y, pos.z),
							rot = Quaternion.from_elements(Quaternion.to_elements(rot)),
						}
					end
					_set_unit_locomotion_disabled(unit, true)
					_set_unit_cooldown_paused(unit, true)
				end
			end
		end
	else
		-- 1. Unfreeze world animations and resume game clock
		pcall(function()
			ScriptWorld.unpause(world)
		end)
		pcall(function()
			if Managers.time and Managers.time:has_timer("game") then
				Managers.time:set_local_scale("game", 1)
			end
		end)

		-- 2. Restore movement and unfreeze ability cooldowns for all players
		pcall(function()
			if Managers.player then
				local players = Managers.player:players()
				for _, player in pairs(players) do
					local unit = player.player_unit
					if unit and Unit.alive(unit) then
						_set_unit_locomotion_disabled(unit, false)
						_set_unit_cooldown_paused(unit, false)
					end
				end
			end
		end)
		mod._paused_player_positions = {}
	end
end

-- Broadcast message to all players via chat, with local echo fallback
mod.chat_broadcast = function(self, message)
	local text = "[Pause] " .. message
	if Managers.chat and Managers.chat:has_channel(1) then
		pcall(function()
			local local_player_id = 1
			Managers.chat:send_chat_message(1, local_player_id, text)
		end)
	else
		mod:echo(text)
	end
end

-- Toggle pause / unpause (Host only)
mod.do_pause = function()
	if not mod.is_in_game() then
		return
	end

	if not Managers.player or not Managers.player.is_server then
		mod:echo(mod:safe_localize("not_server"))
		return
	end

	local new_state = not mod.is_paused
	mod:apply_pause_state(new_state)

	if new_state then
		mod:chat_broadcast(mod:safe_localize("game_paused"))
	else
		mod:chat_broadcast(mod:safe_localize("game_unpaused"))
	end
end

-- Explicit unpause (Host only)
mod.do_unpause = function()
	if not mod.is_in_game() then
		return
	end

	if not Managers.player or not Managers.player.is_server then
		mod:echo(mod:safe_localize("not_server"))
		return
	end

	if mod.is_paused then
		mod:apply_pause_state(false)
		mod:chat_broadcast(mod:safe_localize("game_unpaused"))
	end
end

-- Manual Snapshot Save (Host only)
mod.do_save_snapshot = function()
	if not mod.is_in_game() then
		return
	end
	if not Managers.player or not Managers.player.is_server then
		mod:echo(mod:safe_localize("not_server"))
		return
	end

	if mod.is_in_inn() then
		mod:chat_broadcast(mod:safe_localize("cannot_save_in_inn"))
		return
	end

	SnapshotManager:save_snapshot(false)
end

-- Snapshot Restore (Host only)
mod.do_restore_snapshot = function()
	if not mod.is_in_game() then
		return
	end
	if not Managers.player or not Managers.player.is_server then
		mod:echo(mod:safe_localize("not_server"))
		return
	end

	if mod.is_in_inn() then
		mod:chat_broadcast(mod:safe_localize("cannot_restore_in_inn"))
		return
	end

	SnapshotManager:apply_snapshot()
end

-- Guard AILineOfSightExtension:has_line_of_sight against nil blackboard (can occur on freshly spawned units)
if rawget(_G, "AILineOfSightExtension") then
	mod:hook(AILineOfSightExtension, "has_line_of_sight", function(func, self, unit, blackboard, override_target, override_distance)
		if not blackboard then
			return false, 0
		end
		return func(self, unit, blackboard, override_target, override_distance)
	end)
end

-- Guard PlayerHuskLocomotionExtension to prevent multiplayer crashes during snapshot restore and pause
if rawget(_G, "PlayerHuskLocomotionExtension") then
	mod:hook(PlayerHuskLocomotionExtension, "teleport_to", function(func, self, pos, optional_rot)
		func(self, pos, optional_rot)
		pcall(function()
			local unit = self.unit
			if unit and Unit.alive(unit) then
				Unit.set_data(unit, "last_lerp_position", pos)
				Unit.set_data(unit, "last_lerp_position_offset", Vector3(0, 0, 0))
				Unit.set_data(unit, "accumulated_movement", Vector3(0, 0, 0))
				self._pos_lerp_time = 0
			end
		end)
	end)

	mod:hook(PlayerHuskLocomotionExtension, "_extrapolation_movement", function(func, self, unit, dt, old_pos, new_pos, new_rot, movement_state, velocity, linked_movement, moving_platform)
		-- Ensure last_lerp_position, last_lerp_position_offset, and accumulated_movement are valid Vector3s
		local last_pos = Unit.get_data(unit, "last_lerp_position")
		if not last_pos or type(last_pos) ~= "userdata" or not pcall(function() return last_pos.x end) then
			Unit.set_data(unit, "last_lerp_position", old_pos)
		end
		local last_pos_offset = Unit.get_data(unit, "last_lerp_position_offset")
		if not last_pos_offset or type(last_pos_offset) ~= "userdata" or not pcall(function() return last_pos_offset.x end) then
			Unit.set_data(unit, "last_lerp_position_offset", Vector3(0, 0, 0))
		end
		local accumulated_movement = Unit.get_data(unit, "accumulated_movement")
		if not accumulated_movement or type(accumulated_movement) ~= "userdata" or not pcall(function() return accumulated_movement.x end) then
			Unit.set_data(unit, "accumulated_movement", Vector3(0, 0, 0))
		end
		return func(self, unit, dt, old_pos, new_pos, new_rot, movement_state, velocity, linked_movement, moving_platform)
	end)
end

-- Guard TagQueryDatabase to prevent "invalid key to 'next'" crash when queries reference units destroyed during snapshot restore
if rawget(_G, "TagQueryDatabase") then
	mod:hook(TagQueryDatabase, "iterate_query", function(func, self, t)
		local ok, res = pcall(func, self, t)
		if not ok or not res then
			return { result = nil }
		end
		return res
	end)
end

-- Guard BossHealthUI to prevent crashes when boss units are destroyed and restored during snapshots
if rawget(_G, "BossHealthUI") then
	mod:hook(BossHealthUI, "update", function(func, self, dt, t)
		if self._detected_boss_units then
			for i = #self._detected_boss_units, 1, -1 do
				local data = self._detected_boss_units[i]
				local unit = data and data.unit
				if not unit or not Unit.alive(unit) or not ScriptUnit.has_extension(unit, "health_system") then
					table.remove(self._detected_boss_units, i)
				end
			end
		end
		return func(self, dt, t)
	end)

	mod:hook(BossHealthUI, "_update_enemy_portrait_name_and_attributes", function(func, self, boss_data)
		local unit = boss_data and boss_data.unit
		if not unit or not Unit.alive(unit) then
			return "", nil
		end
		return func(self, boss_data)
	end)
end

-- Hook ConflictDirector to halt AI director/pacing/spawns during pause.
-- mod._allow_director_updates allows frames through after snapshot restore
-- so that spawn_queued_unit enemies get flushed from the queue before re-pausing.
mod._allow_director_updates = 0
-- Allows a few inventory updates after a snapshot restore has re-paused.  This
-- completes weapon attachment setup without resuming gameplay.
mod._allow_inventory_updates = 0

-- Networked animation helpers assert if a newly spawned unit has not yet been
-- inserted into NetworkUnitStorage.  Keep the local animation, but suppress
-- only the impossible RPC during that initialization frame.  Once registered,
-- the normal VT2 sync path is used unchanged.
local function _has_registered_game_object(unit)
	local unit_storage = Managers.state and Managers.state.unit_storage
	return unit_storage and unit_storage.bimap_goid_unit and unit_storage.bimap_goid_unit[unit] ~= nil
end

-- During snapshot replacement a reference can outlive the corresponding
-- NetworkUnitStorage entry for one frame.  The engine GameSession bindings
-- require a numeric id and otherwise abort the entire script update.  Guard
-- both reads and writes globally so every game-object field access made during
-- that transient state behaves as an unavailable field instead of crashing.
-- This includes ActionSweep's cleave calculation, which reads bt_action_name
-- from an enemy that may just have been removed by destroy_all_units().
if GameSession and not GameSession._pause_safe_game_object_fields then
	local original_game_object_field = GameSession.game_object_field
	local original_set_game_object_field = GameSession.set_game_object_field

	GameSession.game_object_field = function(game, game_object_id, field_name)
		if not game or type(game_object_id) ~= "number" then
			return nil
		end
		return original_game_object_field(game, game_object_id, field_name)
	end

	GameSession.set_game_object_field = function(game, game_object_id, field_name, value)
		if not game or type(game_object_id) ~= "number" then
			return nil
		end
		return original_set_game_object_field(game, game_object_id, field_name, value)
	end

	GameSession._pause_safe_game_object_fields = true
end

if rawget(_G, "AnimationSystem") then
	mod:hook(AnimationSystem, "anim_event", function(func, self, unit, event_name, skip_sync)
		if not skip_sync and not _has_registered_game_object(unit) then
			return func(self, unit, event_name, true)
		end
		return func(self, unit, event_name, skip_sync)
	end)

	mod:hook(AnimationSystem, "anim_event_with_variable_float", function(func, self, unit, event_name, variable_name, variable_value, skip_sync)
		if not skip_sync and not _has_registered_game_object(unit) then
			return func(self, unit, event_name, variable_name, variable_value, true)
		end
		return func(self, unit, event_name, variable_name, variable_value, skip_sync)
	end)
end

if rawget(_G, "GameNetworkManager") then
	mod:hook(GameNetworkManager, "anim_set_variable_float", function(func, self, unit, variable_name, variable_value)
		if not _has_registered_game_object(unit) then
			local variable_index = Unit.animation_find_variable(unit, variable_name)
			Unit.animation_set_variable(unit, variable_index, variable_value)
			return
		end
		return func(self, unit, variable_name, variable_value)
	end)
end

-- `ConflictDirector:destroy_all_units()` removes a unit's game object before
-- AISystem's bookkeeping has necessarily removed the same unit from
-- `ai_units_alive`.  Snapshot restoration deliberately performs that bulk
-- replacement, so the stock implementation can attempt to write AI fields to
-- a nil game-object id during this short transition.  Reimplement only this
-- network-sync loop with a registration check; AI behavior and cleanup remain
-- owned by the original systems.
if rawget(_G, "AISystem") then
	mod:hook(AISystem, "update_game_objects", function(_, self)
		local network_manager = Managers.state and Managers.state.network
		local game = network_manager and network_manager:game()
		local unit_storage = Managers.state and Managers.state.unit_storage
		local go_ids = unit_storage and unit_storage.bimap_goid_unit
		if not game or not go_ids then
			return
		end

		local action_names = NetworkLookup and NetworkLookup.bt_action_names
		for unit, extension in pairs(self.ai_units_alive) do
			local game_object_id = go_ids[unit]
			if game_object_id then
				local action_name = extension:current_action_name()
				local action_id = action_names and action_names[action_name]
				if action_id then
					GameSession.set_game_object_field(game, game_object_id, "bt_action_name", action_id)
				end

				local blackboard = BLACKBOARDS[unit]
				local target_unit_id = blackboard and go_ids[blackboard.target_unit]
				GameSession.set_game_object_field(game, game_object_id, "target_unit_id", target_unit_id or NetworkConstants.invalid_game_object_id)
			end
		end
	end)
end

mod:hook(ConflictDirector, "update", function(func, self, dt, t)
	if mod.is_paused then
		if mod._allow_director_updates and mod._allow_director_updates > 0 then
			mod._allow_director_updates = mod._allow_director_updates - 1
			return func(self, dt, t)
		end
		return
	end
	return func(self, dt, t)
end)

-- Hook Character State Machine to freeze player state transitions & weapon animations at current frame
mod:hook(GenericCharacterStateMachineExtension, "update", function(func, self, unit, input, dt, context, t)
	if mod.is_paused then
		return
	end
	return func(self, unit, input, dt, context, t)
end)

-- Hook Inventory Extension to prevent weapon switching & equipment updates during pause
mod:hook(SimpleInventoryExtension, "update", function(func, self, unit, input, dt, context, t)
	if mod.is_paused then
		if mod._allow_inventory_updates and mod._allow_inventory_updates > 0 then
			return func(self, unit, input, dt, context, t)
		end
		return
	end
	return func(self, unit, input, dt, context, t)
end)

-- Hook ActionBase to block any new weapon attacks, swings, shots, or casts from starting during pause
mod:hook(ActionBase, "client_owner_start_action", function(func, self, new_action, t, chain_action_data, power_level, action_init_data)
	if mod.is_paused then
		return
	end
	return func(self, new_action, t, chain_action_data, power_level, action_init_data)
end)

-- Hook NetworkServer.peer_spawned_player:
-- When a rejoining player spawns in while paused, lock position and notify
mod:hook_safe(NetworkServer, "peer_spawned_player", function(self, peer_id)
	if mod.is_paused and self.is_server then
		local player = Managers.player and Managers.player:player_from_peer_id(peer_id)
		if player and player.player_unit and Unit.alive(player.player_unit) then
			local unit = player.player_unit
			local pos = Unit.world_position(unit, 0)
			local rot = Unit.world_rotation(unit, 0)
			mod._paused_player_positions[unit] = {
				pos = Vector3(pos.x, pos.y, pos.z),
				rot = Quaternion.from_elements(Quaternion.to_elements(rot)),
			}
			_set_unit_locomotion_disabled(unit, true)
			_set_unit_cooldown_paused(unit, true)
		end

		local player_name = player and player:name() or tostring(peer_id)
		local joined_msg = mod:safe_localize("player_joined_paused", player_name)
		mod:chat_broadcast(joined_msg)
	end
end)

-- Mod frame update loop (handles auto-snapshot timer, position anchoring, and level-start detection)
mod.update = function(dt)
	pcall(function()
		SnapshotManager:update(dt)

		-- Anchor all player positions when paused so nobody can walk away
		if mod.is_paused and Managers.player and Managers.player.is_server then
			for unit, data in pairs(mod._paused_player_positions) do
				if unit and Unit.alive(unit) and data.pos and data.rot then
					local current_pos = POSITION_LOOKUP[unit] or Unit.local_position(unit, 0)
					if Vector3.distance_squared(current_pos, data.pos) > 0.04 then
						local locomotion = ScriptUnit.has_extension(unit, "locomotion_system") and ScriptUnit.extension(unit, "locomotion_system")
						if locomotion then
							locomotion:teleport_to(data.pos, data.rot)
						end
					end
				end
			end
		end

		-- The inventory allowance is frame-based, rather than per unit update,
		-- so every player's attachment setup gets the same restore window.
		if mod.is_paused and mod._allow_inventory_updates and mod._allow_inventory_updates > 0 then
			mod._allow_inventory_updates = mod._allow_inventory_updates - 1
		end
	end)
end

-- Safety reset and cleanup when changing game state or leaving level
mod.on_game_state_changed = function(status, state_name)
	if status == "exit" and (state_name == "StateIngame" or state_name == "StateLoading") then
		if mod.is_paused then
			mod.is_paused = false
			if Managers.time and Managers.time:has_timer("game") then
				Managers.time:set_local_scale("game", 1)
			end
			mod._paused_player_positions = {}
		end

		-- Clean up snapshot when game ends in victory/defeat or returns to inn
		pcall(function()
			local game_mode = Managers.state and Managers.state.game_mode
			if game_mode and game_mode:is_game_mode_ended() then
				local reason = game_mode:game_mode_end_reason()
				if reason == "won" or reason == "lost" then
					SnapshotManager:cleanup_snapshot()
				end
			end
		end)
	end
end

-- Safety cleanup when mod is unloaded
mod.on_unload = function(exit_game)
	if mod.is_paused then
		mod:apply_pause_state(false)
	end
end

-- Register slash commands safely (using pcall to avoid crashing if another mod registered the same command name)
local function _safe_command(name, desc, callback)
	pcall(function()
		mod:command(name, desc, callback)
	end)
end

_safe_command("pause", mod:localize("pause_command_description"), function() mod.do_pause() end)
_safe_command("pause_game", mod:localize("pause_command_description"), function() mod.do_pause() end)
_safe_command("unpause", mod:localize("unpause_command_description"), function() mod.do_unpause() end)
_safe_command("save_snapshot", mod:localize("save_snapshot_command_description"), function() mod.do_save_snapshot() end)
_safe_command("restore_snapshot", mod:localize("restore_snapshot_command_description"), function() mod.do_restore_snapshot() end)

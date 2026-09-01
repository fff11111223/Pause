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

-- Freeze / unfreeze a specific player unit for all clients via native game locomotion RPC
local function _set_unit_locomotion_disabled(unit, disabled)
	if not unit or not Unit.alive(unit) then
		return
	end

	pcall(function()
		local locomotion_ext = ScriptUnit.has_extension(unit, "locomotion_system") and ScriptUnit.extension(unit, "locomotion_system")
		if locomotion_ext then
			locomotion_ext:set_disabled(disabled, nil)
		end

		if Managers.player and Managers.player.is_server and Managers.state.network and Managers.state.unit_storage then
			local go_id = Managers.state.unit_storage:go_id(unit)
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

-- Apply unified pause state (Freezes animations at current frame, disables all attacks, locks movement, freezes CD & buffs)
mod.apply_pause_state = function(self, paused)
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
		mod._paused_player_positions = {}
		if Managers.player then
			local players = Managers.player:players()
			for _, player in pairs(players) do
				local unit = player.player_unit
				if unit and Unit.alive(unit) then
					local pos = Unit.world_position(unit, 0)
					local rot = Unit.world_rotation(unit, 0)
					mod._paused_player_positions[unit] = {
						pos = Vector3(pos.x, pos.y, pos.z),
						rot = Quaternion.from_elements(Quaternion.to_elements(rot)),
					}
					_set_unit_locomotion_disabled(unit, true)
					_set_unit_cooldown_paused(unit, true)
				end
			end
		end
	else
		-- 1. Unfreeze world animations and resume game clock
		ScriptWorld.unpause(world)
		if Managers.time:has_timer("game") then
			Managers.time:set_local_scale("game", 1)
		end

		-- 2. Restore movement and unfreeze ability cooldowns for all players
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
		mod:echo(mod:localize("not_server"))
		return
	end

	local new_state = not mod.is_paused
	mod:apply_pause_state(new_state)

	if new_state then
		mod:chat_broadcast(mod:localize("game_paused"))
	else
		mod:chat_broadcast(mod:localize("game_unpaused"))
	end
end

-- Explicit unpause (Host only)
mod.do_unpause = function()
	if not mod.is_in_game() then
		return
	end

	if not Managers.player or not Managers.player.is_server then
		mod:echo(mod:localize("not_server"))
		return
	end

	if mod.is_paused then
		mod:apply_pause_state(false)
		mod:chat_broadcast(mod:localize("game_unpaused"))
	end
end

-- Manual Snapshot Save (Host only)
mod.do_save_snapshot = function()
	if not mod.is_in_game() then
		return
	end
	if not Managers.player or not Managers.player.is_server then
		mod:echo(mod:localize("not_server"))
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
		mod:echo(mod:localize("not_server"))
		return
	end

	SnapshotManager:apply_snapshot()
end

-- Hook ConflictDirector to halt AI director/pacing/spawns during pause
mod:hook(ConflictDirector, "update", function(func, self, dt, t)
	if mod.is_paused then
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
		mod:chat_broadcast(string.format(mod:localize("player_joined_paused"), player_name))
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
					local locomotion = ScriptUnit.has_extension(unit, "locomotion_system") and ScriptUnit.extension(unit, "locomotion_system")
					if locomotion then
						locomotion:teleport_to(data.pos, data.rot)
					end
				end
			end
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

-- Register slash commands
mod:command("pause", mod:localize("pause_command_description"), function() mod.do_pause() end)
mod:command("unpause", mod:localize("unpause_command_description"), function() mod.do_unpause() end)
mod:command("save_snapshot", mod:localize("save_snapshot_command_description"), function() mod.do_save_snapshot() end)
mod:command("restore_snapshot", mod:localize("restore_snapshot_command_description"), function() mod.do_restore_snapshot() end)
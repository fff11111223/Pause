-- SnapshotManager for Pause mod
-- Provides robust capture, persistence, and recovery of level progress, seeds, players, enemies, and stats across Host crashes.

local mod = get_mod("Pause")

-- luacheck: globals Managers ScriptWorld Unit ScriptUnit Vector3 Quaternion Vector3Box QuaternionBox Breeds ItemMasterList NetworkLookup cjson ScoreboardHelper

local SnapshotManager = {}
SnapshotManager.__index = SnapshotManager

local AUTO_SNAPSHOT_INTERVAL = 60 -- Default interval in seconds

-- A unit may be alive before the network manager has registered a game object
-- for it.  Read the storage map directly so readiness checks never invoke a
-- network helper that can assert during that short initialization window.
local function _game_object_id_if_ready(unit)
	local unit_storage = Managers.state and Managers.state.unit_storage
	return unit_storage and unit_storage.bimap_goid_unit and unit_storage.bimap_goid_unit[unit] or nil
end

-- Apply the equipment portion of a player snapshot only after the player's
-- network unit and inventory extension have both finished spawning.
local function _restore_player_equipment(pl_unit, pl_data, pl_go_id, is_remote, network_transmit)
	if not pl_go_id or not pl_unit or not Unit.alive(pl_unit) then
		return false
	end

	local inventory_ext = ScriptUnit.has_extension(pl_unit, "inventory_system") and ScriptUnit.extension(pl_unit, "inventory_system")
	if not inventory_ext or not inventory_ext.get_slot_data then
		return false
	end
	-- The default melee and ranged items establish the attachment hierarchy used
	-- by every later equipment operation.  Wait for both rather than treating an
	-- early inventory extension as fully initialized.
	if not inventory_ext:get_slot_data("slot_melee") or not inventory_ext:get_slot_data("slot_ranged") then
		return false
	end

	if pl_data.ammo and pl_data.ammo.slot_ranged then
		local ranged_ammo = pl_data.ammo.slot_ranged
		local ammo_system = Managers.state.entity and Managers.state.entity:system("ammo_system")
		if ammo_system then
			local exts_by_owner = ammo_system._unit_extensions_by_owner or ammo_system._unit_extensions_by_owener
			if exts_by_owner and exts_by_owner[pl_unit] then
				for _, ext in ipairs(exts_by_owner[pl_unit]) do
					if ext.slot_name == "slot_ranged" then
						if type(ranged_ammo) == "table" then
							ext._current_ammo = ranged_ammo.current_ammo or ext._current_ammo
							ext._available_ammo = ranged_ammo.available_ammo or ext._available_ammo
						elseif type(ranged_ammo) == "number" then
							local max_ammo = ext:max_ammo()
							local target_count = math.round(max_ammo * ranged_ammo)
							local clip_size = ext._ammo_per_clip or max_ammo
							ext._current_ammo = math.min(clip_size, target_count)
							ext._available_ammo = math.max(target_count - ext._current_ammo, 0)
						end
						if ext._update_anim_ammo then
							ext:_update_anim_ammo()
						end
					end
				end
			end
			if is_remote and ammo_system.give_ammo_fraction_to_owner then
				local max_ammo = type(ranged_ammo) == "table" and ranged_ammo.max_ammo or 1
				local total_ammo = type(ranged_ammo) == "table" and ((ranged_ammo.current_ammo or 0) + (ranged_ammo.available_ammo or 0)) or 0
				local fraction = type(ranged_ammo) == "table" and total_ammo / math.max(max_ammo, 1) or ranged_ammo
				ammo_system:give_ammo_fraction_to_owner(pl_unit, fraction, false)
			end
		end

		-- The owner map is not populated for every weapon variant immediately.
		-- Update its weapon extensions as well so the saved raw ammo counts are
		-- restored for all ranged weapons.
		local ranged_slot = inventory_ext:get_slot_data("slot_ranged")
		if ranged_slot then
			for _, weapon_unit in ipairs({ ranged_slot.right_unit_1p, ranged_slot.left_unit_1p, ranged_slot.right_unit_3p, ranged_slot.left_unit_3p }) do
				if weapon_unit and Unit.alive(weapon_unit) and ScriptUnit.has_extension(weapon_unit, "ammo_system") then
					local ammo_ext = ScriptUnit.extension(weapon_unit, "ammo_system")
					if type(ranged_ammo) == "table" then
						ammo_ext._current_ammo = ranged_ammo.current_ammo or ammo_ext._current_ammo
						ammo_ext._available_ammo = ranged_ammo.available_ammo or ammo_ext._available_ammo
					elseif type(ranged_ammo) == "number" then
						local max_ammo = ammo_ext:max_ammo()
						local target_count = math.round(max_ammo * ranged_ammo)
						local clip_size = ammo_ext._ammo_per_clip or max_ammo
						ammo_ext._current_ammo = math.min(clip_size, target_count)
						ammo_ext._available_ammo = math.max(target_count - ammo_ext._current_ammo, 0)
					end
					if ammo_ext._update_anim_ammo then
						ammo_ext:_update_anim_ammo()
					end
				end
			end
		end
	end

	if pl_data.consumables then
		for _, slot_name in ipairs({ "slot_healthkit", "slot_potion", "slot_grenade" }) do
			local desired_item = pl_data.consumables[slot_name]
			local current_slot_data = inventory_ext:get_slot_data(slot_name)
			local current_item_key = current_slot_data and current_slot_data.item_data and current_slot_data.item_data.key
			local slot_id = NetworkLookup.equipment_slots[slot_name]
			if current_item_key ~= desired_item then
				if current_slot_data then
					inventory_ext:destroy_slot(slot_name)
					if network_transmit and slot_id then
						network_transmit:send_rpc_clients("rpc_destroy_slot", pl_go_id, slot_id)
					end
				end
				if desired_item and rawget(ItemMasterList, desired_item) then
					inventory_ext:add_equipment(slot_name, desired_item)
					if network_transmit and slot_id then
						local item_id = NetworkLookup.item_names[desired_item]
						local skin_id = NetworkLookup.weapon_skins["n/a"]
						if item_id and skin_id then
							network_transmit:send_rpc_clients("rpc_add_equipment", pl_go_id, slot_id, item_id, skin_id)
						end
					end
				end
			end
		end
	end

	return true
end

local function _get_respawn_handler()
	local game_mode = Managers.state and Managers.state.game_mode
	if not game_mode then return nil end
	if game_mode.get_respawn_handler then
		return game_mode:get_respawn_handler()
	end
	if game_mode._spawning_component and game_mode._spawning_component.get_respawn_handler then
		return game_mode._spawning_component:get_respawn_handler()
	end
	if game_mode._game_mode and game_mode._game_mode._spawning_component then
		local sc = game_mode._game_mode._spawning_component
		if sc.get_respawn_handler then
			return sc:get_respawn_handler()
		elseif sc._respawn_handler then
			return sc._respawn_handler
		end
	end
	return nil
end

local function _resolve_level_unit(level_object_id, position)
	if not level_object_id and not position then
		return nil
	end

	-- 1. Try resolving via network level object ID (VT2 native GameNetworkManager method)
	local network_manager = Managers.state and Managers.state.network
	if level_object_id and network_manager and network_manager.game_object_or_level_unit then
		local ok, unit = pcall(network_manager.game_object_or_level_unit, network_manager, level_object_id, true)
		if ok and unit and Unit.alive(unit) then
			return unit
		end
	end

	-- 2. Try resolving via Level.unit_by_index
	if level_object_id and Managers.world and Managers.world:has_world("level_world") and rawget(_G, "LevelHelper") and rawget(_G, "Level") then
		local ok, unit = pcall(function()
			local world = Managers.world:world("level_world")
			local level = LevelHelper:current_level(world)
			return Level.unit_by_index(level, level_object_id)
		end)
		if ok and unit and Unit.alive(unit) then
			return unit
		end
	end

	-- 3. Position fallback: match against registered spawners in spawner_system
	if position then
		local spawner_system = Managers.state and Managers.state.entity and Managers.state.entity:system("spawner_system")
		if spawner_system and spawner_system._enabled_spawners then
			local target_pos = Vector3(position[1], position[2], position[3])
			local closest_spawner = nil
			local min_dist_sq = 2.25 -- within 1.5m
			for _, spawner_unit in ipairs(spawner_system._enabled_spawners) do
				if Unit.alive(spawner_unit) then
					local dist_sq = Vector3.distance_squared(target_pos, Unit.world_position(spawner_unit, 0))
					if dist_sq < min_dist_sq then
						min_dist_sq = dist_sq
						closest_spawner = spawner_unit
					end
				end
			end
			if closest_spawner then
				return closest_spawner
			end
		end
	end

	return nil
end

local function _resolve_respawn_unit(respawn_unit_data)
	if not respawn_unit_data then
		return nil
	end

	-- 1. Try resolving via standard level unit resolution
	local u = _resolve_level_unit(respawn_unit_data.level_object_id, respawn_unit_data.position)
	if u and Unit.alive(u) then
		return u
	end

	-- 2. Try resolving via RespawnHandler registered units matching coordinates
	local respawn_handler = _get_respawn_handler()
	if respawn_handler and respawn_handler._respawn_units and respawn_unit_data.position then
		local target_pos = Vector3(respawn_unit_data.position[1], respawn_unit_data.position[2], respawn_unit_data.position[3])
		local closest_unit = nil
		local min_dist_sq = 4.0 -- Within 2 meters threshold
		for _, r_data in ipairs(respawn_handler._respawn_units) do
			local r_unit = r_data.unit
			if r_unit and Unit.alive(r_unit) then
				local u_pos = Unit.world_position(r_unit, 0)
				local dist_sq = Vector3.distance_squared(target_pos, u_pos)
				if dist_sq < min_dist_sq then
					min_dist_sq = dist_sq
					closest_unit = r_unit
				end
			end
		end
		if closest_unit then
			return closest_unit
		end
	end

	return nil
end

function SnapshotManager:init()
	self._auto_timer = 0
	self._level_prompted = false
	self._last_loaded_level = nil
	self._pause_after_restore_countdown = nil
	self._inventory_updates_after_restore_pause = nil
	self._pending_player_equipment_restores = {}
end

--- Collect complete level, flow, player, enemy, and scoreboard state
function SnapshotManager:collect_snapshot()
	if not Managers.world or not Managers.world:has_world("level_world") then
		return nil, "Not in a playable level"
	end
	if not Managers.player or not Managers.player.is_server then
		return nil, "Only host can capture snapshot"
	end

	local level_key = Managers.level_transition_handler and Managers.level_transition_handler:get_current_level_key()
	if not level_key or mod.is_in_inn() then
		return nil, "Cannot save snapshot in Inn/Lobby"
	end
	local level_seed = Managers.level_transition_handler:get_current_level_seed()
	local difficulty, difficulty_tweak = Managers.state.difficulty:get_difficulty()
	local mechanism = Managers.mechanism and Managers.mechanism:current_mechanism_name() or "adventure"
	local game_mode = Managers.state.game_mode and Managers.state.game_mode:settings().key or "adventure"

	local snapshot = {
		version = 2,
		timestamp = os.time(),
		level_key = level_key,
		level_seed = level_seed,
		difficulty = difficulty,
		difficulty_tweak = difficulty_tweak,
		mechanism = mechanism,
		game_mode = game_mode,
		missions = nil,
		networked_flow = nil,
		pickups = nil,
		level_analysis = nil,
		players = {},
		enemies = {},
		horde_spawner = nil,
		conflict_pacing = nil,
		scoreboard = {},
	}

	-- 1. MissionSystem checkpoint data
	pcall(function()
		local mission_system = Managers.state.entity:system("mission_system")
		if mission_system and mission_system.create_checkpoint_data then
			snapshot.missions = mission_system:create_checkpoint_data()
		end
	end)

	-- 2. NetworkedFlowState checkpoint data (doors, bridges, destructibles)
	pcall(function()
		local flow_state = Managers.state.networked_flow_state
		if flow_state and flow_state.create_checkpoint_data then
			snapshot.networked_flow = flow_state:create_checkpoint_data()
		end
	end)

	-- 3. PickupSystem checkpoint data (already taken books/potions)
	pcall(function()
		local pickup_system = Managers.state.entity:system("pickup_system")
		if pickup_system and pickup_system.create_checkpoint_data then
			snapshot.pickups = pickup_system:create_checkpoint_data()
		end
	end)

	-- 4. LevelAnalysis checkpoint data (random seeds for level paths)
	pcall(function()
		local level_analysis = Managers.state.conflict and Managers.state.conflict.level_analysis
		if level_analysis and level_analysis.create_checkpoint_data then
			snapshot.level_analysis = level_analysis:create_checkpoint_data()
		end
	end)

	-- 5. Players State (Living & Dead/Respawning)
	pcall(function()
		local players = Managers.player:players()
		local party_manager = Managers.party
		local current_game_t = Managers.time and Managers.time:has_timer("game") and Managers.time:time("game") or 0

		for _, player in pairs(players) do
			local peer_id = player:network_id()
			local local_player_id = player:local_player_id()
			local pl_unit = player.player_unit
			local p_status = party_manager and party_manager:get_player_status(peer_id, local_player_id)
			local gm_data = p_status and p_status.game_mode_data

			local has_unit = pl_unit and Unit.alive(pl_unit)
			local health_ext = has_unit and ScriptUnit.has_extension(pl_unit, "health_system") and ScriptUnit.extension(pl_unit, "health_system")
			local status_ext = has_unit and ScriptUnit.has_extension(pl_unit, "status_system") and ScriptUnit.extension(pl_unit, "status_system")
			local career_ext = has_unit and ScriptUnit.has_extension(pl_unit, "career_system") and ScriptUnit.extension(pl_unit, "career_system")
			local inventory_ext = has_unit and ScriptUnit.has_extension(pl_unit, "inventory_system") and ScriptUnit.extension(pl_unit, "inventory_system")

			local is_knocked_down = (status_ext and status_ext:is_knocked_down()) or (gm_data and gm_data.health_state == "knocked_down") or false
			local is_ready_for_assisted_respawn = (status_ext and status_ext:is_ready_for_assisted_respawn()) or (gm_data and gm_data.health_state == "respawn") or false
			local is_dead = (status_ext and status_ext:is_dead()) or (gm_data and gm_data.health_state == "dead") or (not has_unit and not is_ready_for_assisted_respawn) or false

			-- Position & Rotation
			local pos_tbl = { 0, 0, 0 }
			local rot_tbl = { 0, 0, 0, 1 }
			if has_unit then
				local pos = Unit.world_position(pl_unit, 0)
				local rot = Unit.world_rotation(pl_unit, 0)
				local qx, qy, qz, qw = Quaternion.to_elements(rot)
				pos_tbl = { pos.x, pos.y, pos.z }
				rot_tbl = { qx, qy, qz, qw }
			elseif gm_data and gm_data.position and gm_data.rotation then
				pos_tbl = { gm_data.position[1] or 0, gm_data.position[2] or 0, gm_data.position[3] or 0 }
				rot_tbl = { gm_data.rotation[1] or 0, gm_data.rotation[2] or 0, gm_data.rotation[3] or 0, gm_data.rotation[4] or 1 }
			end

			-- Consumables
			local consumables = {}
			if inventory_ext and rawget(_G, "SpawningHelper") then
				SpawningHelper.fill_consumable_table(consumables, inventory_ext)
			elseif gm_data and gm_data.consumables then
				consumables = table.clone(gm_data.consumables)
			end

			-- Exact raw Health numbers
			local damage_taken = 0
			local max_health = 100
			local current_permanent_health = 100
			local current_temporary_health = 0
			if health_ext then
				damage_taken = health_ext:get_damage_taken() or 0
				max_health = health_ext:get_max_health() or 100
				current_permanent_health = math.max(max_health - damage_taken, 0)
				current_temporary_health = health_ext:current_temporary_health() or 0
			elseif is_dead then
				damage_taken = 100
				max_health = 100
				current_permanent_health = 0
				current_temporary_health = 0
			end

			-- Exact raw Ammo counts
			local ranged_ammo_data = nil
			local ammo_system = Managers.state.entity:system("ammo_system")
			if ammo_system and has_unit then
				local exts_by_owner = ammo_system._unit_extensions_by_owner or ammo_system._unit_extensions_by_owener
				if exts_by_owner and exts_by_owner[pl_unit] then
					for _, ext in ipairs(exts_by_owner[pl_unit]) do
						if ext.slot_name == "slot_ranged" then
							ranged_ammo_data = {
								current_ammo = ext._current_ammo or 0,
								available_ammo = ext._available_ammo or 0,
								max_ammo = ext._max_ammo or 0,
							}
							break
						end
					end
				end
			end

			-- Exact raw Ability Cooldown in seconds
			local ability_cooldown = career_ext and career_ext._ability_cooldown or 0
			local max_ability_cooldown = career_ext and career_ext:get_max_ability_cooldown() or 0

			-- Respawn details (Respawn timer, respawn state, respawn unit/position)
			local respawn_state = nil
			local respawn_remaining_time = nil
			local respawn_unit_data = nil

			if is_ready_for_assisted_respawn then
				respawn_state = "respawn" -- already spawned and waiting for rescue
			elseif is_dead then
				if gm_data and gm_data.ready_for_respawn then
					respawn_state = "ready_for_respawn"
					respawn_remaining_time = 0
				elseif gm_data and gm_data.respawn_timer then
					respawn_remaining_time = math.max(gm_data.respawn_timer - current_game_t, 0)
					if respawn_remaining_time <= 0 then
						respawn_state = "ready_for_respawn"
					else
						respawn_state = "countdown"
					end
				else
					respawn_state = "countdown"
					respawn_remaining_time = nil
				end
			end

			if gm_data and gm_data.respawn_unit and Unit.alive(gm_data.respawn_unit) then
				local r_unit = gm_data.respawn_unit
				local r_pos = Unit.world_position(r_unit, 0)
				local r_rot = Unit.world_rotation(r_unit, 0)
				local rqx, rqy, rqz, rqw = Quaternion.to_elements(r_rot)
				local r_id = Managers.state.network and Managers.state.network:level_object_id(r_unit)
				respawn_unit_data = {
					position = { r_pos.x, r_pos.y, r_pos.z },
					rotation = { rqx, rqy, rqz, rqw },
					level_object_id = r_id,
				}
			end

			local player_data = {
				peer_id = peer_id,
				local_player_id = local_player_id,
				profile_index = player:profile_index(),
				career_index = player:career_index(),
				hero_name = player:name(),
				is_bot = not not player.bot_player,
				position = pos_tbl,
				rotation = rot_tbl,
				-- Exact raw Health numbers
				current_permanent_health = current_permanent_health,
				current_temporary_health = current_temporary_health,
				damage_taken = damage_taken,
				max_health = max_health,
				-- Status
				is_knocked_down = is_knocked_down,
				is_dead = is_dead,
				is_ready_for_assisted_respawn = is_ready_for_assisted_respawn,
				-- Respawn State & Countdown
				respawn_state = respawn_state,
				respawn_remaining_time = respawn_remaining_time,
				respawn_unit_data = respawn_unit_data,
				-- Pacing Intensity
				pacing_intensity = status_ext and status_ext.pacing_intensity or 0,
				pacing_intensity_decay_delay = status_ext and status_ext.pacing_intensity_decay_delay or 0,
				-- Exact raw Ability Cooldown in seconds
				ability_cooldown = ability_cooldown,
				max_ability_cooldown = max_ability_cooldown,
				-- Consumables
				consumables = consumables,
				-- Exact raw Ammo counts
				ammo = {
					slot_ranged = ranged_ammo_data,
				},
			}

			table.insert(snapshot.players, player_data)
		end
	end)

	-- 6. Living Enemies State
	pcall(function()
		if Managers.state.conflict and Managers.state.conflict.all_spawned_units then
			local spawned_units, num_units = Managers.state.conflict:all_spawned_units()
			for i = 1, num_units do
				local ai_unit = spawned_units[i]
				if ai_unit and Unit.alive(ai_unit) then
					local ai_ext = ScriptUnit.has_extension(ai_unit, "ai_system") and ScriptUnit.extension(ai_unit, "ai_system")
					local breed = ai_ext and ai_ext:breed()
					if breed and breed.name and not breed.is_hero and not breed.is_player and not breed.name:find("training_dummy") then
						local pos = Unit.world_position(ai_unit, 0)
						local rot = Unit.world_rotation(ai_unit, 0)
						local qx, qy, qz, qw = Quaternion.to_elements(rot)
						local health_ext = ScriptUnit.has_extension(ai_unit, "health_system") and ScriptUnit.extension(ai_unit, "health_system")
						local damage_taken = health_ext and health_ext:get_damage_taken() or 0

						table.insert(snapshot.enemies, {
							breed_name = breed.name,
							position = { pos.x, pos.y, pos.z },
							rotation = { qx, qy, qz, qw },
							damage_taken = damage_taken,
						})
					end
				end
			end
		end
	end)

	-- 7. Scoreboard Statistics (Save exact raw stats to support full rollback)
	pcall(function()
		local statistics_db = Managers.player and Managers.player:statistics_db()
		local players = Managers.player and Managers.player:players()
		if statistics_db and players and rawget(_G, "ScoreboardHelper") then
			local scoreboard_topics = ScoreboardHelper.scoreboard_topic_stats
			for _, player in pairs(players) do
				local stats_id = player:stats_id()
				local player_scores = {}
				local raw_stats = {}

				for _, topic in ipairs(scoreboard_topics) do
					local stat_types = topic.stat_types
					local score = 0
					if stat_types ~= nil then
						for j = 1, #stat_types do
							local st = stat_types[j]
							local v = 0
							if type(st) == "table" then
								v = statistics_db:get_stat(stats_id, unpack(st)) or 0
								local path_key = table.concat(st, "##")
								raw_stats[path_key] = v
							else
								v = statistics_db:get_stat(stats_id, st) or 0
								raw_stats[tostring(st)] = v
							end
							score = score + v
						end
					elseif topic.stat_type then
						local st = topic.stat_type
						local v = 0
						if type(st) == "table" then
							v = statistics_db:get_stat(stats_id, unpack(st)) or 0
							local path_key = table.concat(st, "##")
							raw_stats[path_key] = v
						else
							v = statistics_db:get_stat(stats_id, st) or 0
							raw_stats[tostring(st)] = v
						end
						score = v
					end
					player_scores[topic.name] = score
				end

				-- Explicitly capture direct total damage dealt & taken
				local direct_dmg = statistics_db:get_stat(stats_id, "damage_dealt") or 0
				raw_stats["damage_dealt"] = direct_dmg
				player_scores["damage_dealt"] = direct_dmg

				local direct_taken = statistics_db:get_stat(stats_id, "damage_taken") or 0
				raw_stats["damage_taken"] = direct_taken
				player_scores["damage_taken"] = direct_taken

				-- DEBUG: print captured damage values
				mod:echo("[Snapshot] Captured stats for " .. tostring(p_name or stats_id) .. ": dmg_dealt=" .. tostring(direct_dmg) .. " dmg_taken=" .. tostring(direct_taken) .. " stats_id=" .. tostring(stats_id))

				local entry = {
					stats_id = stats_id,
					profile_index = player:profile_index(),
					career_index = player:career_index(),
					name = player:name(),
					scores = player_scores,
					raw_stats = raw_stats,
				}

				if player:name() then
					snapshot.scoreboard[player:name()] = entry
				end
				snapshot.scoreboard[stats_id] = entry
				if player:profile_index() then
					snapshot.scoreboard[tostring(player:profile_index())] = entry
				end
			end
		end
	end)

	-- 8. HordeSpawner State (Preserve active and queued hordes, timers, spawners, etc.)
	pcall(function()
		local conflict = Managers.state.conflict
		local horde_spawner = conflict and conflict.horde_spawner
		if not horde_spawner then
			return
		end

		local current_t = Managers.time and Managers.time:has_timer("game") and Managers.time:time("game") or 0
		local saved_hordes = {}

		if horde_spawner.hordes then
			for _, horde in ipairs(horde_spawner.hordes) do
				local start_time = horde.start_time or current_t
				local start_time_remaining = math.max(start_time - current_t, 0)
				local end_time_remaining = horde.end_time and math.max(horde.end_time - current_t, 0) or nil

				-- Main target pos & epicenter pos (unbox Vector3Box if present)
				local main_target_pos = nil
				if horde.main_target_pos and horde.main_target_pos.unbox then
					local p = horde.main_target_pos:unbox()
					main_target_pos = { p.x, p.y, p.z }
				elseif type(horde.main_target_pos) == "table" and horde.main_target_pos[1] then
					main_target_pos = { horde.main_target_pos[1], horde.main_target_pos[2], horde.main_target_pos[3] }
				end

				local epicenter_pos = nil
				if horde.epicenter_pos and horde.epicenter_pos.unbox then
					local p = horde.epicenter_pos:unbox()
					epicenter_pos = { p.x, p.y, p.z }
				elseif type(horde.epicenter_pos) == "table" and horde.epicenter_pos[1] then
					epicenter_pos = { horde.epicenter_pos[1], horde.epicenter_pos[2], horde.epicenter_pos[3] }
				end

				-- Group template (sanitize userdata if present)
				local saved_group_template = nil
				if horde.group_template then
					saved_group_template = {
						id = horde.group_template.id or horde.group_id,
						template = horde.group_template.template or "horde",
						size = horde.group_template.size,
					}
				end

				-- Sound settings
				local saved_sound_settings = nil
				if horde.sound_settings then
					saved_sound_settings = table.clone(horde.sound_settings)
				end

				-- Optional data
				local saved_optional_data = nil
				if horde.optional_data and type(horde.optional_data) == "table" then
					saved_optional_data = {}
					for k, v in pairs(horde.optional_data) do
						if type(v) ~= "userdata" and type(v) ~= "function" then
							saved_optional_data[k] = v
						end
					end
				end

				-- Source unit (for event hordes)
				local source_unit_data = nil
				if horde.source_unit and Unit.alive(horde.source_unit) then
					local s_id = Managers.state.network and Managers.state.network:level_object_id(horde.source_unit)
					local sp = Unit.world_position(horde.source_unit, 0)
					source_unit_data = {
						level_object_id = s_id,
						position = { sp.x, sp.y, sp.z },
					}
				end

				-- Horde spawns
				local saved_horde_spawns = nil
				if horde.horde_spawns then
					saved_horde_spawns = {}
					for _, hs in ipairs(horde.horde_spawns) do
						local spawner_data = nil
						if hs.spawner and Unit.alive(hs.spawner) then
							local sp_id = Managers.state.network and Managers.state.network:level_object_id(hs.spawner)
							local sp_pos = Unit.world_position(hs.spawner, 0)
							spawner_data = {
								level_object_id = sp_id,
								position = { sp_pos.x, sp_pos.y, sp_pos.z },
							}
						end

						local all_done_spawned_remaining = hs.all_done_spawned_time and math.max(hs.all_done_spawned_time - current_t, 0) or nil

						table.insert(saved_horde_spawns, {
							num_to_spawn = hs.num_to_spawn or 0,
							spawner_data = spawner_data,
							spawn_list = table.clone(hs.spawn_list or {}),
							hidden = not not hs.hidden,
							done = not not hs.done,
							all_done_spawned_remaining = all_done_spawned_remaining,
						})
					end
				end

				-- Cover spawns
				local saved_cover_spawns = nil
				if horde.cover_spawns then
					saved_cover_spawns = {}
					for _, cs in ipairs(horde.cover_spawns) do
						local cover_data = nil
						if cs.cover_point_unit and Unit.alive(cs.cover_point_unit) then
							local cp_id = Managers.state.network and Managers.state.network:level_object_id(cs.cover_point_unit)
							local cp_pos = Unit.world_position(cs.cover_point_unit, 0)
							cover_data = {
								level_object_id = cp_id,
								position = { cp_pos.x, cp_pos.y, cp_pos.z },
							}
						end

						local next_spawn_remaining = cs.next_spawn_time and math.max(cs.next_spawn_time - current_t, 0) or 0

						table.insert(saved_cover_spawns, {
							num_to_spawn = cs.num_to_spawn or 0,
							cover_data = cover_data,
							spawn_list = table.clone(cs.spawn_list or {}),
							next_spawn_remaining = next_spawn_remaining,
							dont_move = not not cs.dont_move,
						})
					end
				end

				-- Terror event ids
				local saved_terror_ids = nil
				if horde.terror_event_ids then
					saved_terror_ids = table.clone(horde.terror_event_ids)
				end

				-- Variant (composition)
				local saved_variant = nil
				if horde.variant and type(horde.variant) == "table" then
					saved_variant = table.clone(horde.variant)
				end

				local horde_entry = {
					horde_type = horde.horde_type or "vector",
					started = not not horde.started,
					start_time_remaining = start_time_remaining,
					end_time_remaining = end_time_remaining,
					spawned = horde.spawned or 0,
					num_to_spawn = horde.num_to_spawn or 0,
					group_id = horde.group_id,
					side_id = horde.side_id or 2,
					silent = not not horde.silent,
					main_target_pos = main_target_pos,
					epicenter_pos = epicenter_pos,
					group_template = saved_group_template,
					sound_settings = saved_sound_settings,
					optional_data = saved_optional_data,
					source_unit_data = source_unit_data,
					horde_spawns = saved_horde_spawns,
					cover_spawns = saved_cover_spawns,
					terror_event_ids = saved_terror_ids,
					composition_type = horde.composition_type,
					limit_spawners = horde.limit_spawners,
					strictly = horde.strictly,
					use_closest_spawners = horde.use_closest_spawners,
					variant = saved_variant,
					amount = horde.amount,
					failed = not not horde.failed,
				}

				table.insert(saved_hordes, horde_entry)
			end
		end

		snapshot.horde_spawner = {
			running_horde_type = horde_spawner._running_horde_type,
			running_horde_sound_settings = horde_spawner._running_horde_sound_settings and table.clone(horde_spawner._running_horde_sound_settings) or nil,
			num_paced_hordes = horde_spawner.num_paced_hordes or 0,
			last_paced_horde_type = horde_spawner.last_paced_horde_type,
			hordes = saved_hordes,
		}
	end)

	-- 9. Conflict Director Pacing & Horde Timing State
	pcall(function()
		local conflict = Managers.state.conflict
		if not conflict then
			return
		end

		local current_t = Managers.time and Managers.time:has_timer("game") and Managers.time:time("game") or 0
		local pacing = conflict.pacing

		local pacing_data = nil
		if pacing then
			local state_start_elapsed = math.max(current_t - (pacing._state_start_time or current_t), 0)
			local end_pacing_remaining = nil
			if pacing._end_pacing_time then
				end_pacing_remaining = math.max(pacing._end_pacing_time - current_t, 0)
			end

			pacing_data = {
				pacing_state = pacing.pacing_state,
				total_intensity = pacing.total_intensity or 0,
				player_intensity = pacing.player_intensity and table.clone(pacing.player_intensity) or {},
				state_start_time_elapsed = state_start_elapsed,
				end_pacing_time_remaining = end_pacing_remaining,
				threat_population = pacing._threat_population,
				specials_population = pacing._specials_population,
				horde_population = pacing._horde_population,
			}
		end

		local next_horde_rem = nil
		if conflict._next_horde_time == math.huge then
			next_horde_rem = "huge"
		elseif type(conflict._next_horde_time) == "number" then
			next_horde_rem = math.max(conflict._next_horde_time - current_t, 0)
		end

		local horde_ends_rem = nil
		if conflict._horde_ends_at == math.huge then
			horde_ends_rem = "huge"
		elseif type(conflict._horde_ends_at) == "number" then
			horde_ends_rem = math.max(conflict._horde_ends_at - current_t, 0)
		end

		-- specials_pacing (if active)
		local specials_pacing_data = nil
		local sp_pacing = conflict.specials_pacing
		if sp_pacing and sp_pacing._specials_slots then
			local saved_slots = {}
			for i, slot in ipairs(sp_pacing._specials_slots) do
				local slot_time_rem = nil
				if type(slot.time) == "number" then
					slot_time_rem = math.max(slot.time - current_t, 0)
				end
				local stinger_rem = nil
				if type(slot.special_spawn_stinger_at_t) == "number" then
					stinger_rem = math.max(slot.special_spawn_stinger_at_t - current_t, 0)
				end
				saved_slots[i] = {
					state = slot.state,
					breed = slot.breed,
					time_remaining = slot_time_rem,
					health_modifier = slot.health_modifier,
					special_spawn_stinger = slot.special_spawn_stinger,
					stinger_remaining = stinger_rem,
				}
			end

			local saved_state_data = nil
			if sp_pacing._state_data then
				local sd = sp_pacing._state_data
				saved_state_data = {
					override_breed_name = sd.override_breed_name,
					coordinated_timer_remaining = sd.coordinated_timer and math.max(sd.coordinated_timer - current_t, 0) or nil,
					coord_time_check_remaining = sd.coord_time_check and math.max(sd.coord_time_check - current_t, 0) or nil,
				}
			end

			specials_pacing_data = {
				slots = saved_slots,
				state_data = saved_state_data,
				disabled = sp_pacing._disabled,
				specials_timer = sp_pacing._specials_timer,
			}
		end

		snapshot.conflict_pacing = {
			pacing = pacing_data,
			next_horde_time_remaining = next_horde_rem,
			horde_ends_at_remaining = horde_ends_rem,
			multiple_horde_count = conflict._multiple_horde_count,
			current_wave_composition = conflict._current_wave_composition,
			wave = conflict._wave,
			living_horde = conflict._living_horde or 0,
			delay_horde = conflict.delay_horde,
			delay_specials = conflict.delay_specials,
			delay_mini_patrol = conflict.delay_mini_patrol,
			event_delay = conflict.event_delay,
			threat_value = conflict.threat_value or 0,
			num_aggroed = conflict.num_aggroed or 0,
			specials_pacing = specials_pacing_data,
		}
	end)

	return snapshot
end

-- Deep sanitizer to ensure all tables, keys, and values are JSON-serializable
local function _sanitize_for_json(val, visited)
	visited = visited or {}
	local val_type = type(val)

	if val_type == "number" or val_type == "string" or val_type == "boolean" then
		return val
	elseif val_type == "nil" then
		return nil
	elseif val_type == "userdata" then
		-- Check if it is a Vector3
		if Vector3 and pcall(Vector3.to_elements, val) then
			local x, y, z = Vector3.to_elements(val)
			return { x, y, z }
		end
		-- Check if it is a Quaternion
		if Quaternion and pcall(Quaternion.to_elements, val) then
			local x, y, z, w = Quaternion.to_elements(val)
			return { x, y, z, w }
		end
		-- Check if it is a Vector3Box
		if Vector3Box and pcall(Vector3Box.unbox, val) then
			local vec = val:unbox()
			if vec then
				return { vec.x, vec.y, vec.z }
			end
		end
		-- Check if it is a QuaternionBox
		if QuaternionBox and pcall(QuaternionBox.unbox, val) then
			local q = val:unbox()
			if q then
				local x, y, z, w = Quaternion.to_elements(q)
				return { x, y, z, w }
			end
		end
		-- Other userdata: ignore/nil to avoid JSON crash
		return nil
	elseif val_type == "table" then
		if visited[val] then
			return nil -- Avoid circular references
		end
		visited[val] = true

		-- Check if table is a dense sequential array (1..N with no holes)
		local count = 0
		local max_int_key = 0
		local has_non_int = false

		for k, _ in pairs(val) do
			count = count + 1
			if type(k) == "number" and math.floor(k) == k and k >= 1 then
				if k > max_int_key then
					max_int_key = k
				end
			else
				has_non_int = true
			end
		end

		local is_dense_array = (not has_non_int) and (count > 0) and (max_int_key == count)

		local clean_table = {}
		if is_dense_array then
			-- Safe sequential array -> encode as JSON array [ ... ]
			for i = 1, count do
				clean_table[i] = _sanitize_for_json(val[i], visited)
			end
		else
			-- Object/Map: Force ALL keys to string to prevent cjson "excessively sparse array" error!
			for k, v in pairs(val) do
				local clean_v = _sanitize_for_json(v, visited)
				if clean_v ~= nil then
					local clean_k = tostring(k)
					clean_table[clean_k] = clean_v
				end
			end
		end

		visited[val] = nil
		return clean_table
	else
		-- Functions, threads, etc. are omitted
		return nil
	end
end

--- Save snapshot to file with atomic backup
function SnapshotManager:save_snapshot(is_auto)
	local snapshot, err = self:collect_snapshot()
	if not snapshot then
		if not is_auto then
			mod:chat_broadcast(mod:localize("snapshot_save_failed") .. " (" .. tostring(err) .. ")")
		end
		return false
	end

	-- Deeply sanitize table to remove any non-serializable userdata or invalid keys
	local clean_snapshot = _sanitize_for_json(snapshot)

	local success, json_str_or_err = pcall(cjson.encode, clean_snapshot)
	if not success or not json_str_or_err then
		local err_msg = tostring(json_str_or_err or "Unknown")
		mod:echo("[Pause] JSON Encode Error: " .. err_msg)
		if not is_auto then
			mod:chat_broadcast(mod:localize("snapshot_save_failed") .. " (" .. err_msg .. ")")
		end
		return false
	end

	local json_str = json_str_or_err

	-- Backup previous snapshot and save new snapshot via VMF persistent storage
	local prev_snapshot = mod:get("latest_snapshot")
	if prev_snapshot then
		mod:set("backup_snapshot", prev_snapshot)
	end
	mod:set("latest_snapshot", json_str)

	if not is_auto then
		mod:chat_broadcast(mod:localize("snapshot_saved"))
	end
	return true
end

--- Load snapshot from VMF persistent storage
function SnapshotManager:load_snapshot()
	local json_data = mod:get("latest_snapshot")
	if not json_data then
		json_data = mod:get("backup_snapshot")
	end

	if not json_data then
		return nil, "No snapshot file found"
	end

	local snapshot = nil
	if type(json_data) == "string" then
		local success, decoded = pcall(cjson.decode, json_data)
		if success and decoded then
			snapshot = decoded
		end
	elseif type(json_data) == "table" then
		snapshot = json_data
	end

	if not snapshot then
		return nil, "Corrupted snapshot file"
	end

	return snapshot
end

--- Check if a valid snapshot matches current level
function SnapshotManager:has_snapshot_for_current_level()
	local snapshot = self:load_snapshot()
	if not snapshot or not snapshot.level_key then
		return false, nil
	end

	local current_level = Managers.level_transition_handler and Managers.level_transition_handler:get_current_level_key()
	if current_level and current_level == snapshot.level_key then
		return true, snapshot
	end

	return false, snapshot
end

--- Clean up snapshots (keep only last match)
function SnapshotManager:cleanup_snapshot()
	mod:set("latest_snapshot", nil)
	mod:set("backup_snapshot", nil)
end

--- Apply a loaded snapshot to the current match
function SnapshotManager:apply_snapshot(snapshot)
	snapshot = snapshot or self:load_snapshot()
	if not snapshot then
		mod:chat_broadcast(mod:localize("snapshot_not_found"))
		return false
	end

	if not Managers.player or not Managers.player.is_server then
		mod:chat_broadcast(mod:localize("not_server"))
		return false
	end

	if mod.is_in_inn() then
		mod:chat_broadcast(mod:safe_localize("cannot_restore_in_inn"))
		return false
	end

	local current_level = Managers.level_transition_handler and Managers.level_transition_handler:get_current_level_key()
	if snapshot.level_key ~= current_level then
		local mismatch_msg = mod:safe_localize("snapshot_level_mismatch", snapshot.level_key, current_level)
		mod:chat_broadcast(mismatch_msg)
		return false
	end

	-- If previously paused, temporarily unpause so physics, camera and units can process restore and render
	if mod.is_paused then
		mod:apply_pause_state(false)
	end

	-- Clear dialogue system queries and playing dialogues to avoid invalid key to 'next' crash during restore
	pcall(function()
		local dlg_sys = Managers.state.entity:system("dialogue_system")
		if dlg_sys then
			if dlg_sys._tagquery_database and dlg_sys._tagquery_database.queries then
				table.clear(dlg_sys._tagquery_database.queries)
			end
			if dlg_sys._playing_dialogues then
				table.clear(dlg_sys._playing_dialogues)
			end
		end
	end)

	-- 1. Restore Level Seed & Analysis
	pcall(function()
		if snapshot.level_seed and Managers.state.conflict and Managers.state.conflict.level_analysis then
			Managers.state.conflict.level_analysis:set_random_seed(snapshot.level_analysis, snapshot.level_seed)
		end
	end)

	-- 2. Restore Missions (Completed & Active)
	pcall(function()
		if snapshot.missions and Managers.state.entity:system("mission_system") then
			Managers.state.entity:system("mission_system"):load_checkpoint_data(snapshot.missions)
		end
	end)

	-- 3. Restore Networked Flow State (Doors, bridges, event triggers)
	pcall(function()
		if snapshot.networked_flow and Managers.state.networked_flow_state then
			Managers.state.networked_flow_state:load_checkpoint_data(snapshot.networked_flow)
		end
	end)

	-- 4. Restore Taken Pickups (Tomest/Grimoires/Items already taken)
	pcall(function()
		if snapshot.pickups and Managers.state.entity:system("pickup_system") then
			Managers.state.entity:system("pickup_system"):setup_taken_pickups(snapshot.pickups)
		end
	end)

	-- 5. Restore Players (Teleport, Status, HP, THP, Ammo, Consumables, Cooldown)
	local pl_ok, pl_err = pcall(function()
		local current_players = Managers.player:players()
		local network_transmit = Managers.state.network and Managers.state.network.network_transmit

		for _, pl_data in ipairs(snapshot.players or {}) do
			local matched_player = nil
			-- Match by profile / hero
			for _, player in pairs(current_players) do
				if player:profile_index() == pl_data.profile_index or player:name() == pl_data.hero_name then
					matched_player = player
					break
				end
			end

			if matched_player then
				local pos = Vector3(pl_data.position[1], pl_data.position[2], pl_data.position[3])
				local rot = Quaternion.from_elements(pl_data.rotation[1], pl_data.rotation[2], pl_data.rotation[3], pl_data.rotation[4])
				local was_knocked_down = pl_data.is_knocked_down == true
				local was_dead = pl_data.is_dead == true

				if was_dead then
					-- CASE: DEAD / RESPAWNING PLAYER
					local pl_unit = matched_player.player_unit
					if pl_unit and Unit.alive(pl_unit) then
						pcall(function()
							local death_system = Managers.state.entity:system("death_system")
							if death_system then
								death_system:forced_kill(pl_unit, "forced")
							else
								local health_ext = ScriptUnit.has_extension(pl_unit, "health_system") and ScriptUnit.extension(pl_unit, "health_system")
								if health_ext and health_ext.die then
									health_ext:die("forced")
								end
							end
						end)
						local status_ext = ScriptUnit.has_extension(pl_unit, "status_system") and ScriptUnit.extension(pl_unit, "status_system")
						if status_ext then
							status_ext:set_dead(true)
						end
						local health_ext = ScriptUnit.has_extension(pl_unit, "health_system") and ScriptUnit.extension(pl_unit, "health_system")
						if health_ext then
							health_ext.state = "dead"
							health_ext.previous_state = "dead"
							health_ext.set_health_percentage = 0
							health_ext.set_temporary_health_percentage = 0
							if health_ext.health_game_object_id and health_ext.game then
								GameSession.set_game_object_field(health_ext.game, health_ext.health_game_object_id, "current_health", 0)
								GameSession.set_game_object_field(health_ext.game, health_ext.health_game_object_id, "current_temporary_health", 0)
							end
							local max_hp = pl_data.max_health or 100
							health_ext:set_server_damage_taken(max_hp)
						end
					end

					-- If remote client, switch to observer/spectator camera
					pcall(function()
						local is_remote = matched_player.remote
						if is_remote and rawget(_G, "PEER_ID_TO_CHANNEL") and rawget(_G, "RPC") and RPC.rpc_set_observer_camera then
							local peer_id = matched_player:network_id()
							local channel_id = PEER_ID_TO_CHANNEL[peer_id]
							if channel_id then
								RPC.rpc_set_observer_camera(channel_id, matched_player:local_player_id())
							end
						end
					end)

					-- Restore native respawn state into party game_mode_data
					-- Flow:
					-- 1. If respawn_unit was already designated (or already tied up): restore that exact respawn_unit and ready_for_respawn = true
					-- 2. If timer already expired: data.ready_for_respawn = true, data.respawn_timer = nil -> VT2 native finds respawn point -> Respawn
					-- 3. If timer not yet expired: data.ready_for_respawn = false, data.respawn_timer = t + remaining -> wait -> expires -> VT2 native finds respawn point -> Respawn
					pcall(function()
						local party_manager = Managers.party
						if party_manager then
							local p_status = party_manager:get_player_status(matched_player:network_id(), matched_player:local_player_id())
							if p_status and p_status.game_mode_data then
								local data = p_status.game_mode_data
								data.health_state = "dead"
								data.spawn_state = "despawned"
								data.health_percentage = 0
								data.temporary_health_percentage = 0

								-- Resolve and restore pre-selected Respawn Unit if one was saved
								local restored_respawn_unit = _resolve_respawn_unit(pl_data.respawn_unit_data)
								data.respawn_unit = restored_respawn_unit

								if pl_data.respawn_state == "ready_for_respawn" or pl_data.respawn_state == "respawn" or restored_respawn_unit ~= nil then
									data.ready_for_respawn = true
									data.respawn_timer = nil
								else
									data.ready_for_respawn = false
									local current_t = Managers.time and Managers.time:has_timer("game") and Managers.time:time("game") or 0
									if pl_data.respawn_remaining_time and pl_data.respawn_remaining_time > 0 then
										data.respawn_timer = current_t + pl_data.respawn_remaining_time
									else
										data.respawn_timer = nil
									end
								end

								if pl_data.consumables then
									data.consumables = table.clone(pl_data.consumables)
								end
							end
						end
					end)

				else
					-- CASE: ALIVE PLAYER (NORMAL OR KNOCKED DOWN)
					local spawned_player_unit = false
					if (not matched_player.player_unit or not Unit.alive(matched_player.player_unit)) then
						spawned_player_unit = true
						pcall(function()
							matched_player:spawn(pos, rot, false)
						end)
					end

					local pl_unit = matched_player.player_unit
					if pl_unit and Unit.alive(pl_unit) then
						local is_remote = matched_player.remote
						local pl_go_id = _game_object_id_if_ready(pl_unit)
						local locomotion_ext = ScriptUnit.has_extension(pl_unit, "locomotion_system") and ScriptUnit.extension(pl_unit, "locomotion_system")

						-- 1. Teleport player & camera, and broadcast RPC to remote clients
						-- spawn() already uses pos/rot.  Do not touch first-person or mover
						-- state again until a newly spawned unit has completed initialization.
						if not spawned_player_unit and locomotion_ext then
							locomotion_ext:teleport_to(pos, rot)
						end
						if is_remote and pl_go_id and network_transmit then
							network_transmit:send_rpc_clients("rpc_teleport_unit_to", pl_go_id, pos, rot)
						end

						local fp_ext = ScriptUnit.has_extension(pl_unit, "first_person_system") and ScriptUnit.extension(pl_unit, "first_person_system")
						if not spawned_player_unit and fp_ext and fp_ext.update_position then
							fp_ext:update_position()
						end

						-- Lock movement right away so player doesn't wander off during frame refresh
						if mod.set_unit_locomotion_disabled then
							mod.set_unit_locomotion_disabled(pl_unit, true)
						end

						-- Immediately update mod._paused_player_positions to the restored snapshot coordinate
						mod._paused_player_positions[pl_unit] = {
							pos = Vector3(pos.x, pos.y, pos.z),
							rot = Quaternion.from_elements(Quaternion.to_elements(rot)),
						}

						-- 2. Restore Status (Normal / Downed) and Health (HP / THP using exact raw values)
						local status_ext = ScriptUnit.has_extension(pl_unit, "status_system") and ScriptUnit.extension(pl_unit, "status_system")
						local health_ext = ScriptUnit.has_extension(pl_unit, "health_system") and ScriptUnit.extension(pl_unit, "health_system")

						local max_hp = pl_data.max_health or (health_ext and health_ext:get_max_health()) or 100
						local perm_hp = pl_data.current_permanent_health
						if perm_hp == nil then
							if pl_data.health_percentage then
								perm_hp = max_hp * pl_data.health_percentage
							else
								perm_hp = math.max(max_hp - (pl_data.damage_taken or 0), 0)
							end
						end
						perm_hp = math.clamp(perm_hp, 0, max_hp)

						local temp_hp = pl_data.current_temporary_health
						if temp_hp == nil then
							temp_hp = max_hp * (pl_data.temporary_health_percentage or 0)
						end
						temp_hp = math.clamp(temp_hp, 0, max_hp)

						local safe_damage = math.clamp(max_hp - perm_hp, 0, max_hp)

						if status_ext and health_ext then
							if was_knocked_down then
								-- KNOCKED DOWN
								status_ext.dead = false
								-- A player unit returned by spawn() can be alive before its game
								-- object is registered.  The StatusUtils helpers call
								-- GameNetworkManager:unit_game_object_id(), which asserts in that
								-- small window.  Direct extension state is safe here; defer the
								-- networked status transition until the unit has a GO id.
								if pl_go_id and not status_ext:is_knocked_down() then
									StatusUtils.set_knocked_down_network(pl_unit, true)
								end
								health_ext.state = "knocked_down"
								health_ext.previous_state = "knocked_down"
								health_ext.set_health_percentage = 0
								health_ext.set_temporary_health_percentage = (max_hp > 0) and (temp_hp / max_hp) or 0
								if health_ext.health_game_object_id and health_ext.game then
									local thp_val = DamageUtils.networkify_health(temp_hp)
									GameSession.set_game_object_field(health_ext.game, health_ext.health_game_object_id, "current_health", 0)
									GameSession.set_game_object_field(health_ext.game, health_ext.health_game_object_id, "current_temporary_health", thp_val)
								end
								health_ext:set_server_damage_taken(max_hp)

							else
								-- NORMAL (ALIVE)
								if pl_go_id and status_ext:is_knocked_down() then
									StatusUtils.set_knocked_down_network(pl_unit, false)
								end
								if status_ext:is_dead() then
									status_ext.dead = false
									if pl_go_id and network_transmit and NetworkLookup.statuses.dead then
										network_transmit:send_rpc_clients("rpc_status_change_bool", NetworkLookup.statuses.dead, false, pl_go_id, 0)
									end
								end
								if pl_go_id then
									StatusUtils.set_revived_network(pl_unit, true)
								end

								-- Set both state and previous_state to "alive" so engine update() doesn't overwrite health
								health_ext.state = "alive"
								health_ext.previous_state = "alive"

								health_ext.set_health_percentage = (max_hp > 0) and (perm_hp / max_hp) or 1
								health_ext.set_temporary_health_percentage = (max_hp > 0) and (temp_hp / max_hp) or 0
								if health_ext.health_game_object_id and health_ext.game then
									local perm_val = DamageUtils.networkify_health(perm_hp)
									local temp_val = DamageUtils.networkify_health(temp_hp)
									GameSession.set_game_object_field(health_ext.game, health_ext.health_game_object_id, "current_health", perm_val)
									GameSession.set_game_object_field(health_ext.game, health_ext.health_game_object_id, "current_temporary_health", temp_val)
								end
								health_ext:set_server_damage_taken(safe_damage)
							end
						end

						-- Restore Player Pacing Intensity
						if status_ext then
							if pl_data.pacing_intensity ~= nil then
								status_ext.pacing_intensity = pl_data.pacing_intensity
							end
							if pl_data.pacing_intensity_decay_delay ~= nil then
								status_ext.pacing_intensity_decay_delay = pl_data.pacing_intensity_decay_delay
							end
						end

						-- Sync party game_mode_data
						pcall(function()
							local party_manager = Managers.party
							if party_manager then
								local p_status = party_manager:get_player_status(matched_player:network_id(), matched_player:local_player_id())
								if p_status and p_status.game_mode_data then
									p_status.game_mode_data.health_state = was_knocked_down and "knocked_down" or "alive"
									p_status.game_mode_data.spawn_state = "spawned"
									p_status.game_mode_data.respawn_timer = nil
									p_status.game_mode_data.ready_for_respawn = false
									p_status.game_mode_data.respawn_unit = nil
									p_status.game_mode_data.health_percentage = (max_hp > 0) and (perm_hp / max_hp) or 1
									p_status.game_mode_data.temporary_health_percentage = (max_hp > 0) and (temp_hp / max_hp) or 0
								end
							end
						end)

						-- 3. Restore Ammo (Exact raw counts).  Updating ammo can drive
						-- weapon animations, so do not touch it until the player is
						-- registered with the game session.
						if pl_go_id and not spawned_player_unit then
							pcall(function()
							if pl_data.ammo and pl_data.ammo.slot_ranged then
								local ranged_ammo = pl_data.ammo.slot_ranged
								local ammo_system = Managers.state.entity:system("ammo_system")
								if ammo_system then
									local exts_by_owner = ammo_system._unit_extensions_by_owner or ammo_system._unit_extensions_by_owener
									if exts_by_owner and exts_by_owner[pl_unit] then
										for _, ext in ipairs(exts_by_owner[pl_unit]) do
											if ext.slot_name == "slot_ranged" then
												if type(ranged_ammo) == "table" then
													ext._current_ammo = ranged_ammo.current_ammo or ext._current_ammo
													ext._available_ammo = ranged_ammo.available_ammo or ext._available_ammo
												elseif type(ranged_ammo) == "number" then
													local m_ammo = ext:max_ammo()
													local target_count = math.round(m_ammo * ranged_ammo)
													local clip_size = ext._ammo_per_clip or m_ammo
													local in_clip = math.min(clip_size, target_count)
													ext._current_ammo = in_clip
													ext._available_ammo = math.max(target_count - in_clip, 0)
												end
												if ext._update_anim_ammo then
													ext:_update_anim_ammo()
												end
											end
										end
									end
								end

								-- Direct weapon unit ammo extension update
								local inv_ext = ScriptUnit.has_extension(pl_unit, "inventory_system") and ScriptUnit.extension(pl_unit, "inventory_system")
								if inv_ext and inv_ext.get_slot_data then
									local ranged_slot = inv_ext:get_slot_data("slot_ranged")
									if ranged_slot then
										for _, u in ipairs({ ranged_slot.right_unit_1p, ranged_slot.left_unit_1p, ranged_slot.right_unit_3p, ranged_slot.left_unit_3p }) do
											if u and Unit.alive(u) and ScriptUnit.has_extension(u, "ammo_system") then
												local a_ext = ScriptUnit.extension(u, "ammo_system")
												if type(ranged_ammo) == "table" then
													a_ext._current_ammo = ranged_ammo.current_ammo or a_ext._current_ammo
													a_ext._available_ammo = ranged_ammo.available_ammo or a_ext._available_ammo
												elseif type(ranged_ammo) == "number" then
													local m_ammo = a_ext:max_ammo()
													local target_count = math.round(m_ammo * ranged_ammo)
													local clip_size = a_ext._ammo_per_clip or m_ammo
													local in_clip = math.min(clip_size, target_count)
													a_ext._current_ammo = in_clip
													a_ext._available_ammo = math.max(target_count - in_clip, 0)
												end
												if a_ext._update_anim_ammo then
													a_ext:_update_anim_ammo()
												end
											end
										end
									end
								end

								-- For remote clients:
								if is_remote and ammo_system.give_ammo_fraction_to_owner then
									local m_ammo = (type(ranged_ammo) == "table" and ranged_ammo.max_ammo and ranged_ammo.max_ammo > 0) and ranged_ammo.max_ammo or 1
									local tot_ammo = (type(ranged_ammo) == "table") and ((ranged_ammo.current_ammo or 0) + (ranged_ammo.available_ammo or 0)) or 0
									local frac = (type(ranged_ammo) == "table") and (tot_ammo / m_ammo) or (type(ranged_ammo) == "number" and ranged_ammo or 1)
									ammo_system:give_ammo_fraction_to_owner(pl_unit, frac, false)
								end
							end
							end)
						end

						-- 4. Restore Consumables (slot_healthkit, slot_potion, slot_grenade)
						-- Adding equipment links it to j_rightweaponattach.  A spawned
						-- player does not have a valid attachment hierarchy until its GO
						-- has been registered, so use the same readiness guard here.
						if pl_go_id and not spawned_player_unit then
							pcall(function()
							local inventory_ext = ScriptUnit.has_extension(pl_unit, "inventory_system") and ScriptUnit.extension(pl_unit, "inventory_system")
							if inventory_ext and pl_data.consumables then
								local consumable_slots = { "slot_healthkit", "slot_potion", "slot_grenade" }
								for _, slot_name in ipairs(consumable_slots) do
									local desired_item = pl_data.consumables[slot_name]
									local current_slot_data = inventory_ext:get_slot_data(slot_name)
									local current_item_key = current_slot_data and current_slot_data.item_data and current_slot_data.item_data.key
									local slot_id = NetworkLookup.equipment_slots[slot_name]

									if current_item_key ~= desired_item then
										if current_slot_data then
											inventory_ext:destroy_slot(slot_name)
											if pl_go_id and network_transmit and slot_id then
												network_transmit:send_rpc_clients("rpc_destroy_slot", pl_go_id, slot_id)
											end
										end

										if desired_item and rawget(ItemMasterList, desired_item) then
											inventory_ext:add_equipment(slot_name, desired_item)
											if pl_go_id and network_transmit and slot_id then
												local item_id = NetworkLookup.item_names[desired_item]
												local skin_id = NetworkLookup.weapon_skins["n/a"]
												if item_id and skin_id then
													network_transmit:send_rpc_clients("rpc_add_equipment", pl_go_id, slot_id, item_id, skin_id)
												end
											end
										end
									end
								end
							end
							end)
						end

						-- spawn() creates the player and weapon hierarchy asynchronously.
						-- Preserve the snapshot data and apply it as soon as that hierarchy
						-- is ready instead of discarding ammo or consumable state.
						if spawned_player_unit then
							table.insert(self._pending_player_equipment_restores, {
								player = matched_player,
								player_data = pl_data,
								wait_frames = 1,
							})
						end

						-- 5. Restore Career Ability Cooldown (Exact raw seconds)
						pcall(function()
							local career_ext = ScriptUnit.has_extension(pl_unit, "career_system") and ScriptUnit.extension(pl_unit, "career_system")
							if career_ext then
								local max_cd = pl_data.max_ability_cooldown or career_ext:get_max_ability_cooldown() or 0
								local target_cd = pl_data.ability_cooldown
								if target_cd == nil and pl_data.ability_cooldown_percentage then
									target_cd = max_cd * (1 - pl_data.ability_cooldown_percentage)
								end
								target_cd = target_cd or 0

								career_ext._ability_cooldown = target_cd
								if career_ext._abilities then
									for _, ability in ipairs(career_ext._abilities) do
										if ability.cooldowns then
											for i = 1, #ability.cooldowns do
												ability.cooldowns[i] = target_cd
											end
										end
									end
								end

								-- Sync ability_percentage to GameSession
								local network_manager = Managers.state.network
								local game = network_manager and network_manager:game()
								if game and pl_go_id and max_cd > 0 then
									local ability_pct = math.clamp((max_cd - target_cd) / max_cd, 0, 1)
									GameSession.set_game_object_field(game, pl_go_id, "ability_percentage", ability_pct)
								end

								-- Immediately freeze cooldown ticking
								if mod.set_unit_cooldown_paused then
									mod.set_unit_cooldown_paused(pl_unit, true)
								end
							end
						end)
					end
				end
			end
		end
	end)
	if not pl_ok then
		mod:echo("[Snapshot] Player restore error: " .. tostring(pl_err))
	end

	-- 6. Destroy random level mobs and recreate exact living enemies safely with preserved HP
	local en_ok, en_err = pcall(function()
		local conflict = Managers.state.conflict
		if conflict then
			conflict:destroy_all_units()

			local package_loader = conflict.enemy_package_loader
			local queued_spawns = {}

			for _, enemy_data in ipairs(snapshot.enemies or {}) do
				local breed = Breeds[enemy_data.breed_name]
				-- Security filter: ensure no dummies or heroes are spawned as enemies
				if breed and not breed.is_hero and not breed.is_player and not breed.name:find("training_dummy") then
					local pos = Vector3(enemy_data.position[1], enemy_data.position[2], enemy_data.position[3])
					local rot = Quaternion.from_elements(enemy_data.rotation[1], enemy_data.rotation[2], enemy_data.rotation[3], enemy_data.rotation[4])
					local damage_taken = enemy_data.damage_taken or 0
					local is_boss = breed.boss or breed.is_boss or breed.boss_category or breed.name:find("boss") or breed.name:find("ogre") or breed.name:find("spawn") or breed.name:find("troll") or breed.name:find("stormfiend") or breed.name:find("minotaur")

					-- Ensure breed package is loaded
					if package_loader and package_loader.request_breed then
						pcall(function()
							package_loader:request_breed(breed.name, true, "snapshot")
						end)
					end

					local optional_data = {
						side_id = conflict.default_enemy_side_id,
						force_boss_health_ui = is_boss and true or false,
					}

					local spawned_unit = nil
					-- 1. Only spawn immediately after the breed package has reached every
					-- peer.  Immediate spawning bypasses ConflictDirector's package
					-- readiness check and can construct an AI rig without its a_sword /
					-- weapon attachment nodes.
					local breed_ready = package_loader and package_loader.is_breed_loaded_on_all_peers
						and package_loader:is_breed_loaded_on_all_peers(breed.name)
					if breed_ready and conflict.spawn_unit_immediate then
						pcall(function()
							spawned_unit = conflict:spawn_unit_immediate(breed, pos, rot, "snapshot", nil, "snapshot", optional_data)
						end)
					end

					-- 2. If immediate spawn succeeded, apply health and boss UI directly
					if spawned_unit and Unit.alive(spawned_unit) then
						if damage_taken > 0 then
							local h_ext = ScriptUnit.has_extension(spawned_unit, "health_system") and ScriptUnit.extension(spawned_unit, "health_system")
							if h_ext and h_ext.set_server_damage_taken then
								local max_hp = h_ext:get_max_health()
								local safe_damage = math.min(damage_taken, max_hp - 1)
								if safe_damage > 0 then
									h_ext:set_server_damage_taken(safe_damage)
								end
							end
						end

						if is_boss then
							pcall(function()
								Managers.state.event:trigger("force_add_boss_health_ui", spawned_unit)
								Managers.state.event:trigger("boss_health_bar_register_unit", spawned_unit, "forced")
							end)
						end
					else
						-- 3. Fallback: Queue spawn
						if conflict.spawn_queued_unit then
							pcall(function()
								local pos_box = Vector3Box(pos)
								local rot_box = QuaternionBox(rot)
								local unit_data = {}
								conflict:spawn_queued_unit(breed, pos_box, rot_box, "snapshot", nil, "snapshot", optional_data, nil, unit_data)
								table.insert(queued_spawns, {
									unit_data = unit_data,
									damage_taken = damage_taken,
									is_boss = is_boss,
								})
							end)
						end
					end
				end
			end

			-- Repeatedly process spawn queue until all queued enemies are instantiated
			if conflict.update_spawn_queue and #queued_spawns > 0 then
				local max_iterations = 200
				local iterations = 0
				while conflict.spawn_queue_size and conflict.spawn_queue_size > 0 and iterations < max_iterations do
					iterations = iterations + 1
					conflict:update_spawn_queue(current_t)
				end
			end

			-- Restore remaining HP and Boss UI for queued spawns
			for _, spawn_info in ipairs(queued_spawns) do
				local enemy_unit = spawn_info.unit_data and spawn_info.unit_data[1]
				local damage_taken = spawn_info.damage_taken
				if enemy_unit and Unit.alive(enemy_unit) then
					if damage_taken > 0 then
						local h_ext = ScriptUnit.has_extension(enemy_unit, "health_system") and ScriptUnit.extension(enemy_unit, "health_system")
						if h_ext and h_ext.set_server_damage_taken then
							local max_hp = h_ext:get_max_health()
							local safe_damage = math.min(damage_taken, max_hp - 1)
							if safe_damage > 0 then
								h_ext:set_server_damage_taken(safe_damage)
							end
						end
					end

					if spawn_info.is_boss then
						pcall(function()
							Managers.state.event:trigger("force_add_boss_health_ui", enemy_unit)
							Managers.state.event:trigger("boss_health_bar_register_unit", enemy_unit, "forced")
						end)
					end
				end
			end

			-- Allow ConflictDirector:update to run for 5 frames to settle physics and navmesh
			mod._allow_director_updates = 5
		end
	end)
	if not en_ok then
		mod:echo("[Snapshot] Enemy restore error: " .. tostring(en_err))
	end

	-- 7. Restore HordeSpawner State (Active & Queued Hordes)
	local horde_ok, horde_err = pcall(function()
		local conflict = Managers.state.conflict
		local horde_spawner = conflict and conflict.horde_spawner
		local spawner_sys = Managers.state.entity and Managers.state.entity:system("spawner_system")
		local current_t = Managers.time and Managers.time:has_timer("game") and Managers.time:time("game") or 0

		if not horde_spawner then
			return
		end

		-- Clear old active spawners from the pre-crash session
		if spawner_sys and spawner_sys._active_spawners then
			table.clear(spawner_sys._active_spawners)
		end

		local horde_data = snapshot.horde_spawner
		if horde_data and horde_data.hordes and #horde_data.hordes > 0 then
			table.clear(horde_spawner.hordes)

			for _, h_data in ipairs(horde_data.hordes) do
				local horde = {
					horde_type = h_data.horde_type or "vector",
					started = h_data.started == true,
					spawned = h_data.spawned or 0,
					num_to_spawn = h_data.num_to_spawn or 0,
					group_id = h_data.group_id,
					side_id = h_data.side_id or 2,
					silent = h_data.silent == true,
					composition_type = h_data.composition_type,
					limit_spawners = h_data.limit_spawners,
					strictly = h_data.strictly,
					use_closest_spawners = h_data.use_closest_spawners,
					amount = h_data.amount,
					failed = h_data.failed == true,
					variant = h_data.variant and table.clone(h_data.variant) or nil,
					terror_event_ids = h_data.terror_event_ids and table.clone(h_data.terror_event_ids) or nil,
					sound_settings = h_data.sound_settings and table.clone(h_data.sound_settings) or nil,
					optional_data = h_data.optional_data and table.clone(h_data.optional_data) or nil,
				}

				-- Reconstruct time fields: new game time + remaining time
				if h_data.started then
					horde.start_time = current_t - 0.1
				else
					horde.start_time = current_t + (h_data.start_time_remaining or 0)
				end

				if h_data.end_time_remaining then
					horde.end_time = current_t + h_data.end_time_remaining
				end

				-- Reconstruct Vector3Box for main_target_pos and epicenter_pos
				if h_data.main_target_pos then
					local p = h_data.main_target_pos
					horde.main_target_pos = Vector3Box(Vector3(p[1], p[2], p[3]))
				end
				if h_data.epicenter_pos then
					local p = h_data.epicenter_pos
					horde.epicenter_pos = Vector3Box(Vector3(p[1], p[2], p[3]))
				end

				-- Reconstruct group_template
				if h_data.group_template then
					horde.group_template = {
						id = h_data.group_template.id or h_data.group_id,
						template = h_data.group_template.template or "horde",
						size = h_data.group_template.size,
					}
				elseif h_data.group_id then
					horde.group_template = {
						id = h_data.group_id,
						template = "horde",
					}
				end

				-- Reconstruct source_unit for event hordes
				if h_data.source_unit_data then
					horde.source_unit = _resolve_level_unit(h_data.source_unit_data.level_object_id, h_data.source_unit_data.position)
				end

				-- Reconstruct horde_spawns
				if h_data.horde_spawns then
					horde.horde_spawns = {}
					for _, hs_data in ipairs(h_data.horde_spawns) do
						local spawner_unit = nil
						if hs_data.spawner_data then
							spawner_unit = _resolve_level_unit(hs_data.spawner_data.level_object_id, hs_data.spawner_data.position)
						end

						local all_done_time = nil
						if hs_data.all_done_spawned_remaining then
							all_done_time = current_t + hs_data.all_done_spawned_remaining
						elseif hs_data.done then
							all_done_time = current_t - 0.1
						end

						local hs_entry = {
							num_to_spawn = hs_data.num_to_spawn or 0,
							spawner = spawner_unit,
							spawn_list = table.clone(hs_data.spawn_list or {}),
							hidden = hs_data.hidden == true,
							done = hs_data.done == true,
							all_done_spawned_time = all_done_time,
						}
						table.insert(horde.horde_spawns, hs_entry)

						-- If horde was in-progress and this spawner is not done, re-activate in spawner_system
						if h_data.started and not hs_data.done and spawner_unit and Unit.alive(spawner_unit) and #hs_entry.spawn_list > 0 then
							if spawner_sys and spawner_sys.spawn_horde then
								pcall(function()
									spawner_sys:spawn_horde(spawner_unit, hs_entry.spawn_list, horde.side_id, horde.group_template, horde.optional_data)
								end)
							end
						end
					end
				end

				-- Reconstruct cover_spawns
				if h_data.cover_spawns then
					horde.cover_spawns = {}
					for _, cs_data in ipairs(h_data.cover_spawns) do
						local cover_point_unit = nil
						if cs_data.cover_data then
							cover_point_unit = _resolve_level_unit(cs_data.cover_data.level_object_id, cs_data.cover_data.position)
						end

						local next_spawn_time = current_t + (cs_data.next_spawn_remaining or 0)

						local cs_entry = {
							num_to_spawn = cs_data.num_to_spawn or 0,
							cover_point_unit = cover_point_unit,
							spawn_list = table.clone(cs_data.spawn_list or {}),
							next_spawn_time = next_spawn_time,
							dont_move = cs_data.dont_move == true,
						}
						table.insert(horde.cover_spawns, cs_entry)
					end
				end

				table.insert(horde_spawner.hordes, horde)
			end

			-- Restore running horde audio & type
			horde_spawner._running_horde_type = horde_data.running_horde_type
			horde_spawner._running_horde_sound_settings = horde_data.running_horde_sound_settings
			horde_spawner.num_paced_hordes = horde_data.num_paced_hordes or horde_spawner.num_paced_hordes
			horde_spawner.last_paced_horde_type = horde_data.last_paced_horde_type or horde_spawner.last_paced_horde_type
		else
			-- No active horde in snapshot: clean state
			table.clear(horde_spawner.hordes)
			horde_spawner._running_horde_type = nil
			horde_spawner._running_horde_sound_settings = nil
		end
	end)
	if not horde_ok then
		mod:echo("[Snapshot] Horde restore error: " .. tostring(horde_err))
	end

	-- 8. Restore Conflict Director Pacing & Horde Timing State
	local pacing_ok, pacing_err = pcall(function()
		local conflict = Managers.state.conflict
		if not conflict or not snapshot.conflict_pacing then
			return
		end

		local current_t = Managers.time and Managers.time:has_timer("game") and Managers.time:time("game") or 0
		local cp_data = snapshot.conflict_pacing
		local p_data = cp_data.pacing

		-- Restore Pacing
		if p_data and conflict.pacing then
			local pacing = conflict.pacing

			-- Exact restore of pacing_state (never blindly reset to pacing_build_up!)
			local target_state = p_data.pacing_state or "pacing_build_up"
			local old_state = pacing.pacing_state
			pacing.pacing_state = target_state

			-- Sync pacing state across network if changed
			if old_state ~= target_state and rawget(_G, "NetworkLookup") and NetworkLookup.pacing then
				pcall(function()
					local pacing_id = NetworkLookup.pacing[target_state]
					if pacing_id and Managers.state.network and Managers.state.network.network_transmit then
						Managers.state.network.network_transmit:send_rpc_all("rpc_pacing_changed", pacing_id)
					end
				end)
			end

			-- Exact restore of total_intensity (never reset to 0!)
			pacing.total_intensity = p_data.total_intensity or 0
			if p_data.player_intensity then
				pacing.player_intensity = table.clone(p_data.player_intensity)
			end

			-- Reconstruct timers using new game time
			if p_data.state_start_time_elapsed then
				pacing._state_start_time = math.max(current_t - p_data.state_start_time_elapsed, 0)
			else
				pacing._state_start_time = current_t
			end

			if p_data.end_pacing_time_remaining then
				pacing._end_pacing_time = current_t + p_data.end_pacing_time_remaining
			else
				pacing._end_pacing_time = nil
			end

			-- Restore population multipliers
			if p_data.threat_population ~= nil then
				pacing._threat_population = p_data.threat_population
			end
			if p_data.specials_population ~= nil then
				pacing._specials_population = p_data.specials_population
			end
			if p_data.horde_population ~= nil then
				pacing._horde_population = p_data.horde_population
			end
		end

		-- Restore ConflictDirector timers and horde pacing
		if cp_data.next_horde_time_remaining == "huge" then
			conflict._next_horde_time = math.huge
		elseif type(cp_data.next_horde_time_remaining) == "number" then
			conflict._next_horde_time = current_t + cp_data.next_horde_time_remaining
		else
			conflict._next_horde_time = nil
		end

		if cp_data.horde_ends_at_remaining == "huge" then
			conflict._horde_ends_at = math.huge
		elseif type(cp_data.horde_ends_at_remaining) == "number" then
			conflict._horde_ends_at = current_t + cp_data.horde_ends_at_remaining
		end

		conflict._multiple_horde_count = cp_data.multiple_horde_count
		conflict._current_wave_composition = cp_data.current_wave_composition
		conflict._wave = cp_data.wave
		if cp_data.living_horde ~= nil then
			conflict._living_horde = cp_data.living_horde
		end
		if cp_data.delay_horde ~= nil then
			conflict.delay_horde = cp_data.delay_horde
		end
		if cp_data.delay_specials ~= nil then
			conflict.delay_specials = cp_data.delay_specials
		end
		if cp_data.delay_mini_patrol ~= nil then
			conflict.delay_mini_patrol = cp_data.delay_mini_patrol
		end
		if cp_data.event_delay ~= nil then
			conflict.event_delay = cp_data.event_delay
		end
		if cp_data.threat_value ~= nil then
			conflict.threat_value = cp_data.threat_value
		end
		if cp_data.num_aggroed ~= nil then
			conflict.num_aggroed = cp_data.num_aggroed
		end

		-- Restore specials_pacing (if active)
		if cp_data.specials_pacing and conflict.specials_pacing then
			local sp = conflict.specials_pacing
			local sp_data = cp_data.specials_pacing
			if sp_data.disabled ~= nil then
				sp._disabled = sp_data.disabled
			end
			if sp_data.specials_timer ~= nil then
				sp._specials_timer = sp_data.specials_timer
			end
			if sp_data.slots and sp._specials_slots then
				for i, slot_data in ipairs(sp_data.slots) do
					local slot = sp._specials_slots[i]
					if slot then
						slot.state = slot_data.state or slot.state
						slot.breed = slot_data.breed or slot.breed
						if type(slot_data.time_remaining) == "number" then
							slot.time = current_t + slot_data.time_remaining
						end
						slot.health_modifier = slot_data.health_modifier
						slot.special_spawn_stinger = slot_data.special_spawn_stinger
						if type(slot_data.stinger_remaining) == "number" then
							slot.special_spawn_stinger_at_t = current_t + slot_data.stinger_remaining
						end
					end
				end
			end
			if sp_data.state_data and sp._state_data then
				local sd = sp_data.state_data
				sp._state_data.override_breed_name = sd.override_breed_name
				if type(sd.coordinated_timer_remaining) == "number" then
					sp._state_data.coordinated_timer = current_t + sd.coordinated_timer_remaining
				end
				if type(sd.coord_time_check_remaining) == "number" then
					sp._state_data.coord_time_check = current_t + sd.coord_time_check_remaining
				end
			end
		end
	end)
	if not pacing_ok then
		mod:echo("[Snapshot] Conflict pacing restore error: " .. tostring(pacing_err))
	end

	-- 9. Restore Scoreboard Statistics (Full Rollback to exact snapshot stats & network sync)
	pcall(function()
		local statistics_db = Managers.player and Managers.player:statistics_db()
		local current_players = Managers.player and Managers.player:players()
		if statistics_db and current_players and snapshot.scoreboard then
			for _, player in pairs(current_players) do
				local stats_id = player:stats_id()
				local p_name = player:name()
				local p_idx = tostring(player:profile_index())
				local peer_id = player:network_id()
				local local_player_id = player:local_player_id()

				local saved_entry = (p_name and snapshot.scoreboard[p_name])
					or snapshot.scoreboard[stats_id]
					or snapshot.scoreboard[p_idx]

				-- Get the raw stats root for direct access (bypasses _get_or_create_stat / ferror risk)
				local stats_root = statistics_db.statistics and statistics_db.statistics[stats_id]

				if saved_entry and stats_root then
					-- Helper: safely write a value directly to a stat object by path
					local function _write_stat_direct(root, target_val, ...)
						local node = root
						local parts = { ... }
						for i = 1, #parts do
							node = node[parts[i]]
							if not node then return false end
						end
						-- node is now the leaf stat object
						if node.value ~= nil then
							node.value = target_val
							node.persistent_value = target_val
							node.dirty = true
							return true
						end
						return false
					end

					-- Restore all raw_stats via direct write
					if saved_entry.raw_stats then
						for stat_key, val in pairs(saved_entry.raw_stats) do
							pcall(function()
								local stat_val = tonumber(val) or 0
								local sep = stat_key:find("##")
								local ok = false
								if sep then
									local p1 = stat_key:sub(1, sep - 1)
									local p2 = stat_key:sub(sep + 2)
									local sep2 = p2:find("##")
									if sep2 then
										local p2_real = p2:sub(1, sep2 - 1)
										local p3_real = p2:sub(sep2 + 2)
										ok = _write_stat_direct(stats_root, stat_val, p1, p2_real, p3_real)
									else
										ok = _write_stat_direct(stats_root, stat_val, p1, p2)
									end
								else
									ok = _write_stat_direct(stats_root, stat_val, stat_key)
								end
								-- If direct write failed (stat not yet created), use delta via modify_stat_by_amount
								if not ok and stat_val > 0 then
									local current = statistics_db:get_stat(stats_id, stat_key) or 0
									local delta = stat_val - current
									if delta ~= 0 then
										statistics_db:modify_stat_by_amount(stats_id, stat_key, delta)
									end
								end
							end)
						end
					end

					-- Explicitly restore damage_dealt with step-by-step debug
					if saved_entry.scores then
						if saved_entry.scores.damage_dealt ~= nil then
							local dmg = tonumber(saved_entry.scores.damage_dealt) or 0

							-- Step 1: Check stats_root has the damage_dealt node
							local dd_node = stats_root["damage_dealt"]
							mod:echo("[D1] dd_node=" .. tostring(dd_node ~= nil) .. " dmg=" .. tostring(dmg) .. " stats_root_type=" .. type(stats_root))

							if dd_node then
								-- Step 2: Check current value before write
								mod:echo("[D2] before_write value=" .. tostring(dd_node.value))
								-- Step 3: Direct write
								dd_node.value = dmg
								dd_node.persistent_value = dmg
								dd_node.dirty = true
								-- Step 4: Read back directly from node
								mod:echo("[D3] after_write node.value=" .. tostring(dd_node.value))
							else
								mod:echo("[D2] dd_node is nil! Using modify_stat fallback")
								local current = statistics_db:get_stat(stats_id, "damage_dealt") or 0
								pcall(function() statistics_db:modify_stat_by_amount(stats_id, "damage_dealt", dmg - current) end)
							end

							-- Step 5: Verify via get_stat (reads through the DB)
							local verify = statistics_db:get_stat(stats_id, "damage_dealt")
							mod:echo("[D4] get_stat verify=" .. tostring(verify) .. " (expected " .. tostring(dmg) .. ")")

							if mod.sync_stat_to_clients then
								mod.sync_stat_to_clients(peer_id, local_player_id, { "damage_dealt" }, dmg)
							end
						end

						if saved_entry.scores.damage_taken ~= nil then
							local taken = tonumber(saved_entry.scores.damage_taken) or 0
							local ok = _write_stat_direct(stats_root, taken, "damage_taken")
							if not ok then
								local current = statistics_db:get_stat(stats_id, "damage_taken") or 0
								pcall(function() statistics_db:modify_stat_by_amount(stats_id, "damage_taken", taken - current) end)
							end
							if mod.sync_stat_to_clients then
								mod.sync_stat_to_clients(peer_id, local_player_id, { "damage_taken" }, taken)
							end
						end
					end
				elseif saved_entry and not stats_root then
					mod:echo("[Restore] stats_root nil for stats_id=" .. tostring(stats_id))
				else
					-- DEBUG: no entry found for this player
					mod:echo("[Restore] No scoreboard entry for: name=" .. tostring(p_name) .. " stats_id=" .. tostring(stats_id))
				end
			end
		end
	end)

	-- Pause after the usual three-frame restore window.  Let the inventory
	-- system alone run for a few more paused frames so newly spawned weapons
	-- can finish linking to their attachment nodes.
	self._inventory_updates_after_restore_pause = 7
	self._pause_after_restore_countdown = 3

	local seed_str = tostring(snapshot.level_seed or "default")
	local applied_msg = mod:safe_localize("snapshot_applied_seed", seed_str)
	mod:chat_broadcast(applied_msg)
	return true
end

--- Update loop for periodic auto-snapshot and level-start detection prompt
function SnapshotManager:update(dt)
	-- Handle delayed pause countdown after snapshot restore (allows player equipment setup to finish)
	if self._pause_after_restore_countdown then
		self._pause_after_restore_countdown = self._pause_after_restore_countdown - 1
		if self._pause_after_restore_countdown <= 0 then
			self._pause_after_restore_countdown = nil
			mod._allow_inventory_updates = self._inventory_updates_after_restore_pause or 0
			self._inventory_updates_after_restore_pause = nil
			mod:apply_pause_state(true, true)
		end
	end

	-- Finish equipment restoration for players who had to be spawned during
	-- snapshot application.  It retains the exact saved ammo and consumables
	-- rather than using defaults, including if setup takes past the pause point.
	local pending = self._pending_player_equipment_restores
	if pending and #pending > 0 then
		for i = #pending, 1, -1 do
			local entry = pending[i]
			if entry.wait_frames > 0 then
				entry.wait_frames = entry.wait_frames - 1
			else
				local player = entry.player
				local unit = player and player.player_unit
				local go_id = unit and Unit.alive(unit) and _game_object_id_if_ready(unit)
				if go_id then
					local ok, restored = pcall(_restore_player_equipment, unit, entry.player_data, go_id, player.remote, Managers.state.network and Managers.state.network.network_transmit)
					if ok and restored then
						table.remove(pending, i)
					else
						-- The inventory extension can exist one frame before all weapon
						-- units are linked; retry after a small settling window.
						entry.wait_frames = 2
					end
				end
			end
		end
	end

	if not mod.is_in_game() or not Managers.player or not Managers.player.is_server then
		return
	end

	if not mod.is_in_inn() then
		local current_level = Managers.level_transition_handler and Managers.level_transition_handler:get_current_level_key()
		-- Prompt on level start if snapshot exists
		if not self._level_prompted or self._last_loaded_level ~= current_level then
			self._last_loaded_level = current_level
			self._level_prompted = true
			local has_snapshot, snapshot = self:has_snapshot_for_current_level()
			if has_snapshot and snapshot then
				local prompt_msg = mod:safe_localize("snapshot_detected_prompt", snapshot.level_key, snapshot.level_seed)
				mod:chat_broadcast(prompt_msg)
			end
		end

		-- Periodic auto-snapshot
		local auto_enabled = mod:get(mod.SETTING_NAMES.ENABLE_AUTO_SNAPSHOT)
		if auto_enabled == nil then
			auto_enabled = true
		end
		if auto_enabled then
			self._auto_timer = self._auto_timer + dt
			local interval = mod:get(mod.SETTING_NAMES.AUTO_SNAPSHOT_INTERVAL) or AUTO_SNAPSHOT_INTERVAL
			if self._auto_timer >= interval then
				self._auto_timer = 0
				self:save_snapshot(true)
			end
		else
			self._auto_timer = 0
		end
	else
		-- In Inn level or non-gameplay: reset prompt flag
		self._level_prompted = false
	end
end

return SnapshotManager

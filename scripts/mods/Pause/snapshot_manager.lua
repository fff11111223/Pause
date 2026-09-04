-- SnapshotManager for Pause mod
-- Provides robust capture, persistence, and recovery of level progress, seeds, players, enemies, and stats across Host crashes.

local mod = get_mod("Pause")

-- luacheck: globals Managers ScriptWorld Unit ScriptUnit Vector3 Quaternion Vector3Box QuaternionBox Breeds ItemMasterList NetworkLookup cjson ScoreboardHelper

local SnapshotManager = {}
SnapshotManager.__index = SnapshotManager

local AUTO_SNAPSHOT_INTERVAL = 60 -- Default interval in seconds



function SnapshotManager:init()
	self._auto_timer = 0
	self._level_prompted = false
	self._last_loaded_level = nil
	self._pause_after_restore_countdown = nil
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

	-- 5. Players State
	pcall(function()
		local players = Managers.player:players()
		for _, player in pairs(players) do
			local pl_unit = player.player_unit
			if pl_unit and Unit.alive(pl_unit) then
				local pos = Unit.world_position(pl_unit, 0)
				local rot = Unit.world_rotation(pl_unit, 0)
				local qx, qy, qz, qw = Quaternion.to_elements(rot)
				local health_ext = ScriptUnit.has_extension(pl_unit, "health_system") and ScriptUnit.extension(pl_unit, "health_system")
				local status_ext = ScriptUnit.has_extension(pl_unit, "status_system") and ScriptUnit.extension(pl_unit, "status_system")
				local career_ext = ScriptUnit.has_extension(pl_unit, "career_system") and ScriptUnit.extension(pl_unit, "career_system")
				local inventory_ext = ScriptUnit.has_extension(pl_unit, "inventory_system") and ScriptUnit.extension(pl_unit, "inventory_system")

				local consumables = {}
				if inventory_ext and rawget(_G, "SpawningHelper") then
					SpawningHelper.fill_consumable_table(consumables, inventory_ext)
				end

				local ammo = { slot_melee = 1, slot_ranged = 1 }
				if inventory_ext and rawget(_G, "SpawningHelper") then
					SpawningHelper.fill_ammo_percentage(ammo, inventory_ext, pl_unit)
				end

				local player_data = {
					peer_id = player:network_id(),
					local_player_id = player:local_player_id(),
					profile_index = player:profile_index(),
					career_index = player:career_index(),
					hero_name = player:name(),
					is_bot = not not player.bot_player,
					position = { pos.x, pos.y, pos.z },
					rotation = { qx, qy, qz, qw },
					damage_taken = health_ext and health_ext:get_damage_taken() or 0,
					max_health = health_ext and health_ext:get_max_health() or 100,
					temporary_health_percentage = health_ext and health_ext:current_temporary_health_percent() or 0,
					is_knocked_down = status_ext and status_ext:is_knocked_down() or false,
					is_dead = status_ext and status_ext:is_dead() or false,
					ability_cooldown_percentage = career_ext and career_ext:current_ability_cooldown_percentage() or 1,
					consumables = consumables,
					ammo = ammo,
				}

				table.insert(snapshot.players, player_data)
			end
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

	-- 5. Restore Players (Teleport, Health, THP, Ammo, Cooldown)
	pcall(function()
		local current_players = Managers.player:players()
		for _, pl_data in ipairs(snapshot.players or {}) do
			local matched_player = nil
			-- Match by profile / hero
			for _, player in pairs(current_players) do
				if player:profile_index() == pl_data.profile_index or player:name() == pl_data.hero_name then
					matched_player = player
					break
				end
			end

			if matched_player and matched_player.player_unit and Unit.alive(matched_player.player_unit) then
				local pl_unit = matched_player.player_unit
				local pos = Vector3(pl_data.position[1], pl_data.position[2], pl_data.position[3])
				local rot = Quaternion.from_elements(pl_data.rotation[1], pl_data.rotation[2], pl_data.rotation[3], pl_data.rotation[4])
				local locomotion_ext = ScriptUnit.has_extension(pl_unit, "locomotion_system") and ScriptUnit.extension(pl_unit, "locomotion_system")
				if locomotion_ext then
					locomotion_ext:teleport_to(pos, rot)
				end

				-- Force first person camera to immediately update position
				local fp_ext = ScriptUnit.has_extension(pl_unit, "first_person_system") and ScriptUnit.extension(pl_unit, "first_person_system")
				if fp_ext and fp_ext.update_position then
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

				local health_ext = ScriptUnit.has_extension(pl_unit, "health_system") and ScriptUnit.extension(pl_unit, "health_system")
				if health_ext then
					health_ext:set_server_damage_taken(pl_data.damage_taken or 0)
					if pl_data.temporary_health_percentage and pl_data.temporary_health_percentage > 0 then
						local max_hp = health_ext:get_max_health()
						local thp_amount = max_hp * pl_data.temporary_health_percentage
						health_ext:add_heal(pl_unit, thp_amount, "snapshot_restore", "buff")
					end
				end

				local career_ext = ScriptUnit.has_extension(pl_unit, "career_system") and ScriptUnit.extension(pl_unit, "career_system")
				if career_ext and pl_data.ability_cooldown_percentage then
					-- Restore ability cooldown
					local max_cd = career_ext:get_max_ability_cooldown()
					career_ext._ability_cooldown = max_cd * (1 - pl_data.ability_cooldown_percentage)
				end
			end
		end
	end)

	-- 6. Destroy random level mobs and recreate exact living enemies safely
	pcall(function()
		local conflict = Managers.state.conflict
		if conflict then
			conflict:destroy_all_units()

			for _, enemy_data in ipairs(snapshot.enemies or {}) do
				local breed = Breeds[enemy_data.breed_name]
				-- Security filter: ensure no dummies or heroes are spawned as enemies
				if breed and not breed.is_hero and not breed.is_player and not breed.name:find("training_dummy") then
					local pos = Vector3(enemy_data.position[1], enemy_data.position[2], enemy_data.position[3])
					local rot = Quaternion.from_elements(enemy_data.rotation[1], enemy_data.rotation[2], enemy_data.rotation[3], enemy_data.rotation[4])

					if conflict.spawn_queued_unit then
						pcall(function()
							local pos_box = Vector3Box(pos)
							local rot_box = QuaternionBox(rot)
							conflict:spawn_queued_unit(breed, pos_box, rot_box, "snapshot", nil, "snapshot", {})
						end)
					end
				end
			end

			-- Repeatedly process spawn queue until all queued enemies are instantiated
			if conflict.update_spawn_queue then
				local current_t = Managers.time:time("game") or 0
				local max_iterations = 200
				local iterations = 0
				while conflict.spawn_queue_size and conflict.spawn_queue_size > 0 and iterations < max_iterations do
					iterations = iterations + 1
					conflict:update_spawn_queue(current_t)
				end
			end

			-- Allow ConflictDirector:update to run for 5 frames to settle physics and navmesh
			mod._allow_director_updates = 5
		end
	end)

	-- 7. Restore Scoreboard Statistics (Full Rollback to exact snapshot stats & network sync)
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

					-- Explicitly restore damage_dealt and damage_taken with verification
					if saved_entry.scores then
						if saved_entry.scores.damage_dealt ~= nil then
							local dmg = tonumber(saved_entry.scores.damage_dealt) or 0
							local ok = _write_stat_direct(stats_root, dmg, "damage_dealt")
							if not ok then
								local current = statistics_db:get_stat(stats_id, "damage_dealt") or 0
								pcall(function() statistics_db:modify_stat_by_amount(stats_id, "damage_dealt", dmg - current) end)
							end
							local verify = statistics_db:get_stat(stats_id, "damage_dealt")
							mod:echo("[Restore] damage_dealt target=" .. tostring(dmg) .. " verify=" .. tostring(verify))
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

	-- 8. Auto-pause game after 3 frames so the engine renders the restored state
	self._pause_after_restore_countdown = 3

	local seed_str = tostring(snapshot.level_seed or "default")
	local applied_msg = mod:safe_localize("snapshot_applied_seed", seed_str)
	mod:chat_broadcast(applied_msg)
	return true
end

--- Update loop for periodic auto-snapshot and level-start detection prompt
function SnapshotManager:update(dt)
	-- Handle delayed pause countdown after snapshot restore (allows 3 frames to render restored scene)
	if self._pause_after_restore_countdown then
		self._pause_after_restore_countdown = self._pause_after_restore_countdown - 1
		if self._pause_after_restore_countdown <= 0 then
			self._pause_after_restore_countdown = nil
			mod:apply_pause_state(true, true)
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
		self._auto_timer = self._auto_timer + dt
		local interval = mod:get(mod.SETTING_NAMES.AUTO_SNAPSHOT_INTERVAL) or AUTO_SNAPSHOT_INTERVAL
		if self._auto_timer >= interval then
			self._auto_timer = 0
			self:save_snapshot(true)
		end
	else
		-- In Inn level or non-gameplay: reset prompt flag
		self._level_prompted = false
	end
end

return SnapshotManager

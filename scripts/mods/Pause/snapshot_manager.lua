-- SnapshotManager for Pause mod
-- Provides robust capture, persistence, and recovery of level progress, seeds, players, enemies, and stats across Host crashes.

local mod = get_mod("Pause")

-- luacheck: globals Managers ScriptWorld Unit ScriptUnit Vector3 Quaternion Vector3Box QuaternionBox Breeds ItemMasterList NetworkLookup cjson ScoreboardHelper

local SnapshotManager = {}
SnapshotManager.__index = SnapshotManager

local AUTO_SNAPSHOT_INTERVAL = 60 -- Default interval in seconds

local function _get_storage_dir()
	local appdata = os.getenv("APPDATA") or os.getenv("LOCALAPPDATA") or "."
	local dir = appdata:gsub("\\", "/") .. "/Vermintide2/Mods/Pause"
	pcall(function()
		os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
	end)
	return dir
end

local function _get_snapshot_path()
	return _get_storage_dir() .. "/pause_snapshot_latest.json"
end

local function _get_backup_path()
	return _get_storage_dir() .. "/pause_snapshot_backup.bak"
end

function SnapshotManager:init()
	self._auto_timer = 0
	self._level_prompted = false
	self._last_loaded_level = nil
end

--- Collect complete level, flow, player, enemy, and scoreboard state
function SnapshotManager:collect_snapshot()
	if not Managers.world or not Managers.world:has_world("level_world") then
		return nil, "Not in a playable level"
	end
	if not Managers.player or not Managers.player.is_server then
		return nil, "Only host can capture snapshot"
	end

	local level_key = Managers.level_transition_handler:get_current_level_key()
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
					if breed and breed.name then
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

	-- 7. Scoreboard Statistics
	pcall(function()
		local statistics_db = Managers.player and Managers.player:statistics_db()
		local players = Managers.player and Managers.player:players()
		if statistics_db and players and rawget(_G, "ScoreboardHelper") then
			local scoreboard_topics = ScoreboardHelper.scoreboard_topic_stats
			for _, player in pairs(players) do
				local stats_id = player:stats_id()
				local player_scores = {}
				for _, topic in ipairs(scoreboard_topics) do
					local stat_types = topic.stat_types
					local score = 0
					if stat_types ~= nil then
						for j = 1, #stat_types do
							score = score + (statistics_db:get_stat(stats_id, stat_types[j]) or 0)
						end
					elseif topic.stat_type then
						score = statistics_db:get_stat(stats_id, topic.stat_type) or 0
					end
					player_scores[topic.name] = score
				end
				snapshot.scoreboard[player:name() or stats_id] = {
					stats_id = stats_id,
					scores = player_scores,
				}
			end
		end
	end)

	return snapshot
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

	local success, json_str = pcall(cjson.encode, snapshot)
	if not success or not json_str then
		if not is_auto then
			mod:chat_broadcast(mod:localize("snapshot_save_failed") .. " (JSON Encode Error)")
		end
		return false
	end

	local path = _get_snapshot_path()
	local backup_path = _get_backup_path()

	-- Backup previous snapshot if it exists
	local prev_file = io.open(path, "r")
	if prev_file then
		local prev_content = prev_file:read("*a")
		prev_file:close()
		local bak_file = io.open(backup_path, "w")
		if bak_file then
			bak_file:write(prev_content)
			bak_file:close()
		end
	end

	local file = io.open(path, "w")
	if file then
		file:write(json_str)
		file:close()
		if not is_auto then
			mod:chat_broadcast(mod:localize("snapshot_saved"))
		end
		return true
	else
		if not is_auto then
			mod:chat_broadcast(mod:localize("snapshot_save_failed") .. " (File Write Error)")
		end
		return false
	end
end

--- Load snapshot from disk
function SnapshotManager:load_snapshot()
	local path = _get_snapshot_path()
	local file = io.open(path, "r")
	if not file then
		-- Try backup
		path = _get_backup_path()
		file = io.open(path, "r")
	end

	if not file then
		return nil, "No snapshot file found"
	end

	local json_str = file:read("*a")
	file:close()

	local success, snapshot = pcall(cjson.decode, json_str)
	if not success or not snapshot then
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
	pcall(function()
		os.remove(_get_snapshot_path())
		os.remove(_get_backup_path())
	end)
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

	local current_level = Managers.level_transition_handler:get_current_level_key()
	if snapshot.level_key ~= current_level then
		mod:chat_broadcast(string.format(mod:localize("snapshot_level_mismatch"), tostring(snapshot.level_key), tostring(current_level)))
		return false
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

	-- 6. Destroy random level mobs and recreate exact living enemies
	pcall(function()
		if Managers.state.conflict then
			Managers.state.conflict:destroy_all_units()

			for _, enemy_data in ipairs(snapshot.enemies or {}) do
				local breed = Breeds[enemy_data.breed_name]
				if breed then
					local pos = Vector3(enemy_data.position[1], enemy_data.position[2], enemy_data.position[3])
					local rot = Quaternion.from_elements(enemy_data.rotation[1], enemy_data.rotation[2], enemy_data.rotation[3], enemy_data.rotation[4])
					local pos_box = Vector3Box(pos)
					local rot_box = QuaternionBox(rot)
					local ai_unit = Managers.state.conflict:spawn_queued_unit(breed, pos_box, rot_box, "snapshot", nil, "snapshot")
					if ai_unit and enemy_data.damage_taken and enemy_data.damage_taken > 0 and Unit.alive(ai_unit) then
						local health_ext = ScriptUnit.has_extension(ai_unit, "health_system") and ScriptUnit.extension(ai_unit, "health_system")
						if health_ext then
							health_ext:set_server_damage_taken(enemy_data.damage_taken)
						end
					end
				end
			end
		end
	end)

	-- 7. Restore Scoreboard Statistics
	pcall(function()
		local statistics_db = Managers.player and Managers.player:statistics_db()
		local current_players = Managers.player and Managers.player:players()
		if statistics_db and current_players and snapshot.scoreboard then
			for _, player in pairs(current_players) do
				local stats_id = player:stats_id()
				local saved_entry = snapshot.scoreboard[player:name()] or snapshot.scoreboard[stats_id]
				if saved_entry and saved_entry.scores then
					for topic_name, score in pairs(saved_entry.scores) do
						for _, topic in ipairs(ScoreboardHelper.scoreboard_topic_stats) do
							if topic.name == topic_name then
								if topic.stat_types then
									local primary_stat = topic.stat_types[1]
									statistics_db:set_stat(stats_id, primary_stat, score)
								elseif topic.stat_type then
									statistics_db:set_stat(stats_id, topic.stat_type, score)
								end
								break
							end
						end
					end
				end
			end
		end
	end)

	-- 8. Auto-pause game after restore so players can connect safely
	mod:apply_pause_state(true, true)

	mod:chat_broadcast(string.format(mod:localize("snapshot_applied_seed"), tostring(snapshot.level_seed or "default")))
	return true
end

--- Update loop for periodic auto-snapshot and level-start detection prompt
function SnapshotManager:update(dt)
	if not mod.is_in_game() or not Managers.player or not Managers.player.is_server then
		return
	end

	local current_level = Managers.level_transition_handler and Managers.level_transition_handler:get_current_level_key()
	if current_level and current_level ~= "inn_level" then
		-- Prompt on level start if snapshot exists
		if not self._level_prompted or self._last_loaded_level ~= current_level then
			self._last_loaded_level = current_level
			self._level_prompted = true
			local has_snapshot, snapshot = self:has_snapshot_for_current_level()
			if has_snapshot and snapshot then
				mod:chat_broadcast(string.format(mod:localize("snapshot_detected_prompt"), tostring(snapshot.level_key), tostring(snapshot.level_seed or "")))
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

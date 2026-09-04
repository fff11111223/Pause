return {
	mod_description = {
		en = "Pause the game safely with hotkey or /pause. Features crash-recovery snapshots and allows players to rejoin and spawn during pause.",
		["zh-tw"] = "使用快捷鍵或 /pause 安全暫停遊戲。包含防崩潰戰鬥快照系統，並允許玩家在暫停期間重新連線與進場接管角色。",
		zh = "使用快捷键或 /pause 安全暂停游戏。包含防崩溃战斗快照系统，并允许玩家在暂停期间重新连线与进场接管角色。",
	},
	hotkey = {
		en = "Pause / Unpause Hotkey",
		["zh-tw"] = "暫停 / 恢復 快捷鍵",
		zh = "暂停 / 恢复 快捷键",
	},
	hotkey_tooltip = {
		en = "Hotkey to toggle pause/unpause.",
		["zh-tw"] = "切換暫停與恢復的快捷鍵。",
		zh = "切换暂停与恢复的快捷键。",
	},
	save_snapshot_hotkey = {
		en = "Manual Save Snapshot Hotkey",
		["zh-tw"] = "手動儲存快照 快捷鍵",
		zh = "手动储存快照 快捷键",
	},
	save_snapshot_hotkey_tooltip = {
		en = "Hotkey to manually save the current game snapshot immediately.",
		["zh-tw"] = "立即手動儲存當前遊戲戰局快照的快捷鍵。",
		zh = "立即手动储存当前游戏战局快照的快捷键。",
	},
	restore_snapshot_hotkey = {
		en = "Restore Snapshot Hotkey",
		["zh-tw"] = "恢復快照 快捷鍵",
		zh = "恢复快照 快捷键",
	},
	restore_snapshot_hotkey_tooltip = {
		en = "Hotkey to restore the saved snapshot for the current level.",
		["zh-tw"] = "讀取並套用當前關卡快照的快捷鍵。",
		zh = "读取并套用当前关卡快照的快捷键。",
	},
	auto_snapshot_interval = {
		en = "Auto Snapshot Interval (seconds)",
		["zh-tw"] = "自動快照間隔（秒）",
		zh = "自动快照间隔（秒）",
	},
	auto_snapshot_interval_tooltip = {
		en = "Interval in seconds between background automatic snapshot saves (default 60s).",
		["zh-tw"] = "伺服器在背景自動儲存戰局快照的間隔秒數（預設 60 秒）。",
		zh = "服务器在背景自动储存战局快照的间隔秒数（预设 60 秒）。",
	},
	pause_command_description = {
		en = "Pause or unpause the game. Host only.",
		["zh-tw"] = "暫停或恢復遊戲（僅限 Host）。",
		zh = "暂停或恢复游戏（仅限 Host）。",
	},
	unpause_command_description = {
		en = "Unpause the game. Host only.",
		["zh-tw"] = "恢復遊戲（僅限 Host）。",
		zh = "恢复游戏（仅限 Host）。",
	},
	save_snapshot_command_description = {
		en = "Manually save current game snapshot. Host only.",
		["zh-tw"] = "手動儲存當前遊戲快照（僅限 Host）。",
		zh = "手动储存当前游戏快照（仅限 Host）。",
	},
	restore_snapshot_command_description = {
		en = "Restore saved game snapshot for the current level. Host only.",
		["zh-tw"] = "讀取並恢復當前關卡的遊戲快照（僅限 Host）。",
		zh = "读取并恢复当前关卡的游戏快照（仅限 Host）。",
	},
	game_paused = {
		en = "Game paused! Rejoining players can safely load and spawn now.",
		["zh-tw"] = "遊戲已完全定格！重新加入的玩家現在可以安全連線並進場接管角色。",
		zh = "游戏已完全定格！重新加入的玩家现在可以安全连线并进场接管角色。",
	},
	game_unpaused = {
		en = "Game unpaused! Resuming gameplay.",
		["zh-tw"] = "遊戲已恢復！繼續戰鬥。",
		zh = "游戏已恢复！继续战斗。",
	},
	not_server = {
		en = "You need to be the host to perform this action!",
		["zh-tw"] = "只有房主（Host）可以執行此操作！",
		zh = "只有房主（Host）可以执行此操作！",
	},
	player_joined_paused = {
		en = "%s has joined and spawned into the game while paused.",
		["zh-tw"] = "玩家「%s」已在暫停狀態下成功加入並接管角色進場。",
		zh = "玩家「%s」已在暂停状态下成功加入并接管角色进场。",
	},
	snapshot_saved = {
		en = "Game snapshot saved successfully!",
		["zh-tw"] = "戰局快照已成功儲存！",
		zh = "战局快照已成功储存！",
	},
	snapshot_save_failed = {
		en = "Failed to save game snapshot.",
		["zh-tw"] = "戰局快照儲存失敗。",
		zh = "战局快照储存失败。",
	},
	snapshot_not_found = {
		en = "No valid snapshot found to restore.",
		["zh-tw"] = "未找到可讀取的快照檔案。",
		zh = "未找到可读取的快照档案。",
	},
	snapshot_level_mismatch = {
		en = "Snapshot level '%s' does not match current level '%s'!",
		["zh-tw"] = "快照地圖「%s」與當前地圖「%s」不符，無法恢復！",
		zh = "快照地图「%s」与当前地图「%s」不符，无法恢复！",
	},
	snapshot_applied_seed = {
		en = "Snapshot restored! (Map Seed: %s). Game is PAUSED to wait for teammates. Type /unpause when ready.",
		["zh-tw"] = "快照恢復完成！（地圖 Seed: %s）。遊戲已自動【暫停定格】以等待隊友連線，全員就緒後請輸入 /unpause 繼續。",
		zh = "快照恢复完成！（地图 Seed: %s）。游戏已自动【暂停定格】以等待队友连线，全员就绪后请输入 /unpause 继续。",
	},
	snapshot_detected_prompt = {
		en = "Detected previous snapshot for level '%s' (Seed: %s). Type /restore_snapshot to restore progress.",
		["zh-tw"] = "偵測到本關卡「%s」（Seed: %s）的上次快照記錄！若需接續進度請輸入 /restore_snapshot。",
		zh = "侦测到本关卡「%s」（Seed: %s）的上次快照记录！若需接续进度请输入 /restore_snapshot。",
	},
	cannot_restore_in_inn = {
		en = "Cannot restore snapshot while inside the Inn/Lobby! Please load into the mission first.",
		["zh-tw"] = "在大廳中無法執行戰局快照回溯！請先載入進入該地圖關卡中再執行回溯。",
		zh = "在大厅中无法执行战局快照回溯！请先载入进入该地图关卡中再执行回溯。",
	},
	cannot_save_in_inn = {
		en = "Cannot save snapshot while inside the Inn/Lobby! Snapshots can only be saved during a mission.",
		["zh-tw"] = "在大廳中無法儲存戰局快照！戰局快照僅能在關卡進行中儲存。",
		zh = "在大厅中无法储存战局快照！战局快照仅能在关卡进行中储存。",
	},
}
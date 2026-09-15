local mod = get_mod("Pause") -- luacheck: ignore get_mod

mod.SETTING_NAMES = {
	HOTKEY = "hotkey",
	SAVE_SNAPSHOT = "save_snapshot",
	RESTORE_SNAPSHOT = "restore_snapshot",
	AUTO_SNAPSHOT_INTERVAL = "auto_snapshot_interval",
	ENABLE_AUTO_SNAPSHOT = "enable_auto_snapshot",
}

local mod_data = {
	name = "Pause",
	description = mod:localize("暫停與快照"),
}

mod_data.options_widgets = {
	{
		["setting_id"] = mod.SETTING_NAMES.HOTKEY,
		["type"] = "keybind",
		["text"] = mod:localize("hotkey"),
		["tooltip"] = mod:localize("hotkey_tooltip"),
		["default_value"] = {},
		["keybind_trigger"] = "pressed",
		["keybind_type"] = "function_call",
		["function_name"] = "do_pause",
	},
	{
		["setting_id"] = mod.SETTING_NAMES.SAVE_SNAPSHOT,
		["type"] = "keybind",
		["text"] = mod:localize("save_snapshot_hotkey"),
		["tooltip"] = mod:localize("save_snapshot_hotkey_tooltip"),
		["default_value"] = {},
		["keybind_trigger"] = "pressed",
		["keybind_type"] = "function_call",
		["function_name"] = "do_save_snapshot",
	},
	{
		["setting_id"] = mod.SETTING_NAMES.RESTORE_SNAPSHOT,
		["type"] = "keybind",
		["text"] = mod:localize("restore_snapshot_hotkey"),
		["tooltip"] = mod:localize("restore_snapshot_hotkey_tooltip"),
		["default_value"] = {},
		["keybind_trigger"] = "pressed",
		["keybind_type"] = "function_call",
		["function_name"] = "do_restore_snapshot",
	},
	{
		["setting_id"] = mod.SETTING_NAMES.ENABLE_AUTO_SNAPSHOT,
		["type"] = "checkbox",
		["text"] = mod:localize("enable_auto_snapshot"),
		["tooltip"] = mod:localize("enable_auto_snapshot_tooltip"),
		["default_value"] = true,
	},
	{
		["setting_id"] = mod.SETTING_NAMES.AUTO_SNAPSHOT_INTERVAL,
		["type"] = "numeric",
		["text"] = mod:localize("auto_snapshot_interval"),
		["tooltip"] = mod:localize("auto_snapshot_interval_tooltip"),
		["range"] = { 10, 300 },
		["default_value"] = 60,
	},
}

return mod_data
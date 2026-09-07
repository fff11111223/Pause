return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Pause` mod must be lower than Vermintide Mod Framework in your launcher's load order.")

		new_mod("fff Pause & Recovery", {
			mod_script       = "scripts/mods/Pause/Pause",
			mod_data         = "scripts/mods/Pause/Pause_data",
			mod_localization = "scripts/mods/Pause/Pause_localization",
		})
	end,
	packages = {
		"resource_packages/Pause/Pause",
	},
}

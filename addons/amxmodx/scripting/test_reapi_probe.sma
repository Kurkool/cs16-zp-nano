/*
	TEST ONLY 2026-08-11 - proves ReAPI can hook CheckWinConditions on this
	build, and that a write from inside the pre-hook lands before ReGameDLL
	reads mp_round_infinite at multiplay_gamerules.cpp:903.

	Delete this plugin and its line in plugins-zplague.ini once the question
	is answered - Task 4 does that.

	Step 7 correction (2026-08-11): the hook chain enum for CheckWinConditions
	on installed ReAPI 5.29.0.358 is RG_CSGameRules_CheckWinConditions, not
	RG_CHalfLifeMultiplay_CheckWinConditions as the plan expected. Confirmed
	against addons/amxmodx/scripting/include/reapi_gamedll_const.inc:1202.
	The native name, rg_check_win_conditions(), matched the plan as written.
*/

#include <amxmodx>
#include <reapi>

new g_pHold

public plugin_init()
{
	register_plugin("[TEST] ReAPI probe", "1.0", "setup")

	// 1 = write "f" from inside the hook, 0 = write "0". The control run and
	// the real test are the same code path with this flipped.
	g_pHold = register_cvar("probe_hold", "0")

	new ret = RegisterHookChain(RG_CSGameRules_CheckWinConditions, "Probe_Pre", false)

	log_amx("[PROBE] RegisterHookChain(CheckWinConditions, pre) returned %d", ret)
}

public Probe_Pre()
{
	new bool:bHold = (get_pcvar_num(g_pHold) != 0)

	set_cvar_string("mp_round_infinite", bHold ? "f" : "0")

	log_amx("[PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=%s",
		bHold ? "f" : "0")
}

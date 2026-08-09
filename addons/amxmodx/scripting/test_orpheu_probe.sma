/*
	[TEST] Orpheu round-control probe
	---------------------------------
	Throwaway. Delete once it has answered its question.

	The question: do Orpheu's shipped signatures for CS's round-end machinery
	still resolve against the build this server actually runs?

	That matters because owning the round rules properly - rather than keeping
	the zombie team artificially non-empty so CS never notices - depends on
	being able to reach CheckWinConditions and the individual win checks
	inside it. Both the CSCF and the Zombie The ExHero packages do exactly
	that through Orpheu, so the approach is proven; what is not known is
	whether their signatures survive on build 10210, the HL25 anniversary
	build. The configs shipped with them were written for build 5408 era
	binaries and AMX Mod X already reports a GameConfig CRC mismatch against
	this mp.dll, so there is real doubt.

	Each lookup runs in its own task on purpose. OrpheuGetFunction raises a
	run time error when a signature does not match, which aborts the callback
	it happens in - so putting them in one function would mean learning about
	one failure per server start. Separate tasks contain the damage and get
	the whole picture in a single run.

	Nothing here modifies the game. OrpheuMemoryGet reads; the patching
	natives are deliberately not used.
*/

#include <amxmodx>
#include <orpheu>
#include <orpheu_memory>

#define TASK_PROBE 9100

public plugin_init()
{
	register_plugin("[TEST] Orpheu round-control probe", "1.0", "setup")

	log_amx("[ORPHEU-PROBE] ================ start ================")

	// spaced out so the log order is unambiguous even if one of them dies
	set_task(0.1, "Probe_CheckWinConditions", TASK_PROBE + 1)
	set_task(0.3, "Probe_EndRoundMessage",    TASK_PROBE + 2)
	set_task(0.5, "Probe_InstallGameRules",   TASK_PROBE + 3)
	set_task(0.7, "Probe_UpdateTeamScores",   TASK_PROBE + 4)
	set_task(0.9, "Probe_CTWinCheck",         TASK_PROBE + 5)
	set_task(1.1, "Probe_TerroristWinCheck",  TASK_PROBE + 6)
	set_task(1.3, "Probe_RoundTimeCheck",     TASK_PROBE + 7)
	set_task(1.5, "Probe_Done",               TASK_PROBE + 8)
}

/* ---- functions ---- */

public Probe_CheckWinConditions()
{
	log_amx("[ORPHEU-PROBE] fn  CHalfLifeMultiplay::CheckWinConditions ...")
	new OrpheuFunction:f = OrpheuGetFunction("CheckWinConditions", "CHalfLifeMultiplay")
	log_amx("[ORPHEU-PROBE] fn  CheckWinConditions OK handle=%d", _:f)
}

public Probe_EndRoundMessage()
{
	log_amx("[ORPHEU-PROBE] fn  EndRoundMessage ...")
	new OrpheuFunction:f = OrpheuGetFunction("EndRoundMessage")
	log_amx("[ORPHEU-PROBE] fn  EndRoundMessage OK handle=%d", _:f)
}

public Probe_InstallGameRules()
{
	log_amx("[ORPHEU-PROBE] fn  InstallGameRules ...")
	new OrpheuFunction:f = OrpheuGetFunction("InstallGameRules")
	log_amx("[ORPHEU-PROBE] fn  InstallGameRules OK handle=%d", _:f)
}

public Probe_UpdateTeamScores()
{
	log_amx("[ORPHEU-PROBE] fn  CHalfLifeMultiplay::UpdateTeamScores ...")
	new OrpheuFunction:f = OrpheuGetFunction("UpdateTeamScores", "CHalfLifeMultiplay")
	log_amx("[ORPHEU-PROBE] fn  UpdateTeamScores OK handle=%d", _:f)
}

/* ---- memory structures, the ones ExHero patches to kill individual wins ---- */

public Probe_CTWinCheck()
{
	log_amx("[ORPHEU-PROBE] mem CTWinCheck_#1 ...")
	new value = OrpheuMemoryGet("CTWinCheck_#1")
	log_amx("[ORPHEU-PROBE] mem CTWinCheck_#1 OK value=%d", value)
}

public Probe_TerroristWinCheck()
{
	log_amx("[ORPHEU-PROBE] mem TerroristWinCheck_#1 ...")
	new value = OrpheuMemoryGet("TerroristWinCheck_#1")
	log_amx("[ORPHEU-PROBE] mem TerroristWinCheck_#1 OK value=%d", value)
}

public Probe_RoundTimeCheck()
{
	log_amx("[ORPHEU-PROBE] mem RoundTimeCheck_#1 ...")
	new value = OrpheuMemoryGet("RoundTimeCheck_#1")
	log_amx("[ORPHEU-PROBE] mem RoundTimeCheck_#1 OK value=%d", value)
}

public Probe_Done()
{
	log_amx("[ORPHEU-PROBE] ================ end ================")
	log_amx("[ORPHEU-PROBE] every line above that says '...' without a matching")
	log_amx("[ORPHEU-PROBE] OK on the next line is a signature that did not match")
}

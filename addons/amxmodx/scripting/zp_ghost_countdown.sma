/*
	[ZP] Ghost Countdown
	--------------------
	Counts down ZP's zp_delay window before the infection round starts.

		- centre-screen message every second for the whole window
		- CrossFire "Ghost_Count" voice over the last 10 seconds

	Everything is derived from zp_delay at the start of each round, so
	changing zp_delay keeps both the text and the voice lined up with the
	moment the first zombie actually spawns. With zp_delay 22:

		t=0   "Mutation Spreading in 22 seconds"
		...
		t=12  "... 10 seconds"  + voice "10"
		...
		t=21  "... 1 seconds"   + voice "1"
		t=22  first zombie

	cvars:
		zp_ghost_countdown        1 = on, 0 = off
		zp_ghost_countdown_voice  1 = play the voice over the last 10s

	Notes:
		- Hooked to the HLTV new-round event. zp_round_started is no good
		  here: it only runs *after* zp_delay has already elapsed.
		- One repeating 1s task drives both the text and the voice, so they
		  can never drift apart.
		- Voice uses ATTN_NONE so it is 2D - same volume for everyone
		  regardless of where they are standing.
*/

#include <amxmodx>

#define PLUGIN  "[ZP] Ghost Countdown"
#define VERSION "1.1"
#define AUTHOR  "setup"

#define TASK_TICK 8100

new const g_szCount[11][] = {
	"",
	"cscf/ghost_count_1.wav",
	"cscf/ghost_count_2.wav",
	"cscf/ghost_count_3.wav",
	"cscf/ghost_count_4.wav",
	"cscf/ghost_count_5.wav",
	"cscf/ghost_count_6.wav",
	"cscf/ghost_count_7.wav",
	"cscf/ghost_count_8.wav",
	"cscf/ghost_count_9.wav",
	"cscf/ghost_count_10.wav"
}

new g_pEnabled, g_pVoice
new g_iRemaining

public plugin_precache()
{
	for (new i = 1; i <= 10; i++)
		precache_sound(g_szCount[i])
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	g_pEnabled = register_cvar("zp_ghost_countdown", "1")
	g_pVoice   = register_cvar("zp_ghost_countdown_voice", "1")

	register_event("HLTV", "Event_NewRound", "a", "1=0", "2=0")
}

public Event_NewRound()
{
	remove_task(TASK_TICK)

	if (!get_pcvar_num(g_pEnabled))
		return

	g_iRemaining = floatround(get_cvar_float("zp_delay"), floatround_floor)

	if (g_iRemaining < 1)
		return

	set_task(0.1, "Task_Tick", TASK_TICK)
}

public Task_Tick()
{
	if (g_iRemaining < 1)
		return

	// red for the last ten, white before that
	if (g_iRemaining <= 10)
		set_dhudmessage(255, 60, 60, -1.0, 0.30, 0, 0.0, 1.1, 0.0, 0.0)
	else
		set_dhudmessage(230, 230, 230, -1.0, 0.30, 0, 0.0, 1.1, 0.0, 0.0)

	show_dhudmessage(0, "Mutation Spreading in %d seconds", g_iRemaining)

	if (g_iRemaining <= 10 && get_pcvar_num(g_pVoice))
		SpeakToAll(g_szCount[g_iRemaining])

	g_iRemaining--

	if (g_iRemaining >= 1)
		set_task(1.0, "Task_Tick", TASK_TICK)
}

/*
	spk rather than emit_sound on purpose.

	emit_sound attaches the sound to a player entity and to one of that
	entity's sound channels, so anything else landing on the same channel
	replaces it - and when the round flips, the entity's channels are torn
	down and whatever was playing is cancelled outright. The kill feedback
	sound was being killed exactly that way.

	spk plays straight on the client, outside the entity channel system, so
	the announcer runs in parallel with weapon fire and ZP's ambience instead
	of competing with them for a channel.
*/
SpeakToAll(const sound[])
{
	new players[32], num
	get_players(players, num, "ch")

	for (new i = 0; i < num; i++)
		client_cmd(players[i], "spk ^"%s^"", sound)
}

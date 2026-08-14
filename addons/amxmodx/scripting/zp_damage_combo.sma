/*
	[ZP] Damage Combo - ammo packs for damage and for kills, with the progress shown

	Humans earn an ammo pack for every zp_combo_damage points of damage they
	put into zombies, and another for every zombie they kill. Progress towards
	the next damage pack builds up as a block of lines at the right of the
	screen, and every payout announces itself in large text with the reason and
	the number of packs it actually granted.

	Why this plugin exists at all, given ZP already rewards damage
	    Zombie Plague has the damage mechanic built in - zp_human_damage_reward,
	    at zombie_plague40.sma:2080 - and it works. What it does not have is a
	    way to see it: g_damagedealt_human is an internal variable and no
	    native exposes it, so progress cannot be drawn over the top of it.

	    So this plugin owns the display instead, and zombieplague.cfg sets
	    zp_human_damage_reward 0 to switch ZP's off. That pairing matters. Two
	    accumulators both watching the same damage would both hand out packs,
	    and the player would earn at double rate for no visible reason. One
	    owner per behaviour.

	The kill reward is ours. ZP has no such rule for humans
	    Do not go looking for it in zombie_plague40 - it is not there. ZP's
	    only kill-based reward is gated on the attacker being a zombie
	    (:2011-2013, zp_zombie_infect_reward), and the one thing it does for a
	    human who kills a zombie is add FRAGS, not packs, and only when
	    zp_human_frags_for_kill is above 1 (:2016). At the shipped value of 1
	    it adds nothing and the player simply keeps the frag CS gives out
	    natively.

	    So ZP is asymmetric by design: the zombie side is paid for kills, the
	    human side for damage. zp_combo_kill_packs is what makes the human side
	    pay for kills too.

	    Before this rule existed, killing a zombie already tended to produce a
	    pack, which reads like a kill reward but is not one. Four of the five
	    classes have more health than zp_combo_damage - Big 2700, Classic 1800,
	    Poison 1400, Leech 1300, against a threshold of 1000 - so the damage
	    you must deal to kill one crosses the line on its own. Raptor at 900 is
	    the exception and the reason a real rule is worth having: it was the one
	    kill that could pay nothing.

	    A consequence worth knowing: the killing blow counts its full damage,
	    not the health the zombie had left. A zombie on 80 health hit for 400
	    banks 400. Deliberate - it is what ZP's own accumulator did, and
	    capping it would mean reading the victim's health on every hit.

	The zombie side is untouched on purpose
	    zp_zombie_infect_reward already grants a pack per infection or kill and
	    needs no help; adding to it here would be the same double-grant mistake
	    in the other direction. It also makes no sound of its own, and must not
	    grow one.

	Who is excluded
	    Survivor. It is a mode where one human gets huge health and unlimited
	    ammo against a server full of zombies, so both rewards would fill in
	    seconds. ZP excludes it from its own reward and zp_surv_ignore_rewards
	    is on, so this reads that same cvar rather than inventing a policy.

	    Nemesis needs no check. A nemesis is a zombie, so the "attacker must be
	    human" guard already covers it.

	    zombieplague.cfg also carries zp_sniper_ignore_rewards and
	    zp_assassin_ignore_rewards, and both are dead lines - nothing registers
	    them. This ZP build knows seven modes (INFECTION, MULTI, NEMESIS, NONE,
	    PLAGUE, SURVIVOR, SWARM) and Sniper and Assassin are not among them.

	    Watch out for zombieplague.inc here: it is from a NEWER ZP than the
	    plugin actually running and declares natives this build never
	    registers - zp_get_user_sniper among them. Calling one compiles
	    cleanly and fails at run time. Every native used below was checked
	    against the register_native lines in zombie_plague40.sma:547-557, not
	    against the include.

	Why the kill hook only banks its payout instead of announcing it
	    The engine calls Killed() from inside TakeDamage, so on a fatal hit the
	    order is: our Killed hook, then ZP's, then the respawn hooks, and only
	    then the POST half of TakeDamage. Our post handler therefore runs last
	    and is the only place that knows about both payouts at once. The kill
	    hook grants its packs immediately - pack counts must never depend on a
	    later flush - and leaves the count in g_iPendingKill for that handler
	    to fold into one announcement.

	    That keeps "killed it and crossed the line with the same bullet" from
	    firing two messages on top of each other, and keeps the counts honest:
	    two payouts in one instant say "+2 Ammo Packs" rather than claiming one.

	    The flush is safe on a fatal hit because zp_get_user_zombie reads
	    g_zombie[] with no alive check (:9069-9078), so a dead victim still
	    reads as a zombie when the post handler re-checks it. Respawn cannot
	    interfere either: zp_headshot_permadeath waits
	    zp_endless_respawn_delay seconds via set_task (:317-320), and even at a
	    delay of 0 it puts the player back as ZP_TEAM_ZOMBIE.

	    The one Ham_Killed call made by hand rather than by the engine -
	    zombie_plague40.sma:7883, the infection bomb finishing the last human -
	    cannot reach us. Its victim is a human and its attacker a zombie, so
	    both guards reject it.

	    A lethal non-melee hit on the LAST zombie pays no kill bonus, because
	    zp_headshot_permadeath cancels that hit in TakeDamage and heals the
	    zombie instead of letting it die. Nothing died, so nothing is owed.

	The progress block
	    The block counts up in steps of a tenth of the threshold and folds each
	    group of five into one line, so at a threshold of 1000 it reads:

	        100..500   +100 Damage!  one line per 100, up to five lines
	        600..900   +500 Damage!  the five fold into one as the sixth step
	                                 lands, with a +100 line per step after it
	        1000       block cleared, "+1 Ammo Pack" announced

	    The fold happens on the step AFTER the fifth, not on the fifth itself.
	    Folding at exactly 500 would leave a moment where the screen holds a
	    single +500 line and reads as if progress had gone backwards; waiting
	    for the sixth step means the fold and the line that replaces it appear
	    together.

	    It therefore never exceeds five lines - five +100s at 500, and one +500
	    with four +100s at 900 - and it is a pure function of g_iProgress.
	    Nothing tracks how many lines are currently up, so the display cannot
	    drift out of step with the real total.

	    It has to be a classic HUD message rather than the large DHUD font,
	    because collapsing five lines into one means clearing what was there,
	    and only the classic HUD can rewrite in place. amxmodx.inc:741-744 is
	    explicit about DHUD: "Unlike the classic HUD message, which is
	    channel-based, director messages are stack-based. You can have up to 8
	    messages displaying at once. If more are added, they will be
	    overwritten in the order they were sent. There is no way to clear a
	    specific message."

	    That is not a small distinction. An earlier version of this plugin drew
	    the progress with DHUD to get the bigger font, and because every damage
	    event redrew it, the eight slots filled with eight different values that
	    all stayed on screen for their hold time. It was unreadable.

	    There is a trick for clearing DHUD - flood eight blank messages to push
	    the old ones off the stack - and it must not be used here. The stack is
	    shared by every plugin on the server, so flooding it would also wipe
	    ZP's own win announcements, zp_ghost_countdown's timer and the Angelic's
	    wake-up line.

	Why the payout announcement is not DHUD either
	    It was, for one build. A one-shot message looked like a safe fit for a
	    stack that cannot be cleared, since it never needs rewriting - and it
	    bought the larger font, which is the only thing DHUD is good for.

	    In play it appeared only sometimes. The tell was that the reward SOUND
	    played every time while the text did not: the sound is issued two lines
	    after show_dhudmessage in the same function, so the call was plainly
	    being reached and the message was leaving the server. It was being
	    dropped on the way to the screen.

	    That is the other half of "stack-based" nobody writes down. A finite
	    shared pool of message slots with no clearing means a message that
	    arrives when the pool is full has nowhere to go, and the client discards
	    it rather than evicting something. Payouts land in the middle of
	    sustained fire, which is exactly when the pool is busiest, so the one
	    message you most want to see is the one most likely to be thrown away.

	    Both displays are therefore channel-based now. A channel is reserved:
	    the client clears it and redraws, so the message cannot be starved out.
	    Two consecutive payouts replace each other cleanly instead of piling up.
	    The cost is the small font, which is the trade the reliability is worth.

	    So: nothing in this plugin uses DHUD, and putting anything back on it
	    means re-earning this lesson.

	Screen positions
	    Eleven plugins already draw HUD text on this server and every one of
	    them is horizontally centred at y 0.17 to 0.46. The block sits out at
	    x 0.82 growing downward from y 0.42, so five lines reach about y 0.59;
	    the announcement is centred at y 0.70, below the block and above the
	    health and ammo row. They are separate mechanisms in separate places,
	    so neither has to yield to the other.

	cvars
	    zp_combo_damage     damage per ammo pack (0 turns the damage half off)
	    zp_combo_kill_packs packs per zombie killed (0 turns the kill half off)
	    zp_combo_sound      1 = play the cue on a payout
	    zp_combo_hud        1 = show the progress block
*/

#include <amxmodx>
#include <hamsandwich>
#include <zombieplague>

#define PLUGIN  "[ZP] Damage Combo"
#define VERSION "2.1"
#define AUTHOR  "setup"

new const SND_REWARD[] = "nano3/nano3_wraithpoint_up.wav"

/*
	How long a payout line stays up, and it is two things at once: the hold time
	of the drawn message and the age at which ExpireFeed drops the line. One
	constant for both so they cannot drift - a hold shorter than the expiry would
	blank the feed while lines were still live, and a longer one would keep
	showing lines that had already aged out.
*/
#define ANNOUNCE_HOLD 4.0

/*
	The block counts in BLOCK_STEPS steps to the threshold and folds every
	BLOCK_GROUP of them into one line. Derived from the threshold rather than
	hard-coded so that retuning zp_combo_damage cannot quietly produce a
	twenty-line block: at 1000 a step is 100 and the fold is 500, at 2000 they
	are 200 and 1000, and either way the block tops out at BLOCK_GROUP lines.
*/
#define BLOCK_STEPS 10
#define BLOCK_GROUP 5

#define BLOCK_X     0.82
#define BLOCK_Y     0.42

/*
	Deliberately the same as ANNOUNCE_HOLD, so progress and payouts leave the
	screen together rather than one lingering after the other. Kept as its own
	constant because there is no reason the two must stay equal - only that they
	are today.

	Every hit pushes this window forward, so the block is alive as long as the
	fight is, and the ticker keeps it drawn for the last few seconds after it.
*/
#define BLOCK_HOLD  4.0

/*
	Payouts go into a feed of up to FEED_LINES lines, oldest at the top, all in
	ONE message on ONE channel.

	Every other arrangement lost messages, and each loss was measured:

	  - one message per payout, replacing the last: a kill nearly always lands
	    within the same second as a damage crossing, so whichever drew second
	    erased the other. 6 of 49 announcements were a "1000 Damage" line wiped
	    by a "Zombie Killed" line a fraction of a second later.
	  - one message per payout, folding new payouts into the old: nothing was
	    erased, but a second pack only changed a digit in place, with no fade and
	    no movement, so 11% of payouts produced no visible event at all.
	  - a line each on a channel apiece: correct, but the client only has four
	    channels and taking a third of them squeezed ZP's own notices.

	A feed has none of those problems. Nothing overwrites anything, because
	everything that is still current is in the same message. Every payout appends
	a line, and a line appearing is unmistakably an event. And it costs one
	channel rather than two, which leaves two for ZP and the weapon plugins.

	Lines expire on their own clock, so the feed is rebuilt from whatever is
	still inside ANNOUNCE_HOLD each time a payout lands.
*/
#define FEED_LINES  5
#define FEED_Y      0.62

/*
	Redrawing on every hit covers the feed while the player keeps firing. It does
	not cover the case that gave the most trouble: a payout on the last bullet,
	followed by standing still. With nothing else redrawing, the first thing that
	wants a channel takes the feed and it is gone for good.

	So a payout also starts a ticker. ZP rewrites its status line once a second
	(zombie_plague40.sma:2417), so ticking three times faster than that means
	whatever takes the channel loses it again before the eye catches the gap -
	the same reason the progress block has never visibly flickered. The ticker
	stops itself as soon as the last line expires, so it runs for ANNOUNCE_HOLD
	seconds after the final payout and never longer.
*/
#define FEED_TICK    0.3
#define TASK_REDRAW  9200

/*
	Fixed channels, not -1, and not sync objects either.

	amxmodx.inc:659-665 spells out why: there are only FOUR HUD channels on the
	client (1-4), writing to one overwrites whatever was there, and "if you plan
	to create a permanent message, don't forget to specify a specific channel to
	avoid possible flickering due to auto-channeling."

	Both displays here used -1 for a while. The payout announcement appeared
	only sometimes as a result - auto-channeling handed its channel to the next
	message that wanted one, most often our own progress block a few
	milliseconds later, and the payout was overwritten before it could be read.
	The block never looked broken because it is redrawn on the next bullet
	either way; a message written once and expected to last does not get that
	second chance.

	Sync objects are out for the same reason: they allocate a channel per player
	themselves, so they cannot be pinned. show_hudmessage with an explicit
	channel can.

	scrollmsg.amxx holds channel 2 explicitly (scrollmsg.sma:56), so 3 and 4 are
	taken here and 1 is left for the auto-channel users - imessage, timeleft,
	adminchat, ZP's own notices - to rotate through.
*/
#define CH_BLOCK    3
#define CH_FEED     4

new g_iProgress[33]
new g_iPendingKill[33]

// kind 0 = damage crossing, 1 = kill
new g_iFeedKind[33][FEED_LINES]
new g_iFeedPacks[33][FEED_LINES]
new Float:g_fFeedTime[33][FEED_LINES]
new g_iFeedCount[33]
new bool:g_bFeedShown[33], bool:g_bBlockShown[33]

/*
	The block is held the same way a payout line is: an event opens a window, and
	the ticker keeps redrawing until the window closes. For the feed the window is
	per line (ANNOUNCE_HOLD from when it landed); for the block it is one deadline
	pushed forward by every hit that counts.

	Both displays therefore have one owner and one lifetime rule, and the ticker
	runs while either still has something to show.
*/
new Float:g_fBlockUntil[33]

/*
	One announcement per payout, naming every reason that fired on that shot -
	never a running total carried across a burst.

	Two other designs were tried and each hid something.

	A single merged reason line reported a kill as "1000 Damage + Kill!!! +2",
	and the words "Zombie Killed" reached the screen six times in a hundred and
	thirteen payouts. Killing a zombie nearly always crosses the damage line on
	the way there - every class except Raptor has more health than the threshold
	- so the kill was almost always absorbed into the damage wording. Hence one
	line per reason, below.

	Folding later payouts into the message already on screen fixed that, and
	introduced a quieter failure: a pack earned while the message was still up
	only changed a digit, with no fade and no movement, so 11% of payouts
	produced no visible event at all. "I dealt 1000 damage and nothing showed"
	was that, measured.

	So each payout redraws from scratch and gets a fresh fade-in, which reads as
	an event. Crossing the line and landing the kill on the SAME shot still share
	one message - they are one moment - and each takes its own line. Two payouts
	inside a second do cut each other short, and that is the accepted cost: a
	message that appeared and was cut short is still a message the player saw,
	unlike a digit that changed in place.
*/

new g_pDamage, g_pKillPacks, g_pSound, g_pHud, g_pChat
new g_pSurvIgnore
new g_pDebug

public plugin_precache()
{
	precache_sound(SND_REWARD)
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	g_pDamage    = register_cvar("zp_combo_damage", "1000")
	g_pKillPacks = register_cvar("zp_combo_kill_packs", "1")
	g_pSound     = register_cvar("zp_combo_sound", "1")
	g_pHud       = register_cvar("zp_combo_hud", "1")

	/*
		The guaranteed copy of the payout, and the reason it exists.

		Every HUD-based arrangement of this message went missing some of the
		time, and each one was measured: messages erased by the next payout,
		messages that only changed a digit, messages dropped because the client
		had no free slot, channels handed to another plugin mid-life. The client
		has four HUD channels, they are shared server-wide, and nothing can
		reserve one - ZP alone rewrites one every second and broadcasts a
		five-second notice to everybody on every infection.

		Chat is not in that system at all. It cannot be overwritten, it cannot be
		dropped for want of a slot, and it scrolls back, so a payout seen late is
		still a payout seen. The HUD feed stays because it looks better when it
		survives; this is what makes sure the player never actually loses one.
	*/
	g_pChat = register_cvar("zp_combo_chat", "1")

	/*
		Traces the payout path - a banked kill, a payout, and what was announced.

		OFF by default, and that default is not laziness. log_amx writes to the
		log file synchronously on the game thread, and a payout during a heavy
		fight means several of those a second: it was measured on this server as
		a frame rate drop with visible hitching while shooting, which vanished
		the moment this cvar went to 0. Turn it on to investigate something, and
		turn it off again before playing.

		zp_rules_debug is worth the same suspicion - it writes on every death.
	*/
	g_pDebug = register_cvar("zp_combo_debug", "0")

	/*
		ZP's own cvar, not one of ours - the exclusion policy stays defined in
		one place. ZP registers it during its plugin_init and loads first in
		plugins-zplague.ini, so the pointer is available by now; the null
		check is there in case that order ever changes.
	*/
	g_pSurvIgnore = get_cvar_pointer("zp_surv_ignore_rewards")

	/*
		Post, not pre. ZP subtracts the zombie armour multiplier from the
		damage in its own pre hook, so a pre hook here would count a number
		the zombie never actually lost. By post the value has settled and
		matches what the floating-damage addon puts on screen.
	*/
	RegisterHam(Ham_TakeDamage, "player", "Fw_TakeDamage_Post", 1)

	/*
		Pre, mirroring ZP's own reward at :2012. Reading the victim here rather
		than in a post hook keeps the check clear of anything the respawn
		plugins do once the death has been processed.
	*/
	RegisterHam(Ham_Killed, "player", "Fw_Killed_Pre", 0)
}

public client_putinserver(id)
{
	ResetPlayer(id)
}

public client_disconnected(id)
{
	ResetPlayer(id)
}

ResetPlayer(id)
{
	g_iProgress[id]    = 0
	g_iPendingKill[id] = 0
	g_iFeedCount[id]   = 0
	g_bFeedShown[id]   = false
	g_bBlockShown[id]  = false
	g_fBlockUntil[id]  = 0.0

	// a ticker still in flight would fire into the next player on this slot
	remove_task(id + TASK_REDRAW)
}

/*
	Progress deliberately survives death, respawn and the round boundary. It is
	a running total of what the player has contributed, not a per-life score,
	and ZP's version behaved the same way.
*/

/*
	Both rewards answer the same question about the pair of players involved,
	so they ask it in one place. Note this is called again from the post half
	of TakeDamage after the victim has died - see the header on why that still
	returns true.
*/
bool:IsRewardableHit(attacker, victim)
{
	if (attacker < 1 || attacker > 32 || attacker == victim || !is_user_connected(attacker))
		return false

	if (victim < 1 || victim > 32)
		return false

	// human hurting a zombie, and nothing else
	if (zp_get_user_zombie(attacker) || !zp_get_user_zombie(victim))
		return false

	if (zp_get_user_survivor(attacker) && (!g_pSurvIgnore || get_pcvar_num(g_pSurvIgnore)))
		return false

	return true
}

public Fw_Killed_Pre(victim, attacker, shouldgib)
{
	new packs = get_pcvar_num(g_pKillPacks)

	if (packs <= 0)
		return HAM_IGNORED

	if (!IsRewardableHit(attacker, victim))
	{
		// only player-on-player deaths by a human player, to keep this to a few
		// lines a round
		if (get_pcvar_num(g_pDebug) && 1 <= attacker <= 32 && 1 <= victim <= 32 && attacker != victim
		    && !is_user_bot(attacker))
			log_amx("[COMBO] kill NOT rewarded victim=%d attacker=%d atkZombie=%d vicZombie=%d",
				victim, attacker, zp_get_user_zombie(attacker), zp_get_user_zombie(victim))

		return HAM_IGNORED
	}

	/*
		Granted now, announced later. The packs are the part that must not be
		lost if the announcement never happens; the message is only feedback.
	*/
	GivePacks(attacker, packs)
	g_iPendingKill[attacker] += packs

	if (get_pcvar_num(g_pDebug) && !is_user_bot(attacker))
		log_amx("[COMBO] kill banked victim=%d attacker=%d packs=%d pending=%d progress=%d",
			victim, attacker, packs, g_iPendingKill[attacker], g_iProgress[attacker])

	return HAM_IGNORED
}

public Fw_TakeDamage_Post(victim, inflictor, attacker, Float:damage, damagebits)
{
	if (!IsRewardableHit(attacker, victim))
		return HAM_IGNORED

	new threshold = get_pcvar_num(g_pDamage)
	new crossings = 0

	if (threshold > 0)
	{
		new dealt = floatround(damage)

		if (dealt > 0)
		{
			g_iProgress[attacker] += dealt

			/*
				Subtract rather than zero, and loop rather than test once. A
				single hit can cross the line - a 300 point hit landing at 900
				should pay out and leave 200 behind, not throw 200 away - and a
				big enough hit can cross it more than once.
			*/
			while (g_iProgress[attacker] >= threshold)
			{
				g_iProgress[attacker] -= threshold
				crossings++
			}
		}
	}

	// banked by Fw_Killed_Pre a moment ago if this hit was the fatal one
	new killPacks = g_iPendingKill[attacker]
	g_iPendingKill[attacker] = 0

	if (crossings)
		GivePacks(attacker, crossings)

	/*
		Bots earn exactly as humans do - the economy is theirs too - they are
		simply not shown or told anything, because there is no screen to draw on
		and no client to play a sound. Skipping their trace as well keeps the log
		readable: they were producing about half of every [COMBO] line.
	*/
	new bool:bShow = !is_user_bot(attacker)

	if ((crossings || killPacks) && bShow)
	{
		if (get_pcvar_num(g_pDebug))
			log_amx("[COMBO] payout attacker=%d victim=%d dmg=%.0f progressLeft=%d crossings=%d killPacks=%d",
				attacker, victim, damage, g_iProgress[attacker], crossings, killPacks)

		Announce(attacker, threshold, crossings, killPacks)
	}

	/*
		Both displays are rebuilt here, on every hit, each on a channel of its
		own - the feed on CH_FEED and the block on CH_BLOCK, so neither can
		erase each other and do not overlap on screen. Redrawing this often is
		the whole trick: it costs nothing because a channel write replaces in
		place, and it is what stops either of them from being lost to whatever
		else on this server wants a channel.
	*/
	/*
		Nothing is drawn from here. A hit only opens the block's window and makes
		sure the ticker is running; the ticker owns every write to the screen.

		That is deliberate and it is a performance fix, not a style choice. Drawing
		from here meant two HUD messages per damage event - twenty a second with a
		rifle, and ten in a single frame when one Angelic stab hits five zombies,
		each of them a multi-line string the client has to lay out again. It cost
		visible frames while shooting.

		With the ticker as the only writer, HUD traffic is two messages every
		FEED_TICK no matter how fast the player fires or how many zombies a swing
		catches. The cost is that a new line can take up to FEED_TICK to appear.
	*/
	if (bShow && get_pcvar_num(g_pHud))
	{
		g_fBlockUntil[attacker] = get_gametime() + BLOCK_HOLD

		if (!task_exists(attacker + TASK_REDRAW))
			set_task(FEED_TICK, "Task_Redraw", attacker + TASK_REDRAW, _, _, "b")
	}

	return HAM_IGNORED
}

GivePacks(id, count)
{
	zp_set_user_ammo_packs(id, zp_get_user_ammo_packs(id) + count)
}

/*
	One message for however many packs landed in this instant, naming what
	earned them. The sound belongs here rather than with the grant: two packs
	at once used to mean two overlapping copies of the same cue.
*/
Announce(id, threshold, crossings, killPacks)
{
	new total = crossings + killPacks

	if (total <= 0)
		return

	/*
		Only queued here. The ticker does the drawing, so a payout appears on
		the next tick rather than in this call.
	*/
	ExpireFeed(id)

	if (crossings > 0)
		PushFeed(id, 0, crossings)

	if (killPacks > 0)
		PushFeed(id, 1, killPacks)

	if (get_pcvar_num(g_pChat))
		ChatPayout(id, threshold, crossings, killPacks)

	if (get_pcvar_num(g_pDebug))
		log_amx("[COMBO] announce id=%d cross=%d kill=%d", id, crossings, killPacks)

	/*
		spk rather than emit_sound, following the rest of this server: a sound
		tied to a player entity and channel is torn down when the round flips
		and can be replaced by anything else using that channel. This one is
		pure feedback and belongs on the client.
	*/
	if (get_pcvar_num(g_pSound))
		client_cmd(id, "spk ^"%s^"", SND_REWARD)
}

/*
	One line naming every reason that paid, the packs it paid, and the new
	balance - which is the one number no display on this server shows in a form
	you can look back at.
*/
ChatPayout(id, threshold, crossings, killPacks)
{
	new szWhat[64]

	if (crossings > 0 && killPacks > 0)
		formatex(szWhat, charsmax(szWhat), "%d Damage + Zombie Killed", threshold)
	else if (crossings > 0)
		formatex(szWhat, charsmax(szWhat), "%d Damage", threshold)
	else
		copy(szWhat, charsmax(szWhat), "Zombie Killed")

	new total = crossings + killPacks

	/*
		Coloured so it does not read as somebody talking. client_print_color is
		CS-only and needs a team for ^3 to resolve against, which is what
		print_team_default supplies; ^4 is green and ^1 returns to the normal chat
		colour. The numbers are green too, so the part worth reading at a glance
		is the part that is coloured.
	*/

	// plural as a branch so every format string stays a literal
	if (total > 1)
		client_print_color(id, print_team_default, "^4[Combo]^1 %s -- ^4+%d^1 ammo packs (you now have ^4%d^1)",
			szWhat, total, zp_get_user_ammo_packs(id))
	else
		client_print_color(id, print_team_default, "^4[Combo]^1 %s -- ^4+1^1 ammo pack (you now have ^4%d^1)",
			szWhat, zp_get_user_ammo_packs(id))
}

// drop anything that has outlived the hold, closing the gap it leaves behind
ExpireFeed(id)
{
	new Float:now = get_gametime()
	new keep = 0

	for (new i = 0; i < g_iFeedCount[id]; i++)
	{
		if (now - g_fFeedTime[id][i] >= ANNOUNCE_HOLD)
			continue

		if (keep != i)
		{
			g_iFeedKind[id][keep]  = g_iFeedKind[id][i]
			g_iFeedPacks[id][keep] = g_iFeedPacks[id][i]
			g_fFeedTime[id][keep]  = g_fFeedTime[id][i]
		}

		keep++
	}

	g_iFeedCount[id] = keep
}

/*
	Appended at the bottom. A full feed drops its oldest line rather than
	refusing the new one - the newest payout is the one the player is waiting to
	see.
*/
PushFeed(id, kind, packs)
{
	if (g_iFeedCount[id] >= FEED_LINES)
	{
		for (new i = 0; i < FEED_LINES - 1; i++)
		{
			g_iFeedKind[id][i]  = g_iFeedKind[id][i + 1]
			g_iFeedPacks[id][i] = g_iFeedPacks[id][i + 1]
			g_fFeedTime[id][i]  = g_fFeedTime[id][i + 1]
		}

		g_iFeedCount[id] = FEED_LINES - 1
	}

	new slot = g_iFeedCount[id]

	g_iFeedKind[id][slot]  = kind
	g_iFeedPacks[id][slot] = packs
	g_fFeedTime[id][slot]  = get_gametime()

	g_iFeedCount[id]++
}

/*
	Why anything is redrawn at all: nothing on this server can hold a HUD channel
	against ZP and the weapon plugins, but a message rewritten several times a
	second is never visibly gone - whoever takes the channel loses it again before
	the eye can catch the gap.

	The feed was originally drawn once per payout and had to survive ANNOUNCE_HOLD
	seconds on its own in a contended pool, which is why it came and went while
	the block - redrawn constantly - did not.

	Redrawing per damage event fixed that and cost frames instead, so the ticker is
	the only writer now. See the note at the call site in Fw_TakeDamage_Post.
*/
/*
	Progress and payouts are one message on one channel, because the channel is
	the scarce thing here - see the header. Layout:

	    line 1..BLOCK_GROUP   the progress block, padded with blanks to a fixed
	                          height so that what follows never moves
	    then                  one line per live payout, newest last

	The padding is the point. Two sections that change on different clocks in one
	message means either the block is a fixed height or every step it gains
	shoves the payout lines down the screen while the player is reading them.
*/
/*
	Two displays, a channel each: the progress block at the right edge and the
	payout feed centred below it. Separate messages so each keeps its own colour
	and position, and so neither can erase the other.

	The cost is that this plugin holds two of the client's four HUD channels, and
	the redraw below wins any channel it shares - which is why ZP's own status
	line flickers while this is on. zp_combo_hud 0 gives that channel back.
*/
/*
	The only thing that writes to the screen. Holds both displays against
	everything else that wants a HUD channel by rewriting them faster than anyone
	takes them, and runs only while one of them still has a live window - so it is
	idle whenever the player is.
*/
public Task_Redraw(taskid)
{
	new id = taskid - TASK_REDRAW

	if (!is_user_connected(id) || !get_pcvar_num(g_pHud))
	{
		remove_task(taskid)
		return
	}

	new threshold = get_pcvar_num(g_pDamage)
	new bool:blockLive = (get_gametime() < g_fBlockUntil[id])

	RefreshFeed(id, threshold)
	RefreshBlock(id, threshold)

	// nothing left with a window open
	if (!g_iFeedCount[id] && !blockLive)
		remove_task(taskid)
}

RefreshFeed(id, threshold)
{
	ExpireFeed(id)

	if (!g_iFeedCount[id])
	{
		BlankFeed(id)
		return
	}

	DrawFeed(id, threshold)
}

RefreshBlock(id, threshold)
{
	new steps = 0

	if (threshold > 0 && get_gametime() < g_fBlockUntil[id])
		steps = BlockSteps(id, threshold)

	if (!steps)
	{
		BlankBlock(id)
		return
	}

	DrawBlock(id, threshold, steps)
}

/*
	Clearing a channel means overwriting it, since without a sync object there is
	no ClearSyncHud to call - and a space rather than an empty string, because an
	empty hudmessage is not reliably sent. Guarded so the blank goes out once
	when the display ends rather than on every tick afterwards.
*/
BlankFeed(id)
{
	if (!g_bFeedShown[id])
		return

	set_hudmessage(255, 190, 40, -1.0, FEED_Y, 0, 0.0, 0.1, 0.0, 0.0, CH_FEED)
	show_hudmessage(id, " ")

	g_bFeedShown[id] = false
}

BlankBlock(id)
{
	if (!g_bBlockShown[id])
		return

	set_hudmessage(0, 200, 255, BLOCK_X, BLOCK_Y, 0, 0.0, 0.1, 0.0, 0.0, CH_BLOCK)
	show_hudmessage(id, " ")

	g_bBlockShown[id] = false
}

/*
	How many BLOCK_STEPS-sized steps of progress are banked, clamped. Only
	reachable above the clamp when the threshold does not divide evenly into
	BLOCK_STEPS - 999 leaves a step of 99 and room for a tenth line - and the
	clamp is what keeps the promise of at most BLOCK_GROUP lines.
*/
BlockSteps(id, threshold)
{
	new step = threshold / BLOCK_STEPS

	// a threshold under BLOCK_STEPS would divide to zero
	if (step < 1)
		step = 1

	new steps = g_iProgress[id] / step

	if (steps > BLOCK_STEPS - 1)
		steps = BLOCK_STEPS - 1

	return steps
}

/*
	Strictly greater, not equal, on the fold: the fifth step still shows five
	lines and the fold appears with the sixth.
*/
DrawBlock(id, threshold, steps)
{
	new step = threshold / BLOCK_STEPS

	if (step < 1)
		step = 1

	new szBlock[192]
	new len = 0

	if (steps > BLOCK_GROUP)
	{
		len = formatex(szBlock, charsmax(szBlock), "+%d Damage!", step * BLOCK_GROUP)
		steps -= BLOCK_GROUP
	}

	for (new i = 0; i < steps; i++)
	{
		if (len)
			len += formatex(szBlock[len], charsmax(szBlock) - len, "^n")

		len += formatex(szBlock[len], charsmax(szBlock) - len, "+%d Damage!", step)
	}

	set_hudmessage(0, 200, 255, BLOCK_X, BLOCK_Y, 0, 0.0, BLOCK_HOLD, 0.0, 0.2, CH_BLOCK)
	show_hudmessage(id, szBlock)

	g_bBlockShown[id] = true
}

DrawFeed(id, threshold)
{
	new szMsg[320]
	new len = 0

	for (new i = 0; i < g_iFeedCount[id]; i++)
	{
		if (len)
			len += formatex(szMsg[len], charsmax(szMsg) - len, "^n")

		// plural as a branch so every format string stays a literal
		if (g_iFeedKind[id][i])
		{
			if (g_iFeedPacks[id][i] > 1)
				len += formatex(szMsg[len], charsmax(szMsg) - len, "Zombie Killed!!!  +%d Ammo Packs", g_iFeedPacks[id][i])
			else
				len += formatex(szMsg[len], charsmax(szMsg) - len, "Zombie Killed!!!  +1 Ammo Pack")
		}
		else
		{
			if (g_iFeedPacks[id][i] > 1)
				len += formatex(szMsg[len], charsmax(szMsg) - len, "%d Damage!!!  +%d Ammo Packs", threshold, g_iFeedPacks[id][i])
			else
				len += formatex(szMsg[len], charsmax(szMsg) - len, "%d Damage!!!  +1 Ammo Pack", threshold)
		}
	}

	/*
		Fade-in must be zero. A redraw kills the old message and adds a new one,
		and a new message starts its fade from nothing - so any fade-in at all
		turns re-assertion into a strobe: 0.1s of fade against a 0.3s tick is the
		brightness dropping to zero three times a second.
	*/
	set_hudmessage(255, 190, 40, -1.0, FEED_Y, 0, 0.0, ANNOUNCE_HOLD, 0.0, 0.2, CH_FEED)
	show_hudmessage(id, szMsg)

	g_bFeedShown[id] = true
}

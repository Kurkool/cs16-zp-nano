#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <zombieplague>
#include <xs>

new g_norecoil[33]
new Float: cl_pushangle[33][3]
new g_itemid_norecoil

const WEAPONS_BITSUM = (1<<CSW_KNIFE|1<<CSW_HEGRENADE|1<<CSW_FLASHBANG|1<<CSW_SMOKEGRENADE|1<<CSW_C4)

public plugin_init()
{
	register_plugin("[ZP] Extra Item: No Recoil", "0.1.0", "fezh")

	// buy once and keep it - the "(Single Round)" wording was dropped along
	// with the round-start reset below
	g_itemid_norecoil = zp_register_extra_item("No Recoil", 15, ZP_TEAM_HUMAN)

	new weapon_name[24]
	for (new i = 1; i <= 30; i++)
	{
		if (!(WEAPONS_BITSUM & 1 << i) && get_weaponname(i, weapon_name, 23))
		{
			RegisterHam(Ham_Weapon_PrimaryAttack, weapon_name, "fw_Weapon_PrimaryAttack_Pre")
			RegisterHam(Ham_Weapon_PrimaryAttack, weapon_name, "fw_Weapon_PrimaryAttack_Post", 1)
		}
	}

	// the HLTV round-start event is not registered any more: its handler was
	// removed to make this a buy-once item, and registering a callback that
	// does not exist is a load-time runtime error
}

public zp_extra_item_selected(player, itemid)
{
	if (itemid == g_itemid_norecoil)
	{
		g_norecoil[player] = true
		client_print(player, print_chat, "[ZP] You have bought No Recoil!")
	}
}

public zp_user_infected_post(id)
	g_norecoil[id] = false

public client_connect(id)
	g_norecoil[id] = false

/*
	Round-start reset removed on purpose: this is now a buy-once item, so it
	survives the round flip. It still goes away when the owner is infected,
	which is the same rule the weapon plugins on this server use.

public event_round_start()
	for (new id = 1; id <= g_maxplayers; id++)
		g_norecoil[id] = false
*/

public fw_Weapon_PrimaryAttack_Pre(entity)
{
	new id = pev(entity, pev_owner)

	if (g_norecoil[id])
	{
		pev(id, pev_punchangle, cl_pushangle[id])
		return HAM_IGNORED;
	}
	return HAM_IGNORED;
}

public fw_Weapon_PrimaryAttack_Post(entity)
{
	new id = pev(entity, pev_owner)

	if (g_norecoil[id])
	{
		new Float: push[3]
		pev(id, pev_punchangle, push)
		xs_vec_sub(push, cl_pushangle[id], push)
		xs_vec_mul_scalar(push, 0.0, push)
		xs_vec_add(push, cl_pushangle[id], push)
		set_pev(id, pev_punchangle, push)
		return HAM_IGNORED;
	}
	return HAM_IGNORED;
}

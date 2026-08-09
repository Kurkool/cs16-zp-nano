#if defined _dhudmessage_included
    #endinput
#endif
#define _dhudmessage_included

// Shim added by setup.
// AMX Mod X 1.10 ships set_dhudmessage / show_dhudmessage as CORE NATIVES
// (amxmodx.inc lines 735 and 762). The original bundled copy of this file
// came from the Zombie Plague package and redefined them as stocks, which
// collides on every compile. Original kept as dhudmessage.inc.orig.
#include <amxmodx>

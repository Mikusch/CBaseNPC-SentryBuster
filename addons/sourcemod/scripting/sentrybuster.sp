#include <sourcemod>
#include <dhooks>
#include <cbasenpc>
#include <sdktools>
#include <sdkhooks>
#include <tf2_stocks>

#define FFADE_IN			0x0001		// Just here so we don't pass 0 into the function
#define FFADE_OUT			0x0002		// Fade out (not in)
#define FFADE_MODULATE		0x0004		// Modulate (don't blend)
#define FFADE_STAYOUT		0x0008		// ignores the duration, stays faded out until new ScreenFade message received
#define FFADE_PURGE			0x0010		// Purges all other fades, replacing them with this one
#define SCREENFADE_FRACBITS	9

enum ShakeCommand_t
{
	SHAKE_START = 0,
	SHAKE_STOP,
	SHAKE_AMPLITUDE,
	SHAKE_FREQUENCY,
	SHAKE_START_RUMBLEONLY,
	SHAKE_START_NORUMBLE,
};

enum SpawnLocationResult
{
	SPAWN_LOCATION_NOT_FOUND = 0,
	SPAWN_LOCATION_NAV,
	SPAWN_LOCATION_TELEPORTER
};

enum struct CountdownTimer
{
	float timestamp;
	float duration;
	
	void Reset()
	{
		this.timestamp = GetGameTime() + this.duration;
	}
	
	void Start(float duration)
	{
		this.timestamp = GetGameTime() + duration;
		this.duration = duration;
	}
	
	void Invalidate()
	{
		this.timestamp = -1.0;
	}
	
	bool HasStarted()
	{
		return this.timestamp > 0.0;
	}
	
	bool IsElapsed()
	{
		return GetGameTime() > this.timestamp;
	}
	
	float GetElapsedTime()
	{
		return GetGameTime() - this.timestamp + this.duration;
	}
	
	float GetRemainingTime()
	{
		return this.timestamp - GetGameTime();
	}
	
	float GetCountdownDuration()
	{
		return this.HasStarted() ? this.duration : 0.0;
	}
}

// ConVars
ConVar phys_pushscale;
ConVar tf_mvm_default_sentry_buster_damage_dealt_threshold;
ConVar tf_mvm_default_sentry_buster_kill_threshold;

// Offsets
int g_offsetAccumulatedSentryGunDamageDealt;
int g_offsetAccumulatedSentryGunKillCount;

// Globals
int g_numSentryBustersSpawned;
int g_numSentryBustersKilled;
int g_spawnCount;
int s_lastTeleporter;
CountdownTimer g_TalkTimer;
CountdownTimer g_cooldownTimer[view_as<int>(TFTeam_Blue) + 1];
CountdownTimer g_checkForDangerousSentriesTimer[view_as<int>(TFTeam_Blue) + 1];

#include "sentrybuster/base.sp"

public void OnPluginStart()
{
	phys_pushscale = FindConVar("phys_pushscale");
	tf_mvm_default_sentry_buster_damage_dealt_threshold = FindConVar("tf_mvm_default_sentry_buster_damage_dealt_threshold");
	tf_mvm_default_sentry_buster_kill_threshold = FindConVar("tf_mvm_default_sentry_buster_kill_threshold");
	
	SentryBuster_Init();
	
	HookEvent("teamplay_round_start", Event_TeamplayRoundStart);
	
	RegAdminCmd("sm_bust", Command_Buster, ADMFLAG_ROOT);
	
	GameData gamedata = new GameData("sentrybuster");
	if (gamedata)
	{
		g_offsetAccumulatedSentryGunDamageDealt = gamedata.GetOffset("CTFPlayer::m_accumulatedSentryGunDamageDealt");
		g_offsetAccumulatedSentryGunKillCount = gamedata.GetOffset("CTFPlayer::m_accumulatedSentryGunKillCount");
		
		delete gamedata;
	}
	else
	{
		SetFailState("Could not find sentrybuster gamedata");
	}
}

public void OnMapStart()
{
	SentryBuster.Precache();
}

public void OnGameFrame()
{
	if (GameRules_GetRoundState() == RoundState_Preround)
		return;
	
	for (TFTeam team = TFTeam_Red; team <= TFTeam_Blue; team++)
	{
		UpdateMissionDestroySentries(team);
	}
}

void UpdateMissionDestroySentries(TFTeam team)
{
	if (!g_cooldownTimer[team].IsElapsed())
		return;
	
	if (!g_checkForDangerousSentriesTimer[team].IsElapsed())
		return;
	
	g_checkForDangerousSentriesTimer[team].Start(GetRandomFloat(5.0, 10.0));
	
	ArrayList dangerousSentryList = new ArrayList();
	
	float dmgLimit;
	int killLimit;
	GetSentryBusterDamageAndKillThreshold(team, dmgLimit, killLimit);
	
	int obj = MaxClients + 1;
	while ((obj = FindEntityByClassname(obj, "obj_*")) != -1)
	{
		if (TF2_GetObjectType(obj) == TFObject_Sentry)
		{
			// Disposable sentries are not valid targets
			if (GetEntProp(obj, Prop_Send, "m_bDisposableBuilding"))
				continue;
			
			if (view_as<TFTeam>(GetEntProp(obj, Prop_Data, "m_iTeamNum")) == team)
			{
				int owner = GetEntPropEnt(obj, Prop_Send, "m_hBuilder");
				if (owner != -1)
				{
					float dmgDone = GetEntDataFloat(owner, g_offsetAccumulatedSentryGunDamageDealt);
					int killsMade = GetEntData(owner, g_offsetAccumulatedSentryGunKillCount);
					
					if (dmgDone >= dmgLimit || killsMade >= killLimit)
					{
						dangerousSentryList.Push(obj);
					}
				}
			}
		}
	}
	
	// Dispatch a sentry busting squad for each dangerous sentry
	bool didSpawn = false;
	
	for (int i = 0; i < dangerousSentryList.Length; i++)
	{
		int targetSentry = dangerousSentryList.Get(i);
		
		// If there is already a squad out there destroying this sentry, don't spawn another one
		int npc = MaxClients + 1;
		while ((npc = FindEntityByClassname(npc, "cbasenpc_sentry_buster")) != -1)
		{
			if (GetEntPropEnt(npc, Prop_Data, "m_hTarget") == targetSentry)
			{
				// There is already a sentry busting squad active for this sentry
				break;
			}
		}
		
		float spawnPosition[3];
		SpawnLocationResult spawnLocationResult = FindSpawnLocation(GetEnemyTeam(team), spawnPosition);
		if (spawnLocationResult != SPAWN_LOCATION_NOT_FOUND)
		{
			SentryBuster buster = view_as<SentryBuster>(CreateEntityByName("cbasenpc_sentry_buster"));
			if (buster.index != -1)
			{
				buster.Teleport(spawnPosition);
				buster.hTarget = targetSentry;
				buster.SetProp(Prop_Data, "m_iTeamNum", GetEnemyTeam(team));
				buster.Spawn();
				
				if (view_as<TFTeam>(buster.GetProp(Prop_Data, "m_iTeamNum")) == TFTeam_Red)
				{
					SetEntityRenderMode(buster.index, RENDER_TRANSCOLOR);
					SetEntityRenderColor(buster.index, 255, 64, 64, 255);
				}
				
				didSpawn = true;
				
				// what bot should do after spawning at teleporter exit
				if (spawnLocationResult == SPAWN_LOCATION_TELEPORTER)
				{
					OnBotTeleported(buster);
				}
			}
		}
	}
	
	delete dangerousSentryList;
	
	if (didSpawn)
	{
		g_numSentryBustersSpawned++;
		
		if (g_numSentryBustersSpawned > 1)
		{
			EmitGameSoundToTeam(team, "Announcer.MVM_Sentry_Buster_Alert_Another");
		}
		else
		{
			EmitGameSoundToTeam(team, "Announcer.MVM_Sentry_Buster_Alert");
		}
		
		float cooldown = 60.0 + g_numSentryBustersKilled * 60.0;
		
		g_numSentryBustersKilled = 0;
		
		g_cooldownTimer[team].Start(cooldown);
	}
}

void OnBotTeleported(CBaseCombatCharacter bot)
{
	EmitGameSoundToAll("MVM.Robot_Teleporter_Deliver", s_lastTeleporter);
	
	float angles[3], fwd[3];
	GetEntPropVector(s_lastTeleporter, Prop_Data, "m_angAbsRotation", angles);
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	
	float origin[3];
	bot.GetPropVector(Prop_Data, "m_vecAbsOrigin", origin);
	
	ScaleVector(fwd, 50.0);
	AddVectors(origin, fwd, origin);
	
	bot.MyNextBotPointer().GetLocomotionInterface().FaceTowards(origin);
}

SpawnLocationResult FindSpawnLocation(TFTeam team, float spawnPosition[3])
{
	ArrayList activeSpawns = new ArrayList();
	int spawn = MaxClients + 1;
	while ((spawn = FindEntityByClassname(spawn, "info_player_teamspawn")) != -1)
	{
		if (GetEntProp(spawn, Prop_Data, "m_bDisabled"))
			continue;
		
		if (view_as<TFTeam>(GetEntProp(spawn, Prop_Data, "m_iTeamNum")) != team)
			continue;
		
		activeSpawns.Push(spawn);
	}
	
	if (g_spawnCount >= activeSpawns.Length)
	{
		activeSpawns.Sort(Sort_Random, Sort_Integer);
		g_spawnCount = 0;
	}
	
	if (activeSpawns.Length > 0)
	{
		SpawnLocationResult result = DoTeleporterOverride(team, activeSpawns.Get(g_spawnCount), spawnPosition);
		if (result != SPAWN_LOCATION_NOT_FOUND)
		{
			g_spawnCount++;
			return result;
		}
	}
	
	delete activeSpawns;
	return SPAWN_LOCATION_NOT_FOUND;
}

SpawnLocationResult DoTeleporterOverride(TFTeam team, int spawnEnt, float spawnPosition[3])
{
	ArrayList teleporterList = new ArrayList();
	
	int obj = MaxClients + 1;
	while ((obj = FindEntityByClassname(obj, "obj_*")) != -1)
	{
		if (TF2_GetObjectType(obj) != TFObject_Teleporter)
			continue;
		
		if (view_as<TFTeam>(GetEntProp(obj, Prop_Data, "m_iTeamNum")) != team)
			continue;
		
		if (GetEntProp(obj, Prop_Send, "m_bBuilding"))
			continue;
		
		if (GetEntProp(obj, Prop_Send, "m_bHasSapper"))
			continue;
		
		if (GetEntProp(obj, Prop_Send, "m_bPlasmaDisable"))
			continue;
		
		teleporterList.Push(obj);
	}
	
	if (teleporterList.Length > 0)
	{
		int which = GetRandomInt(0, teleporterList.Length - 1);
		WorldSpaceCenter(teleporterList.Get(which), spawnPosition);
		s_lastTeleporter = teleporterList.Get(which);
		
		delete teleporterList;
		return SPAWN_LOCATION_TELEPORTER;
	}
	
	float center[3];
	WorldSpaceCenter(spawnEnt, center);
	CNavArea nav = TheNavMesh.GetNearestNavArea(center);
	if (nav == NULL_AREA)
		return SPAWN_LOCATION_NOT_FOUND;
	
	nav.GetCenter(spawnPosition);
	
	delete teleporterList;
	return SPAWN_LOCATION_NAV;
}

public void GetSentryBusterDamageAndKillThreshold(TFTeam team, float &damage, int &kills)
{
	int sentries;
	
	int obj = MaxClients + 1;
	while ((obj = FindEntityByClassname(obj, "obj_*")) != -1)
	{
		if (TF2_GetObjectType(obj) == TFObject_Sentry)
		{
			// Disposable sentries are not valid targets
			if (GetEntProp(obj, Prop_Send, "m_bDisposableBuilding"))
				continue;
			
			if (view_as<TFTeam>(GetEntProp(obj, Prop_Data, "m_iTeamNum")) == team)
			{
				sentries++;
			}
		}
	}
	
	// Adjust damage and kill threshold based on number of sentries in the world
	// otherwise players trivially handle the spawn rate with raw damage
	float scale = RemapValClamped(float(sentries), 1.0, 6.0, 1.0, 0.5);
	damage = (sentries >= 2) ? tf_mvm_default_sentry_buster_damage_dealt_threshold.FloatValue * scale : tf_mvm_default_sentry_buster_damage_dealt_threshold.FloatValue;
	kills = (sentries >= 2) ? RoundFloat(tf_mvm_default_sentry_buster_kill_threshold.IntValue * scale) : tf_mvm_default_sentry_buster_kill_threshold.IntValue;
}

public void Event_TeamplayRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_numSentryBustersSpawned = 0;
	g_numSentryBustersKilled = 0;
	g_spawnCount = 0;
	
	for (TFTeam team = TFTeam_Red; team <= TFTeam_Blue; team++)
	{
		g_cooldownTimer[team].Invalidate();
		g_checkForDangerousSentriesTimer[team].Invalidate();
	}
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			SetEntDataFloat(client, g_offsetAccumulatedSentryGunDamageDealt, 0.0);
			SetEntData(client, g_offsetAccumulatedSentryGunKillCount, 0);
		}
	}
}

public Action Command_Buster(int client, int args)
{
	if (client == 0 || args != 3)
	{
		return Plugin_Continue;
	}
	
	char sSpawnTeam[5], sBusterTeam[5];
	GetCmdArg(2, sSpawnTeam, sizeof(sSpawnTeam));
	GetCmdArg(3, sBusterTeam, sizeof(sBusterTeam));
	
	int spawnTeam = StringToInt(sSpawnTeam);
	int busterTeam = StringToInt(sBusterTeam);
	
	ArrayList spawns = new ArrayList();
	int spawn = MaxClients + 1;
	while ((spawn = FindEntityByClassname(spawn, "info_player_teamspawn")) != -1)
	{
		if (GetEntProp(spawn, Prop_Data, "m_iTeamNum") == spawnTeam)
		{
			spawns.Push(spawn);
		}
	}
	
	char targetName[32];
	GetCmdArg(1, targetName, sizeof(targetName));
	
	char target_name[MAX_TARGET_LENGTH];
	int target_list[MAXPLAYERS], target_count;
	bool tn_is_ml;
	
	if ((target_count = ProcessTargetString(
				targetName, 
				client, 
				target_list, 
				MAXPLAYERS, 
				0, 
				target_name, 
				sizeof(target_name), 
				tn_is_ml)) <= 0)
	{
		return Plugin_Handled;
	}
	
	for (int i = 0; i < target_count; i++)
	{
		int target = target_list[i];
		
		if (IsClientSourceTV(target))continue; // Exclude the sourcetv bot
		
		SentryBuster buster = view_as<SentryBuster>(CreateEntityByName("cbasenpc_sentry_buster"));
		if (buster.index != -1)
		{
			CBaseEntity teamSpawn = CBaseEntity(spawns.Get(GetRandomInt(0, spawns.Length - 1)));
			float pos[3];
			teamSpawn.GetAbsOrigin(pos);
			
			buster.Teleport(pos);
			buster.hTarget = target;
			buster.SetProp(Prop_Data, "m_iTeamNum", busterTeam);
			buster.Spawn();
		}
	}
	
	return Plugin_Handled;
}

stock int FindStringIndex2(int tableidx, const char[] str)
{
	char buf[1024];
	int numStrings = GetStringTableNumStrings(tableidx);
	for (int idx = 0; idx < numStrings; idx++)
	{
		ReadStringTable(tableidx, idx, buf, sizeof(buf));
		if (strcmp(buf, str) == 0)
		{
			return idx;
		}
	}
	
	return INVALID_STRING_INDEX;
}

stock int PrecacheParticleSystem(const char[] particleSystem)
{
	static int particleEffectNames = INVALID_STRING_TABLE;
	if (particleEffectNames == INVALID_STRING_TABLE)
	{
		if ((particleEffectNames = FindStringTable("ParticleEffectNames")) == INVALID_STRING_TABLE)
		{
			return INVALID_STRING_INDEX;
		}
	}
	
	int index = FindStringIndex2(particleEffectNames, particleSystem);
	if (index == INVALID_STRING_INDEX)
	{
		int numStrings = GetStringTableNumStrings(particleEffectNames);
		if (numStrings >= GetStringTableMaxStrings(particleEffectNames))
		{
			return INVALID_STRING_INDEX;
		}
		
		AddToStringTable(particleEffectNames, particleSystem);
		index = numStrings;
	}
	
	return index;
}

void TE_Particle(int iParticleIndex, const float origin[3] = NULL_VECTOR, const float start[3] = NULL_VECTOR, 
	const float angles[3] = NULL_VECTOR, int entindex = -1, int attachtype = -1, int attachpoint = -1, bool resetParticles = true)
{
	TE_Start("TFParticleEffect");
	TE_WriteFloat("m_vecOrigin[0]", origin[0]);
	TE_WriteFloat("m_vecOrigin[1]", origin[1]);
	TE_WriteFloat("m_vecOrigin[2]", origin[2]);
	TE_WriteFloat("m_vecStart[0]", start[0]);
	TE_WriteFloat("m_vecStart[1]", start[1]);
	TE_WriteFloat("m_vecStart[2]", start[2]);
	TE_WriteVector("m_vecAngles", angles);
	TE_WriteNum("m_iParticleSystemIndex", iParticleIndex);
	TE_WriteNum("entindex", entindex);
	
	if (attachtype != -1)
	{
		TE_WriteNum("m_iAttachType", attachtype);
	}
	
	if (attachpoint != -1)
	{
		TE_WriteNum("m_iAttachmentPointIndex", attachpoint);
	}
	TE_WriteNum("m_bResetParticles", resetParticles ? 1 : 0);
}

stock int FixedUnsigned16(float value, int scale)
{
	int output;
	
	output = RoundToFloor(value * float(scale));
	if (output < 0)
	{
		output = 0;
	}
	if (output > 0xFFFF)
	{
		output = 0xFFFF;
	}
	
	return output;
}

public void UTIL_ScreenFade(int player, int color[4], float fadeTime, float fadeHold, int flags)
{
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("Fade", player, USERMSG_RELIABLE));
	if (bf != null)
	{
		bf.WriteShort(FixedUnsigned16(fadeTime, 1 << SCREENFADE_FRACBITS));
		bf.WriteShort(FixedUnsigned16(fadeHold, 1 << SCREENFADE_FRACBITS));
		bf.WriteShort(flags);
		bf.WriteByte(color[0]);
		bf.WriteByte(color[1]);
		bf.WriteByte(color[2]);
		bf.WriteByte(color[3]);
		
		EndMessage();
	}
}

const float MAX_SHAKE_AMPLITUDE = 16.0;
void UTIL_ScreenShake(const float center[3], float amplitude, float frequency, float duration, float radius, ShakeCommand_t eCommand, bool bAirShake)
{
	float localAmplitude;
	
	if (amplitude > MAX_SHAKE_AMPLITUDE)
	{
		amplitude = MAX_SHAKE_AMPLITUDE;
	}
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || (!bAirShake && (eCommand == SHAKE_START) && !(GetEntityFlags(i) & FL_ONGROUND)))
		{
			continue;
		}
		
		CBaseCombatCharacter cb = CBaseCombatCharacter(i);
		float playerCenter[3];
		cb.WorldSpaceCenter(playerCenter);
		
		localAmplitude = ComputeShakeAmplitude(center, playerCenter, amplitude, radius);
		
		// This happens if the player is outside the radius, in which case we should ignore 
		// all commands
		if (localAmplitude < 0)
		{
			continue;
		}
		
		TransmitShakeEvent(i, localAmplitude, frequency, duration, eCommand);
	}
}

float ComputeShakeAmplitude(const float center[3], const float shake[3], float amplitude, float radius)
{
	if (radius <= 0)
	{
		return amplitude;
	}
	
	float localAmplitude = -1.0;
	float delta[3];
	SubtractVectors(center, shake, delta);
	float distance = GetVectorLength(delta);
	
	if (distance <= radius)
	{
		// Make the amplitude fall off over distance
		float perc = 1.0 - (distance / radius);
		localAmplitude = amplitude * perc;
	}
	
	return localAmplitude;
}

void TransmitShakeEvent(int player, float localAmplitude, float frequency, float duration, ShakeCommand_t eCommand)
{
	if ((localAmplitude > 0.0) || (eCommand == SHAKE_STOP))
	{
		if (eCommand == SHAKE_STOP)
		{
			localAmplitude = 0.0;
		}
		
		BfWrite msg = UserMessageToBfWrite(StartMessageOne("Shake", player, USERMSG_RELIABLE));
		if (msg != null)
		{
			msg.WriteByte(view_as<int>(eCommand));
			msg.WriteFloat(localAmplitude);
			msg.WriteFloat(frequency);
			msg.WriteFloat(duration);
			
			EndMessage();
		}
	}
}

void CalculateMeleeDamageForce(float buffer[3], float damage, const float vecMeleeDir[3], float scale)
{
	// Calculate an impulse large enough to push a 75kg man 4 in/sec per point of damage
	float forceScale = damage * 75 * 4;
	
	NormalizeVector(vecMeleeDir, buffer);
	ScaleVector(buffer, forceScale);
	ScaleVector(buffer, phys_pushscale.FloatValue);
	ScaleVector(buffer, scale);
}

stock void WorldSpaceCenter(int entity, float buffer[3])
{
	float origin[3], mins[3], maxs[3], offset[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);
	GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
	GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
	
	AddVectors(mins, maxs, offset);
	ScaleVector(offset, 0.5);
	
	AddVectors(origin, offset, buffer);
}

stock TFTeam GetEnemyTeam(TFTeam team)
{
	switch (team)
	{
		case TFTeam_Red: { return TFTeam_Blue; }
		case TFTeam_Blue: { return TFTeam_Red; }
		default: { return team; }
	}
}

stock void EmitGameSoundToTeam(TFTeam team, const char[] gameSound)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && TF2_GetClientTeam(client) == team)
		{
			EmitGameSoundToClient(client, gameSound);
		}
	}
}

stock any Min(any a, any b)
{
	return (a <= b) ? a : b;
}

stock any Max(any a, any b)
{
	return (a >= b) ? a : b;
}

stock any Clamp(any val, any min, any max)
{
	return Min(Max(val, min), max);
}

stock any RemapValClamped(any val, any a, any b, any c, any d)
{
	if (a == b)
		return val >= b ? d : c;
	float cVal = (val - a) / (b - a);
	cVal = Clamp(cVal, 0.0, 1.0);
	
	return c + (d - c) * cVal;
}
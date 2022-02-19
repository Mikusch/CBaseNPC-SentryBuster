
static NextBotActionFactory ActionFactory;
static ConVar tf_bot_suicide_bomb_range;

public bool SentryBusterPath_FilterIgnoreActors(int entity, int contentsMask, int desiredcollisiongroup)
{
	if ((entity > 0 && entity <= MaxClients) || !CBaseEntity(entity).IsCombatCharacter())
		return false;
	
	return true;
}

public bool SentryBusterPath_FilterOnlyActors(int entity, int contentsMask, int desiredcollisiongroup)
{
	return ((entity > 0 && entity <= MaxClients) || CBaseEntity(entity).IsCombatCharacter());
}

static void SentryBusterMain_OnStart(NextBotAction action, int actor, NextBotAction prevAction)
{
	action.SetData("m_PathFollower", PathFollower(_, SentryBusterPath_FilterIgnoreActors, SentryBusterPath_FilterOnlyActors));
	action.SetData("m_PathFailures", 0);
	action.SetDataFloat("m_PathLastTime", 0.0);
	
	int target = GetEntPropEnt(actor, Prop_Data, "m_hTarget");
	if (IsValidEntity(target))
	{
		float vecTargetPos[3];
		GetEntPropVector(target, Prop_Data, "m_vecAbsOrigin", vecTargetPos);
		SetEntPropVector(actor, Prop_Data, "m_lastKnownTargetPosition", vecTargetPos);
	}
}

static int SentryBusterMain_Update(NextBotAction action, int actor, float interval)
{
	float vecPos[3];
	GetEntPropVector(actor, Prop_Data, "m_vecAbsOrigin", vecPos);
	
	SentryBuster pCC = view_as<SentryBuster>(actor);
	INextBot bot = pCC.MyNextBotPointer();
	NextBotGroundLocomotion loco = view_as<NextBotGroundLocomotion>(bot.GetLocomotionInterface());
	
	bool onGround = view_as<bool>(GetEntityFlags(actor) & FL_ONGROUND);
	
	float vecTargetPos[3];
	GetEntPropVector(actor, Prop_Data, "m_lastKnownTargetPosition", vecTargetPos);
	
	int target = GetEntPropEnt(actor, Prop_Data, "m_hTarget");
	if (IsValidEntity(target))
	{
		// update chase destination
		if (GetEntProp(target, Prop_Data, "m_lifeState") == LIFE_ALIVE && !(GetEntProp(target, Prop_Data, "m_fEffects") & EF_NODRAW))
		{
			GetEntPropVector(target, Prop_Data, "m_vecAbsOrigin", vecTargetPos);
		}
		
		// if the engineer is carrying his sentry, he becomes the victim
		if (HasEntProp(target, Prop_Send, "m_iObjectType") && TF2_GetObjectType(target) == TFObject_Sentry && GetEntProp(target, Prop_Send, "m_bCarried"))
		{
			int owner = GetEntPropEnt(target, Prop_Send, "m_hBuilder");
			if (IsValidEntity(owner))
			{
				GetEntPropVector(owner, Prop_Data, "m_vecAbsOrigin", vecTargetPos);
			}
		}
		
		SetEntPropVector(actor, Prop_Data, "m_lastKnownTargetPosition", vecTargetPos);
	}
	
	float dist = GetVectorDistance(vecTargetPos, vecPos);
	
	loco.FaceTowards(vecTargetPos);
	
	if (dist > (tf_bot_suicide_bomb_range.FloatValue / 3) && pCC.GetProp(Prop_Data, "m_iHealth") > 1)
	{
		PathFollower path = action.GetData("m_PathFollower");
		if (path)
		{
			float gameTime = GetGameTime();
			if (gameTime > action.GetDataFloat("m_PathLastTime") + 0.2)
			{
				int pathingFailures = action.GetData("m_PathFailures") + 1;
				if (!path.ComputeToPos(bot, vecTargetPos))
				{
					if (pathingFailures == 3)
					{
						return action.ChangeTo(SentryBusterExplode_Create());
					}
				}
				else
				{
					pathingFailures = 0;
				}
				action.SetData("m_PathFailures", pathingFailures);
				action.SetDataFloat("m_PathLastTime", gameTime);
			}
			path.Update(bot);
			loco.Run();
		}
	}
	else if (onGround)
	{
		return action.ChangeTo(SentryBusterExplode_Create());
	}
	
	float speed = loco.GetGroundSpeed();
	
	int sequence = GetEntProp(actor, Prop_Send, "m_nSequence");
	
	if (speed < 0.01)
	{
		int idleSequence = GetEntProp(actor, Prop_Data, "m_idleSequence");
		if (sequence != idleSequence)
		{
			pCC.ResetSequence(idleSequence);
		}
	}
	else
	{
		int runSequence = GetEntProp(actor, Prop_Data, "m_runSequence");
		int airSequence = GetEntProp(actor, Prop_Data, "m_airSequence");
		
		if (!onGround)
		{
			if (sequence != airSequence)
			{
				pCC.ResetSequence(airSequence);
			}
		}
		else
		{
			if (runSequence != -1 && sequence != runSequence)
			{
				pCC.ResetSequence(runSequence);
			}
		}
		
		float vecForward[3], vecRight[3], vecUp[3];
		pCC.GetVectors(vecForward, vecRight, vecUp);
		
		float vecMotion[3]
		loco.GetGroundMotionVector(vecMotion);
		
		pCC.SetPoseParameter(pCC.GetProp(Prop_Data, "m_moveXPoseParameter"), GetVectorDotProduct(vecMotion, vecForward));
		pCC.SetPoseParameter(pCC.GetProp(Prop_Data, "m_moveYPoseParameter"), GetVectorDotProduct(vecMotion, vecRight));
	}
	
	if (g_TalkTimer.IsElapsed())
	{
		g_TalkTimer.Start(4.0);
		EmitGameSoundToAll("MVM.SentryBusterIntro", actor);
	}
	
	return action.Continue();
}

static void SentryBusterMain_OnEnd(NextBotAction action, int actor, NextBotAction nextAction)
{
	PathFollower path = action.GetData("m_PathFollower");
	if (path)
	{
		path.Destroy();
	}
}

void SentryBusterMain_InitBehavior()
{
	tf_bot_suicide_bomb_range = FindConVar("tf_bot_suicide_bomb_range");
	
	ActionFactory = new NextBotActionFactory("SentryBusterMain");
	ActionFactory.BeginDataMapDesc()
		.DefineIntField("m_PathFollower")
		.DefineIntField("m_PathFailures")
		.DefineFloatField("m_PathLastTime")
	.EndDataMapDesc();
	ActionFactory.SetCallback(NextBotActionCallbackType_OnStart, SentryBusterMain_OnStart);
	ActionFactory.SetCallback(NextBotActionCallbackType_Update, SentryBusterMain_Update);
	ActionFactory.SetCallback(NextBotActionCallbackType_OnEnd, SentryBusterMain_OnEnd);
}

NextBotActionFactory SentryBusterMain_GetFactory()
{
	return ActionFactory;
}

static NextBotActionFactory ActionFactory;

static int SentryBusterExplode_OnStart(NextBotAction action, int actor, NextBotAction prevAction)
{
	CBaseCombatCharacter cb = CBaseCombatCharacter(actor);
	int sequence = cb.LookupSequence("taunt04");

	if (sequence == -1)
	{
		return action.Done();
	}
	
	cb.ResetSequence(sequence);
	cb.SetPropFloat(Prop_Data, "m_flCycle", 0.0);
	cb.SetProp(Prop_Data, "m_takedamage", 0);
	EmitGameSoundToAll("MVM.SentryBusterSpin", actor);

	return action.Continue();
}

static int SentryBusterExplode_Update(NextBotAction action, int actor, float interval)
{
	float cycle = GetEntPropFloat(actor, Prop_Send, "m_flCycle");
	if (cycle == 1.0)
	{
		view_as<SentryBuster>(actor).Detonate();
		return action.Done();
	}

	return action.Continue();
}

void SentryBusterExplode_Init()
{
	ActionFactory = new NextBotActionFactory("SentryBusterExplode");
	ActionFactory.SetCallback(NextBotActionCallbackType_OnStart, SentryBusterExplode_OnStart);
	ActionFactory.SetCallback(NextBotActionCallbackType_Update, SentryBusterExplode_Update);
	//ActionFactory.SetCallback(NextBotActionCallbackType_OnEnd, SentryBusterExplode_OnEnd);
}

NextBotAction SentryBusterExplode_Create()
{
	return ActionFactory.Create();
}
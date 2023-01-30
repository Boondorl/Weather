class MoveTracer : LineTracer
{
	override ETraceStatus TraceCallback()
    {
		switch (results.hitType)
		{
			case TRACE_HitWall:
				if (results.tier == TIER_Middle
					&& (results.hitLine.flags & Line.ML_TWOSIDED)
					&& !(results.hitLine.flags & Line.ML_BLOCKEVERYTHING))
				{
					break;
				}
			case TRACE_HitFloor:
			case TRACE_HitCeiling:
				return TRACE_Stop;
				break;
			
			case TRACE_HitActor:
				if (results.hitActor.bSolid
					&& (results.hitActor != players[consolePlayer].camera
						|| (players[consolePlayer].camera == players[consolePlayer].mo
							&& (players[consolePlayer].cheats & CF_CHASECAM))))
				{
					return TRACE_Stop;
				}
				break;
		}
		
        return TRACE_Skip;
    }
}

class Precipitation : Actor
{
	const MIN_MAP_UNIT = 1 / 65536.0;

	static const double windTab[] = { 5/32.0, 10/32.0, 25/32.0 };
	
	private transient MoveTracer move;
	private bool bDetonated;
	
	Default
	{
		FloatBobPhase 0;
		Height 0;
		Radius 0;
		RenderRadius 1;
		
		+NOBLOCKMAP
		+SYNCHRONIZED
		+DONTBLAST
		+NOTONAUTOMAP
		+WINDTHRUST
	}
	
	override void Tick()
	{
		if (IsFrozen())
			return;

		if (!move)
			move = new("MoveTracer");
		
		if (bWindThrust)
		{
			int special = curSector.special;
			switch (special)
			{
				// Wind_East
				case 40: case 41: case 42: 
					Thrust(windTab[special-40], 0);
					break;
					
				// Wind_North
				case 43: case 44: case 45: 
					Thrust(windTab[special-43], 90);
					break;
					
				// Wind_South
				case 46: case 47: case 48: 
					Thrust(windTab[special-46], 270);
					break;
					
				// Wind_West
				case 49: case 50: case 51: 
					Thrust(windTab[special-49], 180);
					break;
			}
		}
		
		if (!(vel ~== (0,0,0)))
		{
			bool res = move.Trace(pos, curSector, vel, 1, TRACE_HitSky);
			if (move.results.crossedWater || move.results.crossed3DWater)
			{
				res = true;
				bNoGravity = true;
				move.results.hitPos = move.results.crossedWater ? move.results.crossedWaterPos : move.results.crossed3DWaterPos;
			}
			else if (move.results.hitType == TRACE_HasHitSky)
			{
				Destroy();
				return;
			}
			
			SetOrigin(move.results.hitPos - move.results.hitVector.Unit()*MIN_MAP_UNIT, true);
			vel = move.results.hitVector;
			
			CheckPortalTransition();

			if (res)
			{
				vel = (0,0,0);
				if (!bDetonated)
				{
					bDetonated = true;
					SetStateLabel("Death");
					return;
				}
			}
		}
		
		if (!bNoGravity && pos.z > floorZ)
			vel.z -= GetGravity();
		
		if (!CheckNoDelay() || tics < 0 || --tics > 0)
			return;
		
		while (SetState(curState.nextState) && !tics) {}
	}
}
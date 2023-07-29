class MoveTracer : LineTracer
{
	override ETraceStatus TraceCallback()
	{
		switch (results.hitType)
		{
			case TRACE_HitWall:
			case TRACE_HitFloor:
			case TRACE_HitCeiling:
				return TRACE_Stop;

			case TRACE_HitActor:
				if (results.hitActor.bSolid && !results.hitActor.bNonshootable)
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
	const MIN_MAP_UNIT = 1.0 / 65536.0;

	static const double windTab[] = { 5.0/32.0, 10.0/32.0, 25.0/32.0 };

	private transient MoveTracer move;
	private bool bDetonated;

	Default
	{
		FloatBobPhase 0u;
		Height 0.0;
		Radius 0.0;
		RenderRadius 1.0;

		+NOBLOCKMAP;
		+SYNCHRONIZED;
		+DONTBLAST;
		+NOTONAUTOMAP;
		+WINDTHRUST;
	}

	override void Tick()
	{
		if ((freezeTics > 0u && --freezeTics >= 0u) || IsFrozen())
		{
			return;
		}

		if (bWindThrust)
		{
			switch (curSector.special)
			{
				// Wind_East
				case 40: case 41: case 42: 
					Thrust(windTab[curSector.special-40], 0.0);
					break;

				// Wind_North
				case 43: case 44: case 45: 
					Thrust(windTab[curSector.special-43], 90.0);
					break;

				// Wind_South
				case 46: case 47: case 48: 
					Thrust(windTab[curSector.special-46], 270.0);
					break;

				// Wind_West
				case 49: case 50: case 51: 
					Thrust(windTab[curSector.special-49], 180.0);
					break;
			}
		}

		if (!(vel ~== (0.0, 0.0, 0.0)))
		{
			if (!move)
			{
				move = new("MoveTracer");
			}

			Actor ignore;
			if (players[consolePlayer].camera != players[consolePlayer].mo || !(players[consolePlayer].cheats & CF_CHASECAM))
			{
				ignore = players[consolePlayer].camera;
			}

			double dist = vel.Length();
			bool res = move.Trace(pos, curSector, vel/dist, dist, TRACE_HitSky, Line.ML_BLOCKEVERYTHING, ignore: ignore);
			if (move.results.crossedWater || move.results.crossed3DWater)
			{
				res = bNoGravity = true;
				move.results.hitPos = move.results.crossedWater ? move.results.crossedWaterPos : move.results.crossed3DWaterPos;
			}
			else if (move.results.hitType == TRACE_HasHitSky)
			{
				Destroy();
				return;
			}

			SetOrigin(move.results.hitPos - move.results.hitVector*MIN_MAP_UNIT, true);
			if (res)
			{
				vel = (0.0, 0.0, 0.0);
				if (!bDetonated)
				{
					bDetonated = true;
					SetStateLabel("Death");
					return;
				}
			}
			else
			{
				vel = move.results.hitVector*dist;
			}
		}

		if (!bNoGravity && pos.z > floorZ)
		{
			vel.z -= GetGravity();
		}

		if (CheckNoDelay() && tics >= 0 && --tics <= 0)
		{
			SetState(curState.nextState);
		}
	}
}

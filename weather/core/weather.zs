class PortalTracer : LineTracer
{
	override ETraceStatus TraceCallback()
    {
		if (results.hitType == TRACE_HitWall)
		{
			if (results.hitLine.special == 156 && results.hitLine.args[2] <= 1)
			{
				Line l = results.hitLine;
				Line d = l.GetPortalDestination();

				results.srcFromTarget.xy += (d.v1.p + d.delta*0.5) - (l.v1.p + l.delta*0.5);
				
				double angDiff = Actor.DeltaAngle(atan2(l.delta.y, l.delta.x), atan2(d.delta.y, d.delta.x));
				results.hitVector.xy = Actor.RotateVector(results.hitVector.xy, -angDiff);
			}
			else if (!(results.hitLine.flags & Line.ML_TWOSIDED))
			{
				return TRACE_Stop;
			}
		}
		
        return TRACE_Skip;
    }
}

class Weather : Actor
{
	const FADE_TRANSITION = 0.125;

	// CVars
	const AMOUNT = "weather_amount";
	const PRECIP_VOL = "weather_precip_vol";
	const WIND_VOL = "weather_wind_vol";
	const THUNDER_VOL = "weather_thunder_vol";
	
	private transient PortalTracer pt;
	
	private int rateTimer;
	private double pVolume;
	
	private double wVolume;
	
	private double lightning;
	private double prevLightning;
	private bool bInFlash;
	private Color prevLightningColor;
	private int lightningColorTimer;
	private int lightningTimer;
	
	private int thunderTimer;
	private double tVolume;
	
	private double fog;
	private double prevFog;
	private bool bFadingOut;
	private Color prevFogColor;
	private int fogColorTimer;
	
	PrecipitationType current;
	
	Default
	{
		FloatBobPhase 0;
		Radius 0;
		Height 0;
		Tag "Weather Spawner";
		
		+NOBLOCKMAP
		+NOSECTOR
		+SYNCHRONIZED
		+DONTBLAST
		+NOTONAUTOMAP
	}

	override void BeginPlay()
	{
		super.BeginPlay();

		ChangeStatNum(MAX_STATNUM);
	}
	
	clearscope Color BlendColors(Color c1, Color c2, double t) const
	{
		int c1r, c1g, c1b;
		c1r = (c1 & 0xFF0000) >> 16;
		c1g = (c1 & 0xFF00) >> 8;
		c1b = c1 & 0xFF;
		
		int c2r, c2g, c2b;
		c2r = (c2 & 0xFF0000) >> 16;
		c2g = (c2 & 0xFF00) >> 8;
		c2b = c2 & 0xFF;
		
		int rr, rg, rb;
		rr = int(c1r*(1-t) + c2r*t) << 16;
		rg = int(c1g*(1-t) + c2g*t) << 8;
		rb = int(c1b*(1-t) + c2b*t);
		
		return Color(0xFF000000 | rr | rg | rb);
	}
	
	clearscope double, Color GetFog(double t = 1) const
	{
		Color fc = 0;
		if (fog > 0 && (!current || !current.GetBool('Foggy')))
		{
			fc = prevFogColor;
		}
		else if (current && fogColorTimer >= 0)
		{
			double r = min(1, (fogColorTimer + 1-t) / ceil(gameTicRate * FADE_TRANSITION));
			fc = BlendColors(prevFogColor, current.GetColor('Fog'), 1-r);
		}
		else if (current)
		{
			fc = current.GetColor('Fog');
		}
		
		return clamp(prevFog, 0, 1)*(1-t) + clamp(fog, 0, 1)*t, fc;
	}
	
	clearscope double, Color GetLightning(double t = 1) const
	{
		Color lc = 0;
		if (lightning > 0 && (!current || !current.GetBool('Stormy')))
		{
			lc = prevLightningColor;
		}
		else if (current && lightningColorTimer >= 0)
		{
			double r = min(1, (lightningColorTimer + 1-t) / ceil(gameTicRate * FADE_TRANSITION));
			lc = BlendColors(prevLightningColor, current.GetColor('Lightning'), 1-r);
		}
		else if (current)
		{
			lc = current.GetColor('Lightning');
		}
		
		return clamp(prevLightning, 0, 1)*(1-t) + clamp(lightning, 0, 1)*t, lc;
	}
	
	clearscope int InLightningFlash() const
	{
		return bInFlash || lightning > 0;
	}
	
	void Reset(PrecipitationType t = null)
	{
		bool wasFoggy, wasStormy;
		if (current)
		{
			if (current.GetBool('Foggy'))
			{
				wasFoggy = true;
				prevFogColor = current.GetColor('Fog');
			}
			
			if (current.GetBool('Stormy'))
			{
				wasStormy = true;
				prevLightningColor = current.GetColor('Lightning');
			}
		}
		
		current = t;
		if (current)
		{
			if (current.GetBool('Stormy'))
			{
				if (thunderTimer <= 0)
					thunderTimer = Random[Weather](current.GetTime('MinThunder'), current.GetTime('MaxThunder'));
				if (lightningTimer <= 0)
					lightningTimer = Random[Weather](current.GetTime('MinLightning'), current.GetTime('MaxLightning'));
				
				lightningColorTimer = wasStormy ? ceil(gameTicRate * FADE_TRANSITION) : -1;
			}
			else
			{
				thunderTimer = lightningTimer = 0;
				lightningColorTimer = -1;
			}
			
			if (!current.GetType('Precipitation'))
				rateTimer = 0;
			
			fogColorTimer = (wasFoggy && current.GetBool('Foggy')) ? ceil(gameTicRate * FADE_TRANSITION) : -1;
		}
		else
		{
			rateTimer = thunderTimer = lightningTimer = 0;
			fogColorTimer = lightningColorTimer = -1;
		}
	}
	
	private clearscope Vector2 GetCeilingPortalOffset(Sector sec, double z) const
	{
		Vector2 ofs;
		double portZ = sec.GetPortalPlaneZ(Sector.ceiling);
		while (z > portZ && !sec.PortalBlocksMovement(Sector.ceiling))
		{
			ofs += sec.GetPortalDisplacement(Sector.ceiling);
			sec = level.sectorPortals[sec.portals[Sector.ceiling]].mDestination;
			if (!sec)
				break;
			
			portZ = sec.GetPortalPlaneZ(Sector.ceiling);
		}
		
		return ofs;
	}
	
	private clearscope Vector2, Vector2 VisPortalOffset(Line origin, Line dest, Vector2 dir) const
	{
		Vector2 ofs;
		if (!origin || !dest)
			return ofs, dir;
		
		ofs = (dest.v1.p + dest.delta/2) - (origin.v1.p + origin.delta/2);
		
		double angDiff = DeltaAngle(VectorAngle(origin.delta.x,origin.delta.y), VectorAngle(-dest.delta.x,-dest.delta.y));
		dir = RotateVector(dir, angDiff);
		
		return ofs, dir;
	}
	
	private clearscope bool, double CheckSky(Sector sec, Vector2 spot, double z) const
	{
		let [ceilZ, ceilSec] = sec.HighestCeilingAt(spot);
		bool sky = (ceilSec.GetTexture(Sector.ceiling) == skyFlatNum
					&& sec.NextHighestCeilingAt(spot.x, spot.y, z, z+1) ~== ceilZ);
		
		return sky, ceilZ;
	}
	
	private clearscope bool InLiquid(Sector sec, Vector3 spot) const
	{
		if (sec.moreFlags & Sector.SECMF_UNDERWATER)
			return true;
		else
		{
			Sector hSec = sec.GetHeightSec();
			if (hSec)
			{
				if ((hSec.moreFlags & Sector.SECMF_UNDERWATERMASK)
					&& (spot.z < hSec.floorPlane.ZAtPoint(spot.xy)
						|| (!(hSec.moreFlags & Sector.SECMF_FAKEFLOORONLY) && spot.z > hSec.ceilingPlane.ZAtPoint(spot.xy))))
				{
					return true;
				}
			}
			else
			{
				for (int i = 0; i < sec.Get3DFloorCount(); ++i)
				{
					let ffloor = sec.Get3DFloor(i);
					if (!(ffloor.flags & F3DFloor.FF_EXISTS)
						|| (ffloor.flags & F3DFloor.FF_SOLID)
						|| !(ffloor.flags & F3DFloor.FF_SWIMMABLE))
					{
						continue;
					}
					
					if (ffloor.top.ZAtPoint(spot.xy) > spot.z && ffloor.bottom.ZAtPoint(spot.xy) <= spot.z)
						return true;
				}
			}
		}
		
		return false;
	}
	
	private clearscope bool In3DFloor(Sector sec, Vector3 spot) const
	{
		for (int i = 0; i < sec.Get3DFloorCount(); ++i)
		{
			let ffloor = sec.Get3DFloor(i);
			if (!(ffloor.flags & F3DFloor.FF_EXISTS) || !(ffloor.flags & F3DFloor.FF_SOLID))
				continue;
			
			if (ffloor.top.ZAtPoint(spot.xy) > spot.z && ffloor.bottom.ZAtPoint(spot.xy) <= spot.z)
				return true;
		}
		
		return false;
	}
	
	void SpawnPrecipitation(Actor origin, class<Precipitation> precip, Vector2 dir, double dist, double z, bool outdoors = true, bool indoors = false)
	{
		if (!origin || !precip)
			return;
		
		if (dist < 0)
			dist = 0;
		
		bool skyCheck;
		double ceilZ;
		Sector sec;
		
		Vector2 xyOfs = dir * dist;
		Vector2 spawnSpot = origin.pos.xy + xyOfs;
		Vector2 portalSpot = origin.Vec2Offset(xyOfs.x, xyOfs.y);
		
		// Did we enter a portal? If so, spawn some precipitation in it
		if (!(portalSpot ~== spawnSpot))
		{
			sec = level.PointInSector(portalSpot);
			[skyCheck, ceilZ] = CheckSky(sec, portalSpot, z);
			if ((outdoors && skyCheck) || (indoors && !skyCheck))
			{	
				Vector3 spawnPos = (portalSpot+GetCeilingPortalOffset(sec, z), min(z, ceilZ));
				sec = level.PointInSector(spawnPos.xy);
				if (level.IsPointInLevel(spawnPos) && !InLiquid(sec, spawnPos) && !In3DFloor(sec, spawnPos))
				{
					Spawn(precip, spawnPos, ALLOW_REPLACE);
					
					// Shift the position a little
					dist *= FRandom[Weather](0.8, 1.2);
					dir = RotateVector(dir, FRandom[Weather](-10, 10));
					xyOfs = dir * dist;
				}
			}
		}
		
		if (!pt)
			pt = new("PortalTracer");
		
		// If we hit a visual only portal, get the offsets to the location it's looking at
		Vector2 visOfs;
		/*pt.portal = null;
		pt.Trace((origin.pos.xy,-32768), origin.CurSector, (dir,0), dist, 0);
		if (pt.portal)
			[visOfs, xyOfs] = VisPortalOffset(pt.portal, pt.portal.GetPortalDestination(), xyOfs);*/
		
		// Now that we've accounted for portals, spawn it regularly
		spawnSpot = origin.pos.xy + xyOfs + visOfs;
		sec = level.PointInSector(spawnSpot);
		
		// Is there sky at the very top?
		[skyCheck, ceilZ] = CheckSky(sec, spawnSpot, z);
		if ((!outdoors && skyCheck) || (!indoors && !skyCheck))
		{
			if (origin.curSector.PortalBlocksMovement(Sector.ceiling))
				return;
			
			// If not, maybe the portal above the player leads to a valid area?
			spawnSpot += GetCeilingPortalOffset(origin.curSector, z);
			sec = level.PointInSector(spawnSpot);
			[skyCheck, ceilZ] = CheckSky(sec, spawnSpot, z);
			if ((!outdoors && skyCheck) || (!indoors && !skyCheck))
				return;
		}
		
		Vector3 spawnPos = (spawnSpot+GetCeilingPortalOffset(sec, z), min(z, ceilZ));
		sec = level.PointInSector(spawnPos.xy);
		if (!level.IsPointInLevel(spawnPos) || InLiquid(sec, spawnPos) || In3DFloor(sec, spawnPos))
			return;
				
		Spawn(precip, spawnPos, ALLOW_REPLACE);
	}
	
	clearscope bool InFade(Name type, bool sky) const
	{
		if (!current)
			return false;

		bool onlyIndoors = current.GetBool(String.Format("%sOnlyIndoors", type));
		return (sky && onlyIndoors) || (!sky && !onlyIndoors && !current.GetBool(String.Format("%sIndoors", type)));
	}
	
	override void Tick()
	{
		master = players[consolePlayer].camera;
		if (!master)
			return;
		
		bool sky = master.ceilingPic == skyFlatNum;
		
		// Fog
		prevFog = fog;
		if (fogColorTimer >= 0)
			--fogColorTimer;
		
		if (current && current.GetBool('Foggy'))
		{
			bFadingOut = InFade('Fog', sky);
			
			double a = current.GetAlpha('Fog');
			if (fog > a)
			{
				fog = max(fog-0.01, a);
			}
			else if (bFadingOut)
			{
				int fade = current.GetTime('FogFadeOut');
				if (fade <= 0)
					fog = 0;
				else if (fog > 0)
					fog = max(fog - a/fade, 0);
			}
			else if (fog < a)
			{
				int fade = current.GetTime('FogFadeIn');
				if (fade <= 0)
					fog = a;
				else
					fog = min(fog + a/fade, a);
			}
		}
		else if (fog > 0)
		{
			fog = max(fog-0.01, 0);
		}
		
		// Cache sounds
		sound precip, wind, thunder;
		if (current)
		{
			precip = current.GetSound('Precipitation');
			wind = current.GetSound('Wind');
			thunder = current.GetSound('Thunder');
		}
		
		// Storm
		prevLightning = lightning;
		if (lightningColorTimer >= 0)
			--lightningColorTimer;
		
		bool stormy = current && current.GetBool('Stormy');
		if (stormy)
		{
			--thunderTimer;
			if (thunderTimer <= 0)
			{
				thunderTimer = Random[Weather](current.GetTime('MinThunder'), current.GetTime('MaxThunder'));
				A_StartSound(thunder, CHAN_7, CHANF_OVERLAP, 1, ATTN_NONE);
			}
			
			if (!InFade('Lightning', sky) && !IsFrozen())
			{
				--lightningTimer;
				if (lightningTimer <= 0)
				{
					lightningTimer = Random[Weather](current.GetTime('MinLightning'), current.GetTime('MaxLightning'));
					bInFlash = true;
				}
			}
		}
		
		bInFlash = stormy && bInFlash;
		if (bInFlash)
		{
			int fade = current.GetTime('LightningFadeIn');
			double a = current.GetAlpha('Lightning');
			if (fade <= 0)
				lightning = a;
			else if (lightning < a)
				lightning += a / fade;
			
			if (lightning >= a)
			{
				lightning = a;
				bInFlash = false;
			}
		}
		else if (lightning > 0)
		{
			int fade = stormy ? current.GetTime('LightningFadeOut') : 3;
			double a = stormy ? current.GetAlpha('Lightning') : 0.1;
			if (fade <= 0)
				lightning = 0;
			else
				lightning = max(lightning - a/fade, 0);
		}
		
		// Audio
		A_StartSound(precip, CHAN_5, CHANF_LOOPING, 1, ATTN_NONE);
		A_StartSound(wind, CHAN_6, CHANF_LOOPING, 1, ATTN_NONE);
		
		if (current && precip)
		{
			pVolume = CalculateVolume(pVolume, current.GetVolume('MinPrecipitation'), current.GetVolume('MaxPrecipitation'), InFade('Precipitation', sky), current.GetTime('PrecipitationVolumeFadeIn'), current.GetTime('PrecipitationVolumeFadeOut'));
		}
		else
		{
			pVolume = CalculateVolume(pVolume, 0, 1, true, gameTicRate, gameTicRate);
			if (pVolume <= 0)
				A_StopSound(CHAN_5);
		}
		
		if (current && wind)
		{
			wVolume = CalculateVolume(wVolume, current.GetVolume('MinWind'), current.GetVolume('MaxWind'), InFade('Wind', sky), current.GetTime('WindVolumeFadeIn'), current.GetTime('WindVolumeFadeOut'));
		}
		else
		{
			wVolume = CalculateVolume(wVolume, 0, 1, true, gameTicRate, gameTicRate);
			if (wVolume <= 0)
				A_StopSound(CHAN_6);
		}
		
		if (current && thunder)
		{
			tVolume = CalculateVolume(tVolume, current.GetVolume('MinThunder'), current.GetTime('MaxThunder'), InFade('Thunder', sky), current.GetTime('ThunderVolumeFadeIn'), current.GetTime('ThunderVolumeFadeOut'));
		}
		else
		{
			tVolume = CalculateVolume(tVolume, 0, 1, true, gameTicRate, gameTicRate);
			if (tVolume <= 0)
				A_StopSound(CHAN_7);
		}
		
		A_SoundVolume(CHAN_5, pVolume * clamp(CVar.GetCVar(PRECIP_VOL, players[consolePlayer]).GetFloat(), 0, 1));
		A_SoundVolume(CHAN_6, wVolume * clamp(CVar.GetCVar(WIND_VOL, players[consolePlayer]).GetFloat(), 0, 1));
		A_SoundVolume(CHAN_7, tVolume * clamp(CVar.GetCVar(THUNDER_VOL, players[consolePlayer]).GetFloat(), 0, 1));
		
		if (!current)
			return;
		
		// Precipitation
		double multi = min(4, CVar.GetCVar(AMOUNT, players[consolePlayer]).GetFloat());
		if (multi <= 0 || IsFrozen())
			return;
		
		let type = current.GetType('Precipitation');
		if (type && ++rateTimer >= current.GetTime('PrecipitationRate'))
		{
			rateTimer = 0;
			
			double z = master.pos.z + current.GetFloat('PrecipitationHeight');
			double xy = current.GetFloat('PrecipitationRadius');
			double minXY = master == players[consolePlayer].mo && (players[consolePlayer].cheats & CF_CHASECAM) ? 0 : 16;
			bool only = current.GetBool('PrecipitationOnlyIndoors');
			bool inside = only || current.GetBool('PrecipitationIndoors');
			int amt = ceil(current.GetInt('PrecipitationAmount') * multi);
			for (int i = 0; i < amt; ++i)
			{
				Vector2 dir = FRandom[Weather](0, 360).ToVector();
				double dist = FRandom[Weather](minXY, xy);
				
				SpawnPrecipitation(master, type, dir, dist, z, !only, inside);
			}
		}
	}
	
	clearscope double CalculateVolume(double v, double mi, double ma, bool fadeOut, int fis, int fos) const
	{
		v = clamp(v, 0, 1);
		
		if (fadeOut)
		{
			if (v > mi)
			{
				if (fos <= 0)
				{
					v = mi;
				}
				else
				{
					double diff = ma - mi;
					if (diff <= 0)
						diff = 1;

					v = max(v - diff/fos, mi);
				}
			}
			else if (v < mi)
			{
				v = min(v + 1.0/gameTicRate, mi);
			}
		}
		else 
		{
			if (v < ma)
			{
				if (fis <= 0)
				{
					v = ma;
				}
				else
				{
					double diff = ma - mi;
					if (diff <= 0)
						diff = 1;
					
					v = min(v + diff/fis, ma);
				}
			}
			else if (v > ma)
			{
				v = max(v - 1.0/gameTicRate, ma);
			}
		}
		
		return v;
	}
	
	// General helpers and ACS ScriptCall functionality
	
	static clearscope Weather Get()
	{
		let it = ThinkerIterator.Create("Weather", MAX_STATNUM);
		return Weather(it.Next());
	}
	
	static clearscope PrecipitationType GetPrecipitationType(Name n)
	{
		let wh = WeatherHandler(StaticEventHandler.Find("WeatherHandler"));
		return wh ? wh.FindType(n) : null;
	}
	
	static void SetPrecipitationType(Name n)
	{
		let wthr = Weather.Get();
		if (wthr)
			wthr.Reset(Weather.GetPrecipitationType(n));
	}
	
	static clearscope Name GetPrecipitationTypeName()
	{
		Name n;
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			n = wthr.current.GetName();
		
		return n;
	}
	
	static string GetPrecipitationTypeTag()
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return WeatherHandler.DEFAULT_STRING;
		
		string t = wthr.current.GetLocalizedString('PrecipitationTag');
		if (!t.Length())
			t = wthr.current.GetName();
		
		return t;
	}
	
	static void SetPrecipitationTypeTag(string t)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetString('PrecipitationTag', t);
	}
	
	static void SetPrecipitationTypeDefaults()
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetDefaults();
	}
	
	static void ResetPrecipitationType()
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.Reset();
	}
	
	static void SetPrecipitationClass(string cls)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetString('PrecipitationType', cls);
	}
	
	static void SetPrecipitationProperties(double rate = -1, int amt = -1, double rad = -1, double h = -1, int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (rate >= 0)
			wthr.current.SetFloat('PrecipitationRateTime', rate);
		if (amt >= 0)
			wthr.current.SetInt('PrecipitationAmount', amt);
		if (rad >= 0)
			wthr.current.SetFloat('PrecipitationRadius', rad);
		if (h >= 0)
			wthr.current.SetFloat('PrecipitationHeight', h);
		if (indoors >= 0)
			wthr.current.SetBool('PrecipitationIndoors', !!indoors);
		if (indoorsOnly >= 0)
			wthr.current.SetBool('PrecipitationOnlyIndoors', !!indoorsOnly);
	}
	
	static void SetPrecipitationSound(sound s)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetString('PrecipitationSound', s);
	}
	
	static void SetPrecipitationVolume(double mi = -1, double ma = -1, double fadeIn = -1, double fadeOut = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (mi >= 0)
			wthr.current.SetFloat('MinPrecipitationVolume', mi);
		if (ma >= 0)
			wthr.current.SetFloat('MaxPrecipitationVolume', ma);
		if (fadeIn >= 0)
			wthr.current.SetFloat('PrecipitationVolumeFadeInTime', fadeIn);
		if (fadeOut >= 0)
			wthr.current.SetFloat('PrecipitationVolumeFadeOutTime', fadeOut);
	}
	
	static void SetWindProperties(int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (indoors >= 0)
			wthr.current.SetBool('WindIndoors', !!indoors);
		if (indoorsOnly >= 0)
			wthr.current.SetBool('WindOnlyIndoors', !!indoorsOnly);
	}
	
	static void SetWindSound(sound s)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetString('WindSound', s);
	}
	
	static void SetWindVolume(double mi = -1, double ma = -1, double fadeIn = -1, double fadeOut = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (mi >= 0)
			wthr.current.SetFloat('MinWindVolume', mi);
		if (ma >= 0)
			wthr.current.SetFloat('MaxWindVolume', ma);
		if (fadeIn >= 0)
			wthr.current.SetFloat('WindVolumeFadeInTime', fadeIn);
		if (fadeOut >= 0)
			wthr.current.SetFloat('WindVolumeFadeOutTime', fadeOut);
	}
	
	static void ToggleStorm(bool enabled)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetBool('Stormy', enabled);
	}
	
	static void SetThunderInterval(double mi = -1, double ma = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (mi >= 0)
			wthr.current.SetFloat('MinThunderTime', mi);
		if (ma >= 0)
			wthr.current.SetFloat('MaxThunderTime', ma);
	}
	
	static void SetThunderProperties(int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (indoors >= 0)
			wthr.current.SetBool('ThunderIndoors', !!indoors);
		if (indoorsOnly >= 0)
			wthr.current.SetBool('ThunderOnlyIndoors', !!indoorsOnly);
	}
	
	static void SetThunderSound(sound s)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetString('ThunderSound', s);
	}
	
	static void SetThunderVolume(double mi = -1, double ma = -1, double fadeIn = -1, double fadeOut = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (mi >= 0)
			wthr.current.SetFloat('MinThunderVolume', mi);
		if (ma >= 0)
			wthr.current.SetFloat('MaxThunderVolume', ma);
		if (fadeIn >= 0)
			wthr.current.SetFloat('ThunderVolumeFadeInTime', fadeIn);
		if (fadeOut >= 0)
			wthr.current.SetFloat('ThunderVolumeFadeOutTime', fadeOut);
	}
	
	static void SetLightningInterval(double mi = -1, double ma = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (mi >= 0)
			wthr.current.SetFloat('MinLightningTime', mi);
		if (ma >= 0)
			wthr.current.SetFloat('MaxLightningTime', ma);
	}
	
	static void SetLightningProperties(double a = -1, int col = -1, double fadeIn = -1, double fadeOut = -1, int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (a >= 0)
			wthr.current.SetFloat('LightningAlpha', a);
		if (col >= 0)
			wthr.current.SetInt('LightningColor', col);
		if (fadeIn >= 0)
			wthr.current.SetFloat('LightningFadeInTime', fadeIn);
		if (fadeOut >= 0)
			wthr.current.SetFloat('LightningFadeOutTime', fadeOut);
		if (indoors >= 0)
			wthr.current.SetBool('LightningIndoors', !!indoors);
		if (indoorsOnly >= 0)
			wthr.current.SetBool('LightningOnlyIndoors', !!indoorsOnly);
	}
	
	static void ToggleFog(bool enabled)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			wthr.current.SetBool('Foggy', enabled);
	}
	
	static void SetFogProperties(double a = -1, int col = -1, double fadeIn = -1, double fadeOut = -1, int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
			return;
		
		if (a >= 0)
			wthr.current.SetFloat('FogAlpha', a);
		if (col >= 0)
			wthr.current.SetInt('FogColor', col);
		if (fadeIn >= 0)
			wthr.current.SetFloat('FogFadeInTime', fadeIn);
		if (fadeOut >= 0)
			wthr.current.SetFloat('FogFadeOutTime', fadeOut);
		if (indoors >= 0)
			wthr.current.SetBool('FogIndoors', !!indoors);
		if (indoorsOnly >= 0)
			wthr.current.SetBool('FogOnlyIndoors', !!indoorsOnly);
	}
	
	static string GetStringProperty(Name k, bool localized = false)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return localized ? wthr.current.GetLocalizedString(k) : wthr.current.GetString(k);
		
		return WeatherHandler.DEFAULT_STRING;
	}
	
	static bool GetBoolProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetBool(k);
		
		return false;
	}
	
	static int GetIntProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetInt(k);
		
		return 0;
	}
	
	static double GetFloatProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetFloat(k);
		
		return 0;
	}
	
	static string GetDefaultStringProperty(Name k, bool localized = false)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return localized ? wthr.current.GetDefaultLocalizedString(k) : wthr.current.GetDefaultString(k);
		
		return WeatherHandler.DEFAULT_STRING;
	}
	
	static bool GetDefaultBoolProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetDefaultBool(k);
		
		return false;
	}
	
	static int GetDefaultIntProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetDefaultInt(k);
		
		return 0;
	}
	
	static double GetDefaultFloatProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetDefaultFloat(k);
		
		return 0;
	}
}
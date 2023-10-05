class PortalTracer : LineTracer
{
	Line portal;

	// Only check portals that won't offset correctly
	private bool IsPortal(Line l) const
	{
		int type = l.GetPortalType();
		return l.IsVisualPortal()
				&& (type == LinePortal.PORTT_VISUAL || type == LinePortal.PORTT_TELEPORT);
	}

	override ETraceStatus TraceCallback()
	{
		if (results.hitType == TRACE_HitWall)
		{
			if (IsPortal(results.hitLine))
			{
				portal = results.hitLine;
				return TRACE_Stop;
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
	const INVALID_3D_FLOOR = F3DFloor.FF_SOLID | F3DFloor.FF_SWIMMABLE;
	const MIN_DIST = 16.0;

	const FADE_TRANSITION_TIME = 0.125;
	const DEFAULT_FADE = 0.35;
	const DEFAULT_ALPHA = 0.1;
	const FADE_OUT_TIME = 0.075;

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
		FloatBobPhase 0u;
		Radius 0.0;
		Height 0.0;
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

		ChangeStatNum(MAX_STATNUM); // Make sure it always uses the final position for the camera
	}

	static clearscope Color BlendColors(Color c1, Color c2, double t)
	{
		return Color(int(c1.r*(1.0-t) + c2.r*t),
					int(c1.g*(1.0-t) + c2.g*t),
					int(c1.b*(1.0-t) + c2.b*t));
	}

	clearscope double, Color GetFog(double t = 1.0) const
	{
		Color fc;
		if (fog > 0.0 && (!current || !current.GetBool('Foggy')))
		{
			fc = prevFogColor;
		}
		else if (current)
		{
			if (fogColorTimer >= 0)
			{
				double r = min(1.0, (fogColorTimer + 1.0-t) / ceil(FADE_TRANSITION_TIME * gameTicRate));
				fc = BlendColors(prevFogColor, current.GetColor('Fog'), 1.0-r);
			}
			else
			{
				fc = current.GetColor('Fog');
			}
		}

		return clamp(prevFog, 0.0, 1.0)*(1.0-t) + clamp(fog, 0.0, 1.0)*t, fc;
	}

	clearscope double, Color GetLightning(double t = 1.0) const
	{
		Color lc;
		if (lightning > 0.0 && (!current || !current.GetBool('Stormy')))
		{
			lc = prevLightningColor;
		}
		else if (current)
		{
			if (lightningColorTimer >= 0)
			{
				double r = min(1.0, (lightningColorTimer + 1.0-t) / ceil(FADE_TRANSITION_TIME * gameTicRate));
				lc = BlendColors(prevLightningColor, current.GetColor('Lightning'), 1.0-r);
			}
			else
			{
				lc = current.GetColor('Lightning');
			}
		}

		return clamp(prevLightning, 0.0, 1.0)*(1.0-t) + clamp(lightning, 0.0, 1.0)*t, lc;
	}

	clearscope bool InLightningFlash() const
	{
		return bInFlash || lightning > 0.0;
	}

	clearscope bool InFade(Name type, bool sky) const
	{
		if (!current)
		{
			return false;
		}

		bool onlyIndoors = current.GetBool(type.."OnlyIndoors");
		return (sky && onlyIndoors) || (!sky && !onlyIndoors && !current.GetBool(type.."Indoors"));
	}

	clearscope double CalculateVolume(double v, double mi, double ma, bool fadeOut, int fis, int fos) const
	{
		v = clamp(v, 0.0, 1.0);

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
					if (diff <= 0.0)
					{
						diff = 1.0;
					}

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
					if (diff <= 0.0)
					{
						diff = 1.0;
					}

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

	// Spawning logic

	private clearscope Vector2 GetCeilingPortalOffset(Sector sec, double z) const
	{
		Vector2 ofs;
		double portZ = sec.GetPortalPlaneZ(Sector.ceiling);
		while (z >= portZ && !sec.PortalBlocksMovement(Sector.ceiling))
		{
			ofs += sec.GetPortalDisplacement(Sector.ceiling);

			sec = level.sectorPortals[sec.portals[Sector.ceiling]].mDestination;
			portZ = sec.GetPortalPlaneZ(Sector.ceiling);
		}

		return ofs;
	}

	private clearscope Vector2, Vector2 VisPortalOffset(Line origin, Line dest, Vector2 dir) const
	{
		Vector2 ofs = (dest.v1.p + dest.delta*0.5) - (origin.v1.p + origin.delta*0.5);
		dir = RotateVector(dir, origin.GetPortalAngleDiff());

		return ofs, dir;
	}

	private clearscope bool, double CheckSky(Sector sec, Vector2 spot, double z) const
	{
		let [ceilZ, ceilSec] = sec.HighestCeilingAt(spot);
		bool sky = (ceilSec.GetTexture(Sector.ceiling) == skyFlatNum
					&& sec.NextHighestCeilingAt(spot.x, spot.y, z, z+1.0) ~== ceilZ);

		return sky, ceilZ;
	}

	private clearscope bool ValidSpawn(Sector sec, Vector3 spot) const
	{
		if (sec.moreFlags & Sector.SECMF_UNDERWATER)
		{
			return false;
		}

		Sector hSec = sec.GetHeightSec();
		if (hSec && (hSec.moreFlags & Sector.SECMF_UNDERWATERMASK)
			&& (spot.z < hSec.floorPlane.ZAtPoint(spot.xy)
				|| (!(hSec.moreFlags & Sector.SECMF_FAKEFLOORONLY) && spot.z > hSec.ceilingPlane.ZAtPoint(spot.xy))))
		{
			return false;
		}

		for (int i = 0; i < sec.Get3DFloorCount(); ++i)
		{
			let ffloor = sec.Get3DFloor(i);
			if ((ffloor.flags & F3DFloor.FF_EXISTS)
				&& (ffloor.flags & INVALID_3D_FLOOR)
				&& ffloor.top.ZAtPoint(spot.xy) > spot.z
				&& ffloor.bottom.ZAtPoint(spot.xy) <= spot.z)
			{
				return false;
			}
		}

		return level.IsPointInLevel(spot);
	}

	void SpawnPrecipitation(Actor origin, class<Precipitation> precip, Vector2 dir, double dist, double z, bool outdoors = true, bool indoors = false)
	{
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
				if (ValidSpawn(sec, spawnPos))
				{
					Spawn(precip, spawnPos, ALLOW_REPLACE);

					// Shift the position a little
					dist *= FRandom[Weather](0.8, 1.2);
					dir = RotateVector(dir, FRandom[Weather](-10.0, 10.0));
					xyOfs = dir * dist;
				}
			}
		}

		// If we hit a visual only portal, get the offsets to the location it's looking at
		if (!pt)
		{
			pt = new("PortalTracer");
		}

		Vector2 visOfs;
		pt.portal = null;
		pt.Trace((origin.pos.xy,-32768.0), origin.curSector, (dir,0.0), dist, 0, ignoreAllActors: true);
		if (pt.portal)
		{
			[visOfs, xyOfs] = VisPortalOffset(pt.portal, pt.portal.GetPortalDestination(), xyOfs);
		}

		// Now that we've accounted for portals, spawn it regularly
		spawnSpot = origin.pos.xy + xyOfs + visOfs;
		sec = level.PointInSector(spawnSpot);

		// Is there sky at the very top?
		[skyCheck, ceilZ] = CheckSky(sec, spawnSpot, z);
		if ((!outdoors && skyCheck) || (!indoors && !skyCheck))
		{
			if (origin.curSector.PortalBlocksMovement(Sector.ceiling))
			{
				return;
			}

			// If not, maybe the portal above the player leads to a valid area?
			spawnSpot += GetCeilingPortalOffset(origin.curSector, z);
			sec = level.PointInSector(spawnSpot);
			[skyCheck, ceilZ] = CheckSky(sec, spawnSpot, z);
			if ((!outdoors && skyCheck) || (!indoors && !skyCheck))
			{
				return;
			}
		}

		Vector3 spawnPos = (spawnSpot+GetCeilingPortalOffset(sec, z), min(z, ceilZ));
		sec = level.PointInSector(spawnPos.xy);
		if (ValidSpawn(sec, spawnPos))
		{
			Spawn(precip, spawnPos, ALLOW_REPLACE);
		}
	}

	// General handling

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
				{
					thunderTimer = Random[Weather](current.GetTime('MinThunder'), current.GetTime('MaxThunder'));
				}
				if (lightningTimer <= 0)
				{
					lightningTimer = Random[Weather](current.GetTime('MinLightning'), current.GetTime('MaxLightning'));
				}

				lightningColorTimer = wasStormy ? int(ceil(FADE_TRANSITION_TIME * gameTicRate)) : -1;
			}
			else
			{
				thunderTimer = lightningTimer = 0;
				lightningColorTimer = -1;
			}

			if (!current.GetType('Precipitation'))
			{
				rateTimer = 0;
			}

			fogColorTimer = (wasFoggy && current.GetBool('Foggy')) ? int(ceil(FADE_TRANSITION_TIME * gameTicRate)) : -1;
		}
		else
		{
			rateTimer = thunderTimer = lightningTimer = 0;
			fogColorTimer = lightningColorTimer = -1;
		}
	}

	override void Tick()
	{
		master = players[consolePlayer].camera;
		if (!master)
		{
			return;
		}

		bool sky = master.ceilingPic == skyFlatNum;
		bool frozen = (freezeTics > 0u && --freezeTics >= 0u) || IsFrozen();

		// Fog
		prevFog = fog;
		if (fogColorTimer >= 0)
		{
			--fogColorTimer;
		}

		if (current && current.GetBool('Foggy'))
		{
			bFadingOut = InFade('Fog', sky);

			double a = current.GetAlpha('Fog');
			if (fog > a)
			{
				fog = max(fog - DEFAULT_FADE/gameTicRate, a);
			}
			else if (bFadingOut)
			{
				int fade = current.GetTime('FogFadeOut');
				if (fade <= 0)
				{
					fog = 0.0;
				}
				else if (fog > 0.0)
				{
					fog = max(fog - a/fade, 0.0);
				}
			}
			else if (fog < a)
			{
				int fade = current.GetTime('FogFadeIn');
				fog = fade <= 0 ? a : min(fog + a/fade, a);
			}
		}
		else if (fog > 0.0)
		{
			fog = max(fog - DEFAULT_FADE/gameTicRate, 0.0);
		}

		// Cache sounds
		Sound precip, wind, thunder;
		if (current)
		{
			precip = current.GetSound('Precipitation');
			wind = current.GetSound('Wind');
			thunder = current.GetSound('Thunder');
		}

		// Storm
		prevLightning = lightning;
		if (lightningColorTimer >= 0)
		{
			--lightningColorTimer;
		}

		bool stormy = current && current.GetBool('Stormy');
		if (stormy)
		{
			--thunderTimer;
			if (thunderTimer <= 0)
			{
				thunderTimer = Random[Weather](current.GetTime('MinThunder'), current.GetTime('MaxThunder'));
				A_StartSound(thunder, CHAN_7, CHANF_OVERLAP, attenuation: ATTN_NONE);
			}

			if (!frozen && !InFade('Lightning', sky))
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
			{
				lightning = a;
			}
			else if (lightning < a)
			{
				lightning += a / fade;
			}

			if (lightning >= a)
			{
				lightning = a;
				bInFlash = false;
			}
		}
		else if (lightning > 0.0)
		{
			int fade;
			double a;
			if (stormy)
			{
				fade = current.GetTime('LightningFadeOut');
				a = current.GetAlpha('Lightning');
			}
			else
			{
				fade = int(ceil(FADE_OUT_TIME * gameTicRate));
				a = DEFAULT_ALPHA;
			}

			lightning = fade <= 0 ? 0.0 : max(lightning - a/fade, 0.0);
		}

		// Audio
		A_StartSound(precip, CHAN_5, CHANF_LOOPING, attenuation: ATTN_NONE);
		A_StartSound(wind, CHAN_6, CHANF_LOOPING, attenuation: ATTN_NONE);

		if (current && precip)
		{
			pVolume = CalculateVolume(pVolume, current.GetVolume('MinPrecipitation'), current.GetVolume('MaxPrecipitation'), InFade('Precipitation', sky), current.GetTime('PrecipitationVolumeFadeIn'), current.GetTime('PrecipitationVolumeFadeOut'));
		}
		else
		{
			pVolume = CalculateVolume(pVolume, 0.0, 1.0, true, gameTicRate, gameTicRate);
			if (pVolume <= 0.0)
			{
				A_StopSound(CHAN_5);
			}
		}

		if (current && wind)
		{
			wVolume = CalculateVolume(wVolume, current.GetVolume('MinWind'), current.GetVolume('MaxWind'), InFade('Wind', sky), current.GetTime('WindVolumeFadeIn'), current.GetTime('WindVolumeFadeOut'));
		}
		else
		{
			wVolume = CalculateVolume(wVolume, 0.0, 1.0, true, gameTicRate, gameTicRate);
			if (wVolume <= 0.0)
			{
				A_StopSound(CHAN_6);
			}
		}

		if (current && thunder)
		{
			tVolume = CalculateVolume(tVolume, current.GetVolume('MinThunder'), current.GetTime('MaxThunder'), InFade('Thunder', sky), current.GetTime('ThunderVolumeFadeIn'), current.GetTime('ThunderVolumeFadeOut'));
		}
		else
		{
			tVolume = CalculateVolume(tVolume, 0.0, 1.0, true, gameTicRate, gameTicRate);
			if (tVolume <= 0.0)
			{
				A_StopSound(CHAN_7);
			}
		}

		A_SoundVolume(CHAN_5, pVolume * clamp(CVar.GetCVar(PRECIP_VOL, players[consolePlayer]).GetFloat(), 0.0, 1.0));
		A_SoundVolume(CHAN_6, wVolume * clamp(CVar.GetCVar(WIND_VOL, players[consolePlayer]).GetFloat(), 0.0, 1.0));
		A_SoundVolume(CHAN_7, tVolume * clamp(CVar.GetCVar(THUNDER_VOL, players[consolePlayer]).GetFloat(), 0.0, 1.0));

		if (!current || frozen)
		{
			return;
		}

		// Precipitation
		double multi = min(4.0, CVar.GetCVar(AMOUNT, players[consolePlayer]).GetFloat());
		if (multi <= 0.0)
		{
			return;
		}

		let type = current.GetType('Precipitation');
		if (type && ++rateTimer >= current.GetTime('PrecipitationRate'))
		{
			rateTimer = 0;

			double z = master.pos.z + current.GetFloat('PrecipitationHeight');
			double xy = current.GetFloat('PrecipitationRadius');
			double minXY = master == players[consolePlayer].mo && (players[consolePlayer].cheats & CF_CHASECAM) ? 0.0 : MIN_DIST;

			bool only = current.GetBool('PrecipitationOnlyIndoors');
			bool inside = only || current.GetBool('PrecipitationIndoors');

			int amt = int(ceil(current.GetInt('PrecipitationAmount') * multi));
			for (int i = 0; i < amt; ++i)
			{
				Vector2 dir = FRandom[Weather](0.0, 360.0).ToVector();
				double dist = FRandom[Weather](minXY, xy);

				SpawnPrecipitation(master, type, dir, dist, z, !only, inside);
			}
		}
	}

	// General helpers and ACS ScriptCall functionality

	static clearscope Weather Get()
	{
		return Weather(ThinkerIterator.Create("Weather", MAX_STATNUM).Next());
	}

	static clearscope PrecipitationType GetPrecipitationType(Name n)
	{
		return WeatherHandler(StaticEventHandler.Find("WeatherHandler")).FindType(n);
	}

	static clearscope Name GetPrecipitationTypeName()
	{
		Name n;
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			n = wthr.current.GetName();
		}

		return n;
	}

	static void SetPrecipitationType(Name n)
	{
		let wthr = Weather.Get();
		if (wthr)
		{
			wthr.Reset(Weather.GetPrecipitationType(n));
		}
	}

	static clearscope string GetPrecipitationTypeTag()
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return WeatherHandler.DEFAULT_STRING;
		}

		string t = wthr.current.GetLocalizedString('PrecipitationTag');
		if (!t.Length())
		{
			t = wthr.current.GetName();
		}

		return t;
	}

	static void SetPrecipitationTypeTag(string t)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetString('PrecipitationTag', t);
		}
	}

	static void SetPrecipitationTypeDefaults()
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetDefaults();
		}
	}

	static void ResetPrecipitationType()
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.Reset();
		}
	}

	static void SetPrecipitationClass(string cls)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetString('PrecipitationType', cls);
		}
	}

	static void SetPrecipitationProperties(double rate = -1.0, int amt = -1, double rad = -1.0, double h = -1.0, int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (rate >= 0.0)
		{
			wthr.current.SetFloat('PrecipitationRateTime', rate);
		}
		if (amt >= 0)
		{
			wthr.current.SetInt('PrecipitationAmount', amt);
		}
		if (rad >= 0.0)
		{
			wthr.current.SetFloat('PrecipitationRadius', rad);
		}
		if (h >= 0.0)
		{
			wthr.current.SetFloat('PrecipitationHeight', h);
		}
		if (indoors >= 0)
		{
			wthr.current.SetBool('PrecipitationIndoors', !!indoors);
		}
		if (indoorsOnly >= 0)
		{
			wthr.current.SetBool('PrecipitationOnlyIndoors', !!indoorsOnly);
		}
	}

	static void SetPrecipitationSound(Sound s)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetString('PrecipitationSound', s);
		}
	}

	static void SetPrecipitationVolume(double mi = -1.0, double ma = -1.0, double fadeIn = -1.0, double fadeOut = -1.0)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (mi >= 0.0)
		{
			wthr.current.SetFloat('MinPrecipitationVolume', mi);
		}
		if (ma >= 0.0)
		{
			wthr.current.SetFloat('MaxPrecipitationVolume', ma);
		}
		if (fadeIn >= 0.0)
		{
			wthr.current.SetFloat('PrecipitationVolumeFadeInTime', fadeIn);
		}
		if (fadeOut >= 0.0)
		{
			wthr.current.SetFloat('PrecipitationVolumeFadeOutTime', fadeOut);
		}
	}

	static void SetWindProperties(int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (indoors >= 0)
		{
			wthr.current.SetBool('WindIndoors', !!indoors);
		}
		if (indoorsOnly >= 0)
		{
			wthr.current.SetBool('WindOnlyIndoors', !!indoorsOnly);
		}
	}

	static void SetWindSound(Sound s)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetString('WindSound', s);
		}
	}

	static void SetWindVolume(double mi = -1.0, double ma = -1.0, double fadeIn = -1.0, double fadeOut = -1.0)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (mi >= 0.0)
		{
			wthr.current.SetFloat('MinWindVolume', mi);
		}
		if (ma >= 0.0)
		{
			wthr.current.SetFloat('MaxWindVolume', ma);
		}
		if (fadeIn >= 0.0)
		{
			wthr.current.SetFloat('WindVolumeFadeInTime', fadeIn);
		}
		if (fadeOut >= 0.0)
		{
			wthr.current.SetFloat('WindVolumeFadeOutTime', fadeOut);
		}
	}

	static void ToggleStorm(bool enabled)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetBool('Stormy', enabled);
		}
	}

	static void SetThunderInterval(double mi = -1.0, double ma = -1.0)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (mi >= 0.0)
		{
			wthr.current.SetFloat('MinThunderTime', mi);
		}
		if (ma >= 0.0)
		{
			wthr.current.SetFloat('MaxThunderTime', ma);
		}
	}

	static void SetThunderProperties(int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (indoors >= 0)
		{
			wthr.current.SetBool('ThunderIndoors', !!indoors);
		}
		if (indoorsOnly >= 0)
		{
			wthr.current.SetBool('ThunderOnlyIndoors', !!indoorsOnly);
		}
	}

	static void SetThunderSound(Sound s)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetString('ThunderSound', s);
		}
	}

	static void SetThunderVolume(double mi = -1.0, double ma = -1.0, double fadeIn = -1.0, double fadeOut = -1.0)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (mi >= 0.0)
		{
			wthr.current.SetFloat('MinThunderVolume', mi);
		}
		if (ma >= 0.0)
		{
			wthr.current.SetFloat('MaxThunderVolume', ma);
		}
		if (fadeIn >= 0.0)
		{
			wthr.current.SetFloat('ThunderVolumeFadeInTime', fadeIn);
		}
		if (fadeOut >= 0.0)
		{
			wthr.current.SetFloat('ThunderVolumeFadeOutTime', fadeOut);
		}
	}

	static void SetLightningInterval(double mi = -1.0, double ma = -1.0)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (mi >= 0.0)
		{
			wthr.current.SetFloat('MinLightningTime', mi);
		}
		if (ma >= 0.0)
		{
			wthr.current.SetFloat('MaxLightningTime', ma);
		}
	}

	static void SetLightningProperties(double a = -1.0, uint col = 0u, double fadeIn = -1.0, double fadeOut = -1.0, int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (a >= 0.0)
		{
			wthr.current.SetFloat('LightningAlpha', a);
		}
		if (col > 0u)
		{
			wthr.current.SetInt('LightningColor', col);
		}
		if (fadeIn >= 0.0)
		{
			wthr.current.SetFloat('LightningFadeInTime', fadeIn);
		}
		if (fadeOut >= 0.0)
		{
			wthr.current.SetFloat('LightningFadeOutTime', fadeOut);
		}
		if (indoors >= 0)
		{
			wthr.current.SetBool('LightningIndoors', !!indoors);
		}
		if (indoorsOnly >= 0)
		{
			wthr.current.SetBool('LightningOnlyIndoors', !!indoorsOnly);
		}
	}

	static void ToggleFog(bool enabled)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			wthr.current.SetBool('Foggy', enabled);
		}
	}

	static void SetFogProperties(double a = -1.0, uint col = 0u, double fadeIn = -1.0, double fadeOut = -1.0, int indoors = -1, int indoorsOnly = -1)
	{
		let wthr = Weather.Get();
		if (!wthr || !wthr.current)
		{
			return;
		}

		if (a >= 0.0)
		{
			wthr.current.SetFloat('FogAlpha', a);
		}
		if (col > 0u)
		{
			wthr.current.SetInt('FogColor', col);
		}
		if (fadeIn >= 0.0)
		{
			wthr.current.SetFloat('FogFadeInTime', fadeIn);
		}
		if (fadeOut >= 0.0)
		{
			wthr.current.SetFloat('FogFadeOutTime', fadeOut);
		}
		if (indoors >= 0)
		{
			wthr.current.SetBool('FogIndoors', !!indoors);
		}
		if (indoorsOnly >= 0)
		{
			wthr.current.SetBool('FogOnlyIndoors', !!indoorsOnly);
		}
	}

	static clearscope string GetStringProperty(Name k, bool localized = false)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return localized ? wthr.current.GetLocalizedString(k) : wthr.current.GetString(k);
		}

		return WeatherHandler.DEFAULT_STRING;
	}

	static clearscope bool GetBoolProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return wthr.current.GetBool(k);
		}

		return false;
	}

	static clearscope int GetIntProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
			return wthr.current.GetInt(k);

		return 0;
	}

	static clearscope double GetFloatProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return wthr.current.GetFloat(k);
		}

		return 0.0;
	}

	static clearscope string GetDefaultStringProperty(Name k, bool localized = false)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return localized ? wthr.current.GetDefaultLocalizedString(k) : wthr.current.GetDefaultString(k);
		}

		return WeatherHandler.DEFAULT_STRING;
	}

	static clearscope bool GetDefaultBoolProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return wthr.current.GetDefaultBool(k);
		}

		return false;
	}

	static clearscope int GetDefaultIntProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return wthr.current.GetDefaultInt(k);
		}

		return 0;
	}

	static clearscope double GetDefaultFloatProperty(Name k)
	{
		let wthr = Weather.Get();
		if (wthr && wthr.current)
		{
			return wthr.current.GetDefaultFloat(k);
		}

		return 0.0;
	}
}

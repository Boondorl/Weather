class PrecipitationType
{
	private Map<Name, string> fields;
	private Map<Name, string> defaultFields;
	private Name n;

	static PrecipitationType Create(Name n)
	{
		let pt = new("PrecipitationType");
		pt.n = n;

		return pt;
	}

	void Initialize(Map<Name, string> f)
	{
		defaultFields.Move(f);
		Reset();
	}

	void SetDefaults()
	{
		defaultFields.Copy(fields);
	}

	void Reset()
	{
		fields.Copy(defaultFields);
	}

	// Getters

	Name GetName() const
	{
		return n;
	}

	string GetString(Name k) const
	{
		return fields.GetIfExists(k);
	}

	bool GetBool(Name k) const
	{
		return !!fields.GetIfExists(k).ToInt();
	}

	int GetInt(Name k) const
	{
		return fields.GetIfExists(k).ToInt();
	}

	double GetFloat(Name k) const
	{
		return fields.GetIfExists(k).ToDouble();
	}

	string GetDefaultString(Name k) const
	{
		return defaultFields.GetIfExists(k);
	}

	bool GetDefaultBool(Name k) const
	{
		return !!defaultFields.GetIfExists(k).ToInt();
	}

	int GetDefaultInt(Name k) const
	{
		return defaultFields.GetIfExists(k).ToInt();
	}

	double GetDefaultFloat(Name k) const
	{
		return defaultFields.GetIfExists(k).ToDouble();
	}

	// Wrappers

	string GetLocalizedString(Name k) const
	{
		return StringTable.Localize(GetString(k));
	}

	string GetDefaultLocalizedString(Name k) const
	{
		return StringTable.Localize(GetDefaultString(k));
	}

	int GetTime(Name k) const
	{
		return int(ceil(GetFloat(k.."Time") * gameTicRate));
	}

	Color GetColor(Name k) const
	{
		Color col = GetInt(k.."Color");
		return col;
	}

	double GetAlpha(Name k) const
	{
		return GetFloat(k.."Alpha");
	}

	Sound GetSound(Name k) const
	{
		return GetString(k.."Sound");
	}

	double GetVolume(Name k) const
	{
		return GetFloat(k.."Volume");
	}

	class<Precipitation> GetType(Name k) const
	{
		return (class<Precipitation>)(GetString(k.."Type"));
	}

	// Setters

	void SetString(Name k, string v)
	{
		fields.Insert(k, v);
	}

	void SetBool(Name k, bool v)
	{
		fields.Insert(k, String.Format("%d", v));
	}

	void SetInt(Name k, int v)
	{
		fields.Insert(k, String.Format("%d", v));
	}

	void SetFloat(Name k, double v)
	{
		fields.Insert(k, String.Format("%f", v));
	}
}

class WeatherHandler : StaticEventHandler
{
	const OPEN_BRACE = "{";
	const CLOSE_BRACE = "}";
	const ASSIGN = "=";

	const STR_TRUE = "1";
	const STR_FALSE = "0";
	const DEFAULT_STRING = "";

	private Map<Name, string> toggleFields;
	private Map<Name, string> standardFields;

	Map<Name, string> defaults;
	Array<PrecipitationType> precipTypes;

	// Data fields

	protected WeatherStreamReader CreateLookupTables()
	{
		// Bools
		toggleFields.Insert('Stormy', STR_FALSE);
		toggleFields.Insert('Foggy', STR_FALSE);
		toggleFields.Insert('FogIndoors', STR_FALSE);
		toggleFields.Insert('PrecipitationIndoors', STR_FALSE);
		toggleFields.Insert('ThunderIndoors', STR_FALSE);
		toggleFields.Insert('LightningIndoors', STR_FALSE);
		toggleFields.Insert('WindIndoors', STR_FALSE);
		toggleFields.Insert('FogOnlyIndoors', STR_FALSE);
		toggleFields.Insert('PrecipitationOnlyIndoors', STR_FALSE);
		toggleFields.Insert('ThunderOnlyIndoors', STR_FALSE);
		toggleFields.Insert('LightningOnlyIndoors', STR_FALSE);
		toggleFields.Insert('WindOnlyIndoors', STR_FALSE);

		// Ints
		standardFields.Insert('PrecipitationAmount', "0");
		standardFields.Insert('LightningColor', "0xFFFFFFFF");
		standardFields.Insert('FogColor', "0xFF696969");

		// Floats
		standardFields.Insert('FogAlpha', "0.0");
		standardFields.Insert('FogFadeInTime', "0.1");
		standardFields.Insert('FogFadeOutTime', "0.1");
		standardFields.Insert('MinPrecipitationVolume', "0.3");
		standardFields.Insert('MaxPrecipitationVolume', "1.0");
		standardFields.Insert('PrecipitationVolumeFadeInTime', "0.2");
		standardFields.Insert('PrecipitationVolumeFadeOutTime', "1.0");
		standardFields.Insert('MinWindVolume', "0.3");
		standardFields.Insert('MaxWindVolume', "1.0");
		standardFields.Insert('WindVolumeFadeInTime', "0.2");
		standardFields.Insert('WindVolumeFadeOutTime', "1.0");
		standardFields.Insert('MinThunderVolume', "0.3");
		standardFields.Insert('MaxThunderVolume', "1.0");
		standardFields.Insert('ThunderVolumeFadeInTime', "0.2");
		standardFields.Insert('ThunderVolumeFadeOutTime', "1.0");
		standardFields.Insert('MinThunderTime', "15.0");
		standardFields.Insert('MaxThunderTime', "30.0");
		standardFields.Insert('LightningAlpha', "0.0");
		standardFields.Insert('MinLightningTime', "15.0");
		standardFields.Insert('MaxLightningTime', "30.0");
		standardFields.Insert('LightningFadeInTime', "0.02");
		standardFields.Insert('LightningFadeOutTime', "0.1");
		standardFields.Insert('PrecipitationRateTime', "0.0");
		standardFields.Insert('PrecipitationRadius', "768.0");
		standardFields.Insert('PrecipitationHeight', "384.0");

		// Strings
		standardFields.Insert('PrecipitationType', DEFAULT_STRING);
		standardFields.Insert('PrecipitationTag', DEFAULT_STRING);
		standardFields.Insert('PrecipitationSound', DEFAULT_STRING);
		standardFields.Insert('WindSound', DEFAULT_STRING);
		standardFields.Insert('ThunderSound', DEFAULT_STRING);

		// Defaults
		defaults.Copy(standardFields);

		MapIterator<Name, string> it;
		it.Init(toggleFields);
		while (it.Next())
		{
			defaults.Insert(it.GetKey(), it.GetValue());
		}

		// Reader
		Array<string> keywords;
		keywords.PushV(OPEN_BRACE, CLOSE_BRACE, ASSIGN);
		return WeatherStreamReader.Create("WTHRINFO", keywords);
	}

	protected void ClearLookupTables()
	{
		toggleFields.Clear();
		standardFields.Clear();
	}

	// Parsing

	private bool ParseBody(WeatherStreamReader reader, PrecipitationType pType)
	{
		Map<Name, string> vals;
		vals.Copy(defaults);

		bool closed;
		while (reader.NextLexeme())
		{
			string word = reader.GetLexeme();
			if (word == CLOSE_BRACE)
			{
				closed = true;
				break;
			}

			if (reader.IsReserved(word))
			{
				reader.ThrowError(String.Format("Invalid use of keyword %s; expected property", word));
				return false;
			}
			else if (toggleFields.CheckKey(word))
			{
				vals.Insert(word, STR_TRUE);
			}
			else if (standardFields.CheckKey(word))
			{
				if (!reader.ExpectLexeme(ASSIGN))
				{
					string errorWord = reader.GetLexeme();
					reader.ThrowError(String.Format("Expected %s; got %s", ASSIGN, errorWord.Length() ? errorWord : "unexpected end of file"));
					return false;
				}

				if (!reader.ExpectNonReserved())
				{
					string errorWord = reader.GetLexeme();
					reader.ThrowError(errorWord.Length()
										? String.Format("Invalid use of keyword %s; expected property value", errorWord)
										: "Expected property value; got unexpected end of file");
					return false;
				}

				vals.Insert(word, reader.StripQuotes());
			}
			else
			{
				reader.ThrowError(String.Format("Unknown word %s", word));
				return false;
			}
		}

		if (!closed)
		{
			reader.ThrowError(String.Format("Expected %s at end of type name %s; got end of file", CLOSE_BRACE, pType.GetName()));
			return false;
		}

		pType.Initialize(vals);
		return true;
	}

	protected PrecipitationType ParseType(WeatherStreamReader reader)
	{
		if (!reader.ExpectNonReserved())
		{
			string errorWord = reader.GetLexeme();
			if (errorWord.Length())
				reader.ThrowError(String.Format("Invalid use of keyword %s; expected type name", errorWord));
				
			return null;
		}

		string word = reader.StripQuotes();
		if (!word.Length())
		{
			reader.ThrowError("Names of precipitation types cannot be empty");
			return null;
		}

		PrecipitationType pType = FindType(word);
		if (!pType)
		{
			pType = PrecipitationType.Create(word);
		}

		if (!reader.ExpectLexeme(OPEN_BRACE))
		{
			string errorWord = reader.GetLexeme();
			reader.ThrowError(String.Format("Expected %s after type name %s; got %s", OPEN_BRACE, pType.GetName(), errorWord.Length() ? errorWord : "unexpected end of file"));
			return null;
		}

		return ParseBody(reader, pType) ? pType : null;
	}

	override void OnEngineInitialize()
	{
		let reader = CreateLookupTables();
		while (reader.NextLump())
		{
			while (!reader.AtEndOfStream())
			{
				PrecipitationType pType = ParseType(reader);
				if (reader.HasError())
				{
					reader.PrintError();
					break;
				}

				if (pType)
				{
					precipTypes.Push(pType);
				}
			}
		}

		ClearLookupTables();
	}

	// General weather handling

	const NO_FOG = "weather_no_fog";
	const NO_LIGHTNING = "weather_no_lightning";

	protected Weather wthr;

	clearscope PrecipitationType FindType(Name n) const
	{
		if (n == 'None')
		{
			return null;
		}

		foreach (precip : precipTypes)
		{
			if (precip.GetName() == n)
			{
				return precip;
			}
		}

		return null;
	}

	override void WorldTick()
	{
		if (!wthr)
		{
			wthr = Weather.Get();
		}
	}

	override void RenderUnderlay(RenderEvent e)
	{
		if (!wthr || automapActive)
		{
			return;
		}

		let [x, y, w, h] = Screen.GetViewWindow();

		if (!CVar.GetCVar(NO_FOG, players[consolePlayer]).GetBool())
		{
			let [fog, col] = wthr.GetFog(e.fracTic);
			Screen.Dim(col, fog, x, y, w, h);
		}

		if (!CVar.GetCVar(NO_LIGHTNING, players[consolePlayer]).GetBool() && wthr.InLightningFlash())
		{
			let [inten, flash] = wthr.GetLightning(e.fracTic);
			Screen.Dim(flash, inten, x, y, w, h);
		}
	}
}

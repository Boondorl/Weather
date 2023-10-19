class WeatherStreamReader
{
	enum EKeywords
	{
		NEWLINE = 0x0A,
		CARRET = 0x0D,
		QUOTE = 0x22,
		STAR = 0x2A,
		FORW_SLASH = 0x2F,
		BACK_SLASH = 0x5C
	}

	const NOT_FOUND = -1;
	const EMPTY_STRING = "";

	private Map<string, bool> reserved;
	private Map<int, bool> reservedChar;

	private bool bError;
	private string errorMessage;
	private int errorLine;

	private string lumpName;
	private int curLump;
	private string fullName;

	private string stream;
	private int curIndex, nextIndex;
	private bool bEndOfStream;
	private int startingLine, line;
	private string curLexeme;
	private string strippedLexeme;

	static WeatherStreamReader Create(string lumpName, Array<string> symbols)
	{
		let wsr = new("WeatherStreamReader");
		wsr.lumpName = lumpName;

		foreach (symbol : symbols)
		{
			if (symbol.CodePointCount() == 1)
			{
				wsr.reserved.Insert(symbol, true);
				wsr.reservedChar.Insert(symbol.GetNextCodePoint(0), true);
			}
		}

		return wsr;
	}

	// Error handling

	void ThrowError(string msg)
	{
		bError = true;
		errorMessage = msg;
		errorLine = startingLine;
	}

	bool HasError() const
	{
		return bError;
	}

	void PrintError() const
	{
		Console.PrintF("%sError: %s - %s:%d", Font.TEXTCOLOR_RED, errorMessage, fullName, errorLine);
	}

	// Parsing

	private int Read()
	{
		if (bEndOfStream)
		{
			return 0;
		}

		curIndex = nextIndex;

		int ch;
		[ch, nextIndex] = stream.GetNextCodePoint(curIndex);
		bEndOfStream = CheckEndOfStream();

		return ch;
	}

	private int Peek() const
	{
		if (bEndOfStream)
		{
			return 0;
		}

		return stream.GetNextCodePoint(nextIndex);
	}

	private bool SkipWhitespace()
	{
		while (!bEndOfStream && IsWhitespace(Peek()))
		{
			if (Read() == NEWLINE)
			{
				++line;
			}
		}

		return !bEndOfStream;
	}

	private void SkipLineComment()
	{
		while (!bEndOfStream && Peek() != NEWLINE)
		{
			Read();
		}
	}

	private bool SkipBlockComment()
	{
		while (!bEndOfStream)
		{
			int ch = Read();
			if (ch == NEWLINE)
			{
				++line;
			}
			else if (ch == STAR && Peek() == FORW_SLASH)
			{
				Read();
				return true;
			}
		}

		return false;
	}

	private bool CheckEndOfStream() const
	{
		return (Peek() == 0);
	}

	private bool IsReservedChar(int ch) const
	{
		return reservedChar.GetIfExists(ch);
	}

	private bool IsWhitespace(int ch) const
	{
		return ch == 0x20 || ch == 0x09 || (ch >= 0x0A && ch <= 0x0D);
	}

	bool AtEndOfStream() const
	{
		return bEndOfStream;
	}

	bool IsReserved(string symbol) const
	{
		return reserved.GetIfExists(symbol);
	}

	string GetLexeme() const
	{
		return curLexeme;
	}

	string StripQuotes() const
	{
		return strippedLexeme;
	}

	bool NextLump()
	{
		fullName = EMPTY_STRING;
		stream = EMPTY_STRING;
		curIndex = -1;
		nextIndex = 0;
		bEndOfStream = true;
		startingLine = line = 0;
		curLexeme = strippedLexeme = EMPTY_STRING;

		bError = false;
		errorMessage = EMPTY_STRING;
		errorLine = 0;

		curLump = Wads.FindLump(lumpName, curLump);
		if (curLump == NOT_FOUND)
		{
			return false;
		}

		fullName = Wads.GetLumpFullName(curLump);
		stream = Wads.ReadLump(curLump);
		line = 1;
		bEndOfStream = false;

		bEndOfStream = CheckEndOfStream();
		if (bEndOfStream)
		{
			Console.PrintF("%sWarning: File %s is empty", Font.TEXTCOLOR_YELLOW, fullName);
		}

		++curLump;
		return true;
	}

	bool NextLexeme()
	{
		startingLine = line;
		curLexeme = strippedLexeme = EMPTY_STRING;
		if (!SkipWhitespace())
		{
			return false;
		}

		startingLine = line;
		if (IsReservedChar(Peek()))
		{
			curLexeme.AppendCharacter(Read());
			strippedLexeme = curLexeme;
			return true;
		}

		bool inString, wasString;
		inString = wasString = (Peek() == QUOTE);

		if (inString)
		{
			curLexeme.AppendCharacter(Read());
		}

		while (!bEndOfStream)
		{
			int pending = Peek();
			if (inString && (pending == CARRET || pending == NEWLINE))
			{
				if (!SkipWhitespace())
				{
					break;
				}

				pending = Peek();
			}

			if (!inString
				&& (pending == QUOTE || IsWhitespace(pending) || IsReservedChar(pending)))
			{
				break;
			}

			int ch = Read();
			if (!inString && ch == FORW_SLASH)
			{
				int next = Peek();
				if (next == FORW_SLASH)
				{
					Read();
					SkipLineComment();
					break;
				}
				else if (next == STAR)
				{
					Read();
					if (!SkipBlockComment())
					{
						ThrowError("Block comment was not closed");
						return false;
					}

					continue;
				}
			}
			else if (ch == BACK_SLASH)
			{
				int next = Peek();
				if (next == QUOTE || next == BACK_SLASH)
				{
					curLexeme.AppendCharacter(Read());
					continue;
				}
			}
			else if (ch == QUOTE)
			{
				inString = false;
				curLexeme.AppendCharacter(ch);

				break;
			}

			curLexeme.AppendCharacter(ch);
		}

		if (inString)
		{
			ThrowError("String was not closed");
			return false;
		}

		strippedLexeme = curLexeme;
		if (wasString)
		{
			strippedLexeme = strippedLexeme.Length() == 2 ? EMPTY_STRING : strippedLexeme.Mid(1, strippedLexeme.Length()-2);
		}

		// Ignore empty lexemes
		return wasString || curLexeme.Length() ? true : NextLexeme();
	}

	bool ExpectLexeme(string lex)
	{
		return NextLexeme() && curLexeme == lex;
	}

	bool ExpectNonReserved()
	{
		return NextLexeme() && !IsReserved(curLexeme);
	}
}

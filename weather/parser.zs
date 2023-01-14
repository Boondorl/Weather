class WeatherStreamReader
{
    const NOT_FOUND = -1;
    const EMPTY_STRING = "";

    const NEWLINE = 0x0A;
    const QUOTE = 0x22;
    const FORW_SLASH = 0x2F;
    const STAR = 0x2A;
    const BACK_SLASH = 0x5C;

    private bool bError;
    private string errorMessage;
    private int errorLine;

    private string lumpName;
    private int curLump;
    private string fullName;

    private string stream;
    private int curIndex, nextIndex;
    private bool bEndOfStream;
    private int line;
    private string curLexeme;

    static WeatherStreamReader Create(string lumpName)
    {
        let wsr = new("WeatherStreamReader");
        wsr.lumpName = lumpName;

        return wsr;
    }

    bool NextLump()
    {
        fullName = EMPTY_STRING;
        stream = EMPTY_STRING;
        curIndex = -1;
        nextIndex = 0;
        bEndOfStream = true;
        line = 0;
        curLexeme = EMPTY_STRING;

        bError = false;
        errorMessage = EMPTY_STRING;
        errorLine = 0;

        curLump = Wads.FindLump(lumpName, curLump);
        if (curLump == NOT_FOUND)
            return false;

        fullName = Wads.GetLumpFullName(curLump);
        stream = Wads.ReadLump(curLump);
        line = 1;
        bEndOfStream = stream.Length() <= 0;

        ++curLump;
        return true;
    }

    bool NextLexeme()
    {
        curLexeme = EMPTY_STRING;
        SkipWhitespace();

        if (bEndOfStream)
            return false;

        int startingLine = line;

        bool inString, wasString;
        inString = wasString = (Peek() == QUOTE);
        bool appendQuote;

        if (inString)
            Read();

        // TODO: Error handling
        while (!bEndOfStream)
        {
            int pending = Peek();
            if (pending == NEWLINE && inString)
            {
                SkipWhitespace();
                if (bEndOfStream)
                    break;

                pending = Peek();
            }

            if (!inString && ((pending == QUOTE && !appendQuote) || IsWhitespace(pending)))
                break;

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
                        ThrowError("Block comment was not closed", startingLine);
                        return false;
                    }

                    continue;
                }
            }
            else if (ch == BACK_SLASH && Peek() == QUOTE)
            {
                appendQuote = true;
            }
            else if (ch == QUOTE)
            {
                if (appendQuote)
                {
                    appendQuote = false;
                }
                else
                {
                    inString = false;
                    break;
                }
            }

            curLexeme.AppendCharacter(ch);
        }

        if (inString)
        {
            ThrowError("String was not closed", startingLine);
            return false;
        }

        // Ignore empty lexemes
        return wasString || curLexeme.Length() ? true : NextLexeme();
    }

    string GetLexeme() const
    {
        return curLexeme;
    }

    string GetLumpName() const
    {
        return fullName;
    }

    int GetLine() const
    {
        return line;
    }

    private int Read()
    {
        if (bEndOfStream)
            return 0;

        curIndex = nextIndex;

        int ch;
        [ch, nextIndex] = stream.GetNextCodePoint(curIndex);
        bEndOfStream = (Peek() == 0);

        return ch;
    }

    private int Peek()
    {
        if (bEndOfStream)
            return 0;

        return stream.GetNextCodePoint(nextIndex);
    }

    bool HasError() const
    {
        return bError;
    }

    string, int GetError() const
    {
        return errorMessage, errorLine;
    }

    private void ThrowError(string msg, int l)
    {
        bError = true;
        errorMessage = msg;
        errorLine = l;
    }

    private void SkipWhitespace()
    {
        while (!bEndOfStream && IsWhitespace(Peek()))
        {
            if (Read() == NEWLINE)
                ++line;
        }
    }

    private void SkipLineComment()
    {
        while (!bEndOfStream && Peek() != NEWLINE)
            Read();
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

    private bool IsWhitespace(int ch)
    {
        return ch == 0x20 || ch == 0x09 || (ch >= 0x0A && ch <= 0x0D);
    }
}
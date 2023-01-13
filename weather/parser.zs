class WeatherStreamReader
{
    const NOT_FOUND = -1;
    const EMPTY_STRING = "";

    const NEWLINE = 0x0A;
    const QUOTE = 0x22;
    const FORW_SLASH = 0x2F;
    const STAR = 0x2A;
    const BACK_SLASH = 0x5C;

    private string lumpName;
    private int curLump;
    private string fullName;

    private string stream;
    private int curIndex;
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
        curIndex = 0;
        bEndOfStream = true;
        line = 0;
        curLexeme = EMPTY_STRING;

        curLump = Wads.FindLump(lumpName, curLump);
        if (curLump == NOT_FOUND)
            return false;

        fullName = Wads.GetLumpFullName(curLump);
        stream = Wads.ReadLump(curLump);
        bEndOfStream = IsEnd(curIndex);
        line = 1;

        ++curLump;
        return true;
    }

    bool NextLexeme()
    {
        curLexeme = EMPTY_STRING;
        SkipWhitespace();

        if (bEndOfStream)
            return false;

        bool inString = (Peek() == QUOTE);
        bool appendQuote;

        // TODO: Fix up string handling
        while (!bEndOfStream)
        {
            int pending = Peek();
            if (pending == NEWLINE || (!inString && (pending == QUOTE || IsWhitespace(pending))))
                break;

            int ch = Read();
            if (ch == FORW_SLASH)
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
                        break; // failed to close block comment

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

        return true;
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

        int ch;
        [ch, curIndex] = stream.GetNextCodePoint(curIndex);
        bEndOfStream = IsEnd(curIndex);

        return ch;
    }

    private int Peek()
    {
        if (bEndOfStream)
            return 0;

        let [temp, next] = stream.GetNextCodePoint(curIndex);
        return !IsEnd(next) ? stream.GetNextCodePoint(next) : 0;
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

    private bool IsEnd(uint index)
    {
        return index >= stream.Length();
    }
}
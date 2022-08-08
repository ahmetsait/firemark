// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

module firemark.util;

import std.stdio;
import std.format;
import core.sys.windows.windef;
import core.sys.windows.winbase;
import core.sys.windows.wincon;

import arsd.png;
import arsd.terminal;

immutable userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:103.0) Gecko/20100101 Firefox/103.0";

immutable ubyte[] pngMagicBytes = [ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A ];

string normalizeFilename(const(char)[] filename)
{
	if (filename.length == 0)
		return "_";
	
	import core.stdc.stdio : FILENAME_MAX;
	if (filename.length > FILENAME_MAX)
		return filename[0 .. FILENAME_MAX].idup;
	
	char[] result = filename.dup;
	
	import std.string : representation;
	foreach (i, c; result.representation)
	{
		switch (c)
		{
			case 0:
			..
			case 31:
			case '<':
			case '>':
			case ':':
			case '"':
			case '/':
			case '\\':
			case '|':
			case '?':
			case '*':
				result[i] = '_';
				break;
			default:
				break;
		}
	}
	
	char last = result[$ - 1];
	if (last == '.' || last == ' ')
		result[$ - 1] = '_';
	
	return cast(string)result;
}

ubyte[] writePngToMemory(MemoryImage mi)
{
	PNG* png;
	if(auto p = cast(IndexedImage) mi)
		png = pngFromImage(p);
	else if(auto p = cast(TrueColorImage) mi)
		png = pngFromImage(p);
	else
		assert(0);
	return writePng(png);
}

void printProgressBar(ref Terminal terminal, size_t completed, size_t total)
	in(completed >= 0)
	in(total >= completed)
{
	terminal.updateSize();
	
	static char[] buffer;
	buffer.length = 0;
	buffer.reserve(terminal.width);
	buffer ~= format("  %d/%d (%d%%) [", completed, total, completed * 100 / total);
	size_t progressStart = buffer.length;
	size_t progressLength = terminal.width - buffer.length - 3;
	size_t progressCompleted = progressLength * completed / total;
	buffer.length += progressLength;
	buffer[progressStart .. progressStart + progressCompleted][] = '#';
	buffer[progressStart + progressCompleted .. $][] = '.';
	buffer ~= "]\r";
	terminal.writeStringRaw(buffer);
	
	terminal.flush();
}

void clearCurrentLine(ref Terminal terminal)
{
	terminal.updateSize();
	
	version(Windows)
	{
		static char[] buffer;
		buffer.length = terminal.width + 1;
		buffer[0] = '\r'; // Move to beginning of current line
		buffer[1 .. $ - 1] = ' '; // Clear to the end of current line
		buffer[$ - 1] = '\r';
		// We don't clear the last cell since that might put the cursor on a new line
		terminal.writeStringRaw(buffer);
	}
	else version(Posix)
	{
		terminal.writeStringRaw("\r"); // Move to beginning of current line
		terminal.doTermcap("ce"); // Clear to the end of current line
	}
	else
		static assert(0);
	
	terminal.flush();
}

string sqlEscapeLike(string str, char escapeChar)
{
	size_t count = 0;
	foreach (ch; cast(immutable(ubyte)[])str)
	{
		if (ch == '%' || ch == '_')
			count++;
	}
	char[] result = new char[str.length + count];
	for (size_t i = 0, j = 0; i < str.length; i++, j++)
	{
		if (str[i] == '%' || str[i] == '_')
			result[j++] = escapeChar;
		result[j] = str[i];
	}
	
	return cast(string)result;
}

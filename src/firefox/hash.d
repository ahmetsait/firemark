// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

module firefox.hash;

import core.stdc.stdint;

// https://searchfox.org/mozilla-central/rev/7b9d23ece4835bf355e5195f30fef942d376a1c7/mfbt/HashFunctions.h#65-68
enum uint32_t goldenRatio = 0x9E3779B9U;

// https://searchfox.org/mozilla-central/rev/7b9d23ece4835bf355e5195f30fef942d376a1c7/mfbt/HashFunctions.h#104-107
uint32_t rotateLeft5(uint32_t value)
{
	return (value << 5) | (value >> 27);
}

// https://searchfox.org/mozilla-central/rev/7b9d23ece4835bf355e5195f30fef942d376a1c7/mfbt/HashFunctions.h#109-153
uint32_t addToHash(uint32_t hash, uint32_t value)
{
	return goldenRatio * (rotateLeft5(hash) ^ value);
}

// https://searchfox.org/mozilla-central/rev/7b9d23ece4835bf355e5195f30fef942d376a1c7/mfbt/HashFunctions.h#257-268
uint32_t hashString(const(char)[] str)
{
	uint32_t hash = 0;
	
	for (int i = 0; i < str.length; i++)
		hash = addToHash(hash, str[i]);
	
	return hash;
}

// https://searchfox.org/mozilla-central/rev/7b9d23ece4835bf355e5195f30fef942d376a1c7/toolkit/components/places/SQLFunctions.cpp#965-1003
uint64_t hashURL(const(char)[] url)
{
	import std.string : indexOf;
	
	ptrdiff_t prefix = url.indexOf(':');
	
	return (uint64_t(hashString(url[0 .. prefix >= 0 ? prefix : 0]) & 0x0000FFFF) << 32) + hashString(url);
}

// https://searchfox.org/mozilla-central/rev/7b9d23ece4835bf355e5195f30fef942d376a1c7/toolkit/components/places/SQLFunctions.cpp#835-875
string fixupURL(string url)
{
	import std.string : startsWith;
	
	if (url.startsWith("http://"))
		url = url[7 .. $];
	else if (url.startsWith("https://"))
		url = url[8 .. $];
	else if (url.startsWith("ftp://"))
		url = url[6 .. $];
	
	// Remove common URL hostname prefixes
	if (url.startsWith("www."))
		url = url[4 .. $];
	
	return url;
}

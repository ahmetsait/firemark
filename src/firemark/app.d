// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

module firemark.app;

import core.atomic;
import core.sync.condition;
import core.thread;
import core.time;
import core.volatile;
import core.stdc.stdlib : exit;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.format;
import std.getopt;
import std.parallelism;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import std.uni;
import std.utf;

import arsd.bmp;
import arsd.characterencodings;
import arsd.color;
import arsd.dom;
import arsd.http2;
import arsd.ico;
import arsd.jpeg;
import arsd.png;
import arsd.terminal;

import d2sqlite3;

import datefmt;

import firefox.hash;

import firemark.util;

immutable string versionString = "Firemark v0.1.0";

immutable string helpString = q"HELP
Usage:
    firemark [options] -f path/to/favicons.sqlite -p path/to/places.sqlite
        Downloads missing Firefox bookmark icons into 'favicons.sqlite'.
    
    firemark [options] -x https://example.com
        Extract favicon URLs from web page with 'link[rel~=icon]' selector to standard output.

Options:
    -f, --favicons=FILE
        Path to 'favicons.sqlite' file.
    -p, --places=FILE
        Path to 'places.sqlite' file.
    -j, --jobs=N
        Number of concurrent jobs. Use it to speed up downloading process if you have too many bookmarks.
        Anything more than '-j 3' is not recommended since servers might block you out because of rate limiting.
    -x, --extract=URL
        Extract favicon URLs from web page with 'link[rel~=icon]' selector to standard output and exit.
    -v, --verbose
        Print diagnostic messages.
    --version
        Output version information and exit.
    --help
        Show this help information and exit.

<https://github.com/ahmetsait/firemark>
HELP";

__gshared ubyte interrupted = 0;

extern(C)
void interruptHandler(int sig) nothrow @nogc
{
	ubyte i = volatileLoad(&interrupted);
	if (i < 3)
	{
		volatileStore(&interrupted, cast(ubyte)(i + 1));
	}
	else
		exit(sig);
}

int main(string[] args)
{
	string faviconsFilePath;
	string placesFilePath;
	int jobCount = 0; // 0 means we can only utilize the main thread with TaskPool.finish(true)
	string extractUrl = null;
	bool verboseOutput = false;
	bool showVersion = false;
	
	import core.stdc.signal;
	signal(SIGINT, &interruptHandler);
	
	Mutex terminalMutex = new Mutex();
	Terminal terminal = Terminal(ConsoleOutputType.linear);
	scope(exit) destroy(terminal);
	
	version(Posix)
	{
		import core.sys.posix.signal;
		// Prevent crash when servers close the connection early
		signal(SIGPIPE, SIG_IGN); // Ignore SIGPIPE
	}
	
	GetoptResult opt;
	try
	{
		opt = getopt(args,
			"favicons|f", &faviconsFilePath,
			"places|p", &placesFilePath,
			"jobs|j", &jobCount,
			"extract|x", &extractUrl,
			"verbose|v", &verboseOutput,
			"version", &showVersion,
		);
	}
	catch (Exception ex)
	{
		stderr.writeln("firemark: ", ex.msg, ex.msg[$ - 1] != '.' ? "." : ""); // Stupid dot inconsistency
		stderr.writeln("Try 'firemark --help' for more information.");
		return 1;
	}
	
	if (opt.helpWanted)
	{
		write(helpString);
		return 0;
	}
	
	if (showVersion)
	{
		writeln(versionString);
		return 0;
	}
	
	if (extractUrl)
	{
		Uri uri = Uri(extractUrl);
		HttpRequest pageRequest;
		HttpResponse pageResponse;
		try
		{
			HttpClient client = new HttpClient();
			client.userAgent = userAgent;
			client.keepAlive = false;
			
			pageRequest = client.navigateTo(uri);
			pageResponse = pageRequest.waitForCompletion();
			Uri finalUri = Uri(pageRequest.finalUrl);
			
			if (pageResponse.content.length > 0)
			{
				Document doc = new Document();
				if (pageResponse.contentTypeMimeType == "text/html")
					doc.parseGarbage(pageResponse.contentText);
				else if (pageResponse.contentTypeMimeType == "application/xhtml+xml")
					doc.parseStrict(pageResponse.contentText);
				else
					throw new Exception(format("Unexpected mime type: %s", pageResponse.contentTypeMimeType));
				
				Element[] icons = doc.querySelectorAll("link[rel~=icon]");
				foreach (Element icon; icons)
				{
					if (icon.hasAttribute("href"))
					{
						writeln(Uri(icon.getAttribute("href")).basedOn(finalUri));
					}
				}
			}
		}
		catch (Exception ex)
		{
			stderr.writefln("%s: %s", uri, ex.msg);
			return 1;
		}
		writeln(Uri("/favicon.ico").basedOn(uri));
		return 0;
	}
	
	if (placesFilePath == null || faviconsFilePath == null)
	{
		stderr.writeln("firemark: Missing '--places' or '--favicons' arguments.");
		stderr.writeln("Try 'firemark --help' for more information.");
		return 1;
	}
	
	Mutex placesMutex = new Mutex();
	Database places;
	//Statement placesBookmarkCount;
	Statement placesBookmarks;
	try
	{
		places = Database(placesFilePath, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX);
		//placesBookmarkCount = places.prepare(`select count(*) from moz_bookmarks where moz_bookmarks.type = 1`);
		placesBookmarks = places.prepare(`
			select moz_places.id, moz_places.url, moz_places.url_hash
			from moz_bookmarks
			inner join moz_places on moz_bookmarks.fk=moz_places.id
			where moz_bookmarks.type = 1`);
	}
	catch (SqliteException ex)
	{
		stderr.writefln("%s: %s", escapeShellFileName(placesFilePath), ex.msg);
		return 1;
	}
	
	Mutex faviconsMutex = new Mutex();
	Database favicons;
	try
	{
		favicons = Database(faviconsFilePath, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX);
		favicons.createFunction("fixup_url", &fixupURL);
		favicons.createFunction("hash", &hashURL);
	}
	catch (SqliteException ex)
	{
		stderr.writefln("%s: %s", escapeShellFileName(faviconsFilePath), ex.msg);
		return 1;
	}
	
	ResultRange getFaviconsOfPage(string page_url, ulong page_url_hash)
	{
		synchronized (faviconsMutex)
		{
			return favicons.execute(`
				select moz_icons.id, moz_icons.icon_url, moz_icons.fixed_icon_url_hash, moz_icons.width, moz_icons.root
				from moz_pages_w_icons
				inner join moz_icons_to_pages on moz_pages_w_icons.id = moz_icons_to_pages.page_id
				inner join moz_icons on moz_icons_to_pages.icon_id = moz_icons.id
				where moz_pages_w_icons.page_url_hash = ? and moz_pages_w_icons.page_url = ?`,
				page_url_hash, page_url);
		}
	}
	
	ResultRange getFaviconWithURL(string fixed_icon_url, ulong fixed_icon_url_hash, bool root)
	{
		synchronized (faviconsMutex)
		{
			return favicons.execute(`
				select id, icon_url, fixed_icon_url_hash, width
				from moz_icons
				where fixed_icon_url_hash = ? and fixup_url(icon_url) = ? and root = ?`,
				fixed_icon_url_hash, fixed_icon_url, root);
		}
	}
	
	CachedResults bookmarks = cached(placesBookmarks.execute());
	immutable size_t total = bookmarks.rows.length;
	if (verboseOutput)
	{
		terminal.writefln("%d bookmarks found.", total);
		terminal.flush();
	}
	
	bool iconExists(string fixed_icon_url, ulong fixed_icon_url_hash)
	{
		synchronized (faviconsMutex)
		{
			int iconCount = favicons.execute(`
				select count(*)
				from moz_icons
				where fixed_icon_url_hash = ? and fixup_url(icon_url) = ? and root = 1`,
				fixed_icon_url_hash, fixed_icon_url).oneValue!int;
			if (iconCount > 0)
				return true;
		}
		
		return false;
	}
	
	bool hasRootIcon(string page_url)
	{
		// No page specific favicon in database, check if root favicon exists
		Uri uri = Uri(page_url);
		Uri rootFaviconURI = Uri("/favicon.ico").basedOn(uri);
		rootFaviconURI.query = null;
		rootFaviconURI.fragment = null;
		string rootFaviconURL = rootFaviconURI.toString();
		
		string fixedURL = fixupURL(rootFaviconURL);
		
		synchronized (faviconsMutex)
		{
			int iconCount = favicons.execute(`
				select count(*)
				from moz_icons
				where fixed_icon_url_hash = ? and fixup_url(icon_url) = ? and root = 1`,
				hashURL(fixedURL), fixedURL).oneValue!int;
			if (iconCount > 0)
				return true;
		}
		
		return false;
	}
	
	bool hasIcon(string page_url, ulong page_url_hash)
	{
		synchronized (faviconsMutex)
		{
			int iconCount = favicons.execute(`
				select count(*)
				from moz_pages_w_icons
				inner join moz_icons_to_pages on moz_pages_w_icons.id = moz_icons_to_pages.page_id
				inner join moz_icons on moz_icons_to_pages.icon_id = moz_icons.id
				where moz_pages_w_icons.page_url_hash = ? and moz_pages_w_icons.page_url = ?`,
				page_url_hash, page_url).oneValue!int;
			if (iconCount > 0)
				return true;
		}
		
		return hasRootIcon(page_url);
	}
	
	Place[] getBookmarksWithMissingIcons()
	{
		Appender!(Place[]) result = appender!(Place[]);
		foreach (bookmark; bookmarks)
		{
			Place place = Place(
				bookmark["id"].as!int,
				bookmark["url"].as!string,
				bookmark["url_hash"].as!long,
			);
			if (!startsWith(place.url, "place:") && !hasIcon(place.url, place.url_hash))
				result ~= place;
		}
		
		return result[];
	}
	
	Place[] bookmarksWithMissingIcons = getBookmarksWithMissingIcons();
	immutable size_t missing = bookmarksWithMissingIcons.length;
	if (verboseOutput)
	{
		terminal.writefln("%d bookmarks with missing icons.\n", missing);
		terminal.flush();
	}
	
	shared size_t completed = 0;
	
	/// Clears the current line, writes args to terminal and prints progress bar.
	void writeWithProgress(T...)(T args)
	{
		synchronized (terminalMutex)
		{
			if (terminal.stdoutIsTerminal)
			{
				clearCurrentLine(terminal);
				if (verboseOutput)
					terminal.write(args);
				printProgressBar(terminal, completed, missing);
			}
			else if (verboseOutput)
				std.stdio.write(args);
		}
	}
	
	/// Clears the current line, writes args to terminal and prints progress bar.
	void writelnWithProgress(T...)(T args)
	{
		writeWithProgress(args, '\n');
	}
	
	/// Clears the current line, writes formatted args to terminal and prints progress bar.
	void writeflnWithProgress(T...)(string f, T args)
	{
		synchronized (terminalMutex)
		{
			if (terminal.stdoutIsTerminal)
			{
				clearCurrentLine(terminal);
				if (verboseOutput)
					terminal.writefln(f, args);
				printProgressBar(terminal, completed, missing);
			}
			else if (verboseOutput)
				std.stdio.writefln(f, args);
		}
	}
	
	//favicons.setTraceCallback(
	//	(string sql) {
	//		try
	//			writeflnWithProgress("SQLite Trace: %s", sql);
	//		catch (Exception) { }
	//	}
	//);
	
	TaskPool taskPool = new TaskPool(jobCount);
	taskPool.isDaemon = true;
	
	/// Fetch favicon of given URL and insert into favicons.sqlite
	void fetchFavicon(Place place)
	{
		if (volatileLoad(&interrupted) > 0)
		{
			taskPool.stop();
			return;
		}
		
		string url = place.url;
		Uri uri = Uri(place.url);
		
		Appender!string outBuffer = appender!string;
		scope (success)
		{
			string output = outBuffer[];
			if (output.length > 0)
				writelnWithProgress(output);
		}
		
		scope (exit)
			atomicOp!"+="(completed, 1);
		
		if (hasIcon(place.url, place.url_hash))
			return;
		
		HttpClient client = new HttpClient();
		scope(exit) destroy(client);
		client.userAgent = userAgent;
		client.defaultTimeout = 5.seconds;
		client.keepAlive = false;
		
		HttpRequest pageRequest;
		HttpResponse pageResponse;
		int retried = 0;
		Lretry:
		try
		{
			pageRequest = client.navigateTo(uri);
			pageResponse = pageRequest.waitForCompletion();
		}
		catch (Exception ex)
		{
			outBuffer ~= format("%s: %s\n", url, ex.msg);
			return;
		}
		finally
			client.clearCookies();
		
		if (pageResponse.code == 2 && retried++ < 1)
		{
			// Might have ran out of file descriptors
			// Let the GC collect leftover Socket objects
			pageRequest.resetInternals();
			import core.memory;
			GC.collect();
			goto Lretry;
		}
		
		Uri finalUri = Uri(pageRequest.finalUrl);
		
		outBuffer ~= format("%s: %d %s\n", url, pageResponse.code, pageResponse.codeText);
		
		bool faviconDone = false;
		
		string mime = pageResponse.contentTypeMimeType;
		
		void addIconToDB(
			string icon_url, int width, bool root, long moz_icons_expire_ms, const(ubyte)[] data,
			string page_url, long page_url_hash,
			long moz_icons_to_pages_expire_ms)
		{
			synchronized (faviconsMutex)
			{
				int icon_id = favicons.execute(`
					insert into moz_icons (icon_url, fixed_icon_url_hash, width, root, expire_ms, data)
					values (?, ?, ?, ?, ?, ?)
					returning id`,
					icon_url,
					hashURL(fixupURL(icon_url)),
					width,
					root,
					moz_icons_expire_ms,
					data,
				).oneValue!int;
				
				if (!root)
				{
					int page_id = favicons.execute(`
						insert into moz_pages_w_icons (page_url, page_url_hash)
						values (?, ?)
						returning id`,
						page_url,
						page_url_hash,
					).oneValue!int;
					
					favicons.execute(`
						insert into moz_icons_to_pages (page_id, icon_id, expire_ms)
						values (?, ?, ?)`,
						page_id,
						icon_id,
						moz_icons_to_pages_expire_ms,
					);
				}
			}
		}
		
		if (pageResponse.content.length > 0)
		{
			Document doc = new Document();
			if (mime == "text/html")
				doc.parseGarbage(pageResponse.contentText);
			else if (mime == "application/xhtml+xml")
				doc.parseStrict(pageResponse.contentText);
			else
				return;
			
			SysTime pageExpire = calculateExpirationOfResponse(pageResponse);
			long pageExpireMS = pageExpire.toUnixTime * 1000;
			
			Element[] iconLinks = doc.querySelectorAll("link[rel~=icon]");
			
			if (iconLinks.length > 0)
			{
				LiconLinks:
				foreach (linkIndex, iconLink; iconLinks)
				{
					outBuffer ~= format("    %s\n", iconLink);
					string href = iconLink.attrs.get("href");
					
					Uri absoluteIconURI = Uri(href).basedOn(finalUri);
					string absoluteIconURL = absoluteIconURI.toString;
					string fixedAbsoluteIconURL = fixupURL(absoluteIconURL);
					ulong absoluteIconURLHash = hashURL(fixedAbsoluteIconURL);
					
					CachedResults faviconsWithURL;
					synchronized (faviconsMutex)
						faviconsWithURL = cached(getFaviconWithURL(fixedAbsoluteIconURL, absoluteIconURLHash, false));
					
					if (faviconsWithURL.rows.length > 0)
					{
						// If the icon exists already, connect it with this url
						long finalUrlHash = hashURL(pageRequest.finalUrl);
						
						CachedResults faviconsOfPage;
						synchronized (faviconsMutex)
							faviconsOfPage = cached(getFaviconsOfPage(pageRequest.finalUrl, finalUrlHash));
						
						int page_id;
						
						if (faviconsOfPage.rows.length > 0)
						{
							page_id = faviconsOfPage.rows[0]["id"].as!int;
						}
						else
						{
							synchronized (faviconsMutex)
							{
								page_id = favicons.execute(`
									insert into moz_pages_w_icons (page_url, page_url_hash)
									values (?, ?)
									returning id`,
									pageRequest.finalUrl,
									finalUrlHash,
								).oneValue!int;
							}
						}
						
						foreach (fav; faviconsWithURL)
						{
							synchronized (faviconsMutex)
							{
								favicons.execute(`
									insert into moz_icons_to_pages (page_id, icon_id, expire_ms)
									values (?, ?, ?)`,
									page_id,
									fav["id"].as!int,
									pageExpireMS,
								);
							}
						}
						
						faviconDone = true;
					}
					else
					{
						HttpRequest iconRequest;
						HttpResponse iconResponse;
						try
						{
							iconRequest = client.navigateTo(absoluteIconURI);
							iconResponse = iconRequest.waitForCompletion();
						}
						catch (Exception ex)
						{
							outBuffer ~= format("    %s: %s\n", url, ex.msg);
							continue LiconLinks;
						}
						finally
							client.clearCookies();
						
						outBuffer ~= format("        %s: %d %s\n", absoluteIconURL, iconResponse.code, iconResponse.codeText);
						
						if (!iconResponse.wasSuccessful)
							continue;
						
						string iconMime = iconResponse.contentTypeMimeType;
						try
						{
							SysTime iconExpire = calculateExpirationOfResponse(iconResponse);
							long iconExpireMS = iconExpire.toUnixTime * 1000;
							switch (iconMime)
							{
								case "image/vnd.microsoft.icon":
								case "image/x-icon":
									MemoryImage[] icons = loadIcoFromMemory(iconResponse.content);
									foreach (i, icon; icons)
									{
										if (icon is null)
										{
											outBuffer ~= format("Failed to read icon %d from url: %s\n", i, absoluteIconURL);
											continue;
										}
										ubyte[] png = writePngToMemory(icon);
										addIconToDB(
											absoluteIconURL, icon.width, false, iconExpireMS, png,
											url, place.url_hash,
											pageExpireMS,
										);
										faviconDone = true;
									}
									break;
								case "image/png":
									MemoryImage image = readPngFromBytes(iconResponse.content);
									if (image is null)
										throw new Exception("Failed to read png image.");
									ubyte[] png = writePngToMemory(image);
									addIconToDB(
										absoluteIconURL, image.width, false, iconExpireMS, png,
										url, place.url_hash,
										pageExpireMS,
									);
									faviconDone = true;
									break;
								case "image/jpeg":
									MemoryImage image = readJpegFromMemory(iconResponse.content);
									if (image is null)
										throw new Exception("Failed to read jpeg image.");
									ubyte[] png = writePngToMemory(image);
									addIconToDB(
										absoluteIconURL, image.width, false, iconExpireMS, png,
										url, place.url_hash,
										pageExpireMS,
									);
									faviconDone = true;
									break;
								case "image/svg+xml":
									ubyte[] svg = iconResponse.content;
									addIconToDB(
										absoluteIconURL, ushort.max, false, iconExpireMS, svg,
										url, place.url_hash,
										pageExpireMS,
									);
									faviconDone = true;
									break;
								default:
									outBuffer ~= format("    Unsupported mime type %s for %s\n", iconMime, absoluteIconURL);
									break;
							}
						}
						catch (Exception ex)
						{
							outBuffer ~= format("        %s: %s\n", absoluteIconURL, ex.msg);
						}
					}
				}
			}
		}
		
		if (faviconDone)
			return;
		
		// Some dipshits use TLS fingerprinting to stop web scrapers
		// (e.g. cloudflare users) but sometimes it allows access
		// to /favicon.ico so we take our chances although it
		// doesn't work reliably.
		
		Uri rootFaviconURI = Uri("/favicon.ico").basedOn(uri);
		rootFaviconURI.query = null;
		rootFaviconURI.fragment = null;
		string rootFaviconURL = rootFaviconURI.toString();
		
		string fixedRootIconURL = fixupURL(rootFaviconURL);
		ulong rootIconURLHash = hashURL(fixedRootIconURL);
		
		CachedResults rootFaviconsWithURL;
		synchronized (faviconsMutex)
			rootFaviconsWithURL = cached(getFaviconWithURL(fixedRootIconURL, rootIconURLHash, true));
		
		if (!iconExists(fixedRootIconURL, rootIconURLHash))
		{
			HttpRequest rootFaviconRequest;
			HttpResponse rootFaviconResponse;
			try
			{
				rootFaviconRequest = client.navigateTo(rootFaviconURI);
				rootFaviconResponse = rootFaviconRequest.waitForCompletion();
			}
			catch (Exception ex)
			{
				outBuffer ~= format("    %s: %s\n", url, ex.msg);
				return;
			}
			
			outBuffer ~= format("    %s: %d %s\n", rootFaviconURL, rootFaviconResponse.code, rootFaviconResponse.codeText);
			
			if (!rootFaviconResponse.wasSuccessful)
				return;
			
			SysTime iconExpire = calculateExpirationOfResponse(rootFaviconResponse);
			long iconExpireMS = iconExpire.toUnixTime * 1000;
			
			string iconMime = rootFaviconResponse.contentTypeMimeType;
			switch (iconMime)
			{
				case "image/vnd.microsoft.icon":
				case "image/x-icon":
					try
					{
						MemoryImage[] icons = loadIcoFromMemory(rootFaviconResponse.content);
						foreach (i, icon; icons)
						{
							if (icon is null)
							{
								outBuffer ~= format("Failed to read icon %d from url: %s\n", i, rootFaviconURL);
								continue;
							}
							ubyte[] png = writePngToMemory(icon);
							addIconToDB(
								rootFaviconURL, icon.width, true, iconExpireMS, png,
								null, 0,
								0,
							);
						}
					}
					catch (Exception ex)
					{
						if (rootFaviconResponse.content.startsWith(pngMagicBytes))
							// Some websites seriously put a png image named as favicon.ico
							// Total bullshit.
							goto case "image/png";
					}
					break;
				case "image/png":
					try
					{
						MemoryImage image = readPngFromBytes(rootFaviconResponse.content);
						if (image is null)
							throw new Exception("Failed to read png image.");
						ubyte[] png = writePngToMemory(image);
						addIconToDB(
							rootFaviconURL, image.width, true, iconExpireMS, png,
							null, 0,
							0,
						);
					}
					catch (Exception ex)
					{
						outBuffer ~= format("        %s: %s\n", rootFaviconURL, ex.msg);
					}
					break;
				case "text/html":
				case "application/xhtml+xml":
					// Some websites redirect to their home page instead of giving you 404
					break;
				default:
					outBuffer ~= format("    Unexpected mimetype %s for %s\n", iconMime, rootFaviconURL);
					break;
			}
		}
	}
	
	foreach (bookmark; bookmarksWithMissingIcons)
	{
		if (volatileLoad(&interrupted) > 0)
		{
			taskPool.stop();
			break;
		}
		
		taskPool.put(task(&fetchFavicon, bookmark));
	}
	
	taskPool.finish(true);
	
	synchronized (terminalMutex)
	{
		terminal.writeln();
		terminal.flush();
	}
	
	return 0;
}

struct Place
{
	int id;
	string url;
	long url_hash;
}

struct Favicon
{
	int id;
	string icon_url;
	long fixed_icon_url_hash;
	int width;
}

SysTime calculateExpirationOfResponse(ref HttpResponse response, Nullable!SysTime relativeTo = Nullable!SysTime.init)
{
	string* _cacheControl = "cache-control" in response.headersHash;
	string* _expires = "expires" in response.headersHash;
	string* _date = "date" in response.headersHash;
	string* _lastModified = "last-modified" in response.headersHash;
	string* _age = "age" in response.headersHash;
	
	SysTime time = relativeTo.isNull ? Clock.currTime : relativeTo.get;
	
	if (_cacheControl)
	{
		string cacheControl = *_cacheControl;
		auto params = cacheControl.splitter(',').map!strip;
		long maxAge;
		bool maxAgeFound = false;
		foreach (string param; params)
		{
			ptrdiff_t eqIndex = param.indexOf('=');
			if (eqIndex < 0)
				continue;
			string name = param[0 .. eqIndex];
			if (icmp(name, "max-age") == 0)
			{
				try
					maxAge = param[eqIndex + 1 .. $].to!long;
				catch (ConvException)
					break;
				maxAgeFound = true;
			}
		}
		if (maxAgeFound)
		{
			if (_age)
			{
				long age;
				try
				{
					age = (*_age).to!long;
					return SysTime.fromUnixTime(time.toUnixTime + maxAge - age);
				}
				catch (ConvException) { }
			}
		}
	}
	else if (_expires)
	{
		SysTime expires;
		if (tryParse(*_expires, RFC1123FORMAT, expires))
		{
			return expires;
		}
	}
	else if (_date && _lastModified)
	{
		SysTime date, lastModified;
		if (tryParse(*_date, RFC1123FORMAT, date) &&
			tryParse(*_lastModified, RFC1123FORMAT, lastModified))
		{
			// https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching#heuristic_caching
			return lastModified + ((date - lastModified) * 11 / 10);
		}
	}
	return SysTime.init;
}

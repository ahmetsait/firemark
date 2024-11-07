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

immutable string versionString = "Firemark v0.2.0";

immutable string helpString = import("help.txt");

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

struct Place
{
	long id;
	string url;
	ulong url_hash;
}

struct Favicon
{
	long id;
	string icon_url;
	long fixed_icon_url_hash;
	long width;
}

version(none)
void main(string[] args)
{
	try
	{
		Database db = Database("places.sqlite", SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX/+ | SQLITE_OPEN_EXCLUSIVE+/);
		db.execute(`attach database ? as favicons`, "favicons.sqlite");
		
		string url = args[1];
		
		HttpClient client = new HttpClient();
		client.userAgent = userAgent;
		client.defaultTimeout = 5.seconds;
		
		HttpRequest request = client.request(Uri(url));
		HttpResponse response = request.waitForCompletion();
		writefln("%d %s\n%(%s\n%)", response.code, response.codeText, response.headers);
	}
	catch (Exception ex)
	{
		writeln(ex);
	}
}
else
int main(string[] args)
{
	string profilePath;
	bool forceReload = false;
	bool backup = true;
	void noBackup() { backup = false; }
	bool eraseIcons = false;
	int jobCount = 0;
	// 0 means we can only utilize the main thread with TaskPool.finish(true)
	
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
			std.getopt.config.caseSensitive,
			"profile|p", &profilePath,
			"force|f", &forceReload,
			"backup|b", &backup,
			"no-backup|B", &noBackup,
			"erase|e", &eraseIcons,
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
		terminal.write(helpString);
		terminal.flush();
		return 0;
	}
	
	if (showVersion)
	{
		terminal.writeln(versionString);
		terminal.flush();
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
	
	if (profilePath == null)
	{
		stderr.writeln("firemark: Missing '--profile' argument.");
		stderr.writeln("Try 'firemark --help' for more information.");
		return 1;
	}
	
	string placesFilePath = buildPath(profilePath, "places.sqlite");
	string faviconsFilePath = buildPath(profilePath, "favicons.sqlite");
	
	if (backup)
	{
		immutable backupPath = findAvailableFilename(profilePath, "favicons-backup", ".sqlite");
		std.file.copy(faviconsFilePath, backupPath);
		if (verboseOutput)
		{
			terminal.writefln("Backed up '%s' to '%s'", faviconsFilePath, backupPath);
			terminal.flush();
		}
	}
	
	Mutex dbMutex = new Mutex();
	Database db;
	try
	{
		db = Database(placesFilePath, SQLITE_OPEN_READWRITE | SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_FULLMUTEX);
		db.execute(`attach database ? as favicons`, faviconsFilePath);
		
		if (verboseOutput)
		{
			terminal.writeln("places.sqlite");
			terminal.writeln("-------------");
			terminal.writeln("auto_vacuum: ", db.execute(`pragma auto_vacuum`).oneValue!string);
			terminal.writeln("automatic_index: ", db.execute(`pragma automatic_index`).oneValue!string);
			terminal.writeln("checkpoint_fullfsync: ", db.execute(`pragma checkpoint_fullfsync`).oneValue!string);
			terminal.writeln("foreign_keys: ", db.execute(`pragma foreign_keys`).oneValue!string);
			terminal.writeln("fullfsync: ", db.execute(`pragma fullfsync`).oneValue!string);
			terminal.writeln("ignore_check_constraints: ", db.execute(`pragma ignore_check_constraints`).oneValue!string);
			terminal.writeln("journal_mode: ", db.execute(`pragma journal_mode`).oneValue!string);
			terminal.writeln("journal_size_limit: ", db.execute(`pragma journal_size_limit`).oneValue!string);
			terminal.writeln("locking_mode: ", db.execute(`pragma locking_mode`).oneValue!string);
			terminal.writeln("max_page_count: ", db.execute(`pragma max_page_count`).oneValue!string);
			terminal.writeln("page_size: ", db.execute(`pragma page_size`).oneValue!string);
			terminal.writeln("recursive_triggers: ", db.execute(`pragma recursive_triggers`).oneValue!string);
			terminal.writeln("secure_delete: ", db.execute(`pragma secure_delete`).oneValue!string);
			terminal.writeln("synchronous: ", db.execute(`pragma synchronous`).oneValue!string);
			terminal.writeln("temp_store: ", db.execute(`pragma temp_store`).oneValue!string);
			terminal.writeln("user_version: ", db.execute(`pragma user_version`).oneValue!string);
			terminal.writeln("wal_autocheckpoint: ", db.execute(`pragma wal_autocheckpoint`).oneValue!string);
			terminal.writeln();
			
			terminal.writeln("favicons.sqlite");
			terminal.writeln("-------------");
			terminal.writeln("auto_vacuum: ", db.execute(`pragma favicons.auto_vacuum`).oneValue!string);
			terminal.writeln("automatic_index: ", db.execute(`pragma favicons.automatic_index`).oneValue!string);
			terminal.writeln("checkpoint_fullfsync: ", db.execute(`pragma favicons.checkpoint_fullfsync`).oneValue!string);
			terminal.writeln("foreign_keys: ", db.execute(`pragma favicons.foreign_keys`).oneValue!string);
			terminal.writeln("fullfsync: ", db.execute(`pragma favicons.fullfsync`).oneValue!string);
			terminal.writeln("ignore_check_constraints: ", db.execute(`pragma favicons.ignore_check_constraints`).oneValue!string);
			terminal.writeln("journal_mode: ", db.execute(`pragma favicons.journal_mode`).oneValue!string);
			terminal.writeln("journal_size_limit: ", db.execute(`pragma favicons.journal_size_limit`).oneValue!string);
			terminal.writeln("locking_mode: ", db.execute(`pragma favicons.locking_mode`).oneValue!string);
			terminal.writeln("max_page_count: ", db.execute(`pragma favicons.max_page_count`).oneValue!string);
			terminal.writeln("page_size: ", db.execute(`pragma favicons.page_size`).oneValue!string);
			terminal.writeln("recursive_triggers: ", db.execute(`pragma favicons.recursive_triggers`).oneValue!string);
			terminal.writeln("secure_delete: ", db.execute(`pragma favicons.secure_delete`).oneValue!string);
			terminal.writeln("synchronous: ", db.execute(`pragma favicons.synchronous`).oneValue!string);
			terminal.writeln("temp_store: ", db.execute(`pragma favicons.temp_store`).oneValue!string);
			terminal.writeln("user_version: ", db.execute(`pragma favicons.user_version`).oneValue!string);
			terminal.writeln("wal_autocheckpoint: ", db.execute(`pragma favicons.wal_autocheckpoint`).oneValue!string);
			terminal.writeln();
			terminal.flush();
		}
		
		db.createFunction("fixup_url", &fixupURL);
		db.createFunction("hash", &hashURL);
		db.createFunction("root_favicon_url_of",
			function string(string url) => Uri("/favicon.ico").basedOn(Uri(url)).toString()
		);
		
		db.run(`
			create temp table added_icons (
				icon_id integer primary key
			);
			
			create temp table added_icons_to_pages (
				page_id integer,
				icon_id integer,
				primary key (page_id, icon_id)
			);
			
			create temp table added_pages_w_icons (
				page_id integer primary key
			);
			
			create temp view bookmarks as
			select moz_places.*
			from moz_bookmarks, moz_places
			where
				moz_bookmarks.fk = moz_places.id
				and moz_bookmarks.type = 1
				and moz_places.url not like 'place:%';
			
			create temp view bookmarks_without_direct_icons as
			select bookmarks.*
			from bookmarks
			where
				not exists (
					select *
					from moz_pages_w_icons, moz_icons_to_pages, moz_icons
					where
						bookmarks.url_hash = moz_pages_w_icons.page_url_hash
						and bookmarks.url = moz_pages_w_icons.page_url
						and moz_pages_w_icons.id = moz_icons_to_pages.page_id
						and moz_icons_to_pages.icon_id = moz_icons.id
				);
			
			create temp view bookmarks_without_any_icons as
			select bookmarks_without_direct_icons.*
			from bookmarks_without_direct_icons
			where
				not exists (
					select *
					from moz_icons
					where
						moz_icons.fixed_icon_url_hash = hash(fixup_url(root_favicon_url_of(bookmarks_without_direct_icons.url)))
						and moz_icons.icon_url = root_favicon_url_of(bookmarks_without_direct_icons.url)
				);
		`);
	}
	catch (SqliteException ex)
	{
		stderr.writefln("SQLite Exception\n%s", ex.msg);
		return 1;
	}
	
	immutable total_bookmarks = db.execute(`select count(*) from bookmarks`).oneValue!long;
	immutable bookmarks_without_direct_icons = db.execute(`select count(*) from bookmarks_without_direct_icons`).oneValue!long;
	immutable bookmarks_without_any_icons = db.execute(`select count(*) from bookmarks_without_any_icons`).oneValue!long;
	if (verboseOutput)
	{
		terminal.writeln("Total bookmarks: ", total_bookmarks);
		terminal.writeln("Bookmarks without direct icons: ", bookmarks_without_direct_icons);
		terminal.writeln("Bookmarks without any icons: ", bookmarks_without_any_icons);
		terminal.writeln();
		terminal.flush();
	}
	
	CachedResults getDirectIconsOfPage(string page_url, ulong page_url_hash)
	{
		synchronized (dbMutex)
		{
			return db.execute(`
				select moz_icons.id, moz_icons.icon_url, moz_icons.fixed_icon_url_hash, moz_icons.width
				from moz_pages_w_icons, moz_icons_to_pages, moz_icons
				where
					moz_pages_w_icons.page_url_hash = ?
					and moz_pages_w_icons.page_url = ?
					and moz_pages_w_icons.id = moz_icons_to_pages.page_id
					and moz_icons_to_pages.icon_id = moz_icons.id`,
				page_url_hash, page_url
			).cached;
		}
	}
	
	CachedResults getIconsByURL(string icon_url, ulong fixed_icon_url_hash = 0)
	{
		if (fixed_icon_url_hash == 0)
			fixed_icon_url_hash = hashURL(fixupURL(icon_url));
		synchronized (dbMutex)
		{
			return db.execute(`
				select id, icon_url, fixed_icon_url_hash, width, root
				from moz_icons
				where
					fixed_icon_url_hash = ?
					and icon_url = ?`,
				fixed_icon_url_hash, icon_url
			).cached;
		}
	}
	
	bool iconExists(string icon_url, ulong fixed_icon_url_hash = 0)
	{
		if (fixed_icon_url_hash == 0)
			fixed_icon_url_hash = hashURL(fixupURL(icon_url));
		synchronized (dbMutex)
		{
			return db.execute(`
				select exists (
					select *
					from moz_icons
					where
						fixed_icon_url_hash = ?
						and icon_url = ?
				)`,
				fixed_icon_url_hash, icon_url
			).oneValue!bool;
		}
	}
	
	bool pageHasRootIcon(string page_url)
	{
		Uri uri = Uri(page_url);
		Uri rootFaviconURI = Uri("/favicon.ico").basedOn(uri);
		string rootFaviconURL = rootFaviconURI.toString();
		string fixedRootFaviconURL = fixupURL(rootFaviconURL);
		ulong fixedRootFaviconURLHash = hashURL(fixedRootFaviconURL);
		
		synchronized (dbMutex)
		{
			return db.execute(`
				select exists (
					select *
					from moz_icons
					where
						fixed_icon_url_hash = ?
						and icon_url = ?
						and root = 1
				)`,
				fixedRootFaviconURLHash,
				rootFaviconURL,
			).oneValue!bool;
		}
	}
	
	bool pageHasDirectIcon(string page_url, ulong page_url_hash = 0)
	{
		if (page_url_hash == 0)
			page_url_hash = hashURL(page_url);
		synchronized (dbMutex)
		{
			return db.execute(`
				select exists (
					select moz_icons.*
					from moz_pages_w_icons, moz_icons_to_pages, moz_icons
					where
						moz_pages_w_icons.page_url_hash = ?
						and moz_pages_w_icons.page_url = ?
						and moz_pages_w_icons.id = moz_icons_to_pages.page_id
						and moz_icons_to_pages.icon_id = moz_icons.id
				)`,
				page_url_hash,
				page_url,
			).oneValue!bool;
		}
	}
	
	bool pageHasAnyIcon(string page_url, ulong page_url_hash = 0)
	{
		return pageHasDirectIcon(page_url, page_url_hash) || pageHasRootIcon(page_url);
	}
	
	immutable size_t bookmarksToProcess = forceReload ? total_bookmarks : bookmarks_without_any_icons;
	shared size_t bookmarksProcessed = 0;
	
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
				printProgressBar(terminal, bookmarksProcessed, bookmarksToProcess);
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
				printProgressBar(terminal, bookmarksProcessed, bookmarksToProcess);
			}
			else if (verboseOutput)
				std.stdio.writefln(f, args);
		}
	}
	
	//db.setTraceCallback(
	//	(string sql) {
	//		try
	//			writeflnWithProgress("SQLite Trace: %s", sql);
	//		catch (Exception) { }
	//	}
	//);
	
	//if (readln)
	//	return 0;
	
	TaskPool taskPool = new TaskPool(jobCount);
	taskPool.isDaemon = true;
	auto clients = taskPool.workerLocalStorage(
		() {
			HttpClient client = new HttpClient();
			client.userAgent = userAgent;
			client.defaultTimeout = 5.seconds;
			return client;
		} ()
	);
	
	void processBookmark(Place place)
	{
		if (volatileLoad(&interrupted) > 0)
		{
			taskPool.stop();
			return;
		}
		
		Appender!string outBuffer = appender!string;
		scope (exit)
		{
			atomicOp!"+="(bookmarksProcessed, 1);
			
			string output = outBuffer[];
			if (output.length > 0)
				writelnWithProgress(output);
		}
		
		enum indentation = "    ";
		
		void writeIndented(Args...)(int level, Args args)
		{
			for (int i = 0; i < level; i++)
				outBuffer ~= indentation;
			foreach (arg; args)
				outBuffer ~= arg.to!string;
		}
		
		void writelnIndented(Args...)(int level, Args args)
		{
			writeIndented(level, args, '\n');
		}
		
		void writefIndented(Args...)(int level, in string fmt, Args args)
		{
			writeIndented(level, format(fmt, args));
		}
		
		void writeflnIndented(Args...)(int level, in string fmt, Args args)
		{
			writelnIndented(level, format(fmt, args));
		}
		
		string url = place.url;
		Uri uri = Uri(place.url);
		
		HttpClient client = clients.get;
		scope (exit)
			client.clearCookies();
		
		HttpRequest pageRequest;
		HttpResponse pageResponse;
		
		try
		{
			pageRequest = client.navigateTo(uri);
			pageResponse = pageRequest.waitForCompletion();
		}
		catch (Exception ex)
		{
			writeflnIndented(0, "%s: %s", url, ex.msg);
			return;
		}
		
		Uri finalUri = Uri(pageRequest.finalUrl);
		
		if (uri != finalUri)
			writeflnIndented(0, "%s -> %s", url, finalUri);
		
		writeflnIndented(0, "%s: %d %s", finalUri, pageResponse.code, pageResponse.codeText);
		
		string mime = pageResponse.contentTypeMimeType;
		
		void addIconToDB(
			string icon_url, ulong fixed_icon_url_hash, long width, bool root, long moz_icons_expire_ms, const(ubyte)[] data,
			string page_url, ulong page_url_hash,
			long moz_icons_to_pages_expire_ms)
		{
			synchronized (dbMutex)
			{
				try
				{
					ResultRange icon_id_range = db.execute(`
						select moz_icons.*
						from added_icons, moz_icons
						where
							added_icons.icon_id = moz_icons.id
							and moz_icons.icon_url = ?
							and moz_icons.fixed_icon_url_hash = ?
							and moz_icons.width = ?`,
						icon_url,
						fixed_icon_url_hash,
						width,
					);
					
					long icon_id;
					
					if (!icon_id_range.empty)
					{
						icon_id = icon_id_range.front["id"].as!long;
						
						writeflnIndented(2,
							"Found Icon: id: %s icon_url: %s fixed_icon_url_hash: %s width: %s root: %s expire_ms: %s",
							icon_id,
							icon_url,
							fixed_icon_url_hash,
							width,
							icon_id_range.front["root"].as!bool,
							icon_id_range.front["expire_ms"].as!long,
						);
					}
					else
					{
						icon_id = db.execute(`
							insert into moz_icons (icon_url, fixed_icon_url_hash, width, root, expire_ms, data)
							values (?, ?, ?, ?, ?, ?)
							returning id`,
							icon_url,
							fixed_icon_url_hash,
							width,
							root,
							moz_icons_expire_ms,
							data,
						).oneValue!long;
						
						db.execute(`insert into added_icons (icon_id) values (?)`, icon_id);
						
						writeflnIndented(2,
							"Inserted Icon: id: %s icon_url: %s fixed_icon_url_hash: %s width: %s root: %s expire_ms: %s",
							icon_id,
							icon_url,
							fixed_icon_url_hash,
							width,
							root,
							moz_icons_expire_ms,
						);
					}
					
					if (!root)
					{
						ResultRange page_id_range = db.execute(`
							select added_pages_w_icons.page_id
							from added_pages_w_icons, moz_pages_w_icons
							where
								added_pages_w_icons.page_id = moz_pages_w_icons.id
								and moz_pages_w_icons.page_url = ?
								and moz_pages_w_icons.page_url_hash = ?`,
							page_url,
							page_url_hash,
						);
						
						long page_id;
						
						if (!page_id_range.empty)
						{
							page_id = page_id_range.oneValue!long;
							
							writeflnIndented(2,
								"Found Page: id: %s page_url: %s page_url_hash: %s",
								page_id,
								page_url,
								page_url_hash,
							);
						}
						else
						{
							page_id = db.execute(`
								insert into moz_pages_w_icons (page_url, page_url_hash)
								values (?, ?)
								returning id`,
								page_url,
								page_url_hash,
							).oneValue!long;
							
							db.execute(`insert into added_pages_w_icons (page_id) values (?)`, page_id);
							
							writeflnIndented(2,
								"Inserted Page: id: %s page_url: %s page_url_hash: %s",
								page_id,
								page_url,
								page_url_hash,
							);
						}
						
						ResultRange moz_icons_to_pages_range = db.execute(`
							select *
							from moz_icons_to_pages
							where
								page_id = ?
								and icon_id = ?`,
							page_id,
							icon_id,
						);
						
						if (!moz_icons_to_pages_range.empty)
						{
							writeflnIndented(2,
								"Found Icon-to-Page: page_id: %s icon_id: %s expire_ms: %s",
								page_id,
								icon_id,
								moz_icons_to_pages_range.front["expire_ms"].as!long,
							);
						}
						else
						{
							db.execute(`
								insert into moz_icons_to_pages (page_id, icon_id, expire_ms)
								values (?, ?, ?)`,
								page_id,
								icon_id,
								moz_icons_to_pages_expire_ms,
							);
							
							writeflnIndented(2,
								"Inserted Icon-to-Page: page_id: %s icon_id: %s",
								page_id,
								icon_id,
							);
						}
					}
				}
				catch (Exception ex)
				{
					writeflnIndented(2, "%s", ex.msg);
				}
			}
		}
		
		bool checkRoot = true;
		
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
			long pageExpireMS = pageExpire.toUnixTime!long * 1000;
			
			Element[] directIconLinks = doc.querySelectorAll("link[rel~=icon]");
			
			foreach (directIconLink; directIconLinks)
			{
				string href = directIconLink.attrs.get("href");
				
				Uri absoluteIconURI = Uri(href).basedOn(finalUri);
				string absoluteIconURL = absoluteIconURI.toString;
				string fixedAbsoluteIconURL = fixupURL(absoluteIconURL);
				ulong fixedAbsoluteIconURLHash = hashURL(fixedAbsoluteIconURL);
				
				bool isRoot = absoluteIconURL == Uri("/favicon.ico").basedOn(finalUri);
				
				if (isRoot)
					checkRoot = false;
				
				HttpRequest iconRequest;
				HttpResponse iconResponse;
				try
				{
					iconRequest = client.navigateTo(absoluteIconURI);
					iconResponse = iconRequest.waitForCompletion();
				}
				catch (Exception ex)
				{
					writeflnIndented(1, "%s: %s", directIconLink, ex.msg);
					continue;
				}
				
				writeflnIndented(1, "%s: %d %s", directIconLink, iconResponse.code, iconResponse.codeText);
				
				if (!iconResponse.wasSuccessful)
					continue;
				
				string iconMime = iconResponse.contentTypeMimeType;
				
				SysTime iconExpire = calculateExpirationOfResponse(iconResponse);
				long iconExpireMS = iconExpire.toUnixTime!long * 1000;
				switch (iconMime)
				{
					case "image/vnd.microsoft.icon":
					case "image/x-icon":
						try
						{
							MemoryImage[] icons = loadIcoFromMemory(iconResponse.content);
							foreach (i, icon; icons)
							{
								if (icon is null)
								{
									writeflnIndented(2, "Failed to read icon [%d]", i);
									continue;
								}
								ubyte[] png = writePngToMemory(icon);
								addIconToDB(
									absoluteIconURL, fixedAbsoluteIconURLHash, icon.width, isRoot, iconExpireMS, png,
									url, place.url_hash,
									pageExpireMS,
								);
								checkRoot = false;
							}
						}
						catch (Exception ex)
						{
							writeflnIndented(2, "Failed to read icon: %s", ex.msg);
						}
						break;
					case "image/png":
						try
						{
							MemoryImage image = readPngFromBytes(iconResponse.content);
							if (image is null)
							{
								writeflnIndented(2, "Failed to read png image");
								continue;
							}
							ubyte[] png = writePngToMemory(image);
							addIconToDB(
								absoluteIconURL, fixedAbsoluteIconURLHash, image.width, isRoot, iconExpireMS, png,
								url, place.url_hash,
								pageExpireMS,
							);
							checkRoot = false;
						}
						catch (Exception ex)
						{
							writeflnIndented(2, "Failed to read png image: %s", ex.msg);
						}
						break;
					case "image/jpeg":
						try
						{
							MemoryImage image = readJpegFromMemory(iconResponse.content);
							if (image is null)
							{
								writeflnIndented(2, "Failed to read jpeg image");
								continue;
							}
							ubyte[] png = writePngToMemory(image);
							addIconToDB(
								absoluteIconURL, fixedAbsoluteIconURLHash, image.width, isRoot, iconExpireMS, png,
								url, place.url_hash,
								pageExpireMS,
							);
							checkRoot = false;
						}
						catch (Exception ex)
						{
							writeflnIndented(2, "Failed to read jpeg image: %s", ex.msg);
						}
						break;
					case "image/svg+xml":
						ubyte[] svg = iconResponse.content;
						addIconToDB(
							absoluteIconURL, fixedAbsoluteIconURLHash, ushort.max, isRoot, iconExpireMS, svg,
							url, place.url_hash,
							pageExpireMS,
						);
						checkRoot = false;
						break;
					default:
						writeflnIndented(2, "Unsupported mime type %s", iconMime);
						break;
				}
			}
		}
		
		if (!checkRoot)
			return;
		
		// Some dipshits use TLS fingerprinting to stop web scrapers
		// (e.g. cloudflare users) but sometimes it allows access
		// to /favicon.ico so we take our chances although it
		// doesn't work reliably.
		
		Uri rootFaviconURI = Uri("/favicon.ico").basedOn(uri);
		string rootFaviconURL = rootFaviconURI.toString();
		
		string fixedRootFaviconURL = fixupURL(rootFaviconURL);
		ulong fixedRootFaviconURLHash = hashURL(fixedRootFaviconURL);
		
		if (!forceReload && !iconExists(rootFaviconURL, fixedRootFaviconURLHash))
			return;
		
		HttpRequest rootFaviconRequest;
		HttpResponse rootFaviconResponse;
		try
		{
			rootFaviconRequest = client.navigateTo(rootFaviconURI);
			rootFaviconResponse = rootFaviconRequest.waitForCompletion();
		}
		catch (Exception ex)
		{
			writeflnIndented(1, "(root) %s: %s", rootFaviconURL, ex.msg);
			return;
		}
		
		writeflnIndented(1, "(root) %s: %d %s", rootFaviconURL, rootFaviconResponse.code, rootFaviconResponse.codeText);
		
		if (!rootFaviconResponse.wasSuccessful)
			return;
		
		SysTime iconExpire = calculateExpirationOfResponse(rootFaviconResponse);
		long iconExpireMS = iconExpire.toUnixTime!long * 1000;
		
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
							writeflnIndented(2, "Failed to read icon [%d]", i);
							continue;
						}
						ubyte[] png = writePngToMemory(icon);
						addIconToDB(
							rootFaviconURL, fixedRootFaviconURLHash, icon.width, true, iconExpireMS, png,
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
					else
						writeflnIndented(2, "Failed to read icon: %s", ex.msg);
				}
				break;
			case "image/png":
				try
				{
					MemoryImage image = readPngFromBytes(rootFaviconResponse.content);
					if (image is null)
					{
						writeflnIndented(2, "Failed to read png image");
					}
					ubyte[] png = writePngToMemory(image);
					addIconToDB(
						rootFaviconURL, fixedRootFaviconURLHash, image.width, true, iconExpireMS, png,
						null, 0,
						0,
					);
				}
				catch (Exception ex)
				{
					writeflnIndented(2, "Failed to read png image: %s", ex.msg);
				}
				break;
			case "text/html":
			case "application/xhtml+xml":
				// Some websites redirect to their home page instead of giving you 404
				break;
			default:
				writeflnIndented(2, "Unexpected mimetype %s", iconMime);
				break;
		}
	}
	
	ResultRange bookmarks = forceReload ?
		db.execute(`select id, url, url_hash from bookmarks`) :
		db.execute(`select id, url, url_hash from bookmarks_without_any_icons`);
	
	foreach (bookmark; bookmarks)
	{
		if (volatileLoad(&interrupted) > 0)
		{
			taskPool.stop();
			break;
		}
		
		Place place = Place(
			bookmark["id"].as!long,
			bookmark["url"].as!string,
			bookmark["url_hash"].as!ulong,
		);
		taskPool.put(task(&processBookmark, place));
	}
	
	taskPool.finish(true);
	
	synchronized (terminalMutex)
	{
		terminal.writeln();
		terminal.flush();
	}
	
	return 0;
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
					return SysTime.fromUnixTime(time.toUnixTime!long + maxAge - age);
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
	
	// Not sure but it seems like Firefox defaults to 7 days if there is no cache info
	return time + 7.days;
}

string findAvailableFilename(const(char)[] folder, const(char)[] name, const(char)[] extension, size_t limit = 256)
{
	for (size_t i = 1; i <= limit; i++)
	{
		string filename = buildPath(folder, text(name, '-', i, extension));
		if (!exists(filename))
			return filename;
	}
	return buildPath(folder, text(name, '-', 256, extension));
}

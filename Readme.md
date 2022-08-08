<div align="center">

![Firemark Icon](icon.svg)  
Firemark  
![Platforms](https://img.shields.io/badge/platform-windows%20%7C%20linux-blue) ![Latest Release](https://img.shields.io/github/v/release/ahmetsait/firemark) ![Downloads](https://img.shields.io/github/downloads/ahmetsait/firemark/total) [![License](https://img.shields.io/github/license/ahmetsait/firemark)](LICENSE.txt)
========
</div>

Firemark is a command line program for downloading missing Firefox bookmark icons. It works by retrieving bookmarks from the given `places.sqlite` file and downloads missing favicons into the given `favicons.sqlite` file.

**Backup your `*.sqlite` files before modifying them with Firemark.**

Firemark can also be used as a helper utility for extracting favicon links from a given URL as an alternative to various online favicon retrieval services. See the `--extract` [option](#documentation).

Downloads
---------
Prebuilt binaries can be found in [Releases](https://github.com/ahmetsait/firemark/releases) section.

Getting Started
---------------
Navigate to `about:support` in Firefox and copy the path from `Profile Directory` section and replace with `<Profile-Directory>` in the commands below. Press `Ctrl+C` to stop Firemark, it might take quite a while if it's waiting for a nonresponding server. You can press `Ctrl+C` 3 times to immediately shut it down.

**Close all Firefox instances before using Firemark on the current `*.sqlite` files (files in the active profile directory).**

### Windows
```batch
@REM Backup favicons.sqlite
xcopy "<Profile-Directory>\favicons.sqlite" "<Profile-Directory>\favicons-backup.sqlite"
.\firemark.exe --verbose --places "<Profile-Directory>\places.sqlite" --favicons "<Profile-Directory>\favicons.sqlite"
```

### Linux
```bash
# Backup favicons.sqlite
cp "<Profile-Directory>/favicons.sqlite" "<Profile-Directory>/favicons-backup.sqlite"
./firemark --verbose --places "<Profile-Directory>/places.sqlite" --favicons "<Profile-Directory>/favicons.sqlite"
```

Documentation
-------------
### Usage
`firemark [options] -f path/to/favicons.sqlite -p path/to/places.sqlite`  
Downloads missing Firefox bookmark icons into 'favicons.sqlite'.

`firemark [options] -x https://example.com`  
Extract favicon URLs from web page with `link[rel~=icon]` selector to standard output.

### Options
- `-f` `--favicons`  
  Path to `favicons.sqlite` file.
- `-p` `--places`  
  Path to `places.sqlite` file.
- `-j` `--jobs`  
  Number of concurrent jobs. Use it to speed up downloading process if you have too many bookmarks.  
  Anything more than `-j 3` is not recommended since servers might block you out because of rate limiting.
- `-x` `--extract`  
  Extract favicon URLs from web page with `link[rel~=icon]` selector to standard output and exit.
- `-v` `--verbose`  
  Print diagnostic messages.
- `--version`  
  Output version information and exit.
- `--help`  
  Show this help information and exit.

Known Issues
------------
- Firemark inserts the duplicate pages into moz_pages_w_icons table.
- Some URLs takes too long to timeout if the server does not respond.
- Firemark might run out of file descriptors because of too many open connections.
- Firemark inserts wrong `expire_ms` when there is no relevant info in response headers.

See [Issues](https://github.com/ahmetsait/firemark/issues) for bug reports.

Building
--------
You don't strictly need a specific compiler but those listed in Prerequisites are the ones used in build scripts.
Check out the `build.sh` & `build.ps1` files to learn more and tweak as you like.
On Windows, you can also link against `sqlite3.lib` import library instead of the object file directly. In this case the compiled executable will depend on `sqlite3.dll`. See: [How to generate an import library (LIB-file) from a DLL?](https://stackoverflow.com/questions/9946322/how-to-generate-an-import-library-lib-file-from-a-dll).

### Windows
Prerequisites:
- Microsoft Visual C Compiler `cl`
- Digital Mars D Compiler `dmd`

From PowerShell:
```powershell
pushd sqlite3
.\build.ps1
popd
.\build.ps1
```
If you're getting "running scripts is disabled on this system" errors, execute the following:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force
```
See [About Execution Policies](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies) for more information.

### Linux
Prerequisites:
- GNU Compiler Collection `gcc`
- Digital Mars D Compiler `dmd`

From Bash:
```bash
pushd sqlite3 && ./build.sh && popd && ./build.sh
```

License
-------
Firemark is licensed under the [Mozilla Public License 2.0](LICENSE.txt).

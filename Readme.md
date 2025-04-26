<div align="center">

![Firemark Icon](icon.svg)  
Firemark  
[![Platforms](https://img.shields.io/badge/platforms-windows%20%7C%20linux-blue)](https://github.com/ahmetsait/firemark/releases) [![Latest Release](https://img.shields.io/github/v/release/ahmetsait/firemark)](https://github.com/ahmetsait/firemark/releases/latest) [![Downloads](https://img.shields.io/github/downloads/ahmetsait/firemark/total)](https://github.com/ahmetsait/firemark/releases) [![License](https://img.shields.io/github/license/ahmetsait/firemark)](LICENSE.txt) [![Sponsor](https://img.shields.io/badge/Sponsor-black?logo=githubsponsors)](https://github.com/sponsors/ahmetsait)
========
</div>

Firemark is a command line program for downloading missing Firefox bookmark icons. It reads `places.sqlite` from the given profile directory and downloads missing favicons into `favicons.sqlite` in the same folder.

Firemark can also be used as a helper utility for extracting favicon links from a given URL as an alternative to various online favicon retrieval services. See the [`--extract` option](#documentation).

Downloads
---------
Prebuilt binaries can be found in [Releases](https://github.com/ahmetsait/firemark/releases) section.

Getting Started
---------------
Navigate to `about:profiles` in Firefox and copy the `Root Directory` path from your default profile and replace `<Profile-Directory>` with it in the commands below. Press `Ctrl+C` to stop Firemark before it completes. You can also press `Ctrl+C` 3 times to immediately shut it down in case Firemark takes too long to respond.

**Close all Firefox instances before using Firemark on your profile directory.**

### Windows
```batch
.\firemark.exe --verbose --profile "<Profile-Directory>"
```

### Linux
```bash
./firemark --verbose --profile "<Profile-Directory>"
```

Documentation
-------------
### Usage
`firemark [options] --profile path/to/profile-folder`  
Downloads missing Firefox bookmark icons.

`firemark [options] --extract https://example.com`  
Extract favicon URLs from web page with [`link[rel~=icon]` selector](https://developer.mozilla.org/en-US/docs/Web/CSS/Attribute_selectors) to standard output.

### Options
- `-p`, `--profile=PATH`  
  Path to profile folder where `favicons.sqlite` and `places.sqlite` exists.
- `-b`, `--backup`  
  Backup `favicons.sqlite`. (Default)
- `-B`, `--no-backup`  
  Don't backup `favicons.sqlite`.
- `-e`, `--erase`  
  Erase favicon table before proceeding.
- `-f`, `--force`  
  Force downloading icons for all bookmarks instead of just missing ones.
- `-j`, `--jobs=N`  
  Number of concurrent jobs. Use it to speed up downloading favicons if you have too many bookmarks.  
  Anything more than `-j 5` is not recommended since servers might block you out because of rate limiting.
- `-x`, `--extract=URL`  
  Extract favicon URLs from web page with [`link[rel~=icon]` selector](https://developer.mozilla.org/en-US/docs/Web/CSS/Attribute_selectors) to standard output and exit.  
  This also includes the root `/favicon.ico` for convenience.
- `-v`, `--verbose`  
  Print diagnostic messages.
- `--version`  
  Output version information and exit.
- `--help`  
  Show this help information and exit.

Known Issues
------------
- Firemark inserts duplicate pages into `moz_pages_w_icons` table.
- Apparently some `icon_url` columns in `moz_icons` table end up with incomplete URLs such as `/favicon.ico`, `/assets/favicons/favicon.ico` or `/static/assets/favicon.ico?v=2`.

See [Issues](https://github.com/ahmetsait/firemark/issues) for bug reports.

Building
--------
You don't strictly need a specific compiler but those listed in Prerequisites are the ones used in build scripts.
Check out the `build.sh` & `build.ps1` files to learn more and tweak as you like.
On Windows, you can also link against `sqlite3.lib` import library instead of the object file directly. In this case the compiled executable will depend on `sqlite3.dll`. See: [How to generate an import library (LIB-file) from a DLL?](https://stackoverflow.com/questions/9946322/how-to-generate-an-import-library-lib-file-from-a-dll)

### Windows
Prerequisites:
- Microsoft Visual C Compiler `cl`
- Digital Mars D Compiler `dmd`

From PowerShell:
```powershell
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
./build.sh
```

License
-------
Firemark is licensed under the [Mozilla Public License 2.0](LICENSE.txt).

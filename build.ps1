pushd sqlite3
.\build.ps1
if ($LastExitCode -ne 0) {
	exit 1
}
popd

$config = "debug"
$platform = "windows"
$arch = "x86_64"

$sourceDir = "src"
$mainSource = "$sourceDir\firemark\app.d"
$outputDir = "bin\$config-$platform-$arch"
$outputFile = "$outputDir\firemark.exe"
$libDir = "lib\$config-$platform-$arch"

$outdated = $false

if (Test-Path -Path $outputFile -PathType Leaf) {
	$outputFile = Get-Item -Path $outputFile
	$thisPath = Get-Item -Path $MyInvocation.MyCommand.Path
	if ($thisPath.LastWriteTime -gt $outputFile.LastWriteTime) {
		$outdated = $true
	}
	else {
		$files = Get-ChildItem -Recurse -Path $sourceDir
		foreach ($file in $files) {
			if ($file.LastWriteTime -gt $outputFile.LastWriteTime) {
				$outdated = $true
				break
			}
		}
	}
}
else {
	$outdated = $true
}

if ($outdated) {
	dmd -i -g -debug -m64 -w -vcolumns -preview=dip1000 -preview=dip1008 -preview=fieldwise -preview=fixAliasThis -preview=rvaluerefparam -preview=inclusiveincontracts (Get-ChildItem "$libDir" -Filter "*.lib").FullName "sqlite3\sqlite3.obj" -J"$sourceDir" -I"$sourceDir" "$mainSource" -of"$outputFile"
	Copy-Item (Get-ChildItem "$libDir" -Filter "*.dll").FullName -Destination "$outputDir"
}

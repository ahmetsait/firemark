# Should probably use this to get VS path at some point: https://stackoverflow.com/a/65869986/3624513
#Get-ChildItem HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall | foreach { Get-ItemProperty $_.PsPath } | where { $_.DisplayName -like '*Visual Studio*' -and $_.InstallLocation.Length -gt 0 } | sort InstallDate -Descending | foreach { (Join-Path $_.InstallLocation 'Common7\IDE') } | where { Test-Path $_ } | select -First 1

$cl = "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Tools\MSVC\14.29.30133\bin\Hostx64\x64\cl.exe"

$mainSource = "sqlite3.c"
$outputFile = "sqlite3.obj"

$outdated = $false

if (Test-Path -Path $outputFile -PathType Leaf) {
	$outputFile = Get-Item -Path $outputFile
	$thisPath = Get-Item -Path $MyInvocation.MyCommand.Path
	if ($thisPath.LastWriteTime -gt $outputFile.LastWriteTime) {
		$outdated = $true
	}
	else {
		$file = Get-Item -Path $mainSource
		if ($file.LastWriteTime -gt $outputFile.LastWriteTime) {
			$outdated = $true
			break
		}
	}
}
else {
	$outdated = $true
}

if ($outdated) {
	& $cl /c "$mainSource" -o "$outputFile"
}

# https://stackoverflow.com/a/65869986/3624513
$VS_INSTALL_DIR = Get-ChildItem HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall | foreach { Get-ItemProperty $_.PsPath } | where { $_.DisplayName -like '*Visual Studio*' -and $_.InstallLocation.Length -gt 0 } | sort InstallDate -Descending | foreach { $_.InstallLocation } | where { Test-Path $_ } | select -First 1

# https://stackoverflow.com/a/2124759
pushd "$VS_INSTALL_DIR\VC\Auxiliary\Build"
cmd /c "vcvars64.bat&set" |
foreach {
	if ($_ -match "=") {
		$v = $_.split("="); set-item -force -path "ENV:\$($v[0])" -value "$($v[1])"
	}
}
popd

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
	cl /c "$mainSource" /Fo:"$outputFile"
}

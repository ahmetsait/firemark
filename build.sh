#!/usr/bin/env bash

config="debug"
platform="linux"
arch="x86_64"

sourceDir="src"
mainSource="$sourceDir/firemark/app.d"
outputDir="bin/$config-$platform-$arch"
outputFile="$outputDir/firemark"

outdated=false

if [[ -f $outputFile ]]; then
	if [[ "${BASH_SOURCE[0]}" -nt "$outputFile" ]]; then
		outdated=true
	else
		readarray -d '' files < <(find "$sourceDir" -print0)
		for file in "${files[@]}"; do
			if [[ -f "$file" && "$file" -nt "$outputFile" ]]; then
				outdated=true
				break
			fi
		done
	fi
else
	outdated=true
fi

if [[ "$outdated" == true ]]; then
	dmd -i -g -debug -m64 -preview=dip25 -preview=dip1000 -preview=dip1008 -preview=fieldwise -preview=fixAliasThis -preview=rvaluerefparam -preview=in -preview=inclusiveincontracts -preview=shortenedMethods "sqlite3/sqlite3.o" -I"$sourceDir" "$mainSource" -of"$outputFile"
fi

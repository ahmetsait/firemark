#!/usr/bin/env bash

if pushd sqlite3 > /dev/null; then
	./build.sh || exit 1 && \
	popd > /dev/null
fi

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
	dmd -i -g -debug -m64 -w -vcolumns -preview=dip1000 -preview=dip1008 -preview=fieldwise -preview=fixAliasThis -preview=rvaluerefparam -preview=inclusiveincontracts "sqlite3/sqlite3.o" -J"$sourceDir" -I"$sourceDir" "$mainSource" -of"$outputFile"
fi

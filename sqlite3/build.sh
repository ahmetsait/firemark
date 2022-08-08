#!/usr/bin/env bash

mainSource="sqlite3.c"
outputFile="sqlite3.o"

outdated=false

if [[ -f $outputFile ]]; then
	if [[ "${BASH_SOURCE[0]}" -nt "$outputFile" ]]; then
		outdated=true
	else
		if [[ -f "$mainSource" && "$mainSource" -nt "$outputFile" ]]; then
			outdated=true
		fi
	fi
else
	outdated=true
fi

if [[ "$outdated" == true ]]; then
	gcc -c "$mainSource" -o "$outputFile"
fi

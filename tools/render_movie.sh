#!/usr/bin/env bash
# Renders a demo scene to a movie and makes sure the Godot it started exits.
#
#   tools/render_movie.sh res://tools/duel_m2_demo.tscn recordings/bg3/m2_duel.avi
#
# Godot sometimes hangs in engine shutdown after the demo calls quit(), with
# the window left open. The movie is already finished by then ("Done recording
# movie" is in the log), so once that line is there and the process has had
# a few seconds, this kills the process it started - only that one.
set -u
scene="$1"; movie="$2"; log="${movie%.*}.log"
godot="${GODOT:-/d/PortablePrograms/Godot_v4.4.1-stable_win64.exe/Godot_v4.4.1-stable_win64_console.exe}"
"$godot" --resolution 1600x900 --write-movie "$movie" --fixed-fps 30 "$scene" > "$log" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
	if grep -aq "Done recording movie" "$log"; then
		sleep 8
		if kill -0 "$pid" 2>/dev/null; then
			echo "render_movie: Godot $pid still open after the movie finished; closing it"
			kill "$pid"
		fi
		break
	fi
	sleep 2
done
wait "$pid" 2>/dev/null
echo "render_movie: log in $log"

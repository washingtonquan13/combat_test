#!/bin/bash
# Renders a sheet through a running live lab (anim_lab.gd --watch), starting
# one if none answers. Arguments are the lab's, without the dashes:
#
#   bash tools/anim_lab/live.sh out=C:/path/sheet.png \
#     keys=res://tools/anim_lab/rifle_blocking.gd set=stance times=0 views=front,side
#
# LAB_DIR holds the request file and the lab's log; GODOT is the editor binary.
GODOT=${GODOT:-/d/PortablePrograms/Godot_v4.4.1-stable_win64.exe/Godot_v4.4.1-stable_win64_console.exe}
LAB_DIR=${LAB_DIR:-${TMP:-/tmp}/anim_lab_live}
mkdir -p "$LAB_DIR"
REQ="$LAB_DIR/request.json"
REQ_WIN=$(cygpath -m "$REQ" 2>/dev/null || echo "$REQ")
json="{"
out=""
for a in "$@"; do
	k=${a%%=*}; v=${a#*=}
	[ "$k" = "$a" ] && v=""
	[ "$k" = "out" ] && out=$v
	json+="\"$k\":\"$v\","
done
json="${json%,}}"
if ! grep -q "watching" "$LAB_DIR/lab.log" 2>/dev/null || ! kill -0 "$(cat "$LAB_DIR/lab.pid" 2>/dev/null)" 2>/dev/null; then
	rm -f "$LAB_DIR/lab.log"
	"$GODOT" --path . --rendering-driver opengl3 --resolution 560x560 \
		res://tools/anim_lab/anim_lab.tscn -- --watch="$REQ_WIN" > "$LAB_DIR/lab.log" 2>&1 &
	echo $! > "$LAB_DIR/lab.pid"
	for _ in $(seq 600); do grep -q "watching" "$LAB_DIR/lab.log" 2>/dev/null && break; sleep 0.1; done
fi
rm -f "$out.done"
# The lab sees a change by modified time, to the second.
sleep 1
echo "$json" > "$REQ"
for _ in $(seq 1200); do [ -f "$out.done" ] && break; sleep 0.1; done
grep -E "^(SCRIPT ERROR|ERROR: .*Parse)" "$LAB_DIR/lab.log" | tail -5
echo "live lab: $(cat "$out.done" 2>/dev/null || echo timeout) $out"

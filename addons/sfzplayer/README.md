# SFZ Player

Scored, adaptive game music for Godot 4.4, played live through SFZ
instruments by [sfizz](https://sfz.tools/sfizz). A piece is written once as a
score for a set of parts (a lead, a choir, a bass, a kit), each of a family;
an ensemble decides what each part sounds like, out of a registry of
instruments; a transitions table decides how the music moves from one area of
the game to the next, on the beat.

This page is for wiring it into a game. For writing the music itself (the
score format, loops and stings, rendering and MIDI export), see
[COMPOSING.md](COMPOSING.md).

## Installing

1. Copy `addons/sfzplayer/` into your project, with the extension built into
   `addons/sfzplayer/bin/` (see "Building" in the repository README).
2. Project > Project Settings > Plugins: enable **SFZ Player**. This adds the
   director as an autoload called `Music` and puts the paths below under
   Project Settings > sfzplayer.

The classes (`SfzMusicDirector`, `SfzEnsemble`, `SfzScorePlayer`, ...) are global
whether or not the plugin is enabled; the plugin only adds the autoload and
the settings UI.

## Where your music lives

| Setting                       | Default                        | Holds |
|-------------------------------|--------------------------------|-------|
| `sfzplayer/paths/samples`     | `res://samples`                | SFZ files and their samples; the registry's `"sfz"` paths are relative to it |
| `sfzplayer/paths/registry`    | `res://registry`               | `<library>.json`, one per sample library: its instruments, once, for every ensemble |
| `sfzplayer/paths/ensembles`       | `res://ensembles`                  | `<id>.json` ensemble manifests (a "ensemble" in the API and in `ensemble:`) |
| `sfzplayer/paths/scores`      | `res://scores`                 | `<id>.score` scores, stings included |
| `sfzplayer/paths/transitions` | `res://music/transitions.json` | areas and the rules between them |
| `sfzplayer/audio/bus`         | `Music`                        | the bus all the music ends up on, sending to Master; the master chain (EQ, glue, limiter) goes on it, and volume, ducking and pausing act on it |
| `sfzplayer/memory/preload_scale` | `1.0`                       | how much of the head of every sample is held in memory, against what the ensembles ask for; the rest streams from disk |

Every setting takes a feature-tag override, so a platform can differ:
`sfzplayer/memory/preload_scale.mobile = 0.25` quarters the resident sample
memory on phones and leaves desktops alone.

Put an empty `.gdignore` in the samples folder. sfizz reads the samples from
disk itself, and without it the editor imports every one of them as an
`AudioStreamWAV` - gigabytes of import cache that nothing loads, and an
export that would carry them all.

## Driving it from a game

```gdscript
Music.preload_area("battle")     # optional: load the next ensemble ahead of time
await Music.go_to("field")       # leaves the current piece by the table's rule
await Music.go_to("battle", true) # urgent: the shortest exit the rule allows
Music.silence()
```

The rest of what a game does to its music, without changing it:

```gdscript
Music.volume_db = linear_to_db(settings.music_volume)   # options menu
Music.duck(-10.0)          # under dialogue; Music.unduck() after
Music.set_intensity(2)     # layer:2 lanes join on the next bar ("beat", "section", "now")
Music.pause()              # every clock stops mid-note; Music.resume()
save["music"] = Music.state()        # plain, JSON-safe data
await Music.restore(save["music"])   # the same area, back at its bar
```

The director keeps playing while the scene tree is paused - a pause menu
usually wants its music. `pause()` stops it; setting `Music.process_mode` to
`PROCESS_MODE_INHERIT` ties it to the tree instead.

`go_to` returns once the new piece is playing. Reading the score, the sting
and the ensemble manifest, loading the ensemble and compiling the score all run off
the game thread, so it can be awaited or just called and left. After
`preload_area`, the area's score and stings are already parsed as well.
`area_changed` and `transition_finished` are emitted along the way, and
`last_handoff()` says how the last one was made.

Mid-transition, `go_to` waits its turn rather than failing: when the
transition under way lands, the latest request made during it goes, and any
earlier one still waiting returns `false`. A waiting request for the area
that is playing by then returns `true` and does nothing. `silence()` waits
the same way and cancels what was waiting.

A transitions table:

```json
{
	"areas": {
		"field": { "ensemble": "wayfarer", "score": "long-time-way" },
		"battle": { "ensemble": "band", "score": "low-end" }
	},
	"rules": [
		{ "from": "*", "to": "*", "exit": "section", "fade": 2.5 },
		{ "from": "*", "to": "battle", "exit": "bar", "fade": 0.8, "urgent": true,
		  "max_wait": 2.0, "sting": "battle-sting" },
		{ "from": "battle", "to": "*", "exit": "section", "outro": true }
	]
}
```

`exit` is `pass`, `section`, `bar`, `beat` or `now`; the most specific rule
wins. `"pick_up": true` on a rule brings an area the player has
been to back in at the bar it was left at - the field after a battle -
rather than from the top. The repository README ("Handing over on the beat") explains each field.

## Musical time, and building your own behaviour

The director is one way to use the engine, built on public calls. Those calls
are open to a game too:

```gdscript
var player := Music.foreground()          # an SfzScorePlayer
var conductor := Music.conductor()        # its SfzConductor
# The next bar, in seconds from the top ("beat", "section", "section:boss", "end").
# INF when there is none; it follows the loop's passes and, once decided, the outro.
var bar := player.next_boundary("bar")
# The game time (Time.get_ticks_usec() / 1e6) at which that bar is heard.
var heard_at := conductor.heard(player.origin() + bar)
player.leave_loop("section:boss")         # leave where the boss section next comes round
player.play_at(sting, at, 0.0, false)     # false: leave the bus's loudness trim alone
conductor.hit("perc", "crash", 110, conductor.now() + conductor.lead(), true)  # exact: no take variation
```

`position()` reads the dispatch clock. It runs about one output latency ahead
of what is heard, so use `heard()` to put something on screen with the music.
An unknown way out, landing or boundary kind is an error: the call returns
-1 (`NAN` for `next_boundary`) and nothing changes. `runtime/marks.gd`
(`SfzMarks`) is a short reference script that turns these two calls into bar,
section and end signals. Copy it and change it rather than depending on it.

## Shipping a game

sfizz opens sample files by their path on disk, and in an exported game
`res://` is the `.pck`, which it cannot read. So the samples ship as a
folder beside the game:

- A `res://` samples path (the default) is looked for next to the
  executable once exported - `MyGame.exe` and `samples/` side by side - or,
  on macOS, in the bundle's `Contents/Resources/samples/`. Copy the folder
  there as part of the build; only the libraries your ensembles use are needed.
- An absolute path or a `user://` one is used as it is, for a game that
  downloads its samples after install.

Ensembles, the registry, scores and the transitions table are read from `res://` as usual and
travel in the `.pck`, but `.score` is not a type Godot knows: add `*.score`
(and `*.json` if your preset does not export it) to the export preset's
"Filters to export non-resource files".

What loading costs: an ensemble's layers parse at once, off the game thread,
and each layer's time is sfizz reading its SFZ and opening every sample it
names - about 0.8 s for a 14,000-region guitar library on this machine with
the files cached (2.9 s when they were not), a fraction of a second for most.
Call `Music.preload_area()` behind a loading screen or while the previous area
plays; `scripts/load_test.gd` measures an ensemble.

What it holds: the preload, and nothing else of note. The demo's largest
ensemble (twelve layers, two of them a 14,000-region guitar) holds 241 MB at
`preload_scale` 1.0, 121 MB at 0.5 and 30 MB at 0.125. Before the sfizz load
patches it loaded in the same ~15 s at every scale; the scale's effect on load
time has not been measured since. None of those scales cut a note short on an
SSD. The floor is 1,024 frames per sample; below a few hundred, most notes end
early. If notes cut out on a slow disk,
`SfzInstrument.get_starved_voices()` counts them - raise the scale until it
stays at zero. A reasonable start: 1.0 on desktop, 0.25 on mobile.

## Licences

The extension links sfizz and godot-cpp and what they carry;
`THIRD_PARTY_LICENSES.txt` has their terms and ships with the binary.
Sample libraries are yours to choose and license.

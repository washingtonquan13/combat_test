# Writing music for SFZ Player

This is the guide for the person writing the music: how a piece is laid out,
how to hear it while you work, and how to get it in and out of a DAW. For
wiring the music into a game, see `README.md` beside this file.

## The model in one paragraph

A piece is a **score**: a text file that says what the music does, in beats
and bars, written for **parts** it declares itself - a `lead`, a `high` choir
line, a `bass`, a kit. Each part is of a **family** (`lead`, `choir`,
`strings`...). A score never names an instrument, a sample or a MIDI CC. An
**ensemble** (`ensembles/<id>.json`, still called an ensemble in `ensemble:` and in the
API) decides what each part sounds like, out of a **registry** of instruments
(`registry/<library>.json`), so the same score can be played by an orchestra
in one area and a synth band in another: a part the ensemble has by name plays
that, and one it lacks plays the ensemble's part of the same family, and says
so. The engine does not play the score note for note. A
**performance compiler** reads it the way a player reads a part: dynamics
become curves, `feel:loose` puts the drummer behind the beat, a slur is held
into the next note. You write what you mean and it does the playing.

## A first score

Save this as `scores/first.score`, in the folder that
`sfzplayer/paths/scores` points at:

```
// comments are //, because # is a sharp
title: First
ensemble: band
parts: lead bass pad perc
tempo: 120
meter: 4/4
key: a minor
order: intro [verse chorus] end

section intro bars:2
  pad dyn:p..mf
    | [a3 c4 e4]:8 |

section verse bars:4
  lead dyn:mf vib:warm
    | a4:1.5 c5:0.5 e5:2~ | d5:4 |
    | c5:1 b4:1 a4:1 g4:1 | a4:4^ |
  bass dyn:mf feel:tight
    | a2:0.5' a2:0.5' r:1 a2:1 g2:1 | f2:4 |
    | e2:2 g2:2 | a2:4 |
  perc.feet dyn:mf
    | kick:2 kick:2 | kick:2 kick:2 | kick:2 kick:2 | kick:2 kick:1 kick:1 |
  perc.hands dyn:mp feel:loose
    | r:1 snare:1 r:1 snare:1 | r:1 snare:1 r:1 snare:1 |
    | r:1 snare:1 r:1 snare:1 | r:1 snare:1 snare:0.5 snare:0.5 snare:1! |

section chorus bars:4 from:verse
  lead dyn:f
    | e5:2 d5:1 c5:1 | b4:4 | c5:2 b4:1 g4:1 | a4:4 |

section end bars:2
  pad dyn:mf..pp
    | [a3 c4 e4]:8 |
```

Render it (next section) and you hear it. The chorus is the verse again with a
new lead line: `from:verse` copies every lane and the `lead` written
underneath replaces the copied one.

## Syntax

### Headers

| Header | Example | |
| --- | --- | --- |
| `title:` | `title: Low End` | shown in logs and MIDI exports |
| `ensemble:` | `ensemble: band` | the ensemble it is played on unless something says otherwise |
| `parts:` | `parts: lead high:choir@lead bass perc` | the parts the lanes may name; see Parts below |
| `tempo:` | `tempo: 150` | beats per minute of the meter's beat unit; a number above 0 |
| `meter:` | `meter: 6/8` | beats per bar / beat unit; the unit is 1, 2, 4, 8, 16 or 32 |
| `key:` | `key: bb major`, `key: e minor` | a note name and `minor` (the default) or `major`; for the MIDI export and the logs; notes are always written as themselves |
| `order:` | `order: intro [a b a2] end` | the order sections play in; the brackets are the loop, and there is at most one |
| `include:` | `include: grooves.score` | patterns and chords from another file; see Reuse below |

Each header is given once, with a value; only `include:` may repeat. Any
other header is an error.

### Sections

```
section NAME bars:N [tempo:X] [repeat:N] [from:OTHER]
```

- `bars:` is checked. Every lane must fill exactly that many bars, rests
  included: a lane that stops short is an error at its last line, and one
  that runs past is an error at the line that ran past. Write `r:4` for a
  bar the lane sits out.
- `tempo:` changes tempo from this section on. It is a number above 0.
- `repeat:3` plays the section three times in a row. `bars:` and `repeat:`
  are whole numbers above 0.
- Any other setting is an error.
- `from:OTHER` starts as a copy of an earlier section. A lane you write
  replaces the copied lane of the same name. A whole part (`perc`) replaces
  all of that part's copied sub-lanes (`perc.feet`, `perc.hands`), and a
  whole player replaces its co-parts' lanes too (see Parts).

### Parts

```
parts: lead high:choir@lead keys bass pad perc metal:perc@perc
```

Each entry is `NAME[:FAMILY][@PLAYER]`.

- `NAME` is the part, and what its lanes are headed with. It is letters,
  digits and `_`, starting with a letter.
- `FAMILY` is what kind of part it is: `lead`, `guitar`, `keys`, `bass`,
  `pad`, `perc`, `brass`, `choir`, `strings` or `bells`. It defaults to the
  name, so `bass` means `bass:bass`; a name that is not a family needs one
  (`melody:lead`).
- `@PLAYER` makes the part a **co-part**: played by the same performer as
  the part PLAYER, with one pocket, one drift and one set of limbs. `high`
  above is a second line the lead player sings; `metal` is more of the
  drummer. PLAYER is declared in the same header and has no `@` of its own.

A score without `parts:` has the six `lead guitar keys bass pad perc`, each
its own family and player.

**Where a part lands.** On whichever ensemble plays the score, each part is
cast once, by the first of these that finds something:

1. the ensemble's part of the same name, whatever its family;
2. the ensemble's part for the family (its `family_parts` default, else a
   part named after the family, else its first part of that family, else
   its first part of a family that falls back to it);
3. for a co-part, whatever its player landed on;
4. the same as step 2 for the family's fallback: `brass` to `guitar`,
   `choir` and `strings` to `pad`, `bells` to `keys`;
5. nothing: its notes reach no instrument.

Anything past step 1 is warned once, naming the part and where it landed
(`part 'high' (choir): not in ensemble band; plays pad (family fallback)`),
a co-part on its player's part included.

Casting is the ensemble's job and nothing else's. To have a line played by a
particular instrument, make it a part and give the ensemble a part of that
name; there is no way to pick a layer from the score.

### Lanes

A lane is a part, or a part and a sub-lane name (`perc.feet`), followed by
settings, then its bars on the following lines. A lane plays one thing at a
time, so a kick under a hi-hat needs two lanes. Sub-lane names are yours, in
letters, digits and `_`: a sub-lane is another line for the same part, like a
second hand, and plays exactly that part's instruments. A line in a section
that names an undeclared part, or is not a lane, a bar line or `section`, is
an error, and the bar lines under it are skipped.

| Setting | Values | What it does |
| --- | --- | --- |
| `dyn:` | `ppp pp p mp mf f ff fff`, or a ramp `p..f` | the level; a ramp is a curve across the section |
| `art:` | a name from the part's `keyswitches` | the articulation the lane plays throughout, e.g. `art:sustain`; see Articulations below |
| `feel:` | `tight`, `straight` (default), `loose`, `swing` | how far off the grid the player sits; `swing` pushes offbeat eighths back |
| `pocket:` | `push`, `on`, `lay`, or milliseconds (`-8`) | ahead of or behind the beat, for the whole lane |
| `vib:` | `warm`, `deep` | vibrato that opens up over held notes |
| `bend:` | `+200@0.4,+200@2,0@3.5` | a pitch shape each note follows: cents at beats from the note start |
| `rot:` | `slow`, `fast` | a rotary cabinet (organs) spinning down or up |
| `shape:` | `none`, `light`, `natural` (default), `broad` | how hard the phrases breathe |
| `layer:` | `2`, `..1`, `1..3` | an intensity layer: plays only at those levels (`2` is 2 and up) |

Any other setting, a value not in its list, or a setting with no value
(`layer:`) is an error.

Levels as velocity: ppp 16, pp 28, p 45, mp 62, mf 78, f 95, ff 110,
fff 122.

### Phrases

You do not mark them. The performance compiler finds them the way a player
reading the same page would: a phrase ends at a rest of a beat or more, after
a note much longer than the ones around it, or at a hole in the writing - and
failing all three at a four-bar group, so a line that never stops still
breathes. Each phrase is then played as an arc: under the written level going
in, over it past the middle, released into the close, leaning a few
milliseconds forward through the body and broadening at the end. A kit gets
the dynamics of that and not the timing, because the band is reading the beat
off it.

`shape:` scales the whole thing, and `shape:none` turns it off. That is not a
lapse in taste - an ostinato holding the floor of a piece wants to be a
machine, and breathing it turns the floor into a waterbed. Use `broad` on a
line that is meant to be sung and `light` on one that is meant to drive.

### Notes

A token is `HEAD[:DURATION][MARKS]`.

- **HEAD**: a note (`d4`, `f#3`, `bb2`; middle C is `c4`), a chord
  (`[d3 f3 a3]`), a rest (`r`), or a drum name (`kick`, `snare`, `hat`,
  `crash`...). `s` and `f` are sharp and flat too (`fs3`, `ef4`), a note with
  no octave is in octave 4 (`d` is `d4`), and notes run from `c-1` to `g9`.
  In a lane of a `perc` part, anything that isn't a note name is a drum, and
  the ensemble maps drum names to keys. In any other lane it is an error.
- **DURATION**: in beats, default 1. `0.5` is an eighth in 4/4, `0.25` a
  sixteenth, `0.333` a triplet eighth.
- **MARKS** can be stacked, e.g. `e2:0.25+!`:

| Mark | | Mark | |
| --- | --- | --- | --- |
| `!` | accent | `~` | slur into the next note |
| `.` | soft | `^` | swell: dips under its level, then climbs past it |
| `'` | staccato | `/` | slide into the next note |
| `_` | tenuto, full length | `\` | glide into the next note (see below) |
| `+` | muted (palm mute, stopped horn) | `<` | scoop up into this note |
| | | `>` | fall off the end |

`/` and `\` are the same join played two ways. On `/` the note leaves early
and bends toward the next one, so the next lands in tune on its own beat -
what a player does, and what you almost always want. On `\` the next note
arrives on the beat at the old note's pitch and corrects itself afterwards,
which is a mono synth's portamento. Use `\` when you want to hear the
machine doing it.

`|` is a checkpoint, not a container. It checks that the lane has reached a
barline. A note may cross it (`[a3 c4 e4]:8` holds two bars and is written
once), but a bar that adds up to 3.5 beats is an error, reported with its
line number. A lane reports its first error and no more, since a note that
failed to parse takes no time and would make every later bar look short too:

```
first.score:14: lane 'lead' reaches a bar line 3.000 beats into a bar
```

### Articulations

`art:` on a lane names the articulation it plays throughout, and some of the
marks above quietly ask for one of their own on the note they are written on.
That second half is the part that has bitten people, so it is written out
here.

A part's `keyswitches` are just names against keys, and any name a library
uses can go there. But the compiler only ever asks for these by itself:

| Asked for | when |
| --- | --- |
| `mute` | a note marked `+`; where the part has no `mute`, `staccato` instead |
| `staccato` | a note marked `'` |
| `legato` | a note the previous note slurred (`~`) into |
| `marcato` | a note marked `!` |
| `slide_up` / `slide_down` | a note reached by `/` from below or above |
| `slide_in` | a note marked `<` |
| `slide_out` | the tail a note marked `>` falls away on |

`!` taking `marcato` and `+` taking `mute` are the two that surprise people:
an accent and a palm mute read like dynamics and are also switches into
another set of samples. Note that `.` is **not** one of them. `.` is soft, a
level and nothing else, and no articulation is attached to it - if you want a
short muted note, `+` or `'` is the mark, not `.`.

Every other mark is played rather than switched, and not all in the same way.
`.` is velocity, 18 under the lane's level. `^` is a CC curve. `_` is neither:
tenuto is a gate, holding the note for more of its written length and taking
the random variation off its release, so it changes how long the note sounds
and not how loud it is. `~` is an overlap and a softer attack whether or not a
`legato` mapping exists. `!` is the busiest of them - 18 over the level, a
keyswitch, a few milliseconds early, and a wider spread if it is a chord being
strummed.

**Stacking is not adding.** Marks stack on a note, but only one of them wins
the keyswitch, and the order is fixed: muted, then staccato, then legato, then
accent. `e2:0.25+!` - the example in the marks table above - is a muted note.
It is accented in level, timing and strum, and the `!` contributes nothing as
a switch, because the `+` got there first. If you want `marcato` on a short
note, do not also write `+`.

**Falling back.** A name the part has no keyswitch for is not an error and
does not stop the note. The lane returns to its resting articulation instead:
`art:` if the lane names one, otherwise the part's `keyswitch_default`. That fallback is deliberate and it is why a plain note switches
back explicitly rather than being left alone - one `+` used to leave
everything after it muted until something else changed the switch. The same
goes for a `'` on a part with no `staccato`: the note is still cut short by
its written length, it is simply not cut short by a different sample.

A lane's own `art:` is not checked against the ensemble at all. The parser
takes whatever word you wrote, and a part with no key for it is left playing what
it was playing. A misspelled `art:susatin` is therefore silent in the log and
audible only as the wrong sound, so check the spelling against the ensemble when
a lane sounds like the instrument ignored you.

**What the ensembles here can honour.** In `band.json` and `tonewheel.json` only
`guitar` and `bass` carry keyswitches. Both declare `sustain`,
`fret_mute`, `legato`, `marcato`, `mute`, `slide_up`, `slide_down`,
`slide_in`, `slide_out`, and `sustain_up`/`sustain_alt`,
`mute_up`/`mute_alt` - the `_up` and `_alt` names are the library's
alternating pick directions, and nothing asks for them by itself; you get
them by naming one in `art:`. `guitar` adds `scratch`, `harmonic`, `pinch`,
the three `brush` names, and `fret_mute_up`/`fret_mute_alt`, which the bass
does not have. Treat that list as a pointer rather than an inventory: the
ensemble JSON is the only thing that actually decides, and it changes. `band`'s guitar and both basses rest on
`sustain_alt`; `tonewheel`'s guitar rests on `mute`, so a plain note there is
already a palm mute and `art:sustain` is what opens it up. `tonewheel`'s
`pad` has a set of its own - `choir`, `brass`, `brass_long`, `brass_short`,
resting on `choir` - which is the case `art:` is really for, since none of
the compiler's own names appear in it and nothing but an `art:` naming
`brass`, `brass_long` or `brass_short` will ever move it.

Neither ensemble gives `lead`, `keys` or `pad` (in `band`) any keyswitches,
and no `perc` part has any. On those parts every articulation name, written or
implied, does nothing at all; `+` and `'` still shorten the note and `!`
still accents it, because those parts were never keyswitches. Drums never
reach this code: a `perc` hit is emitted before articulations are considered,
so a mark on a drum is dynamics and timing only.

### Reuse: patterns, chords, `%`, `*N`, include

Sections copy with `from:` and `repeat:`. Below that, these save you writing
the same bars again. The parser writes them all out, so the player and the
MIDI export only ever see plain notes.

```
include: grooves.score            // patterns and chords from another file
chord am7 = [a3 c4 e4 g4]         // a name for a chord
pattern riff                      // bars of one lane, defined outside sections
  | d4:1 f4:1 a4:1 d5:1 | c5:2 a4:2 |

section verse bars:8
  lead
    | riff | riff+5 | % | am7:2 am7:2 | [c4 e4]:4 |
  perc
    | groove | % | % | hat:0.25*16 |
```

- **`pattern NAME`**, followed by bar lines. In a lane, `NAME` on its own plays
  the whole pattern, which can be several bars long. It must start on a
  barline and add up to whole bars. A pattern can use other patterns, but not
  itself.
- **`NAME+3`, `NAME-12`** play the pattern moved up or down by that many
  semitones. Drum hits are not moved. A pattern name takes no `:duration` or
  marks.
- **`%`** at the start of a bar plays again what was written between the last
  two barlines, at the same pitch. After a pattern, that is the pattern's last
  bar.
- **`TOKEN*N`** plays one token N times: `hat:0.5*8` is a bar of eighths.
  `riff*2` plays a pattern twice.
- **`chord NAME = [a3 c4 e4]`** (the `=` is optional). The name can go
  anywhere a `[chord]` can: `am7:2!`.
- **`include: FILE`** is a header. It takes the patterns and chords from
  another file. Its sections, headers and order are ignored. The path is
  relative to the including file, or to `res://scores` if it isn't found
  there. Included files can include others, but an include cycle is an error.
  Reaching the same file by two routes is fine.

Patterns and chords must be defined above where they are used (an include
counts as defining them). Their names can't look like notes (`c4`) and can't
contain `:`. A pattern name hides a drum of the same name, so don't call a
pattern `kick`. A name used before its pattern is defined is taken as a drum
in a `perc` lane (skipped, with a warning, if the kit has no such piece)
and is an error anywhere else. A pattern is moved by whole semitones only
(`riff+5`, `riff-2`). Errors inside a pattern are reported at the line that used
it, and also name the pattern's own line:

```
verse.score:31: lane 'lead' reaches a bar line 2.000 beats into a bar (in pattern 'riff', grooves.score:6)
```

## Writing for a game

Game music doesn't end on its own; the player leaves. A few rules make that
work.

**Loops.** Brackets in `order:` mark the part that repeats:
`intro [a b a2 b2] end`. The intro plays once, the bracket goes round until
the game moves on, and the sections after it are the **outro**. The join is
not an audio splice. The next pass is scheduled like any other music, so
releases and reverb from the last bar ring into the first. Write the end of
the loop to lead back into its start, the way a repeat sign would.

**Leaving.** The transitions table (see `README.md`) decides how a piece is
left:

| `exit` | leaves at | write for it by |
| --- | --- | --- |
| `pass` | the end of the loop | nothing special; this is the join you wrote |
| `section` | the next section boundary | making section ends sound like places to stop |
| `bar` | the next barline | an outro that can start from anywhere |
| `beat` / `now` | almost at once | usually paired with a fade or a sting |

With `"outro": true` the rule plays your outro after the exit. From a bar
exit the outro follows silence and clean instruments rather than the end of
the loop, so an outro that begins from nothing (a hit, a held chord) lands
well from anywhere.

**Stings.** A sting is a short score (a bar or two) played between two areas,
for example as the battle starts. Write it as its own file with one section.
The best ones are the destination's own pickup: the last bar of its loop, so
the new piece arrives the way it comes back round. See
`scores/battle-sting.score` in the repository.

**Picking up.** `"pick_up": true` on a rule brings an area back in at the bar
it was left at. Pieces with long through-composed stretches benefit most.

**Intensity layers.** A lane written `layer:N` plays only when the game's
intensity is N or more; `layer:..1` plays only up to 1 (a quiet-only part),
`layer:1..2` in between. Lanes without it always play. The game raises and
lowers the level (`Music.set_intensity(2, "bar")`) and layers come in and
drop out on the next bar (or `beat`, `section`, `now`) without the piece
restarting: a layer coming in picks up mid-note where it would have been,
at its own dynamics and articulation. Write level 0 so it stands on its own,
and give each layer a job - drums at 2, a countermelody at 3 - rather than
doubling what is there. A lane can be a layer in one section and not in the
next. Render a level with `--intensity 2`.

**Sections are the unit.** Exits, renders, slices and markers all work in
sections. Eight or sixteen bars per section, each with a clear name, makes
everything else easier.

## Hearing it: the renderer

The addon ships an offline renderer. It plays a score through the same
engine the game uses and writes a `.wav`, faster than real time:

```bash
godot --headless --path . --audio-driver Dummy res://addons/sfzplayer/tools/render.tscn -- --score first
```

The file lands in `renders/` as `<title>-<ensemble>.wav`. Options after the `--`:

| Option | |
| --- | --- |
| `--score first` | a score id or a path |
| `--ensemble orchestra` | a different ensemble than the score's own |
| `--from verse --to chorus` | just those sections, in the order the score plays them |
| `--sections verse verse chorus` | exactly these sections, in this order |
| `--only lead bass` | solo buses: a part is heard with the others on its bus |
| `--loops 3` | the loop three times |
| `--leave bar 70` | loop until 70 s in, then leave at the next bar (or `section`, `pass`) into the outro |
| `--play literal` | the notes exactly as written, no performance, for checking the writing |
| `--gain 2` | extra gain in dB on top of the score's loudness trim (default 0: the level the game plays it at) |
| `--no-trim` | leave out the score's trim, for measuring the mix as the ensemble makes it |
| `--variants -3 3` | also write the take at these extra gains, from the same render |
| `--out res://takes` | another folder |
| `--intensity 2` | at that intensity: `layer:` lanes from 2 up come in |
| `--realtime` | through the real audio server at 1x, as a check |

Each render also prints every bus's peak level. A bus you wrote for that
reads `silent` means something is wrong: a note outside the instrument's
range, a missing drum name, a part cast onto nothing, or an ensemble problem
(see below).

Rendering a section usually takes a second or two, against a minute or more
for the whole piece. Iterate on sections with `--from`/`--to` and render the
whole piece to decide whether it's finished.

### Loudness

Every score plays at the same loudness: -16 LUFS integrated, peaks no higher
than -1 dBTP. You don't set that by hand. Each score has a trim, stored in
`scores/loudness.json` against the score and its ensemble, which the player applies
when the score starts and the renderer applies to every file, so one area
handing off to the next lands at the same level. A true-peak limiter at the
end of the music bus catches whatever gets past it.

When a score is new, or its notes or its ensemble changed, measure it again:

```bash
python tools/loudness_fix.py
```

It renders every score that changed since last time (the rest come from a
cache in `.loudness-cache/`), sets each trim, rewrites `scores/loudness.json`
and prints a table. Commit the JSON with the score. `--check` measures without
writing and exits non-zero if any score misses; the test suite runs that.
`--fresh` ignores the cache.

The trim fixes the level of the whole piece, not the balance inside it. If
one part is buried, fix its `gain_db` in the ensemble first, then run the tool.

## MIDI in

If a piece starts in a DAW, `tools/midi_to_score.py` in the SFZ Player
repository turns a MIDI file into a first draft of a score. It is plain
Python with no dependencies:

```bash
python tools/midi_to_score.py sketch.mid --list
```

```bash
python tools/midi_to_score.py sketch.mid --key "d minor" -o scores/sketch.score --part 0=bass --part 2=lead
```

`--list` shows the tracks and what it would do with them. `--part N=NAME`
puts a track on a part (`--part 2=high:choir` declares it with its family),
or on a lane (`--part 3=perc.feet`), or drops it (`--part 4=drop`).
It writes the notes, their bar positions, `dyn:`, and the marks it can
measure (`!` `.` `'` `_`). Slurs, swells, articulations and vibrato are
intent, not data, so it leaves them for you to add. It also reports whatever
it couldn't represent instead of dropping it silently.

## MIDI out

A score can go back to MIDI, to take it into a DAW, hand it to someone, or
play it on other instruments:

- **In the editor**: Project > Tools > Export Score to MIDI... writes
  `<score>.mid` beside the score.
- **From the command line**:

```bash
godot --headless --path . -s res://addons/sfzplayer/tools/export_midi.gd -- first
```

| Option | |
| --- | --- |
| `--out path.mid` | somewhere else |
| `--ensemble id` | the key mapping of another ensemble (drum keys, keyswitches) |
| `--literal` | the notes as written, on the grid, instead of as performed |
| `--no-keyswitches` | leave articulation keyswitch notes out |

The file is a type-1 MIDI file with one track per lane (`lead`, `lead.high`,
`perc.feet`). Drums are on channel 10 at the ensemble's drum keys. Tempo changes, the meter, the key
signature and a marker at each section are included, plus `loopStart`/`loopEnd`
markers around the loop. The default export is the performance, with its
timing, velocities and CC curves, which sounds like the game.
`--literal --no-keyswitches` gives clean, quantised notes for notation or
another instrument, and that file brings back the same notes, chords,
rhythms, accents and drum names through `midi_to_score.py`.

## Ensembles and the registry, briefly

An instrument is written down once, in the **registry**:
`registry/<library>.json` holds a library's instruments, each with its SFZ
files, the CCs it reads, its playable range and its drum keys, under an id
like `vpo/choir-female` or `sm-drums/kit`.

An **ensemble** is `ensembles/<id>.json`, one per area. It lists its parts, and
each part names registry instruments, plus what this ensemble does with them:

```json
"parts": {
	"lead": {
		"family": "lead",
		"gain_db": -6.0,
		"layers": [ { "instrument": "synth/halo-lead" } ]
	},
	"high": {
		"family": "choir",
		"bus": "lead",
		"layers": [ { "instrument": "vpo/choir-female", "transpose": 12 } ]
	}
},
"buses": { "lead": { "space": "hall", "wet": 0.22 } }
```

- `family` is what the part offers to other scores: a score's `choir` part
  that this ensemble has no part of that name for lands here.
- `family_parts`, beside `parts`, picks which part a family lands on when
  the ensemble has several and the first is not the one: `{ "choir":
  "high" }`. Leave it out otherwise; none of the shipped ensembles needs
  it. It must name a part of that family, or of a family that falls back
  to it (`"pad": "high"` for a choir part); anything else refuses the
  ensemble.
- `bus` is one of the six mixer buses, `lead guitar keys bass pad perc`, and
  defaults to the family's base. Parts on one bus share its compressor
  and its room; `buses` sets the room.
- `range` is the playable span. Notes outside it are moved by octaves to
  fit. An articulation sampled more narrowly than the part's range is not
  fitted, so those notes don't sound. Check a new library's span before
  writing to its edges.
- `controls` map the score's performance to CCs: `dynamics` (dyn curves and
  swells), `brightness`, `bend` (slides, scoops, falls, `bend:`),
  `vibrato_depth`, `sustain`, `legato_attack`, `rotary`. They can be written
  once in the registry instead of on each part; `bend` goes on the registry
  instrument, never one of its layers, and the part takes it from there. The compiler writes nothing for a control the part
  doesn't map, so the same score works on an ensemble with fewer controls.
- An SFZ whose level rides a CC should give that CC a starting value in its
  `<control>` header (`set_cc1=81`). Otherwise, on a part that doesn't map
  the control, sfizz can hold the instrument at silence.
- `drums` maps drum names to keys for a `perc` part. A name a kit doesn't
  have is skipped, so a score can ask for a ride and a small kit just leaves
  it out. It is warned once, when the score is prepared on that ensemble.
- An unknown family or bus, an instrument id the registry doesn't have, or
  an SFZ that is not on disk refuses the whole ensemble, with the file and
  the part.

The repository README covers ensembles in depth: layers, cabinets, spaces
and velocity windows, and `docs/REGISTRY.md` is the full specification.

Before changing an instrument, ask what it touches:

    godot --headless --path . --audio-driver Dummy -s res://addons/sfzplayer/tools/check.gd -- --impact vpo/choir-female

prints the ensembles and parts that use it, the scores and areas that play
them, the other score and ensemble pairings that reach them by family, and the
tests to re-run. It takes an instrument id, a registry file, an SFZ or cabinet
path, several of those separated by commas, or `registry --since main` for
every instrument changed since a revision.

## What an ensemble can play, and what your score asks for

Two questions this document used to answer in prose, and now answers by
reading the manifests themselves:

    python tools/roster.py --show tonewheel        one ensemble's roster
    python tools/roster.py --xref sealed-ward      what this score asks for
                                                   that its ensemble cannot answer
    python tools/roster.py --xref --matrix         every score, every ensemble

`--show` prints each part's family, bus, layers, key range, mapped controls,
articulations and drum names, with a `tier`: **expressive** when the part
hears three or more of the controls a score can send, **raw** otherwise.
Every part hears `bend`, on the pitch wheel when it has no control for it,
so the line is bend plus two of the part's own. Whether a part hears a
control is `SfzEnsemble.Part.hears()`, the same call `check.gd` makes. It also prints where each gain came from - `measured`, `by-ear`
or `guessed` - which is annotation, not arithmetic: no gain value changes.

`--xref` is the one to run before moving a piece to another ensemble. A gap
is an event that would be sent and lost - a part cast onto nothing, an
unmapped drum or lane articulation - and apart from a
one-line warning for an unmapped drum it is silent at run time by design, which is right for a game and wrong for the person
writing: `sealed-ward` asks for the drum `snare_dry` and the articulation
`marcato`, and only two of the ensembles have either. Controls the part
cannot shape, and notes folded into range, are listed as notes and not
counted: the compiler never sends an unmapped control, so nothing is lost.
That is the same thing `check.gd` counts, and every score's own ensemble reads
clean in both: `test_check` and `test_roster` in `tools/run_tests.py` fail
otherwise.

The reading is done by the player's own `SfzEnsemble` and `SfzScoreParser`, so
it cannot drift from what actually plays. `check.gd -- --matrix` is the same
table with the casting in it: each cell's digit is the furthest resolution
step one of the score's parts took on that ensemble.

## Checking your work

- **Parse errors** come with file and line, and name the lane they are in.
  Each lane's first error is listed, all at once. Render the score to see
  them.
- **Every bus you wrote for should have a peak** in the render log, and
  on another ensemble, read the `not in ensemble` warnings to see where each
  part landed.
- **Loops**: `--loops 2` and listen to the join; `--leave bar <seconds>` at a
  few points to hear the outro from a cut.
- In the SFZ Player repository, `python tools/run_tests.py` runs the whole
  suite (score parsing, handoffs, rendering, MIDI export) against the demo
  scores.

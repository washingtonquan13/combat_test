extends SceneTree

# The true-peak limiter against the signals that break limiters, written out
# for `tools/run_tests.py loudness` to measure. Each is run through
# SfzTruePeakLimiter.process_buffer() - the same code as the bus effect and
# the offline master chain - and saved as a 16-bit WAV, the format a render
# is, so the measurement includes the rounding a real file has.
#
#   godot --headless --path . --audio-driver Dummy \
#       -s res://addons/sfzplayer/tools/limiter_check.gd -- --out <dir>
#
# The cases, all well over the ceiling going in:
#   quarter   a sine at a quarter of the sample rate, phased so every sample
#             lands 3 dB under the wave's crest: the textbook intersample
#             peak, invisible to a sample-peak limiter
#   square    a full-scale square wave, +12 dB: Gibbs overshoot at every edge
#   noise     white noise at +12 dB: a peak on nearly every sample
#   clicks    single-sample impulses, +6 dB, on silence: nothing to see coming
#             but the lookahead
#   bursts    a 60 Hz sine gated on and off every 50 ms at +10 dB: attack and
#             release over and over
#   hf        a 19 kHz sine at +6 dB, near Nyquist, where the interpolator
#             is least exact

const RATE := 48000.0
const SECONDS := 2.0


func _init() -> void:
	var out := "res://renders/limiter"
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	if at >= 0 and at + 1 < args.size():
		out = args[at + 1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))

	var limiter := SfzTruePeakLimiter.new()
	limiter.ceiling_db = SfzMixer.MASTER_CEILING
	limiter.lookahead_ms = SfzMixer.MASTER_LOOKAHEAD_MS
	limiter.release_ms = SfzMixer.MASTER_RELEASE_MS

	var rng := RandomNumberGenerator.new()
	rng.seed = 1770
	var n := int(RATE * SECONDS)
	var cases := {}
	for name in ["quarter", "square", "noise", "clicks", "bursts", "hf"]:
		cases[name] = PackedVector2Array()
		cases[name].resize(n)
	for i in n:
		var t := float(i) / RATE
		var q := 2.0 * sin(PI * 0.5 * i + PI * 0.25)
		cases["quarter"][i] = Vector2(q, -q)
		var sq := 4.0 * (1.0 if fmod(t * 440.0, 1.0) < 0.5 else -1.0)
		cases["square"][i] = Vector2(sq, sq)
		cases["noise"][i] = Vector2(rng.randfn(0.0, 1.3), rng.randfn(0.0, 1.3))
		var click := 2.0 if i % 4801 == 2400 else 0.0
		cases["clicks"][i] = Vector2(click, -click)
		var gate := 1.0 if fmod(t, 0.1) < 0.05 else 0.0
		var b := 3.2 * gate * sin(TAU * 60.0 * t)
		cases["bursts"][i] = Vector2(b, b * 0.5)
		var h := 2.0 * sin(TAU * 19000.0 * t)
		cases["hf"][i] = Vector2(h, h)

	for name: String in cases:
		var y := limiter.process_buffer(cases[name], RATE)
		var bytes := PackedByteArray()
		bytes.resize(n * 4)
		for i in n:
			bytes.encode_s16(i * 4, clampi(roundi(y[i].x * 32768.0), -32768, 32767))
			bytes.encode_s16(i * 4 + 2, clampi(roundi(y[i].y * 32768.0), -32768, 32767))
		var wav := AudioStreamWAV.new()
		wav.format = AudioStreamWAV.FORMAT_16_BITS
		wav.stereo = true
		wav.mix_rate = int(RATE)
		wav.data = bytes
		wav.save_to_wav("%s/%s.wav" % [out, name])
		print("%s/%s.wav" % [out, name])
	print("latency %d frames" % limiter.get_latency_frames(RATE))
	quit()

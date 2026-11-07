"""Bake a looping grayscale WALL of fire flipbook (8x8 atlas of 256px frames)
from a Mantaflow gas simulation: a long bed of fuel pads burning as one sheet,
cropped to a section that tiles left to right, so a wall drawn from it is one
continuous fire instead of separate flames.

One file, two modes:

  1. Blender mode (builds scene from nothing, bakes the sim, renders frames,
     then calls mode 2 with system python unless --no-assemble):

     "C:\\Program Files\\Blender Foundation\\Blender 4.3\\blender.exe" --background ^
         --factory-startup --python tools/vfx/bake_fire_wall.py -- ^
         --work <scratch_dir> --out assets/vfx/fire_wall_flipbook.png

  2. Assembly mode (plain python, numpy + PIL + imageio_ffmpeg): loop
     crossfade, normalisation, atlas, preview MP4/GIF + 50% atlas:

     python tools/vfx/bake_fire_wall.py --assemble --work <scratch_dir> ^
         --out assets/vfx/fire_wall_flipbook.png

  Bake caches go to <work>/cache, raw frames to <work>/raw, previews to <work>.

Output: RGBA PNG, RGB = A = flame intensity 0-1 (grayscale, no colour baked;
colour comes from a gradient in the game shader). Frames row-major, left to
right, top to bottom. The loop is made seamless by rendering LOOP+XFADE frames
of the settled sim and crossfading the last XFADE into the first XFADE; the
sides tile the same way, the right TILE_XFADE of the section crossfaded into
its left.
"""

import argparse
import os
import subprocess
import sys
import time

LOOP = 64          # frames in the atlas
XFADE = 16         # overlap frames crossfaded for the seamless loop
SETTLE = 50        # sim frames discarded before the loop window
FRAME_PX = 256
RENDER_PX = 512
BASE_MARGIN = 0.04
GRID = 8
EMIT_Z = 0.06     # emitter centre height (domain floor at 0)
HALF_X = 1.6      # domain half length; the bed runs its whole length
HEIGHT = 2.4      # domain height
ORTHO = 3.2       # camera ortho_scale: the whole domain length
SECTION = 1.2     # meters of wall one frame shows, centred
TILE_XFADE = 0.4  # meters past the section crossfaded into its left side
PADS = 14
FLAME_LO = 0.3    # flame values below this render black (shader threshold)
FUEL_PULSE_FRAMES = 6.0  # time scale of per-pad fuel flicker


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    p = argparse.ArgumentParser()
    p.add_argument("--work", required=True, help="scratch dir for cache/raw/previews")
    p.add_argument("--out", required=True, help="atlas PNG path")
    p.add_argument("--res", type=int, default=128, help="domain resolution_max")
    # no noise upres: fine detail turns to glitter at game distance
    p.add_argument("--noise", type=int, default=0, help="noise upres factor, 0 = off")
    p.add_argument("--samples", type=int, default=24)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--assemble", action="store_true", help="assembly mode (system python)")
    p.add_argument("--no-assemble", action="store_true")
    p.add_argument("--skip-bake", action="store_true", help="reuse existing cache")
    p.add_argument("--python", default="python", help="python exe for assembly step")
    return p.parse_args(argv)


# --------------------------------------------------------------------------
# Blender mode
# --------------------------------------------------------------------------

def blender_main(args):
    import bpy
    from math import radians

    work = os.path.abspath(args.work)
    cache = os.path.join(work, "cache")
    raw = os.path.join(work, "raw")
    os.makedirs(cache, exist_ok=True)
    os.makedirs(raw, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    first = SETTLE + 1
    last = SETTLE + LOOP + XFADE
    scene.frame_start = 1
    scene.frame_end = last
    scene.render.fps = 24

    # ---- domain: x [-HALF_X,HALF_X], y [-0.4,0.4], z [0,HEIGHT] ------------
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, HEIGHT / 2))
    dom = bpy.context.active_object
    dom.name = "FireDomain"
    dom.scale = (HALF_X * 2, 0.8, HEIGHT)
    bpy.ops.object.transform_apply(scale=True)
    mod = dom.modifiers.new("Fluid", "FLUID")
    mod.fluid_type = "DOMAIN"
    d = mod.domain_settings
    d.domain_type = "GAS"
    d.resolution_max = args.res
    d.use_adaptive_domain = False
    d.cache_directory = cache
    d.cache_type = "ALL"
    d.cache_data_format = "OPENVDB"
    d.cache_frame_start = 1
    d.cache_frame_end = last
    d.alpha = 0.0            # no smoke-density buoyancy
    d.beta = 3.0             # heat buoyancy drives the flames up
    d.vorticity = 0.35
    d.time_scale = 1.0
    d.use_dissolve_smoke = True
    d.dissolve_speed = 8
    d.burning_rate = 2.0    # how fast fuel burns -> flame height
    d.flame_smoke = 0.15
    d.flame_vorticity = 0.7
    d.flame_ignition = 1.5
    d.flame_max_temp = 3.0
    d.use_collision_border_top = False
    # open ends: the sheet runs on past them instead of curling off a wall
    d.use_collision_border_left = False
    d.use_collision_border_right = False
    d.use_noise = args.noise > 0
    if d.use_noise:
        d.noise_scale = args.noise
        d.noise_strength = 1.4
        d.noise_pos_scale = 2.2
        d.noise_time_anim = 0.25

    # ---- emitter: cluster of flattened blobs ("logs"), each a fuel source
    # so separate tongues rise and merge/split instead of one column --------
    import random
    rnd = random.Random(args.seed)
    step = HALF_X * 2 / PADS
    blobs = [  # (x, y, z offset, rx, ry, rz) - overlapping flat pads, one
        # continuous bed along the whole domain, sizes varied a little
        (-HALF_X + step * (k + 0.5) + rnd.uniform(-0.03, 0.03), rnd.uniform(-0.04, 0.04),
         rnd.uniform(-0.01, 0.01), step * rnd.uniform(0.6, 0.8), rnd.uniform(0.07, 0.1), 0.03)
        for k in range(PADS)]
    # scrolling cloud texture varies fuel across each pad's surface
    tex = bpy.data.textures.new("FuelNoise", "CLOUDS")
    tex.noise_scale = 0.45
    tex.noise_depth = 2
    tex.noise_basis = "BLENDER_ORIGINAL"
    tex.contrast = 3.0
    tex.intensity = 1.0
    # all meshes first: a view-layer update after a FIRE flow exists makes
    # Mantaflow re-init its grids and fail ('getDataPointer' on None)
    emitters = []
    for k, (bx, by, bz, rx, ry, rz) in enumerate(blobs):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=1.0,
                                             location=(bx, by, EMIT_Z + bz))
        em = bpy.context.active_object
        em.name = f"FireEmitter{k}"
        em.scale = (rx, ry, rz)
        bpy.ops.object.transform_apply(location=False, scale=True)
        emitters.append(em)
    for k, em in enumerate(emitters):
        fm = em.modifiers.new("Fluid", "FLUID")
        fm.fluid_type = "FLOW"
        f = fm.flow_settings
        f.flow_type = "FIRE"
        f.flow_behavior = "INFLOW"
        f.flow_source = "MESH"
        f.surface_distance = 0.012
        f.volume_density = 1.0
        f.temperature = 1.0
        f.subframes = 1
        f.use_texture = True
        f.noise_texture = tex
        f.texture_map_type = "AUTO"
        f.texture_size = 1.0
        f.texture_offset = 0.0
        f.keyframe_insert("texture_offset", frame=1)
        f.texture_offset = 20.0
        f.keyframe_insert("texture_offset", frame=last)
        # each pad's fuel pulses on its own noise -> tongues puff, lick and
        # die back independently instead of standing as steady columns
        f.fuel_amount = 1.2
        f.keyframe_insert("fuel_amount", frame=1)
        for fc in em.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"
            if fc.data_path.endswith("fuel_amount"):
                nm = fc.modifiers.new("NOISE")
                nm.scale = FUEL_PULSE_FRAMES
                nm.strength = 1.6
                nm.phase = 17.0 * k + args.seed
                nm.blend_type = "ADD"
                lim = fc.modifiers.new("LIMITS")
                lim.use_min_y = True
                lim.min_y = 0.15
        em.hide_render = True

    # ---- material: emission from flame, zero density ---------------------
    mat = bpy.data.materials.new("FlameGray")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    info = nt.nodes.new("ShaderNodeVolumeInfo")
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    mul.inputs[1].default_value = 1.5
    vol.inputs["Density"].default_value = 0.0
    vol.inputs["Emission Color"].default_value = (1, 1, 1, 1)
    vol.inputs["Blackbody Intensity"].default_value = 0.0
    # threshold the flame field: the low-flame haze becomes black so tongues
    # get defined edges and break into detached wisps instead of a cloud
    rng = nt.nodes.new("ShaderNodeMapRange")
    rng.interpolation_type = "SMOOTHSTEP"
    rng.inputs["From Min"].default_value = FLAME_LO
    rng.inputs["From Max"].default_value = 1.0
    nt.links.new(info.outputs["Flame"], rng.inputs["Value"])
    nt.links.new(rng.outputs["Result"], mul.inputs[0])
    nt.links.new(mul.outputs[0], vol.inputs["Emission Strength"])
    nt.links.new(vol.outputs[0], out.inputs["Volume"])
    dom.data.materials.append(mat)

    # ---- camera: orthographic side view ----------------------------------
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ORTHO
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    # frame bottom just below the emitter base (~6% margin)
    cam.location = (0, -6, ORTHO / 2 - 0.05)
    cam.rotation_euler = (radians(90), 0, 0)
    scene.camera = cam

    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0
    scene.world = world

    r = scene.render
    r.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = False
    scene.cycles.volume_step_rate = 0.5
    scene.cycles.volume_max_steps = 512
    scene.cycles.seed = args.seed
    r.film_transparent = True
    r.resolution_x = RENDER_PX
    r.resolution_y = RENDER_PX
    r.resolution_percentage = 100
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "BW"
    r.image_settings.color_depth = "16"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0   # headroom; normalised in assembly

    # ---- bake ------------------------------------------------------------
    t0 = time.time()
    if not args.skip_bake:
        import shutil
        shutil.rmtree(cache, ignore_errors=True)
        os.makedirs(cache, exist_ok=True)
        bpy.context.view_layer.objects.active = dom
        dom.select_set(True)
        with bpy.context.temp_override(object=dom, active_object=dom,
                                       selected_objects=[dom]):
            res = bpy.ops.fluid.bake_all()
        print("[fire] bake_all ->", res, flush=True)
    t_bake = time.time() - t0
    print(f"[fire] bake {t_bake:.1f}s", flush=True)

    # ---- render loop window ----------------------------------------------
    t1 = time.time()
    for i, fr in enumerate(range(first, last + 1)):
        scene.frame_set(fr)
        r.filepath = os.path.join(raw, f"f_{i:03d}.png")
        bpy.ops.render.render(write_still=True)
    t_render = time.time() - t1
    print(f"[fire] render {t_render:.1f}s ({last - first + 1} frames)", flush=True)
    with open(os.path.join(work, "timings.txt"), "w") as fh:
        fh.write(f"bake {t_bake:.1f}s\nrender {t_render:.1f}s\n")

    if not args.no_assemble:
        cmd = [args.python, os.path.abspath(__file__), "--assemble",
               "--work", work, "--out", os.path.abspath(args.out)]
        print("[fire] assembling:", " ".join(cmd), flush=True)
        subprocess.check_call(cmd)


# --------------------------------------------------------------------------
# Assembly mode (system python)
# --------------------------------------------------------------------------

def assemble_main(args):
    import numpy as np
    from PIL import Image

    work = os.path.abspath(args.work)
    raw = os.path.join(work, "raw")
    n = LOOP + XFADE
    frames = np.stack([
        np.asarray(Image.open(os.path.join(raw, f"f_{i:03d}.png")), dtype=np.float32)
        for i in range(n)])
    if frames.ndim == 4:   # in case RGB(A) slipped through
        frames = frames[..., :3].mean(-1)
    frames /= 65535.0 if frames.max() > 255 else 255.0

    # seamless loop: o[i] = lerp(f[LOOP+i], f[i], i/XFADE) for i < XFADE,
    # so o[LOOP-1] = f[LOOP-1] is followed by o[0] = f[LOOP].
    w = (np.arange(XFADE, dtype=np.float32) / XFADE)[:, None, None]
    loop = frames[:LOOP].copy()
    loop[:XFADE] = (1.0 - w) * frames[LOOP:LOOP + XFADE] + w * frames[:XFADE]

    # normalise: hottest core ~white, then a mild curve so tips stay dim
    hi = np.percentile(loop[loop > 0.01], 99.7) if np.any(loop > 0.01) else 1.0
    loop = np.clip(loop / hi, 0.0, 1.0) ** 1.6   # undo part of sRGB lift: tips dim
    loop = np.where(loop < 0.012, 0.0, loop)   # kill render-noise floor
    print(f"[fire] normalise hi={hi:.4f}")

    # the section: SECTION m centred, plus TILE_XFADE m to its right that is
    # crossfaded into its left edge so the right edge runs on into the left;
    # cropped from the floor up to the tallest lit row, so frames are
    # SECTION wide and fire_height tall (printed, for the game side)
    px = RENDER_PX / ORTHO
    floor = RENDER_PX - int(round(0.05 * px))
    sec, fade = int(round(SECTION * px)), int(round(TILE_XFADE * px))
    x0 = RENDER_PX // 2 - sec // 2
    strip = loop[:, :floor, x0:x0 + sec + fade]
    ramp = (np.arange(fade, dtype=np.float32) / fade)[None, None, :]
    tiled = strip[:, :, :sec].copy()
    tiled[:, :, :fade] = (1.0 - ramp) * strip[:, :, sec:sec + fade] + ramp * strip[:, :, :fade]
    lit_rows = np.nonzero(tiled.max(axis=(0, 2)) > 0.02)[0]
    top = max(lit_rows.min() - 4, 0)
    tiled = tiled[:, top:, :]
    print(f"[fire] fire_height={(floor - top) / px:.3f} m  section={SECTION} m")
    loop = np.stack([np.asarray(Image.fromarray(fr, "F").resize(
        (FRAME_PX, FRAME_PX), Image.LANCZOS)) for fr in tiled])
    loop = np.clip(loop, 0.0, 1.0)
    loop = np.where(loop < 0.012, 0.0, loop)

    # tiling check: the right column against the left, like any neighbours
    edge = np.abs(loop[:, :, -1] - loop[:, :, 0]).mean()
    bottom_rows = loop.max(axis=(0, 2))
    nz = np.nonzero(bottom_rows > 0.02)[0]
    print(f"[fire] tile seam={edge:.4f} vs neighbour columns={np.abs(np.diff(loop, axis=2)).mean():.4f}  lit rows {nz.min() if nz.size else -1}-"
          f"{nz.max() if nz.size else -1} of {FRAME_PX}")

    # seam check
    diffs = np.abs(np.diff(np.concatenate([loop, loop[:1]]), axis=0)).mean(axis=(1, 2))
    print(f"[fire] seam diff (63->0)={diffs[-1]:.5f}  neighbour mean={diffs[:-1].mean():.5f}"
          f"  min={diffs[:-1].min():.5f} max={diffs[:-1].max():.5f}")

    g8 = (loop * 255.0 + 0.5).astype(np.uint8)
    atlas = g8.reshape(GRID, GRID, FRAME_PX, FRAME_PX).transpose(0, 2, 1, 3) \
              .reshape(GRID * FRAME_PX, GRID * FRAME_PX)
    rgba = np.repeat(atlas[..., None], 4, axis=-1)
    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    Image.fromarray(rgba, "RGBA").save(out, optimize=True)
    print(f"[fire] atlas {rgba.shape[1]}x{rgba.shape[0]} -> {out}")

    # previews
    Image.fromarray(atlas).resize((atlas.shape[1] // 2, atlas.shape[0] // 2),
                                  Image.LANCZOS).save(os.path.join(work, "atlas_50.png"))
    # tinted preview over dark grey, purely for eyeballing
    ramp = np.stack([np.clip(loop * 3.0, 0, 1), np.clip(loop * 1.6 - 0.2, 0, 1),
                     np.clip(loop * 2.0 - 1.0, 0, 1)], -1)
    bg = 0.08
    a = loop[..., None]
    tinted = ((ramp * a + bg * (1 - a)) * 255).astype(np.uint8)
    gray = np.repeat(g8[..., None], 3, -1)
    side = np.concatenate([tinted, tinted, tinted], axis=2)   # tiled x3
    seq = np.concatenate([side] * 3)
    try:
        import imageio_ffmpeg
        mp4 = os.path.join(work, "fire_loop_x3.mp4")
        h, wd = seq.shape[1:3]
        wr = imageio_ffmpeg.write_frames(mp4, (wd, h), fps=24, quality=8,
                                         macro_block_size=16)
        wr.send(None)
        for fr in seq:
            wr.send(np.ascontiguousarray(fr))
        wr.close()
        print(f"[fire] preview {mp4}")
    except Exception as e:  # pragma: no cover
        print("[fire] mp4 failed:", e)
    gif = [Image.fromarray(fr) for fr in seq]
    gif[0].save(os.path.join(work, "fire_loop_x3.gif"), save_all=True,
                append_images=gif[1:], duration=42, loop=0)
    # seam strip: frames 60..63,0..3
    strip = np.concatenate([g8[i] for i in (60, 61, 62, 63, 0, 1, 2, 3)], axis=1)
    Image.fromarray(strip).save(os.path.join(work, "seam_strip.png"))


if __name__ == "__main__":
    a = parse_args()
    if a.assemble:
        assemble_main(a)
    else:
        blender_main(a)

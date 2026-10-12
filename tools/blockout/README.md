# OSM blockouts

Builds a walkable blockout scene from OpenStreetMap data.

1. Get an Overpass API JSON extract for a bounding box.
2. Convert it to local metres:

   ```bash
   python -I tools/blockout/osm_to_local.py <overpass.json> data/blockouts/<name>.json --bbox S,W,N,E
   ```

3. Optionally write `data/blockouts/<name>.terrain.json` to shape the ground.
   OSM has no elevation, so this sidecar is hand-estimated. See
   `jackson_square.terrain.json` for the levee, deck and ramp format.
4. Build the scene:

   ```bash
   godot --headless --path . res://tools/blockout/build_osm_blockout.tscn -- --src=res://data/blockouts/<name>.json --out=res://world/<name>.tscn
   ```

The builder must run as a scene, not with `-s`, because the scripts it attaches
reference autoloads.

## Editing the result

Buildings are CSGPolygon3D so their shape stays editable. Their collision,
though, is a separate `Walls` body of box segments, one per footprint edge.
NavigationGrid only sees StaticBody3D box shapes, and CSG collision is
invisible to it. If you edit a footprint by hand, move its walls too, or
re-run the builder.

## Whole-city overworld

A second pipeline builds a city-sized overworld map: block masses instead
of buildings, with their tall buildings rising out of them, scaled down,
with water as impassable collision. Everything stays a polygon from the
OSM data (shapely, `pip install shapely`), so edges keep their real angles.

```bash
python -I tools/blockout/fetch_osm_city.py <raw dir> --boundary "Orleans Parish"
python -I tools/blockout/osm_city.py <raw dir> data/blockouts/<name> --water-seeds "LAT,LON;LAT,LON"
python -I tools/blockout/city_gltf.py data/blockouts/<name> world/<name>
godot --headless --path . --import
```

- `--boundary` names an administrative boundary relation. The map is
  clipped to it: buildings stop short of it, a wall runs along it, and fog
  past it (`world/city_fog.gdshader`, driven by the signed distance field
  `edge.bin` that `shore_field.py` bakes) hides the rest of the world.
  The fog is clear everywhere inside the line, so it never covers a road
  the player can reach, and the builder starts the depth haze past the
  farthest ground the camera frames at full zoom out. The fields reach
  the shaders as global shader parameters (`city_edge_*`, `city_shore_*`
  in `project.godot`), set by `world/city_geometry.gd` on the glb's
  instance for whichever city is in play.
  Give `--bbox S,W,N,E` to both scripts instead for a plain rectangle with
  no fog.
- `osm_city.py` takes about 13 minutes for all of Orleans Parish, almost
  all of it merging the footprints of the two lowest height steps.
- Keep the raw download outside the project. It is large (Orleans Parish
  is about 250 MB) and only `osm_city.py` reads it.
- `data/blockouts/<name>/` needs a `.gdignore`, because its tile files are
  not Godot resources.
- The download runs on overpass-api.de, a volunteer-run server. The
  fetcher asks its `/api/status` for a free query slot before every query,
  backs off after a failure, and skips the files it already has, so a
  re-run costs the server nothing for what is done. Keep it that way: no
  mirror rotation, no tight retry loops. A tile of buildings that still
  times out is split into quarters.
- `--water-seeds` gives one point inside each water body that the map edge
  cuts open: a lake or river polygon that crosses the boundary (Lake
  Pontchartrain, the Mississippi) keeps only its banks, and water outlined
  by `natural=coastline` (`coast.json`) has no polygon at all. Water wholly
  inside the map needs no seed. The point must be inside the boundary. For
  Orleans Parish the seeds are `30.10,-90.05` (Lake Pontchartrain),
  `29.9535,-90.0590` (the Mississippi), `30.165,-89.70` (the Rigolets) and
  `30.0777,-89.6828` (the strip of Lake Borgne inside the parish line).
  For the old rectangle (`29.900,-90.140,30.035,-89.960`) they were
  `29.9535,-90.0590` and `30.033,-90.08`.
- Bridges, overpasses and their ramps are walkable decks. `osm_city.py`
  leaves bridges off the ground and runs `decks_seed.py`, which writes
  `decks.json`: one record per elevated way, its heights measured from
  LiDAR (`lidar_fetch.py`) where there are returns and from the
  `bridges.py` / `heights.py` solve where there are not. Records marked
  `"source": "hand"` survive a re-seed. Then `decks_mesh.py` draws
  `decks.json` as swept ribbons and writes `tiles/d_X_Z.bin`. Twin
  carriageways (`twin_of`, kept where LiDAR puts them within 1.5 m of
  each other over 80% of their shared length) are drawn flush, one
  surface with crossfall and no median rail; any other step between
  decks is railed. Re-run
  them alone with `python -I tools/blockout/decks_seed.py <raw dir>
  data/blockouts/<name>` (about six minutes for the parish) and
  `python -I tools/blockout/decks_mesh.py <raw dir> data/blockouts/<name>`.
  Heights are real metres.
  `world/city_deck.gdshader` cuts a hole in any deck above the player, so
  the camera can see them under an overpass.
- Culverted waterways (`tunnel=culvert`) are left out of the water: water
  is solid collision, and a ditch under a road would wall the road off.
- `osm_city.py` ends by running `shore_field.py`, which bakes `shore.png`,
  each water pixel's distance to the bank and how open the water around it
  is, for the water shader's shallows, shore foam and calm small water. Re-bake it alone with
  `python -I tools/blockout/shore_field.py data/blockouts/<name>`.
- `city_gltf.py` writes `world/<name>/city.glb` every time, with
  `shore.png`, `edge.exr` and `city.json` beside it and `.import` files
  for all three, so `godot --headless --import` (or opening the editor)
  brings it in as a scene: ground, buildings and decks per tile, the
  buildings and decks walkable through glTF's `-col` node suffix, water
  walled off through `-colonly`. The glb's four materials are mapped to
  `world/materials/city_*.tres`, so the city's look is edited there and
  survives a rebuild. The script writes `world/<name>_overworld.tscn`,
  the editable area with spawn, camera, fog sheets and light, only if that
  file is missing, so doors placed by hand survive a rebuild. The live
  city is `world/city_overworld/`, instanced by `world/city_overworld.tscn`;
  rebuild it with `--scene world/city_overworld.tscn`.
  Framing options: `--pitch`, `--range` (metres camera to avatar), `--icon`,
  `--speed`, `--cutaway`.
- `compress.py` shortens the city the SMT way, before `osm_city.py` runs:
  it cuts bands of filler out of the raw download and slides everything
  past each band in to close the gap, so districts and landmarks keep
  their arrangement and the walk between them shortens.

  ```bash
  python -I tools/blockout/compress.py <cuts.json> <raw dir> <out raw dir> --decks data/blockouts/<name>/decks.json --decks-out data/blockouts/<new name>
  python -I tools/blockout/osm_city.py <out raw dir> data/blockouts/<new name> --water-seeds "LAT,LON"
  ```

  `cuts.json` names the frame (a built city's `city.json`) its bands are
  measured in and lists them: `{"centre": [x, z], "angle": deg, "width": m,
  "keep": 0}` for a band along a line (angle 0 runs east-west, 90
  north-south), or `{"axis": "z", "from": z0, "to": z1}` for one across
  the map; `keep` 0 deletes, 0.3 squeezes to 30%, 1 changes nothing.
  Bands apply in order, each measured in the map as earlier ones left it.
  Cut along the local cross streets, not across the map: a band askew to
  the grid shears every street crossing it sideways. The output raw dir
  carries a `boundary.json` for the new map edge and a `lidar_decks.npz`
  cropped and warped to match, which `decks_seed.py` picks up by default.
  Hand deck records are carried when no band touches them. The report
  counts the street ends left on each cut line, met, snapped (ends of one
  street within 80 m of each other, `--snap`) or loose, and the height
  step where elevated decks meet; `--mark name=x,z` reports where a point
  lands. The new map's `osm_city.py` run needs no `--bbox`: the carried
  `boundary.json` is the map.

## Attribution

Map data © OpenStreetMap contributors, available under the Open Database
License (ODbL 1.0): https://www.openstreetmap.org/copyright

Each generated scene also carries this notice in its `osm_attribution`
metadata.

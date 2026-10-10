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
godot --headless --path . res://tools/blockout/build_osm_city.tscn -- --src=res://data/blockouts/<name> --out=res://world/<name> --scale=0.25 --vscale=0.3
```

- `--boundary` names an administrative boundary relation. The map is
  clipped to it: buildings stop short of it, a wall runs along it, and fog
  past it (`world/city_fog.gdshader`, driven by the signed distance field
  `edge.png` that `shore_field.py` bakes) hides the rest of the world.
  The fog is clear everywhere inside the line, so it never covers a road
  the player can reach, and the builder starts the depth haze past the
  farthest ground the camera frames at full zoom out.
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
  leaves bridges off the ground and runs `bridges.py`, which makes up
  their heights (OSM has only a layer) and writes `tiles/d_X_Z.bin`; its
  docstring has the rules. Re-run it alone, in seconds, with
  `python -I tools/blockout/bridges.py <raw dir> data/blockouts/<name>`.
  Its heights are real metres, and `CLEAR` assumes `--vscale 0.3`.
  `world/city_deck.gdshader` cuts a hole in any deck above the player, so
  the camera can see them under an overpass.
- Culverted waterways (`tunnel=culvert`) are left out of the water: water
  is solid collision, and a ditch under a road would wall the road off.
- `osm_city.py` ends by running `shore_field.py`, which bakes `shore.png`,
  each water pixel's distance to the bank and how open the water around it
  is, for the water shader's shallows, shore foam and calm small water. Re-bake it alone with
  `python -I tools/blockout/shore_field.py data/blockouts/<name>`.
- The builder writes `world/<name>/city_geometry.scn` every time. It writes
  `world/<name>_overworld.tscn`, the editable area with spawn, camera and
  light, only if that file is missing, so doors placed by hand survive a
  rebuild.

## Attribution

Map data © OpenStreetMap contributors, available under the Open Database
License (ODbL 1.0): https://www.openstreetmap.org/copyright

Each generated scene also carries this notice in its `osm_attribution`
metadata.

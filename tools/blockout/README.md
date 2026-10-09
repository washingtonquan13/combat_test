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
of buildings, scaled down, with water as impassable collision.

```bash
python -I tools/blockout/fetch_osm_city.py <raw dir> --bbox S,W,N,E
python -I tools/blockout/osm_city.py <raw dir> data/blockouts/<name> --bbox S,W,N,E --water-seeds "LAT,LON;LAT,LON"
cp data/blockouts/<name>/ground.png world/<name>/ground.png
godot --headless --path . --import
godot --headless --path . res://tools/blockout/build_osm_city.tscn -- --src=res://data/blockouts/<name> --out=res://world/<name> --scale=0.125
```

- Keep the raw download outside the project. It is large (New Orleans is
  about 70 MB) and only `osm_city.py` reads it.
- `data/blockouts/<name>/` needs a `.gdignore`, because its tile files are
  not Godot resources.
- The download runs on public Overpass servers, which often rate-limit or
  time out. The fetcher retries and skips the files it already has, so
  re-run it until it finishes.
- `--water-seeds` gives one point inside each water body that the bbox cuts
  open. For New Orleans (`29.900,-90.140,30.035,-89.960`) the seeds are
  `29.9535,-90.0590` (the Mississippi) and `30.033,-90.08` (Lake
  Pontchartrain).
- The builder writes `world/<name>/city_geometry.scn` every time. It writes
  `world/<name>_overworld.tscn`, the editable area with spawn, camera and
  light, only if that file is missing, so doors placed by hand survive a
  rebuild.

## Attribution

Map data © OpenStreetMap contributors, available under the Open Database
License (ODbL 1.0): https://www.openstreetmap.org/copyright

Each generated scene also carries this notice in its `osm_attribution`
metadata.

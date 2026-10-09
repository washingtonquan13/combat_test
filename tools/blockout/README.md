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

## Attribution

Map data © OpenStreetMap contributors, available under the Open Database
License (ODbL 1.0): https://www.openstreetmap.org/copyright

Each generated scene also carries this notice in its `osm_attribution`
metadata.

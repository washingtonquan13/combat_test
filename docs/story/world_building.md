# World building and story

The game's setting, premise and pitch. Systems live in docs/systems; this is
the fiction they serve.

## Pitch (2026-11-26)

### ReManifest Destiny (RMD)

**High concept.** ReManifest Destiny (RMD) is a dark, post-apocalyptic
tactical CRPG that blends the bleak tone, demon negotiation, and fusion-based
team building of Shin Megami Tensei with the systemic, vertical tactical
combat and reactivity of Baldur's Gate 3, powered by a deterministic,
GURPS-inspired 3d6 ruleset.

**Setting and premise.** Set in the ruins of America following a catastrophic
Y2K demon and Eldritch invasion, humanity has been driven underground and
fractured. Players must push back onto the reclaimed surface, confront
demonic and cosmic entities, and carve out a new kingdom ruled by humans, and
the demons they bind or ally with.

**Core pillars**

- **Tactical CRPG combat (BG3 x GURPS):** turn-based, grid-and-verticality
  tactical combat driven by a deterministic 3d6 roll-under system, WYSIWYG
  movement previews, environmental interactions, and composable abilities.
  (Adopts BG3-style spatial tactics rather than SMT's Press Turn combat.)
- **Demon negotiation and recruitment (SMT):** rather than slaughtering every
  threat, players negotiate with, bargain with, or bind demons and Eldritch
  beings to build a customized tactical roster.
- **Fusion and composable team building:** recruited demons can be fused and
  customized using modular traits, elemental affinities, and inheritable
  abilities to tackle escalating surface threats.
- **Surface reclamation and kingdom building:** expanding across ruined Y2K
  America, establishing outposts, and shaping a new civilization through
  ideological choices and human-demon alliances.

**Technical foundation**

- Engine: Godot 4 (GDScript + custom GDExtension)
- Architecture: data-driven registry, composable ability/status pipelines,
  and modular 6-component unit architecture.

Earlier framing (also 2026-11-26): "Fallout meets Divinity meets Giten
Megami Tensei", with Giten as the main inspiration. The vertical slice
starts in an underground shelter.

## Open questions

Raised in review of the pitch; none decided yet.

- **The title.** "Manifest Destiny" is the doctrine behind westward expansion
  and the removal of Native peoples, and "a new kingdom ruled by humans"
  echoes it. Either the game takes that on as a theme (do the demons have a
  claim to the land? does reclamation repeat the old sin?) or the pitch should
  show it knows.
- **The 1999 look.** If the world's technology stopped at midnight on
  31 December 1999 (beige towers, CRTs, pagers, dial-up, malls as ruins),
  that is the setting's most distinctive image. The diegetic terminal already
  fits it.
- **Two invaders.** Why both demons and Eldritch beings? If they differ (one
  can be bargained with, one can't), that is a design pillar in itself.
- **The protagonist.** Who leaves the shelter, and why them.
- **The shelter.** The underground start is missing from the pitch, though
  the slice begins there.
- **Wording that doesn't match the rules.** "Deterministic" 3d6 (the dice are
  random; the odds are shown, so "transparent"); "grid" (movement is
  metre-based with a path line, like BG3).
- **Kingdom building scope.** No system exists yet; the nearest is faction
  relations (docs/systems). For the slice, "outposts and factions", or a
  stated later goal.
- **What only RMD has.** Every pillar names another game; the 1999 look and
  demons bound into the squad are the candidates.

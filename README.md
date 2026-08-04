# CRPG Combat System (Godot 4)

A modular, turn‑based tactical combat engine inspired by GURPS and presented in a BG3‑style UI. Built for clarity, scalability, and fully deterministic gameplay.

## Features

- **Turn‑based tactical combat** using 3d6 roll‑under accuracy, DX‑based initiative, and clean action flow  
- **Deterministic movement** with true WYSIWYG previews — the preview and real movement use the exact same logic  
- **Composable ability system** (targeting + effects) supporting melee, ranged, AoE, movement abilities, and status application  
- **Status effects** built from reusable behaviors (DoT, incapacitate, prone, remove‑on‑damage, stacking modes)  
- **Clean unit architecture** using six focused components (movement, combat, facing, selection, statuses, action state)  
- **BG3‑style UI** including ability hotbar, initiative strip, targeting indicators, AoE rings, and combat log  
- **Animation & VFX sync** with start vs. resolution signals and a step‑based VFX pipeline

## Design Goals

- Deterministic, preview‑accurate gameplay  
- Strict modularity and single‑responsibility components  
- Composition over flat data fields  
- Clear, debuggable architecture suitable for long‑term growth

## Current Limitations

- AI does not yet use AoE or jump abilities  
- No equipment/weapon system  
- No post‑combat flow (loot, XP, narrative)  
- Limited animation/VFX wiring beyond example abilities

## Engine

Built in **Godot 4 (GDScript)**.

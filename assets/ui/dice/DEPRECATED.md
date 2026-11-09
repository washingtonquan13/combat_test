Deprecated: skill checks spin the odds wheel now (`assets/ui/wheel/`).

Kept so the dice still work. `systems/dialogue_system/skill_check_dice_popup.tscn` plays these sheets and `tools/dice/build.sh` rebuilds them, but the popup isn't in `MainRoot.tscn`. No new work should build on them.

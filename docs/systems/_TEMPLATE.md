# <System name>

**Files:** <folders / key files, with line counts>
**Autoloads owned:** <names, or none>

## Purpose
<2-4 sentences: what this system is responsible for, and what it is explicitly NOT responsible for>

## State it owns (source of truth)
| State | Where (file:line) | Persisted? (save key) |
|---|---|---|

## Derived / cached state
<state that copies or caches another system's truth — each one is a place two truths can disagree>

## Public surface
- **Calls in** (who calls this system, which functions)
- **Signals out** (signal → who listens)
- **Signals in** (what it listens to, from whom)

## Depends on
<other systems/autoloads it reaches into directly, with file:line for each reach>

## Assumptions and invariants
<rules the code relies on. Flag any that encode "only one fight at a time", "no saving during combat", "only one focused world", or similar global assumptions — mark STALE if the rest of the codebase has since broken them>

## Lifecycle
<when it is created/torn down; behavior on new game, save, load, world travel, combat start/end, dialogue, cutscene>

## Known issues
| # | Issue | Evidence (file:line) | Status |
|---|---|---|---|
<Status = CONFIRMED (traced in code) / NOT REPRODUCED (code disagrees) / NEW (found while mapping)>

## Tests
<test files covering this system; notable gaps>

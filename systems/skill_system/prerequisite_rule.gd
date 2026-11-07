class_name PrerequisiteRule
extends Resource
## Base for one composable prerequisite check. Every subclass is meant to
## implement is_satisfied() itself — the data (that subclass's own
## @export fields) and the logic that interprets it live together on the
## same resource, same discipline as this project's AbilityEffect/
## AbilityTargeting/StatusBehavior, rather than data resources with the
## evaluation logic living somewhere else entirely.
##
## Not every subclass has is_satisfied() implemented yet —
## AdvantagePrerequisite, TagPrerequisite, and SkillCategoryPrerequisite
## are still data-only, since they each depend on a system (advantages,
## tags, skill categories) that doesn't exist in this project yet. They
## stay valid to author into a Skill.prerequisites tree regardless — this
## base's default just refuses to evaluate until someone fills that in.

func is_satisfied(_unit: Unit) -> bool:
	push_error("%s doesn't implement is_satisfied() yet" % get_script().resource_path)
	return false


## The same question asked inside a conversation — what a dialogue
## choice's or interjection's gate calls. Defaults to asking about the
## conversation's acting unit, so every rule that only cares about a
## unit works unchanged; a rule that reads the conversation itself
## (its cast, its variables, its dice) overrides this instead.
func is_satisfied_in(c: Conversation) -> bool:
	return is_satisfied(c.cast.get("player") as Unit)

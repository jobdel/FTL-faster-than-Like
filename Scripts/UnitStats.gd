## UnitStats.gd
## Resource storing persistent unit data: health and skill progression.
## One instance per unit — create via Inspector or automatically in Unit._ready().
class_name UnitStats
extends Resource

@export var max_health : float = 100.0
var health             : float = 100.0

## XP required to advance from level 0→1, 1→2, 2→3 (mirrors FTL pacing).
const XP_THRESHOLDS : Array[float] = [30.0, 60.0, 120.0]
const MAX_LEVEL      : int          = 3

## skill_id → { "xp": float, "level": int }
## Add more skills here as new station types are introduced.
var skills : Dictionary = {
	"pilot":   {"xp": 0.0, "level": 0},
	"shields": {"xp": 0.0, "level": 0},
	"weapons": {"xp": 0.0, "level": 0},
	"combat":  {"xp": 0.0, "level": 0},
	"repair":  {"xp": 0.0, "level": 0},
}


## Adds XP to skill. Returns true when the skill levels up this call.
func gain_xp(skill: String, amount: float) -> bool:
	if not skills.has(skill):
		return false
	var entry : Dictionary = skills[skill]
	if entry["level"] >= MAX_LEVEL:
		return false
	entry["xp"] += amount
	var threshold : float = XP_THRESHOLDS[entry["level"]]
	if entry["xp"] >= threshold:
		entry["xp"] -= threshold
		entry["level"] += 1
		return true
	return false


func health_percent() -> float:
	return health / max_health

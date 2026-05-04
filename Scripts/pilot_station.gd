class_name PilotStation
extends Station

@export var evasion_bonus: float = 15.0


func _ready() -> void:
	super()
	system_name = "Pilot Console"
	xp_skill    = "pilot"


func apply_bonus() -> void:
	var ship := _get_ship()
	if ship:
		ship.evasion += evasion_bonus


func remove_bonus() -> void:
	var ship := _get_ship()
	if ship:
		ship.evasion -= evasion_bonus


func _get_ship() -> Node:
	# Assumes the station is a child (or descendant) of a ship node.
	return get_parent()

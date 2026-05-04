class_name ShieldStation
extends Station

@export var recharge_bonus: float = 1.5


func _ready() -> void:
	super()
	system_name = "Shield Console"
	xp_skill    = "shields"


func apply_bonus() -> void:
	var ship := _get_ship()
	if ship:
		ship.shield_recharge_speed += recharge_bonus


func remove_bonus() -> void:
	var ship := _get_ship()
	if ship:
		ship.shield_recharge_speed -= recharge_bonus


func _get_ship() -> Node:
	return get_parent()

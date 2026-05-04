## ship.gd  —  attach to the root ship node (SpaceShip1).
##
## Owns all ship-level stats.  Station scripts already call get_parent() and
## write directly to `evasion` and `shield_recharge_speed`, so this script just
## fills those variables in and keeps everything alive.
##
## ShipUI listens to the four signals below and redraws only when values change.
extends Node2D
class_name Ship
# ── hull ──────────────────────────────────────────────────────────────────────
@export var hull_max     : int   = 30
var         hull_current : int   = 30
var rooms_registry = {}
# ── shields ───────────────────────────────────────────────────────────────────
## Number of bubble layers (FTL typically 2–4).
@export var shields_max          : int   = 2
var         shields_current      : float = 2.0  # fractional: supports partial charge

## Base charge speed in layers-per-second.  ShieldStation adds to this.
@export var shield_recharge_rate : float = 0.35
## Written by ShieldStation.apply_bonus() / remove_bonus().
var         shield_recharge_speed: float = 0.0

# ── systems ───────────────────────────────────────────────────────────────────
var oxygen        : float = 1.0   # 0..1
var engine        : float = 0.5   # 0..1  base efficiency
var evasion       : float = 0.0   # bonus added by PilotStation
var weapons_power : int   = 0     # 0..8  future power-management system

# ── signals ───────────────────────────────────────────────────────────────────
signal hull_changed(current: int, maximum: int)
signal shields_changed(current: float, maximum: int)
signal engine_changed(value: float)
signal oxygen_changed(value: float)


func _ready() -> void:
	add_to_group("ship")
	hull_current    = hull_max
	shields_current = float(shields_max)
	

func register_room(room_id, room_ref):
	rooms_registry[room_id] = room_ref


func _physics_process(delta: float) -> void:
	_tick_shields(delta)


func _tick_shields(delta: float) -> void:
	if shields_current >= float(shields_max):
		return
	var rate := shield_recharge_rate + shield_recharge_speed
	shields_current = minf(shields_current + rate * delta, float(shields_max))
	shields_changed.emit(shields_current, shields_max)

func _input(event):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# ALL of this must be indented inside the IF above
			print("--- RIGHT CLICK TRIGGERED ---")
			var world_pos = get_global_mouse_position()
			var all_rooms = get_tree().get_nodes_in_group("rooms")
			
			print("Rooms found in group: ", all_rooms.size())
			
			for room in all_rooms:
				if room is Control and room.get_global_rect().has_point(world_pos):
					print("SUCCESS: Clicked on room: ", room.name)
					var sm = get_tree().get_first_node_in_group("selection_manager")
					if sm:
						sm.distribute_units_to_tiles(room)
					return
# ── public API ────────────────────────────────────────────────────────────────

func take_hull_damage(amount: int) -> void:
	hull_current = maxi(hull_current - amount, 0)
	hull_changed.emit(hull_current, hull_max)

func repair_hull(amount: int) -> void:
	hull_current = mini(hull_current + amount, hull_max)
	hull_changed.emit(hull_current, hull_max)

## Returns true if the room_id exists in the registry and is valid
func _has_objective_room(room_id: String) -> bool:
	# Check if the key exists in our dictionary
	if rooms_registry.has(room_id):
		# Ensure the reference isn't null (optional but safer)
		return rooms_registry[room_id] != null
	
	return false

	
## Returns the Room node that contains `pos`, or null.
## Units call this on arrival to update their current_room reference.
func get_room_at_pos(pos: Vector2) -> Node:
	# Look through all children of the ship that are Rooms
	for child in get_children():
		if child is Room:
		# Check if the pos is inside the room's area
		# This assumes your Room has a way to check its bounds
			if child.is_position_inside(pos):
				return child
	return null

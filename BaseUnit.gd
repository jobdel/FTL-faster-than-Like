## BaseUnit.gd
## Shared base class for all unit types (player-controlled and enemy AI).
## Provides the common state variables, constants, and helper methods used by
## both Unit.gd (PlayerUnit) and Enemy.gd (EnemyAI).
##
## Extend this instead of CharacterBody2D directly:
##   Unit.gd  →  class_name Unit  extends BaseUnit
##   Enemy.gd →                   extends BaseUnit
class_name BaseUnit
extends CharacterBody2D

# ── shared exported properties ─────────────────────────────────────────────────
@export var speed : float = 80.0

# ── shared state ───────────────────────────────────────────────────────────────
## Unified combat/interaction target — Door, Station, or enemy unit.
## Always guard every access with: if is_instance_valid(current_target):
var current_target : Node  = null

## Room the unit is currently standing in.
## Set directly via _on_entered_room() when available; polled as fallback.
var current_room: Room = null 

## Saved destination to resume path after breaking a door or defeating a target.
var _resume_destination : Vector2 = Vector2.ZERO

var _path       : PackedVector2Array = PackedVector2Array()
var _path_index : int                = 0
var _last_dir   : String             = "Down"
var _smooth_dir : Vector2            = Vector2.DOWN

# ── shared constants ───────────────────────────────────────────────────────────
const _ARRIVE_SNAP       : float = 5.0
const _DOOR_SNAP_RADIUS  : float = 24.0
const _DOOR_ATTACK_RANGE : float = 128.0
const _DOOR_ATTACK_RATE  : float = 1.0
const _AI_THINK_INTERVAL : float = 2.0


# ── door signal auto-connection ───────────────────────────────────────────────
## On ready, connect to every door's door_destroyed signal.
## Fires synchronously before the door node is freed, so current_target is
## always cleared before any state handler can read it as a freed object.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		call_deferred("_connect_door_signals")


func _connect_door_signals() -> void:
	for door in get_tree().get_nodes_in_group("doors"):
		if is_instance_valid(door) and door.has_signal("door_destroyed"):
			if not door.is_connected("door_destroyed", _on_door_destroyed):
				door.connect("door_destroyed", _on_door_destroyed)


## Called synchronously the moment a door breaks (before queue_free).
## Immediately nulls current_target so every state handler that re-checks
## is_instance_valid() on the SAME frame will already see null — no crash.
## Re-evaluation (path resume + scan) is handled by on_door_destroyed, which
## fires one frame later via _notify_units_door_broken.
func _on_door_destroyed(door: Node) -> void:
	if is_instance_valid(current_target) and current_target == door:
		current_target = null
		print(name, " target cleared, re-scanning ship...")
	# Clear the room's shared breach target so walking units stop joining.
	if is_instance_valid(current_room):
		var at = current_room.get("active_target")
		if at == door:
			current_room.set("active_target", null)


# ── hostile faction helper ─────────────────────────────────────────────────────
## Returns the faction index that this unit treats as hostile.
## Override in each subclass:
##   Unit (team 0 / PLAYER): return 1 - int(team)
##   Enemy (owner_faction 1): return 0
func _get_hostile_faction() -> int:
	return 0


# ── take_damage duck-typing interface ──────────────────────────────────────────
## Receive damage. Override in subclasses that have HP.
## Callers should use duck-typing:
##   if target.has_method("take_damage"): target.take_damage(amount)
func take_damage(_amount: float) -> void:
	pass


# ── door event ────────────────────────────────────────────────────────────────
## Called by Door._notify_units_door_broken() when a door is destroyed.
## Override in subclasses to handle path recalculation and combat state.
func on_door_destroyed(_door: Node) -> void:
	pass


## Re-calculate the active movement path after a door obstacle is removed.
## Called as an alias by door notification code.  Override in subclasses.
func _recalculate_path() -> void:
	pass


## Re-assess objectives after a target is destroyed or a door is cleared.
## Override in subclasses to scan for new targets and resume saved paths.
func re_evaluate_mission() -> void:
	pass


## Assign a specific door as the attack target and save the resume destination.
## Override in subclasses to transition into the appropriate attack state.
func set_door_target(_door: Node, _resume_dest: Vector2) -> void:
	pass


# ── room tracking via signal ───────────────────────────────────────────────────
## Called by room_base._on_body_entered() so the room pushes the assignment
## instead of requiring the unit to poll.  Keeps current_room up-to-date
## without the per-frame loop over all rooms.
func _update_current_room() -> void:
	# 1. Grab all nodes assigned to the "rooms" group
	var rooms = get_tree().get_nodes_in_group("rooms")
	var found_room: Room = null

	for r in rooms:
		# 2. Check if the node is actually a Room class instance
		if r is Room:
			# 3. Use your preferred detection method. 
			# If your Room has an Area2D child named "DetectionArea":
			if r.has_node("DetectionArea"):
				var area = r.get_node("DetectionArea") as Area2D
				if area.overlaps_body(self):
					found_room = r
					break # Exit loop early once room is found
			
			# Alternative: Simple distance/rect check if not using Areas
			# elif r.get_rect().has_point(global_position):
				#found_room = r
				#break

	# 4. Only trigger logic if the room actually changed
		if current_room != found_room:
			current_room = found_room
			_on_room_changed()

func _on_room_changed() -> void:
	if current_room:
		print("Unit entered: ", current_room.room_name)
	else:
		print("Unit is in a hallway or vacuum!")

func _on_entered_room(room: Node) -> void:
	current_room = room


## Called by room_base._on_body_exited() when this unit leaves the room.
func _on_exited_room(room: Node) -> void:
	if current_room == room:
		current_room = null


# ── shared helpers ─────────────────────────────────────────────────────────────

func _dir_from_vec(v: Vector2) -> String:
	if abs(v.x) > abs(v.y) * 2.0:
		return "Right" if v.x >= 0.0 else "Left"
	else:
		return "Down" if v.y >= 0.0 else "Up"


## Returns the Room that this unit is currently standing in, or null.
func _get_current_room() -> Node:
	for room in get_tree().get_nodes_in_group("rooms"):
		if is_instance_valid(room) and room.has_method("get_tile_index_at"):
			if room.get_tile_index_at(global_position) != -1:
				return room
	return null


## Returns the Room that contains world-space position `pos`, or null.
func _get_room_at(pos: Vector2) -> Node:
	for room in get_tree().get_nodes_in_group("rooms"):
		if is_instance_valid(room) and room.has_method("get_tile_index_at"):
			if room.get_tile_index_at(pos) != -1:
				return room
	return null


## Returns the impassable hostile-faction door blocking movement toward `waypoint`.
## Faction is determined by _get_hostile_faction() — override in subclasses.
## Uses a perpendicular-band check to avoid false positives at junctions.
func _find_blocking_door(waypoint: Vector2) -> Node:
	var seg     : Vector2 = waypoint - global_position
	var seg_len : float   = seg.length()
	if seg_len < 0.001:
		return null
	var seg_dir  : Vector2 = seg / seg_len
	var perp_dir : Vector2 = Vector2(-seg_dir.y, seg_dir.x)
	var hostile  : int     = _get_hostile_faction()

	var all_doors := get_tree().get_nodes_in_group("doors")
	if all_doors.is_empty():
		print("DEBUG: [Force Audit] No doors found in 'doors' group — physics areas may not be set up")

	for door in all_doors:
		if not is_instance_valid(door):
			continue
		if not door.has_method("is_passable") or door.is_passable():
			continue
		var door_faction : int = int(door.get("owner_faction") if door.get("owner_faction") != null else 0)
		if door_faction != hostile:
			continue   # own-faction door — can pass freely
		var door_pos : Vector2 = (door as Node2D).global_position
		var to_door  : Vector2 = door_pos - global_position
		var along    : float   = to_door.dot(seg_dir)
		if along < -8.0 or along > seg_len + 8.0:
			continue
		if abs(to_door.dot(perp_dir)) <= 16.0:
			return door
	return null


## Returns the hostile-faction door blocking the nav path to `target_pos`.
## Uses NavigationManager.get_door_blocking_enemy_path for junction accuracy.
func _find_blocking_door_to_target(target_pos: Vector2) -> Node:
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if not is_instance_valid(nav) or not nav.has_method("get_door_blocking_enemy_path"):
		return null
	var door : Node = nav.get_door_blocking_enemy_path(global_position, target_pos)
	if not is_instance_valid(door):
		return null
	var door_faction : int = int(door.get("owner_faction") if door.get("owner_faction") != null else 0)
	if door_faction != _get_hostile_faction():
		return null
	return door

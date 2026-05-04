## unit.gd  –  attach to Unit.tscn (CharacterBody2D)
##
## Movement strategy
## ─────────────────
## SelectionManager queries NavigationManager for an AStar2D path of tile-centre
## world positions and calls move_along_path().  The unit walks waypoint-to-waypoint
## using global_position.move_toward() — pure ghost movement, no physics collision.
class_name Unit
extends BaseUnit

## Emitted whenever this unit's health changes. hp_pct is in [0.0, 1.0].
signal health_changed(hp_pct: float)

# ---------------------------------------------------------------------------
# Team
# ---------------------------------------------------------------------------
enum Team { PLAYER, ENEMY }

@export var team            : Team = Team.PLAYER
@export var is_ai_controlled : bool = false

# ---------------------------------------------------------------------------
# State Machine
# ---------------------------------------------------------------------------
## ATTACKING handles unit combat, door breaching, AND station sabotage.
## Uses duck-typing: if "health" in target → safe to hit; CharacterBody2D → ranged.
enum State { IDLE, WALKING, STATION_ACTIVE, ATTACKING, REPAIRING }

@export var race_stats : Resource
@export var stats      : UnitStats

@export var station_work_speed : float = 0.2

var is_selected : bool = false:
	set(value):
		is_selected = value
		modulate = Color(0.4, 1.0, 0.4) if is_selected else Color.WHITE

# ── private state ─────────────────────────────────────────────────────────────
var state          : State = State.IDLE
var target_station : Node  = null
## Shared health interface — makes Unit readable as target.health like Door/Station.
var health : float:
	get: return stats.health if is_instance_valid(stats) else 0.0

var _path_door_map : Dictionary = {}   # waypoint index → Door node
var _tween         : Tween      = null
var _manning_target : Node      = null


var _target_room       : Node  = null   # room this unit is currently travelling to
var _ai_think_cooldown : float = 0.0
var _xp_popup_cooldown : float = 0.0
var _xp_tween          : Tween = null

const _ATTACK_RANGE : float = 150.0
const _DAMAGE       : float = 10.0   # per bullet (unit vs unit)
var _fire_timer     : Timer = null
var _fire_target    : Node  = null   # kept separate so bullet system keeps working

# ── shared combat constants ───────────────────────────────────────────────────
const _DOOR_DAMAGE     : float = 10.0
const _SABOTAGE_DAMAGE : float = 10.0
const _SABOTAGE_RATE   : float = 1.5

## Shared attack timer — counts down for door breaching and station sabotage.
## Unit-vs-unit combat uses _fire_timer instead.
var _attack_timer : float = 0.0

# ── AI navigation ─────────────────────────────────────────────────────────────
var _nav_reserved_room : Node = null   # room pre-reserved during AI cross-room navigation

## Shared across all Unit instances: door → Array[Unit] currently breaching it.
## Prevents multiple AI units from stacking on the same door simultaneously.
static var _door_attacker_registry : Dictionary = {}

@onready var _sprite       : AnimatedSprite2D   = $AnimatedSprite2D
@onready var _path_line    : Line2D             = $PathLine
@onready var _progress     : Control            = get_node_or_null("HealthBar")
@onready var _health_fill  : ColorRect          = get_node_or_null("HealthBar/Fill")
@onready var _station_bar  : TextureProgressBar = get_node_or_null("StationBar")
@onready var _xp_popup     : Label              = get_node_or_null("XpPopup")
@onready var _click_area   : Area2D             = $ClickArea

# Station health restored per second while in REPAIRING state.
const _REPAIR_RATE    : float = 20.0
# Seat proximity trigger — half a tile + buffer to handle off-centre markers.
const _SEAT_SNAP_DIST : float = 20.0


func _ready() -> void:
	z_index = 10
	add_to_group("units")
	add_to_group("player_units" if team == Team.PLAYER else "enemy_units")
	collision_layer = 1   # always detectable by hitscan and Area2D
	collision_mask  = 0   # unit ghosts through everything (ghost movement)

	if not stats:
		stats = UnitStats.new()

	if _progress:
		_progress.hide()

	if _station_bar:
		_station_bar.min_value     = 0.0
		_station_bar.max_value     = 1.0
		_station_bar.value         = 0.0
		_station_bar.tint_progress = Color(0.3, 0.6, 1.0, 1.0)
		_station_bar.tint_under    = Color(0.05, 0.1, 0.25, 1.0)
		_station_bar.hide()

	if _xp_popup:
		_xp_popup.visible = false

	_sprite.play("Idle" + _last_dir)
	print(name, " initialized with Faction: ", team)
	call_deferred("_register_with_room")
	call_deferred("_reparent_path_line")
	call_deferred("_check_spawn_door_overlap")

	_fire_timer = Timer.new()
	_fire_timer.wait_time = 1.5
	_fire_timer.one_shot  = true
	_fire_timer.timeout.connect(_on_fire_timer_timeout)
	add_child(_fire_timer)

	# Door proximity sensor — detects the StaticBody2D inside each door (layer 1).
	# If no print appears, check that the door's StaticBody2D is on physics layer 1.
	var door_sensor := Area2D.new()
	door_sensor.name          = "DoorSensor"
	door_sensor.collision_layer = 0
	door_sensor.collision_mask  = 1
	var sensor_shape := CollisionShape2D.new()
	var sensor_circle := CircleShape2D.new()
	sensor_circle.radius = 20.0
	sensor_shape.shape   = sensor_circle
	door_sensor.add_child(sensor_shape)
	door_sensor.body_entered.connect(_on_door_sensor_body_entered)
	add_child(door_sensor)


func _reparent_path_line() -> void:
	# Detach from parent transform so the line renders in world space.
	# top_level = true keeps it in the scene tree but ignores the unit's transform,
	# which prevents waypoint drift caused by physics interpolation.
	_path_line.top_level = true
	_path_line.position  = Vector2.ZERO


## Fired by the DoorSensor Area2D when a physics body enters its radius.
## body is typically the door's StaticBody2D; its parent is the VDoor Node2D.
func _on_door_sensor_body_entered(body: Node) -> void:
	var door_node = body.get_parent()
	if not is_instance_valid(door_node) or not door_node.is_in_group("doors"):
		return
	print("UNIT: Detected door ", door_node.name)
	if door_node.get("owner_faction") == int(team):
		# Friendly door — open it.
		if door_node.has_method("reserve"):
			door_node.reserve(self)
	else:
		# Hostile door — stop and breach it if not already passable.
		if door_node.has_method("is_passable") and not door_node.is_passable() \
				and current_target != door_node:
			_resume_destination = _path[_path.size() - 1] if _path.size() > 0 else Vector2.ZERO
			current_target = door_node
			change_state(State.ATTACKING)


## Called deferred on spawn — opens any same-faction door we are already overlapping.
## Fixes the stuck-open bug where a unit spawns inside a door's Area2D and the
## body_entered signal never fires because the overlap pre-exists.
func _check_spawn_door_overlap() -> void:
	var sensor := get_node_or_null("DoorSensor") as Area2D
	if not is_instance_valid(sensor):
		return
	for body in sensor.get_overlapping_bodies():
		var door_node = body.get_parent()
		if not is_instance_valid(door_node) or not door_node.is_in_group("doors"):
			continue
		if door_node.get("owner_faction") == int(team):
			if door_node.has_method("reserve"):
				door_node.reserve(self)
				print("DEBUG: [", name, "] spawned overlapping door ", door_node.name, " — triggered open")


func _exit_tree() -> void:
	_cleanup_path()
	if is_instance_valid(current_room):
		current_room.release_unit(self)
	if is_instance_valid(_nav_reserved_room) and _nav_reserved_room != current_room:
		_nav_reserved_room.release_unit(self)
	if is_instance_valid(current_target) and "face_index" in current_target \
			and Unit._door_attacker_registry.has(current_target):
		Unit._door_attacker_registry[current_target].erase(self)

# Add this to Unit.gd (ensure it's not inside another function)
func move_to(target_pos: Vector2):
	# 1. If the unit was working at a station, they aren't anymore
	target_station = null
	
	# 2. Set the internal target (Claude likely uses a variable for this)
	# If your script uses a different name like _target_pos, change it here
	target_pos = target_pos 
	
	# 3. Change state to WALKING so the physics_process starts moving them
	if has_method("change_state"):
		change_state(State.WALKING)
# ===========================================================================
# MAIN LOOP
# ===========================================================================

func _physics_process(delta: float) -> void:
	if state == State.IDLE:
		_ai_think_cooldown -= delta
		if _ai_think_cooldown <= 0.0:
			_ai_think_cooldown = _AI_THINK_INTERVAL
			if is_ai_controlled:
				_ai_tick()
			else:
				_player_combat_tick()

	match state:
		State.IDLE:
			_check_seat_proximity()
		State.WALKING:
			_state_walking(delta)
		State.STATION_ACTIVE:
			_state_station_active(delta)
		State.ATTACKING:
			_state_attacking(delta)
		State.REPAIRING:
			_state_repairing(delta)
	_update_animations()


# ===========================================================================
# STATE HANDLERS
# ===========================================================================

func _state_walking(delta: float) -> void:
	if _path.is_empty() or _path_index >= _path.size():
		change_state(State.IDLE)
		return

	var target := _path[_path_index]

	# If the upcoming waypoint has an enemy-faction door that's still closed,
	# switch to ATTACKING (door-breach mode) before continuing.
	if _path_door_map.has(_path_index):
		var wp_door = _path_door_map[_path_index]
		if is_instance_valid(wp_door) and not wp_door.is_passable() \
				and wp_door.get("owner_faction") != int(team):
			_resume_destination = _path[_path.size() - 1]
			current_target = wp_door
			change_state(State.ATTACKING)
			return

	# AI units dynamically detect blocking hostile doors (no pre-scanned _path_door_map).
	# Group breaching: all units in the room attack the door together.
	if is_ai_controlled:
		var blocking_door := _find_blocking_door(target)
		if blocking_door != null:
			_resume_destination = _path[_path.size() - 1]
			current_target = blocking_door
			change_state(State.ATTACKING)
			return

	# Snap and advance when close enough to the current waypoint.
	if global_position.distance_to(target) < _ARRIVE_SNAP:
		# Notify any door at this exact waypoint that the unit has passed through.
		if _path_door_map.has(_path_index):
			var door = _path_door_map[_path_index]
			if is_instance_valid(door) and door.has_method("unit_passed_through"):
				door.unit_passed_through(self)
			if is_instance_valid(door):
				print("DEBUG: [", name, "] passed through door, re-verifying target")
		_path_index += 1
		if _path_index >= _path.size():
			global_position = target   # lock exactly onto tile centre
			velocity        = Vector2.ZERO
			# Hard-lock: if we somehow have a cross-faction station target, sabotage it.
			if is_instance_valid(target_station) and \
					int(target_station.get("owner_faction") if target_station.get("owner_faction") != null else -1) != int(team):
				current_target = target_station
				target_station = null
				change_state(State.ATTACKING)
			else:
				change_state(State.IDLE)
			return
		target = _path[_path_index]

	# Ghost movement — directly set position, no physics involved.
	var direction := (target - global_position).normalized()
	global_position = global_position.move_toward(target, speed * delta)
	velocity        = direction * speed   # kept for animation direction only

	if velocity.length_squared() > 0.0001:
		_smooth_dir = _smooth_dir.lerp(velocity.normalized(), 0.25).normalized()
		var new_dir := _dir_from_vec(_smooth_dir)
		if new_dir != _last_dir:
			_last_dir = new_dir

	update_path_line()


func _state_station_active(delta: float) -> void:
	if not is_instance_valid(target_station):
		change_state(State.IDLE)
		return
	# Station was destroyed while we were manning it — switch to repair mode.
	if not target_station.get("is_functional"):
		change_state(State.REPAIRING)
		return
	# Station bar driven by _tween (see change_state).
	# XP only awarded to player-controlled units.
	if is_ai_controlled:
		return
	var skill : String = target_station.get("xp_skill") if target_station.get("xp_skill") != null else ""
	if skill.is_empty():
		return
	_xp_popup_cooldown -= delta
	var levelled_up := stats.gain_xp(skill, delta)
	if levelled_up or _xp_popup_cooldown <= 0.0:
		_xp_popup_cooldown = 3.0
		_show_xp_popup(levelled_up)


func _state_repairing(delta: float) -> void:
	if not is_instance_valid(target_station):
		change_state(State.IDLE)
		return
	# Repair is complete — transition to properly manning the station.
	if target_station.get("is_functional"):
		target_station.on_unit_seated(self)
		change_state(State.STATION_ACTIVE)
		return
	# Restore station health each frame.
	if target_station.has_method("repair"):
		target_station.repair(_REPAIR_RATE * delta)
	# Update the bar to show live repair progress.
	if _station_bar and _station_bar.visible:
		var _h  = target_station.get("health")
		var _mh = target_station.get("max_health")
		var h  : float = _h  if _h  != null else 0.0
		var mh : float = _mh if _mh != null else 100.0
		_station_bar.value = (h / mh) if mh > 0.0 else 0.0
	# Award repair XP to player-controlled units.
	if not is_ai_controlled:
		_xp_popup_cooldown -= delta
		var levelled_up := stats.gain_xp("repair", delta)
		if levelled_up or _xp_popup_cooldown <= 0.0:
			_xp_popup_cooldown = 3.0
			_show_xp_popup(levelled_up)


## Unified attack handler — duck-typed, no class-name checks.
## CharacterBody2D targets → ranged fire.  All others → melee approach + take_damage().
func _state_attacking(delta: float) -> void:
	if not is_instance_valid(current_target):
		current_target = null
		print(name, " safely cleared null target and is re-scanning.")
		change_state(State.IDLE)
		return

	# ── Shared death / destroyed check ───────────────────────────────────────
	var _ct_health = current_target.get("health")
	if _ct_health != null and _ct_health <= 0:
		_on_target_destroyed()
		return

	# ── Melee targets: Door and Station (has take_damage but is not a mobile unit) ──
	if current_target.has_method("take_damage") and not (current_target is CharacterBody2D):
		# Disengage sabotage if a hostile unit enters the room.
		if "is_functional" in current_target and is_instance_valid(current_room):
			var hostile_group := "enemy_units" if team == Team.PLAYER else "player_units"
			for u in get_tree().get_nodes_in_group(hostile_group):
				if is_instance_valid(u) and \
						current_room.get_tile_index_at((u as Node2D).global_position) != -1:
					change_state(State.IDLE)
					return
			if team == Team.PLAYER:
				for u in get_tree().get_nodes_in_group("enemies"):
					if is_instance_valid(u) and \
							current_room.get_tile_index_at((u as Node2D).global_position) != -1:
						change_state(State.IDLE)
						return

		var target_pos     : Vector2 = (current_target as Node2D).global_position
		var dist           : float   = global_position.distance_to(target_pos)
		var is_door_target : bool    = "face_index" in current_target
		# Doors are attacked from range; stations require melee proximity.
		var approach_range : float   = _DOOR_ATTACK_RANGE if is_door_target else _DOOR_SNAP_RADIUS

		# Approach phase — walk toward the target until within attack range.
		if dist > approach_range:
			var dir := (target_pos - global_position).normalized()
			global_position = global_position.move_toward(target_pos, speed * delta)
			velocity        = dir * speed
			if velocity.length_squared() > 0.0001:
				_smooth_dir = _smooth_dir.lerp(velocity.normalized(), 0.25).normalized()
				var new_dir := _dir_from_vec(_smooth_dir)
				if new_dir != _last_dir:
					_last_dir = new_dir
			return

		# Attack phase — call take_damage() on the target.
		# Rate/damage differ by whether the target has a door face_index (door) or not (station).
		var attack_rate := _DOOR_ATTACK_RATE if is_door_target else _SABOTAGE_RATE
		var damage      := _DOOR_DAMAGE      if is_door_target else _SABOTAGE_DAMAGE
		velocity = Vector2.ZERO
		_attack_timer -= delta
		if _attack_timer <= 0.0:
			_attack_timer = attack_rate
			if is_door_target:
				print("DEBUG: [", name, "] attacking Door from distance. Distance: ", dist)
			if is_instance_valid(current_target) and current_target.has_method("take_damage"):
				current_target.take_damage(damage)
				if not is_instance_valid(current_target) or current_target.get("health") <= 0:
					current_target = null
					_on_target_destroyed()

	# ── Ranged unit combat ───────────────────────────────────────────────────
	else:
		# Disengage when the target leaves this room.
		if is_instance_valid(current_room):
			if current_room.get_tile_index_at((current_target as Node2D).global_position) == -1:
				change_state(State.IDLE)
				return

		var dist : float = global_position.distance_to((current_target as Node2D).global_position)
		if dist <= _ATTACK_RANGE:
			if _fire_timer.is_stopped():
				_fire_target = current_target
				_on_fire_timer_timeout()   # fire immediately on engagement
		else:
			_fire_timer.stop()


## Called when current_target's health reaches 0.
## Clears the target and delegates to re_evaluate_mission().
func _on_target_destroyed() -> void:
	print("[", Team.keys()[int(team)], "] Target destroyed: ",
		  current_target.name if is_instance_valid(current_target) else "?")
	current_target = null
	# Wait for the navigation map to process the removed obstacle before re-pathing.
	await get_tree().process_frame
	if not is_instance_valid(self):
		return
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	var path_check := PackedVector2Array()
	if is_instance_valid(nav) and _resume_destination != Vector2.ZERO:
		if is_ai_controlled:
			path_check = nav.get_enemy_nav_path(global_position, _resume_destination)
		elif nav.has_method("get_nav_path"):
			path_check = nav.get_nav_path(global_position, _resume_destination)
	print("DEBUG: [", name, "] Map refreshed, found new path: ", !path_check.is_empty())
	_scan_for_targets()
	re_evaluate_mission()


## Centralised re-evaluation: transitions to IDLE, triggers AI scan, and
## resumes any saved destination (e.g. the room behind a now-breached door).
## Call whenever a target is destroyed or a door along the path becomes passable.
func re_evaluate_mission() -> void:
	var dest := _resume_destination
	_resume_destination = Vector2.ZERO
	change_state(State.IDLE)
	if is_ai_controlled:
		_scan_for_targets()
	if dest == Vector2.ZERO:
		return
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if not nav:
		return
	var path : PackedVector2Array
	if is_ai_controlled:
		path = nav.get_enemy_nav_path(global_position, dest)
	else:
		path = nav.get_nav_path(global_position, dest)
	if path.size() > 0:
		print("DEBUG: [Unit] Resuming movement through breached door.")
		move_along_path(path)
	else:
		print("DEBUG: Re-scan failed - still no path found for ", name, " to ", dest)


## Called by Door._break() on every unit when a door is destroyed.
## Clears door-related combat state and delegates to re_evaluate_mission().
func on_door_destroyed(door: Node) -> void:
	print("DEBUG: Door destroyed! ", name, " is re-scanning for new path...")
	var was_attacking_door := (is_instance_valid(current_target) and current_target == door)
	if was_attacking_door:
		current_target = null
		_attack_timer  = 0.0
		# Preserve _resume_destination so re_evaluate_mission() can resume the path.
	# If we were walking through or attacking this door, re-evaluate immediately.
	if was_attacking_door or state == State.WALKING or state == State.ATTACKING:
		re_evaluate_mission()
	elif is_ai_controlled:
		# Small delay so NavigationServer fully processes the door removal.
		await get_tree().create_timer(0.1).timeout
		if is_instance_valid(self):
			_scan_for_targets()


# ===========================================================================
# STATE TRANSITIONS
# ===========================================================================

func change_state(new_state: State) -> void:
	if new_state == state:
		return

	match state:
		State.WALKING:
			_cleanup_path()
		State.STATION_ACTIVE:
			if _tween:
				_tween.kill()
				_tween = null
			if _station_bar:
				_station_bar.hide()
				_station_bar.value = 0.0
			_xp_popup_cooldown = 0.0
			# Preserve target_station when switching to REPAIRING (same station).
			if new_state != State.REPAIRING:
				if is_instance_valid(target_station) and target_station.has_method("on_unit_departing"):
					target_station.on_unit_departing(self)
				target_station = null
		State.REPAIRING:
			if _tween:
				_tween.kill()
				_tween = null
			if _station_bar:
				_station_bar.hide()
				_station_bar.value = 0.0
			_xp_popup_cooldown = 0.0
			# Preserve target_station when transitioning to STATION_ACTIVE (repair done).
			if new_state != State.STATION_ACTIVE:
				if is_instance_valid(target_station) and target_station.has_method("on_unit_stopped_repairing"):
					target_station.on_unit_stopped_repairing(self)
				target_station = null
		State.ATTACKING:
			# Deregister from door registry (duck-type: doors have face_index).
			if is_instance_valid(current_target) and "face_index" in current_target \
					and Unit._door_attacker_registry.has(current_target):
				Unit._door_attacker_registry[current_target].erase(self)
			# Reset unit-combat sprite offsets only when leaving unit-vs-unit combat.
			if not is_instance_valid(current_target) or (current_target is CharacterBody2D):
				set_sprite_offset(0.0)
				var _opp := _find_tile_opponent()
				if is_instance_valid(_opp) and _opp.has_method("set_sprite_offset"):
					_opp.set_sprite_offset(0.0)
			_fire_timer.stop()
			_fire_target   = null
			current_target = null
			_attack_timer  = 0.0

	match new_state:
		State.IDLE:
			collision_layer = 1
			_sprite.play("Idle" + _last_dir)
			# AI units re-evaluate immediately when ATTACKING ends.
			if is_ai_controlled and state == State.ATTACKING:
				_ai_think_cooldown = 0.0
			if state == State.WALKING:
				# All units (player and AI) track which room they arrived in.
				_update_current_room()
				# Notify the room so it can clear its green border when all units arrive.
				if is_instance_valid(current_room) and current_room.has_method("on_unit_arrived"):
					current_room.on_unit_arrived(self)
				# Mark the tile as occupied and re-route any same-faction unit that
				# pre-reserved this same slot (real-time slot conflict resolution).
				if is_instance_valid(current_room):
					var my_tile : int = current_room.get_tile_index_at(global_position)
					if my_tile != -1 and current_room.has_method("_on_tile_entered"):
						current_room._on_tile_entered(self, my_tile)
				# Tile-based station detection: if we landed directly on a station tile,
				# set _manning_target so _check_seat_proximity() picks it up next frame.
				_check_station_on_arrival()
				# Defer the room-assignment call so it runs AFTER change_state(IDLE)
				# sets state = IDLE.  Calling it inline would re-enter change_state
				# while state is still WALKING, causing _cleanup_path() to kill the
				# newly-set path and leaving the unit stuck.
				call_deferred("_deferred_station_check")
				# Apply combat visual offset if an opponent is on this tile.
				var opp := _find_tile_opponent()
				if is_instance_valid(opp):
					var my_offset := -6.0 if team == Team.PLAYER else 6.0
					set_sprite_offset(my_offset)
					if opp.has_method("set_sprite_offset"):
						opp.set_sprite_offset(-my_offset)
		State.WALKING:
			collision_layer = 1
			set_sprite_offset(0.0)
			# Release only the tile at the current position so a pre-reserved
			# destination tile in the same room is never wiped.
			if is_instance_valid(current_room):
				current_room.release_unit_from_position(self, global_position)
			var opp := _find_tile_opponent()
			if is_instance_valid(opp) and opp.has_method("set_sprite_offset"):
				opp.set_sprite_offset(0.0)
		State.ATTACKING:
			collision_layer = 1
			velocity        = Vector2.ZERO
			_attack_timer   = 0.0
			# Register in door registry (duck-type: doors have face_index).
			if is_instance_valid(current_target) and "face_index" in current_target:
				if not Unit._door_attacker_registry.has(current_target):
					Unit._door_attacker_registry[current_target] = []
				if self not in Unit._door_attacker_registry[current_target]:
					Unit._door_attacker_registry[current_target].append(self)
		State.STATION_ACTIVE:
			collision_layer = 1
			_sprite.play("OccupyStation")
			if _station_bar:
				_station_bar.tint_progress = Color(0.3, 0.6, 1.0, 1.0)  # blue
				_station_bar.value = 0.0
				_station_bar.show()
				_tween = create_tween()
				_tween.tween_property(_station_bar, "value", _station_bar.max_value, 2.0)
		State.REPAIRING:
			collision_layer = 1
			_sprite.play("OccupyStation")
			# Register with the station so no second unit tries to repair it.
			if is_instance_valid(target_station) and target_station.has_method("on_unit_repairing"):
				target_station.on_unit_repairing(self)
			if _station_bar:
				var _h  = target_station.get("health")    if is_instance_valid(target_station) else null
				var _mh = target_station.get("max_health") if is_instance_valid(target_station) else null
				var h  : float = _h  if _h  != null else 0.0
				var mh : float = _mh if _mh != null else 100.0
				_station_bar.tint_progress = Color(0.9, 0.5, 0.1, 1.0)  # orange for repair
				_station_bar.value = (h / mh) if mh > 0.0 else 0.0
				_station_bar.show()

	print(name, " State Change: ", State.keys()[state], " -> ", State.keys()[new_state])
	state = new_state



# ===========================================================================
# PUBLIC API
# ===========================================================================

## Detects left-clicks directly on this unit using world-space coordinates.
## Uses _input() + get_global_mouse_position() instead of Area2D.input_event
## because the SubViewport + Camera2D zoom setup causes physics picking offsets.
## set_input_as_handled() blocks room._gui_input so the room is not selected too.
const _CLICK_RADIUS : float = 14.0

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if global_position.distance_to(get_global_mouse_position()) > _CLICK_RADIUS:
		return
	get_viewport().set_input_as_handled()
	var sm := get_tree().get_first_node_in_group("selection_manager")
	if not sm:
		return
	if team == Team.PLAYER:
		if sm.has_method("select_unit"):
			sm.select_unit(self)
	else:
		if sm.has_method("target_enemy"):
			sm.target_enemy(self)


## Walk along a pre-computed world-space path from SelectionManager's AStarGrid2D.
## Each element is a tile-centre world position.
func move_along_path(path: PackedVector2Array) -> void:
	if path.is_empty():
		return
	# Any new path cancels a pending station assignment so the station tile is
	# freed immediately (SelectionManager already called release_unit on the room).
	_manning_target = null
	_path       = path
	_path_index = 0
	# Player-controlled units reserve every door that lies on their path.
	if team == Team.PLAYER and not is_ai_controlled:
		_scan_path_for_doors(path)
	change_state(State.WALKING)


## Scan all waypoints for nearby doors.
## Same-faction doors are reserved (auto-opened); enemy-faction doors are
## recorded in _path_door_map so _state_walking() can trigger ATTACK_DOOR.
##
## Doors sit at tile-face boundaries, roughly half a tile (16 px) from each
## tile-centre waypoint.  Checking exact waypoints with a small radius misses
## them entirely.  Instead we test the midpoint of each consecutive segment
## [i-1, i] — that midpoint is very close to the door — and map the hit to
## index i (the destination tile the unit is walking toward through the door).
func _scan_path_for_doors(path: PackedVector2Array) -> void:
	_path_door_map = {}
	# 18 px > half a tile (16 px) so boundary doors are always caught.
	const DOOR_MATCH_RADIUS := 18.0
	var doors := get_tree().get_nodes_in_group("doors")
	for i in range(1, path.size()):
		var seg_mid := (path[i - 1] + path[i]) * 0.5
		for door in doors:
			if not is_instance_valid(door):
				continue
			if (door as Node2D).global_position.distance_to(seg_mid) <= DOOR_MATCH_RADIUS:
				_path_door_map[i] = door
				# Only auto-open (reserve) doors of our own faction.
				if door.get("owner_faction") == int(team):
					if door.has_method("reserve"):
						door.reserve(self)
				break   # at most one door per segment


func set_manning_target(station: Node) -> void:
	_manning_target = station

func clear_manning_target(station: Node) -> void:
	if _manning_target == station:
		_manning_target = null

func set_bar_colors(fill: Color, bg: Color) -> void:
	if _health_fill:
		_health_fill.color = fill
	var bg_rect := get_node_or_null("HealthBar/Background") as ColorRect
	if bg_rect:
		bg_rect.color = bg

func engage(target: Node) -> void:
	print("[", Team.keys()[int(team)], "] Attacking [", target.name, "]")
	current_target = target
	change_state(State.ATTACKING)

## Order this unit to breach a hostile door directly (e.g. from a player right-click).
## Pass resume_dest to continue toward a destination once the door is destroyed.
func attack_door(door: Node, resume_dest: Vector2 = Vector2.ZERO) -> void:
	current_target      = door
	_resume_destination = resume_dest
	change_state(State.ATTACKING)

func set_sprite_offset(x_offset: float) -> void:
	_sprite.position.x = x_offset

func take_damage(amount: float) -> void:
	stats.health -= amount
	if _progress and _health_fill:
		_health_fill.size.x = _progress.size.x * stats.health_percent()
		_progress.visible   = stats.health < stats.max_health
	health_changed.emit(stats.health_percent())
	if stats.health <= 0.0:
		var opp := _find_tile_opponent()
		if is_instance_valid(opp) and opp.has_method("set_sprite_offset"):
			opp.set_sprite_offset(0.0)
		if is_instance_valid(current_room):
			current_room.release_unit(self)
		queue_free()

func _on_fire_timer_timeout() -> void:
	if not is_instance_valid(_fire_target):
		return
	BulletManager.fire(self, _fire_target, team, _DAMAGE, get_world_2d().direct_space_state)
	if not is_ai_controlled:
		var levelled_up := stats.gain_xp("combat", 2.0)
		_show_xp_popup(levelled_up)
	_fire_timer.start(_get_fire_cooldown())


func _show_xp_popup(levelled_up: bool) -> void:
	if not _xp_popup:
		return
	if _xp_tween:
		_xp_tween.kill()
	_xp_popup.text       = "++" if levelled_up else "+"
	_xp_popup.position   = Vector2(-4.0, -32.0)
	_xp_popup.modulate.a = 1.0
	_xp_popup.visible    = true
	_xp_tween = create_tween()
	_xp_tween.tween_property(_xp_popup, "position:y", -46.0, 1.2)
	_xp_tween.parallel().tween_property(_xp_popup, "modulate:a", 0.0, 1.2)
	_xp_tween.tween_callback(func():
		if is_instance_valid(_xp_popup):
			_xp_popup.visible = false
	)

func is_enemy(other_unit: Node) -> bool:
	return other_unit.get("team") != team


## BaseUnit override — returns the faction this unit attacks.
## Player (team 0) attacks faction 1; enemy-controlled (team 1) attacks faction 0.
func _get_hostile_faction() -> int:
	return 1 - int(team)


# ===========================================================================
# ANIMATIONS
# ===========================================================================

func _update_animations() -> void:
	match state:
		State.IDLE:
			pass
		State.WALKING:
			_sprite.play("Run" + _last_dir)
		State.STATION_ACTIVE:
			pass
		State.REPAIRING:
			pass   # OccupyStation animation set in change_state enter
		State.ATTACKING:
			if not is_instance_valid(current_target):
				return
			if current_target is CharacterBody2D:
				# Unit combat animations.
				var to_target := ((current_target as Node2D).global_position - global_position).normalized()
				_last_dir = _dir_from_vec(to_target)
				if not _fire_timer.is_stopped():
					_sprite.flip_h = (_last_dir == "Right")
					_sprite.play("Attacking")
				else:
					_sprite.flip_h = false
					_sprite.play("Idle" + _last_dir)
			elif "face_index" in current_target:
				# Door breach: face-aligned animation for AI, idle-facing for player.
				if is_ai_controlled:
					var face_idx : int = int(current_target.get("face_index") if current_target.get("face_index") != null else -1)
					const _FACE_TO_DIR : Array[String] = ["Up", "Right", "Down", "Left"]
					if face_idx >= 0 and face_idx < 4:
						_last_dir = _FACE_TO_DIR[face_idx]
					else:
						var to_door := ((current_target as Node2D).global_position - global_position).normalized()
						_last_dir = _dir_from_vec(to_door)
					var door_dist := global_position.distance_to((current_target as Node2D).global_position)
					if door_dist <= _DOOR_ATTACK_RANGE:
						_sprite.flip_h = (_last_dir == "Right")
						_sprite.play("Attacking")
					else:
						_sprite.flip_h = false
						_sprite.play("Run" + _last_dir)
				else:
					var to_door := ((current_target as Node2D).global_position - global_position).normalized()
					_last_dir = _dir_from_vec(to_door)
					_sprite.play("Idle" + _last_dir)
			else:
				# Station sabotage animation — face toward the station.
				var to_st := ((current_target as Node2D).global_position - global_position).normalized()
				_sprite.play("Idle" + _dir_from_vec(to_st))


# ===========================================================================
# HELPERS
# ===========================================================================

func _ai_tick() -> void:
	var my_faction     := int(team)
	var hostile_faction := 1 - my_faction
	var hostile_groups  := ["player_units"] if team == Team.ENEMY else ["enemy_units", "enemies"]

	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if not nav:
		return

	print("DEBUG: [", name, "] is in ",
		  current_room.name if is_instance_valid(current_room) else "No Room")

	var my_room := _get_current_room()
	if is_instance_valid(my_room):
		# ── Priority 1: Engage the nearest hostile unit in this room ──────────
		var nearest      : Node  = null
		var nearest_dist : float = INF
		for grp in hostile_groups:
			for u in get_tree().get_nodes_in_group(grp):
				if not is_instance_valid(u):
					continue
				if my_room.get_tile_index_at((u as Node2D).global_position) == -1:
					continue
				var d := global_position.distance_to((u as Node2D).global_position)
				if d < nearest_dist:
					nearest_dist = d
					nearest      = u
		if is_instance_valid(nearest):
			print("[", Team.keys()[my_faction], "] Attacking [", nearest.name, "]")
			engage(nearest)
			return
		print("DEBUG: [", Team.keys()[my_faction], "] No unit to attack in room")

		# ── Priority 2: Sabotage a hostile-faction station in this room ───────
		for s in get_tree().get_nodes_in_group("stations"):
			if not is_instance_valid(s) or not s.get("is_functional"):
				continue
			if int(s.get("owner_faction") if s.get("owner_faction") != null else 0) != hostile_faction:
				continue
			var s_pos   : Vector2 = (s as Node2D).global_position
			var in_room : bool    = my_room.get_tile_index_at(s_pos) != -1
			if not in_room:
				var seat_node := s.get("interaction_spot") as Marker2D
				in_room = is_instance_valid(seat_node) and \
						  my_room.get_tile_index_at(seat_node.global_position) != -1
			if not in_room:
				continue
			var best_tile : int = -1
			if my_room.has_method("request_assignment"):
				best_tile = my_room.request_assignment(self)
			elif my_room.has_method("request_unique_tile"):
				best_tile = my_room.request_unique_tile(self)
			if best_tile == -1:
				continue
			var my_tile : int = my_room.get_tile_index_at(global_position)
			if my_tile == best_tile:
				print("[", Team.keys()[my_faction], "] Attacking [", s.name, "]")
				current_target = s
				change_state(State.ATTACKING)
			else:
				_navigate_within_room_prereserved(my_room, best_tile, nav)
			return
		print("DEBUG: [", Team.keys()[my_faction], "] No station to attack in room")

	# ── Priority 3: Navigate toward a room with hostile units ────────────────
	var target_pos := _find_hostile_room_tile()
	if target_pos != Vector2.ZERO:
		var path : PackedVector2Array = nav.get_enemy_nav_path(global_position, target_pos)
		if path.size() > 0:
			move_along_path(path)
			return
		var door := _find_blocking_door_to_target(target_pos)
		if not is_instance_valid(door) and is_instance_valid(my_room) \
				and nav.has_method("get_door_blocking_room"):
			var target_room := _get_room_at(target_pos)
			if is_instance_valid(target_room):
				door = nav.get_door_blocking_room(my_room, target_room)
		# Room-based fallback: ask the room for its hostile exit doors directly.
		if not is_instance_valid(door) and is_instance_valid(current_room) \
				and current_room.has_method("get_exit_doors"):
			var exit_doors : Array = current_room.get_exit_doors(hostile_faction)
			if not exit_doors.is_empty():
				# Pick the exit door most aligned toward the destination.
				var to_dest := (target_pos - global_position).normalized()
				var best_dot := -INF
				for d in exit_doors:
					var dot := ((d as Node2D).global_position - global_position).normalized().dot(to_dest)
					if dot > best_dot:
						best_dot = dot
						door = d
		if is_instance_valid(door):
			print("DEBUG: [", name, "] is in [",
				  current_room.name if is_instance_valid(current_room) else "?",
				  "]. Targeting exit door: [", door.name, "]")
			_resume_destination = target_pos
			current_target = door
			change_state(State.ATTACKING)
			# Tell every same-faction unit in this room to attack the same door.
			_broadcast_door_target_to_room(door, target_pos, current_room)
		else:
			print("DEBUG: Pathfinding failed to ", target_pos, " - Path is blocked")
		return

	# ── Priority 4: Navigate toward nearest hostile-faction station ──────────
	var station_pos := _find_hostile_station_tile()
	if station_pos != Vector2.ZERO:
		var path : PackedVector2Array = nav.get_enemy_nav_path(global_position, station_pos)
		if path.size() > 0:
			move_along_path(path)
			return
		var door := _find_blocking_door_to_target(station_pos)
		if not is_instance_valid(door) and is_instance_valid(my_room) \
				and nav.has_method("get_door_blocking_room"):
			var target_room := _get_room_at(station_pos)
			if is_instance_valid(target_room):
				door = nav.get_door_blocking_room(my_room, target_room)
		# Room-based fallback: ask the room for its hostile exit doors directly.
		if not is_instance_valid(door) and is_instance_valid(current_room) \
				and current_room.has_method("get_exit_doors"):
			var exit_doors : Array = current_room.get_exit_doors(hostile_faction)
			if not exit_doors.is_empty():
				var to_dest := (station_pos - global_position).normalized()
				var best_dot := -INF
				for d in exit_doors:
					var dot := ((d as Node2D).global_position - global_position).normalized().dot(to_dest)
					if dot > best_dot:
						best_dot = dot
						door = d
		if is_instance_valid(door):
			print("DEBUG: [", name, "] is in [",
				  current_room.name if is_instance_valid(current_room) else "?",
				  "]. Targeting exit door: [", door.name, "]")
			_resume_destination = station_pos
			current_target = door
			change_state(State.ATTACKING)
			# Tell every same-faction unit in this room to attack the same door.
			_broadcast_door_target_to_room(door, station_pos, current_room)
		else:
			print("DEBUG: Pathfinding failed to ", station_pos, " - Path is blocked")
		return

	# ── Priority 5: Spread to any empty tile in current room ─────────────────
	if is_instance_valid(my_room):
		var my_tile5    : int = my_room.get_tile_index_at(global_position)
		var spread_tile : int = -1
		if my_room.has_method("request_assignment"):
			spread_tile = my_room.request_assignment(self)
		elif my_room.has_method("request_unique_tile"):
			spread_tile = my_room.request_unique_tile(self)
		if spread_tile != -1 and spread_tile != my_tile5:
			_navigate_within_room_prereserved(my_room, spread_tile, nav)


## Scans the current room for enemy units and engages the nearest one.
## If in an enemy-faction room with no enemies, auto-sabotages the station.
## Runs on the same _AI_THINK_INTERVAL tick as _ai_tick(), but for player units.
func _player_combat_tick() -> void:
	if not is_instance_valid(current_room):
		_update_current_room()
	if not is_instance_valid(current_room):
		return
	var nearest      : Node  = null
	var nearest_dist : float = _ATTACK_RANGE
	var all_enemies  : Array = get_tree().get_nodes_in_group("enemy_units")
	for eu in get_tree().get_nodes_in_group("enemies"):
		if not all_enemies.has(eu):
			all_enemies.append(eu)
	for eu in all_enemies:
		if not is_instance_valid(eu):
			continue
		if current_room.get_tile_index_at((eu as Node2D).global_position) == -1:
			continue
		var d := global_position.distance_to((eu as Node2D).global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest      = eu
	if is_instance_valid(nearest):
		engage(nearest)
		return
	print("DEBUG: No enemy to attack")

	# No enemies to fight — if inside an enemy-faction room, sabotage its station.
	if int(current_room.get("owner_faction") if current_room.get("owner_faction") != null else 0) == 1:
		for s in get_tree().get_nodes_in_group("stations"):
			if not is_instance_valid(s) or not s.get("is_functional"):
				continue
			if int(s.get("owner_faction") if s.get("owner_faction") != null else 0) != 1:
				continue   # only target enemy-faction stations
			var in_room: bool = current_room.get_tile_index_at((s as Node2D).global_position) != -1
			if not in_room:
				var seat := s.get("interaction_spot") as Marker2D
				in_room = is_instance_valid(seat) and \
						  current_room.get_tile_index_at(seat.global_position) != -1
			if in_room:
				print("[", Team.keys()[int(team)], "] Attacking [", s.name, "]")
				current_target = s
				change_state(State.ATTACKING)
				return
		print("DEBUG: No station to attack")
	# No enemy station in room — attack the nearest blocked enemy door to proceed.
	if int(current_room.get("owner_faction") if current_room.get("owner_faction") != null else 0) == 1:
		var best_door : Node  = null
		var best_dist : float = INF
		for door in get_tree().get_nodes_in_group("doors"):
			if not is_instance_valid(door):
				continue
			if not door.has_method("is_passable") or door.is_passable():
				continue
			if int(door.get("owner_faction") if door.get("owner_faction") != null else 0) != 1:
				continue   # only attack enemy-faction doors
			var dist := global_position.distance_to((door as Node2D).global_position)
			if dist < best_dist:
				best_dist = dist
				best_door = door
		if is_instance_valid(best_door):
			print("[", Team.keys()[int(team)], "] Attacking [", best_door.name, "]")
			_resume_destination = Vector2.ZERO
			current_target = best_door
			change_state(State.ATTACKING)


## Returns fire cooldown in seconds, reduced by the unit's 'weapons' skill level.
## Level 0 = 1.5 s, level 1 ≈ 1.05 s, level 2 ≈ 0.74 s, level 3 ≈ 0.51 s.
func _get_fire_cooldown() -> float:
	var level : int = stats.skills.get("weapons", {"level": 0}).get("level", 0)
	return 1.5 * pow(0.7, level)


func _update_current_room() -> void:
	# Prefer ship.get_room_at_pos() when available — single authoritative lookup.
	var ship := get_tree().get_first_node_in_group("ship")
	if is_instance_valid(ship) and ship.has_method("get_room_at_pos"):
		var r : Node = ship.get_room_at_pos(global_position)
		if is_instance_valid(r):
			current_room = r
			print("DEBUG: [", name, "] is in ", current_room.name)
			return
	for room in get_tree().get_nodes_in_group("rooms"):
		if room.get_tile_index_at(global_position) != -1:
			current_room = room
			print("DEBUG: [", name, "] is in ", current_room.name)
			return


## Deferred counterpart to the WALKING→IDLE arrival block.
## Runs one frame after change_state(IDLE) completes so state is truly IDLE,
## which means move_along_path → change_state(WALKING) works without re-entrancy.
## Guards against state having changed in the same frame (e.g. combat engaged).
func _deferred_station_check() -> void:
	if state != State.IDLE:
		return
	if _manning_target != null:
		return   # _check_station_on_arrival already assigned a target this frame
	if is_instance_valid(current_room) and current_room.has_method("check_for_available_assignments"):
		current_room.check_for_available_assignments(self)


func _check_station_on_arrival() -> void:
	# Primary: tile-index match inside the current room — works after any rotation.
	if is_instance_valid(current_room):
		var my_tile : int = current_room.get_tile_index_at(global_position)
		var stn_tile : int = current_room.get("_station_tile_index") if current_room.get("_station_tile_index") != null else -1
		if my_tile != -1 and my_tile == stn_tile:
			var s : Node = current_room.get("_station")
			if is_instance_valid(s) and not s.get("is_manned"):
				# Faction gate: only target same-faction stations.
				if can_man_station(s):
					set_manning_target(s)
					return

	# Fallback: world-space proximity check for stations in any room.
	for station in get_tree().get_nodes_in_group("stations"):
		# Skip stations already occupied; broken stations are still valid (for repair).
		if station.get("is_manned"):
			continue
		# Faction gate: never target an opposing-faction station.
		if not can_man_station(station):
			continue
		var seat := station.get("interaction_spot") as Marker2D
		if not is_instance_valid(seat):
			continue
		if global_position.distance_to(seat.global_position) <= _SEAT_SNAP_DIST:
			set_manning_target(station)
			return


## Hard faction gate — returns true only when this unit may man the station.
## A unit can never man a station whose owner_faction differs from its own team.
func can_man_station(station: Node) -> bool:
	var station_faction : int = int(station.get("owner_faction") if station.get("owner_faction") != null else -1)
	return int(team) == station_faction


func _check_seat_proximity() -> void:
	if not is_instance_valid(_manning_target):
		_manning_target = null
		return
	var seat := _manning_target.get("interaction_spot") as Marker2D
	if not is_instance_valid(seat):
		return
	if global_position.distance_to(seat.global_position) > _SEAT_SNAP_DIST:
		return
	var station    := _manning_target
	_manning_target = null
	# Hard-lock: if somehow a cross-faction station ended up as a manning target,
	# discard it silently rather than snapping the unit to the enemy seat.
	if not can_man_station(station):
		return
	target_station  = station
	# Snap to the exact seat world position — handles rotated and L-shaped rooms.
	global_position = seat.global_position
	if station.get("is_functional"):
		station.on_unit_seated(self)
		change_state(State.STATION_ACTIVE)
	else:
		change_state(State.REPAIRING)


## Draw the remaining path waypoints as a Line2D.
func update_path_line() -> void:
	if state != State.WALKING or _path.is_empty():
		_path_line.points = PackedVector2Array()
		return
	# _path_line has top_level=true so its points are in world space directly.
	var pts := PackedVector2Array()
	pts.append(global_position)
	for i in range(_path_index, _path.size()):
		pts.append(_path[i])
	_path_line.points = pts


func _register_with_room() -> void:
	for room in get_tree().get_nodes_in_group("rooms"):
		var index: int = room.get_tile_index_at(global_position)
		if index != -1:
			room.reserve_tile(index, self, false)
			current_room = room
			return


func _find_tile_opponent() -> Node:
	for u in get_tree().get_nodes_in_group("units"):
		if u == self or not is_instance_valid(u):
			continue
		if u.get("team") == team:
			continue
		if global_position.distance_to((u as Node2D).global_position) < 8.0:
			return u
	# Also check Enemy.gd instances (in "enemies" group, not "units").
	if team == Team.PLAYER:
		for e in get_tree().get_nodes_in_group("enemies"):
			if is_instance_valid(e) and global_position.distance_to((e as Node2D).global_position) < 8.0:
				return e
	return null



func _cleanup_path() -> void:
	# Release reservations for any doors the unit never reached.
	for i in _path_door_map:
		if i >= _path_index:
			var door = _path_door_map[i]
			if is_instance_valid(door) and door.has_method("release_reservation"):
				door.release_reservation(self)
	_path_door_map = {}

	_path_line.points = PackedVector2Array()
	_path       = PackedVector2Array()
	_path_index = 0
	velocity    = Vector2.ZERO
	_sprite.play("Idle" + _last_dir)


## Triggers immediate AI re-evaluation on the next physics frame.
func _scan_for_targets() -> void:
	_ai_think_cooldown = 0.0


## Navigate to a tile pre-reserved by request_assignment (skips the reserve call).
func _navigate_within_room_prereserved(room: Node, tile_idx: int, nav: Node) -> void:
	if is_instance_valid(_nav_reserved_room) and _nav_reserved_room != room:
		_nav_reserved_room.release_unit(self)
		_nav_reserved_room = null
	_nav_reserved_room = room
	var target_pos : Vector2 = room.get_tile_center(tile_idx)
	var path : PackedVector2Array = nav.get_enemy_nav_path(global_position, target_pos)
	if path.size() > 0:
		move_along_path(path)
	else:
		print("DEBUG: Pathfinding failed to ", target_pos, " - Path is blocked")


## Returns a tile centre in the nearest room containing hostile units.
func _find_hostile_room_tile() -> Vector2:
	var hostile_group := "player_units" if team == Team.ENEMY else "enemy_units"
	var target_room : Node  = null
	var best_dist   : float = INF
	for room in get_tree().get_nodes_in_group("rooms"):
		if not is_instance_valid(room) or not room.has_method("get_tile_index_at"):
			continue
		var has_hostile := false
		for u in get_tree().get_nodes_in_group(hostile_group):
			if is_instance_valid(u) and room.get_tile_index_at((u as Node2D).global_position) != -1:
				has_hostile = true
				break
		if not has_hostile:
			continue
		if not room is Node2D:
			continue
		var d := global_position.distance_to((room as Node2D).global_position)
		if d < best_dist:
			best_dist   = d
			target_room = room
	if not is_instance_valid(target_room):
		return Vector2.ZERO
	if is_instance_valid(_nav_reserved_room):
		_nav_reserved_room.release_unit(self)
		_nav_reserved_room = null
	var tile_idx : int = -1
	if target_room.has_method("request_assignment"):
		tile_idx = target_room.request_assignment(self)
	elif target_room.has_method("request_unique_tile"):
		tile_idx = target_room.request_unique_tile(self)
	if tile_idx == -1:
		return Vector2.ZERO
	_nav_reserved_room = target_room
	return target_room.get_tile_center(tile_idx)


## Returns a tile centre adjacent to the nearest hostile-faction station.
func _find_hostile_station_tile() -> Vector2:
	var hostile_faction := 1 - int(team)
	var best_room    : Node  = null
	var best_dist    : float = INF
	var best_station : Node  = null
	for s in get_tree().get_nodes_in_group("stations"):
		if not is_instance_valid(s) or not s.get("is_functional"):
			continue
		if int(s.get("owner_faction") if s.get("owner_faction") != null else 0) != hostile_faction:
			continue
		var s_pos : Vector2 = (s as Node2D).global_position
		var d := global_position.distance_to(s_pos)
		if d < best_dist:
			best_dist    = d
			best_station = s
			for room in get_tree().get_nodes_in_group("rooms"):
				if not is_instance_valid(room):
					continue
				var in_room: bool = room.get_tile_index_at(s_pos) != -1
				if not in_room:
					var seat := s.get("interaction_spot") as Marker2D
					in_room = is_instance_valid(seat) and room.get_tile_index_at(seat.global_position) != -1
				if in_room:
					best_room = room
					break
	if not is_instance_valid(best_room) or not is_instance_valid(best_station):
		return Vector2.ZERO
	if is_instance_valid(_nav_reserved_room):
		_nav_reserved_room.release_unit(self)
		_nav_reserved_room = null
	var tile_idx : int = -1
	if best_room.has_method("request_assignment"):
		tile_idx = best_room.request_assignment(self)
	elif best_room.has_method("request_unique_tile"):
		tile_idx = best_room.request_unique_tile(self)
	if tile_idx == -1:
		return Vector2.ZERO
	_nav_reserved_room = best_room
	return best_room.get_tile_center(tile_idx)


# ===========================================================================
# ROOM-BASED DOOR TARGETING
# ===========================================================================

## Broadcasts a door-attack order to all idle or walking AI same-faction units
## in `room`. Called when one unit identifies a blocking door so the whole squad
## converges on it without waiting for individual AI ticks.
func _broadcast_door_target_to_room(door: Node, resume_dest: Vector2, room: Node) -> void:
	if not is_instance_valid(room):
		return
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or u == self:
			continue
		if u.get("team") != team:
			continue
		if not u.get("is_ai_controlled"):
			continue
		if room.get_tile_index_at((u as Node2D).global_position) == -1:
			continue
		var u_state = u.get("state")
		# Don't interrupt a unit already fighting an enemy unit.
		if u_state == State.STATION_ACTIVE or u_state == State.REPAIRING:
			continue
		if u_state == State.ATTACKING and \
				is_instance_valid(u.get("current_target")) and \
				u.get("current_target") is CharacterBody2D:
			continue
		if u.has_method("attack_door"):
			u.attack_door(door, resume_dest)


## Returns the impassable hostile-faction door that exits `room` and is most
## aligned toward `destination`. Used when direct pathfinding fails so that
## all units in the room converge on the correct exit door.
func _find_exit_door_toward(room: Node, destination: Vector2) -> Node:
	var best_door : Node  = null
	var best_dot  : float = -INF
	var to_dest := (destination - global_position).normalized()
	for door in get_tree().get_nodes_in_group("doors"):
		if not is_instance_valid(door) or door.is_passable():
			continue
		var door_faction := int(door.get("owner_faction") if door.get("owner_faction") != null else 0)
		if door_faction == int(team):
			continue  # own-faction — can pass
		var host_pos : Vector2 = door.get("host_tile_world_pos") if door.get("host_tile_world_pos") != null else Vector2.ZERO
		var door_pos : Vector2 = (door as Node2D).global_position
		var connected : Vector2 = (host_pos != Vector2.ZERO and room.get_tile_index_at(host_pos) != -1) \
					  or room.get_tile_index_at(door_pos) != -1
		if not connected:
			continue
		var to_door := (door_pos - global_position).normalized()
		var dot := to_door.dot(to_dest)
		if dot > best_dot:
			best_dot  = dot
			best_door = door
	return best_door

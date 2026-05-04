## enemy.gd  –  attach to enemy.tscn (CharacterBody2D)
##
## Variation of Unit that belongs to the enemy faction.
## Uses the same animation set (IdleDown/Up/Left/Right, RunDown/…).
## AI movement uses get_enemy_nav_path() which respects locked-door A* points.
## When a door blocks the only route the enemy enters ATTACK_DOOR state,
## chips the door's health down, then resumes once the door is passable.
extends BaseUnit
class_name Enemy

enum State { IDLE, WALKING, ATTACKING, ATTACK_DOOR, SABOTAGE }

@export var owner_faction : int = 1   # 1 = enemy faction

# ── door-combat constants ──────────────────────────────────────────────────
const _DOOR_DAMAGE : float = 20.0   # health removed per hit (higher than player)

# ── station-sabotage constants ─────────────────────────────────────────────
const _STATION_DAMAGE      : float = 10.0  # health removed per sabotage hit
const _STATION_ATTACK_RATE : float = 1.5   # seconds between sabotage hits

# ── unit-combat constants ───────────────────────────────────────────────────
const _ATTACK_RANGE : float = 150.0
const _DAMAGE       : float = 10.0

## Static registry: door Node → Array[Enemy] currently attacking that door.
## Shared across all instances so simultaneous AI ticks see each other's state.
#static var _door_attacker_registry : Dictionary = {}
#static var _door_destructor_registry: Dictionary = {}
# ── health ─────────────────────────────────────────────────────────────────────
var _health    : float = 100.0
var max_health : float = 100.0

var health : float:
	get: return _health

var current_target_door = null

func take_damage(amount: float) -> void:
	_health = maxf(0.0, _health - amount)
	if _health <= 0.0:
		if is_instance_valid(current_room):
			current_room.release_unit(self)
		queue_free()

## BaseUnit override — enemies attack player-faction (0) doors and units.
func _get_hostile_faction() -> int:
	return 0

# ── private state ──────────────────────────────────────────────────────────────
var state : State = State.IDLE

# _ATTACK_DOOR fields
var _door_attack_timer : float   = 0.0
## Per-unit lateral offset so multiple units spread out instead of stacking at the door.
var _breach_offset     : Vector2 = Vector2.ZERO

# SABOTAGE fields
var _station_attack_timer : float = 0.0

# Combat fields
var _fire_timer  : Timer = null
var _fire_target : Node  = null

# AI tick timer
var _ai_timer : float = 0.0

# Room tracking
var _nav_reserved_room     : Node = null   # room where a pre-navigation tile is reserved
var _last_room_during_walk : Node = null   # room at the start of the current WALKING state
var objective_id: String = "room_base" # Or whatever your default room ID is
var ship_ref: Ship

@onready var _sprite      : AnimatedSprite2D = $AnimatedSprite2D
#@onready var _click_area  : Area2D           = $ClickArea

func _ready() -> void:
	add_to_group("enemies")
	add_to_group("enemy_units")
	collision_layer = 1   # always detectable by hitscan and Area2D
	_sprite.play("Idle" + _last_dir)
	print(name, " initialized with Faction: ", owner_faction)
	ship_ref = get_tree().get_first_node_in_group("ship") as Ship

	_fire_timer = Timer.new()
	_fire_timer.wait_time = 1.5
	_fire_timer.one_shot  = true
	_fire_timer.timeout.connect(_on_fire_timer_timeout)
	add_child(_fire_timer)
	call_deferred("_init_room_tracking")
	call_deferred("_check_spawn_door_overlap")

	
	ship_ref = get_tree().get_first_node_in_group("ship") as Ship

func _init_room_tracking() -> void:
	current_room = _get_current_room()
	if is_instance_valid(current_room):
		var tile_idx : int = current_room.get_tile_index_at(global_position)
		if tile_idx != -1:
			current_room.reserve_tile(tile_idx, self, false)


## Opens any same-faction door we are already overlapping at spawn time.
## Deferred so the physics server has registered all initial overlaps.
func _check_spawn_door_overlap() -> void:
	for door in get_tree().get_nodes_in_group("doors"):
		if not is_instance_valid(door):
			continue
		var door_faction : int = int(door.get("owner_faction") if door.get("owner_faction") != null else -1)
		if door_faction != owner_faction:
			continue
		var door_pos : Vector2 = (door as Node2D).global_position
		if global_position.distance_to(door_pos) <= 24.0:
			if door.has_method("reserve"):
				door.reserve(self)
				print("DEBUG: [", name, "] spawned overlapping door ", door.name, " — triggered open")


func _exit_tree() -> void:
	_cleanup_path()
	if is_instance_valid(current_room):
		current_room.release_unit(self)
	if is_instance_valid(_nav_reserved_room) and _nav_reserved_room != current_room:
		_nav_reserved_room.release_unit(self)
	# Only de-register from the door registry when we were actively attacking a door.
	if state == State.ATTACK_DOOR and is_instance_valid(current_target):
		pass # We no longer need to manage a registry here
	# The _on_door_destroyed signal handles the logic now.


# ===========================================================================
# MAIN LOOP
# ===========================================================================

func _physics_process(delta: float) -> void:
	# AI tick fires while idle with no active task.
	if state == State.IDLE:
		_ai_timer -= delta
		if _ai_timer <= 0.0:
			_ai_timer = _AI_THINK_INTERVAL
			_ai_tick()

	match state:
		State.IDLE:
			pass
		State.WALKING:
			_state_walking()
		State.ATTACKING:
			_state_attacking()
		State.ATTACK_DOOR:
			_state_attack_door(delta)
		State.SABOTAGE:
			_state_sabotage(delta)
	_update_animations()


# ===========================================================================
# STATE HANDLERS
# ===========================================================================

func _state_walking() -> void:
	if _path.is_empty() or _path_index >= _path.size():
		change_state(State.IDLE)
		return

	var target := _path[_path_index]

	# Join a room-wide breach if another unit has already identified the blocking door.
	if is_instance_valid(current_room):
		var breach : Node = current_room.get("active_target")
		if is_instance_valid(breach) and breach.has_method("is_passable") and not breach.is_passable():
			_resume_destination = _path[_path.size() - 1]
			current_target = breach
			change_state(State.ATTACK_DOOR)
			return

	# Check for an impassable door at the upcoming waypoint before moving there.
	var blocking_door := _find_blocking_door(target)
	if blocking_door != null:
		# Group breaching: all units in the room attack the door together.
		_resume_destination = _path[_path.size() - 1]
		current_target = blocking_door
		change_state(State.ATTACK_DOOR)
		return

	if global_position.distance_to(target) < _ARRIVE_SNAP:
		_path_index += 1
		# Detect room transitions — means we just walked through a door.
		var new_room := _get_current_room()
		if is_instance_valid(new_room) and is_instance_valid(_last_room_during_walk) \
				and new_room != _last_room_during_walk:
			print("DEBUG: [", name, "] passed through door, re-verifying target")
			_last_room_during_walk = new_room
		if _path_index >= _path.size():
			velocity = Vector2.ZERO
			change_state(State.IDLE)
			return
		target = _path[_path_index]

	var direction := (target - global_position).normalized()
	velocity = direction * speed
	move_and_slide()

	if velocity.length_squared() > 0.0001:
		_smooth_dir = _smooth_dir.lerp(velocity.normalized(), 0.25).normalized()
		var new_dir := _dir_from_vec(_smooth_dir)
		if new_dir != _last_dir:
			_last_dir = new_dir


func _state_attacking() -> void:
	if not is_instance_valid(current_target):
		current_target = null
		print(name, " target cleared, re-scanning ship...")
		change_state(State.IDLE)
		return
	var dist : float = global_position.distance_to((current_target as Node2D).global_position)
	if dist <= _ATTACK_RANGE:
		if _fire_timer.is_stopped():
			_fire_target = current_target
			_on_fire_timer_timeout()   # fire immediately on engagement
	else:
		_fire_timer.stop()


func _on_fire_timer_timeout() -> void:
	# SAFETY CHECK: Only deal damage if the target still exists
	if is_instance_valid(current_target):
		# Your existing fire/bullet code
		# Example: current_target.take_damage(damage_amount)
		_fire_timer.start(1.0) # Restart the attack loop
	else:
	# If the target is gone, stop the timer and go back to Idle
		_fire_timer.stop()
		change_state(State.IDLE)


func _state_attack_door(delta: float) -> void:
	# 1. EXIT CHECK: If door is gone or broken, stop trying to move to it
	if not is_instance_valid(current_target):
		current_target = null
		#change_state(State.IDLE)
		re_evaluate_mission()
		return
	# 2. PROXIMITY CHECK (Safe access to position)
	var door_pos := (current_target as Node2D).global_position
	# Door was destroyed or freed — clear target and resume path.
	if not is_instance_valid(current_target) or current_target.get("is_broken") == true:
		current_target = null
		print(name, " target cleared, re-scanning ship...")
		_resume_after_door()
		return
	#var door_pos  : Vector2 = (current_target as Node2D).global_position
	# Each unit approaches a slightly offset position so the group spreads out.
	var stand_pos : Vector2 = door_pos + _breach_offset
	var door_dist : float   = global_position.distance_to(stand_pos)
	# Distance Attacking: if the unit is in the same room as the door (door is
	# within the room's bounding rect), attack from any position in the room.
	# This fixes 'back row' units that stop walking but never reach attack range.
	var same_room_as_door := false
	if is_instance_valid(current_room) and current_room is Control:
		var room_rect := Rect2(
			(current_room as Control).global_position,
			(current_room as Control).size
		)
		same_room_as_door = room_rect.has_point(door_pos)
	# Approach phase — only needed when outside the door's room.
	if not same_room_as_door and door_dist > _DOOR_ATTACK_RANGE:
		var dir := (stand_pos - global_position).normalized()
		velocity = dir * speed
		move_and_slide()
		if velocity.length_squared() > 0.0001:
			_smooth_dir = _smooth_dir.lerp(velocity.normalized(), 0.25).normalized()
			var new_dir := _dir_from_vec(_smooth_dir)
			if new_dir != _last_dir:
				_last_dir = new_dir
		return
	# Attack phase — stand still and chip the door.
	velocity = Vector2.ZERO
	_door_attack_timer -= delta
	if _door_attack_timer <= 0.0:
		_door_attack_timer = _DOOR_ATTACK_RATE
		print("DEBUG: [", name, "] attacking door. Distance: ",
			  global_position.distance_to(door_pos), " | same room: ", same_room_as_door)
		if current_target.has_method("take_damage"):
			current_target.take_damage(_DOOR_DAMAGE)
			# CRITICAL: take_damage triggers door_destroyed signal synchronously,
			# which sets current_target = null via _on_door_destroyed.
			# Re-check before accessing any property.
			if is_instance_valid(current_target):
				var hp = current_target.get("health")
				print("[ENEMY] Attacking [", current_target.name, "] | Target Health: ", hp if hp != null else "?")


func _on_attack_door_timer_timeout():
	# ALWAYS check if the door still exists before attacking it
	if not is_instance_valid(current_target_door):
		current_target_door = null
		re_evaluate_mission() # Look for a new target
		return
	
	# Only then do the damage
	#current_target_door.take_damage(attack_damage)


func _state_sabotage(delta: float) -> void:
	# Safety: clear and bail immediately if the station was freed.
	if not is_instance_valid(current_target):
		current_target = null
		print(name, " target cleared, re-scanning ship...")
		change_state(State.IDLE)
		return

	# Disengage immediately if a player unit enters the room.
	var my_room := _get_current_room()
	if is_instance_valid(my_room):
		for pu in get_tree().get_nodes_in_group("player_units"):
			if is_instance_valid(pu) and \
			   my_room.get_tile_index_at((pu as Node2D).global_position) != -1:
				change_state(State.IDLE)
				return

	if not current_target.get("is_functional"):
		change_state(State.IDLE)
		return

	velocity = Vector2.ZERO
	_station_attack_timer -= delta
	if _station_attack_timer <= 0.0:
		_station_attack_timer = _STATION_ATTACK_RATE
		if current_target.has_method("take_damage"):
			current_target.take_damage(_STATION_DAMAGE)
			# Re-check: take_damage may have freed the station and cleared current_target
			# via the door_destroyed signal or station's own queue_free.
			if is_instance_valid(current_target):
				var hp = current_target.get("health")
				print("[ENEMY] Attacking [", current_target.name, "] | Target Health: ", hp if hp != null else "?")


# ===========================================================================
# STATE TRANSITIONS
# ===========================================================================

func change_state(new_state: State) -> void:
	if new_state == state:
		return

	# ── on EXIT ───────────────────────────────────────────────────────────────
	match state:
		State.WALKING:
			_cleanup_path()
		State.ATTACKING:
			set_sprite_offset(0.0)
			var opp := _find_tile_opponent()
			if is_instance_valid(opp) and opp.has_method("set_sprite_offset"):
				opp.set_sprite_offset(0.0)
			current_target = null
			_fire_timer.stop()
			_fire_target   = null
		State.ATTACK_DOOR:
			#if is_instance_valid(current_target) and Enemy._door_attacker_registry.has(current_target):
				#Enemy._door_attacker_registry[current_target].erase(self)
			current_target     = null
			_door_attack_timer = 0.0
		State.SABOTAGE:
			current_target        = null
			_station_attack_timer = 0.0

	# ── on ENTER ──────────────────────────────────────────────────────────────
	match new_state:
		State.IDLE:
			collision_layer = 1
			_sprite.play("Idle" + _last_dir)
			# Immediately re-evaluate when combat / sabotage / door-breach ends.
			if state in [State.ATTACKING, State.SABOTAGE, State.ATTACK_DOOR]:
				_ai_timer = 0.0
			# Track room arrival and reserve the landed tile when coming from WALKING.
			if state == State.WALKING:
				_nav_reserved_room = null
				_update_current_room()
				if is_instance_valid(current_room):
					var tile_idx : int = current_room.get_tile_index_at(global_position)
					if tile_idx != -1:
						# _on_tile_entered reserves the tile AND re-routes any same-faction
						# unit that had pre-reserved this same slot.
						if current_room.has_method("_on_tile_entered"):
							current_room._on_tile_entered(self, tile_idx)
						else:
							current_room.reserve_tile(tile_idx, self, false)
			var opp := _find_tile_opponent()
			if is_instance_valid(opp):
				set_sprite_offset(6.0)
				if opp.has_method("set_sprite_offset"):
					opp.set_sprite_offset(-6.0)
		State.WALKING:
			collision_layer = 1
			set_sprite_offset(0.0)
			_last_room_during_walk = _get_current_room()
			# Release only the origin tile; the pre-reserved destination tile must
			# remain so other enemies can see it as taken and pick a different tile.
			if is_instance_valid(current_room):
				current_room.release_unit_from_position(self, global_position)
			var opp := _find_tile_opponent()
			if is_instance_valid(opp) and opp.has_method("set_sprite_offset"):
				opp.set_sprite_offset(0.0)
		State.ATTACKING:
			collision_layer = 1
		State.ATTACK_DOOR:
			collision_layer    = 1
			velocity           = Vector2.ZERO
			_door_attack_timer = 0.0  # first hit fires immediately on next tick
			if is_instance_valid(current_target):
				#if not Enemy._door_attacker_registry.has(current_target):
					#Enemy._door_attacker_registry[current_target] = []
				#if self not in Enemy._door_attacker_registry[current_target]:
					#Enemy._door_attacker_registry[current_target].append(self)
				# Assign a lateral spread offset so units don't stack on the exact door centre.
				#var attacker_list : Array = Enemy._door_attacker_registry[current_target]
				#var my_index      : int   = attacker_list.find(self)
				# Perpendicular to approach direction; alternates left/right: 0→0, 1→+8, 2→-8 …
				var approach_dir  : Vector2 = ((current_target as Node2D).global_position - global_position).normalized()
				var perp          : Vector2 = Vector2(-approach_dir.y, approach_dir.x)
				#var side   := 1 if (my_index % 2 == 1) else -1
				#var step   : int = ceili(my_index / 2.0) * 8
				#_breach_offset = perp * (side * step)
		State.SABOTAGE:
			collision_layer       = 1
			velocity              = Vector2.ZERO
			_station_attack_timer = 0.0  # first hit fires immediately on next tick

	print(name, " State Change: ", State.keys()[state], " -> ", State.keys()[new_state])
	state = new_state


# ===========================================================================
# INPUT
# ===========================================================================

## Uses _input() + get_global_mouse_position() — same coordinate path as
## SelectionManager box-select, which correctly handles the SubViewport + Camera2D zoom.
const _CLICK_RADIUS : float = 14.0

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if global_position.distance_to(get_global_mouse_position()) > _CLICK_RADIUS:
		return
	get_viewport().set_input_as_handled()
	var sm := get_tree().get_first_node_in_group("selection_manager")
	if sm and sm.has_method("target_enemy"):
		sm.target_enemy(self)


# ===========================================================================
# PUBLIC API
# ===========================================================================

func move_along_path(path: PackedVector2Array) -> void:
	if path.is_empty():
		return
	_path       = path
	_path_index = 0
	change_state(State.WALKING)


func engage(target: Node) -> void:
	current_target = target
	change_state(State.ATTACKING)


func set_sprite_offset(x_offset: float) -> void:
	_sprite.position.x = x_offset

func is_in_same_room(target: Node2D) -> bool:
	# 1. Validation: If target is gone or we aren't in a room, it's impossible
	if not is_instance_valid(target) or not current_room:
		return false
	
	# 2. Get the ship instance
	var ship = get_tree().get_first_node_in_group("ship")
	
	# 3. Guard Clause: If there's no ship, we can't check rooms
	if not ship:
		return false
		
	# 4. The actual logic: Check if target is in our current room
	var target_room = ship.get_room_at_pos(target.global_position)
	return target_room == current_room
	
## Triggers an immediate AI re-evaluation on the very next physics frame.
## Call whenever a blocker disappears (door broken, attack target killed) so the
## enemy reacts instantly instead of waiting for the full _AI_THINK_INTERVAL.
func _scan_for_targets() -> bool:
	_ai_timer = 0.0
	# 1. Search for hostile Units first (Highest Priority)
	var units = get_tree().get_nodes_in_group("units")
	for u in units:
		if is_instance_valid(u) and u.get("faction") != self.faction:
			if is_in_same_room(u):
				current_target = u
				return true
	# 2. Search for hostile Stations (Medium Priority)
	var stations = get_tree().get_nodes_in_group("stations")
	for s in stations:
		if is_instance_valid(s) and s.get("owner_faction") != self.faction:
			if is_in_same_room(s):
				current_target = s
				return true
	# 3. Search for blocking Doors (Lowest Priority)
	var doors = get_tree().get_nodes_in_group("doors")
	for d in doors:
		if is_instance_valid(d) and d.get("is_closed"):
			if is_in_same_room(d):
				current_target = d
				return true
	return false # Found nothing


# ===========================================================================
# AI TICK
# ===========================================================================

func _ai_tick() -> void:
	print("Enemy State: ", state, " | Target: ", current_target.name if is_instance_valid(current_target) else "null")

	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if not nav:
		return

	var my_room := _get_current_room()
	if is_instance_valid(my_room):
		# ── Priority 1: Engage the nearest player unit in this room ──────────
		var nearest      : Node  = null
		var nearest_dist : float = INF
		for pu in get_tree().get_nodes_in_group("player_units"):
			if not is_instance_valid(pu):
				continue
			if my_room.get_tile_index_at((pu as Node2D).global_position) == -1:
				continue
			var d := global_position.distance_to((pu as Node2D).global_position)
			if d < nearest_dist:
				nearest_dist = d
				nearest      = pu
		if is_instance_valid(nearest):
			engage(nearest)
			return
		print("DEBUG: No enemy to attack")

		# ── Priority 2: Sabotage a player-faction station in this room ───────
		# Navigate to the best adjacent tile first; only start SABOTAGE once
		# already positioned there.  This forces enemies to physically spread
		# to different tiles instead of all sabotageing from the same spot.
		for s in get_tree().get_nodes_in_group("stations"):
			if not is_instance_valid(s) or not s.get("is_functional"):
				continue
			if int(s.get("owner_faction") if s.get("owner_faction") != null else 0) != 0:
				continue   # only target player-faction (0) stations
			# Is the station inside this room?
			var s_pos   : Vector2 = (s as Node2D).global_position
			var in_room : bool    = my_room.get_tile_index_at(s_pos) != -1
			if not in_room:
				var seat_node := s.get("interaction_spot") as Marker2D
				in_room = is_instance_valid(seat_node) and \
						  my_room.get_tile_index_at(seat_node.global_position) != -1
			if not in_room:
				continue
			# Determine the station's tile so we can exclude it from candidates.
			var sta_tile : int = my_room.get_tile_index_at(s_pos)
			if sta_tile == -1:
				var seat := s.get("interaction_spot") as Marker2D
				if is_instance_valid(seat):
					sta_tile = my_room.get_tile_index_at(seat.global_position)
			# request_assignment picks the nearest free tile, excludes station seats
			# for opposing-faction units, and pre-reserves it atomically.
			var best_tile : int = -1
			if my_room.has_method("request_assignment"):
				best_tile = my_room.request_assignment(self)
			elif my_room.has_method("request_unique_tile"):
				best_tile = my_room.request_unique_tile(self)
			if best_tile == -1:
				continue   # no open tile in this room — try next station
			var my_tile : int = my_room.get_tile_index_at(global_position)
			if my_tile == best_tile:
				# Already at the optimal sabotage tile — begin sabotaging.
				current_target = s
				change_state(State.SABOTAGE)
			else:
				# Navigate to the best adjacent tile; sabotage on next tick.
				# Tile is already pre-reserved by request_assignment; pass it
				# directly so _navigate_within_room does not double-book.
				_navigate_within_room_prereserved(my_room, best_tile, nav)
			return
		print("DEBUG: No station to attack")

	# ── Priority 3: Navigate toward a room with player units (breach doors) ───
	# This runs regardless of whether we're in a room, so enemies never get
	# stuck spreading indefinitely when a hostile door blocks the path.
	var target_pos := _find_player_room_tile()
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
		if is_instance_valid(door):
			print("DEBUG: Target found: ", door.name, " - Path is blocked, attacking door")
			_resume_destination = target_pos
			current_target = door
			change_state(State.ATTACK_DOOR)
			# Mark the room's shared breach target so all units converge on this door.
			if is_instance_valid(my_room):
				my_room.active_target = door
			# Tell every enemy in this room to attack the same door.
			_broadcast_door_target_to_room(door, target_pos, my_room)
		else:
			print("DEBUG: Pathfinding failed to ", target_pos, " - Path is blocked")
		return

	# ── Priority 4: Navigate to nearest functional player-faction station ─────
	var station_pos := _find_station_room_tile()
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
		if is_instance_valid(door):
			print("DEBUG: Target found: ", door.name, " - Path is blocked, attacking door")
			_resume_destination = station_pos
			current_target = door
			change_state(State.ATTACK_DOOR)
			# Mark the room's shared breach target so all units converge on this door.
			if is_instance_valid(my_room):
				my_room.active_target = door
			# Tell every enemy in this room to attack the same door.
			_broadcast_door_target_to_room(door, station_pos, my_room)
		else:
			print("DEBUG: Pathfinding failed to ", station_pos, " - Path is blocked")
		return

	# ── Priority 5 (last resort): Spread to any empty tile in current room ────
	# Only reached when there is nothing to chase cross-room.
	if is_instance_valid(my_room):
		var my_tile5 : int = my_room.get_tile_index_at(global_position)
		var spread_tile : int = -1
		if my_room.has_method("request_assignment"):
			spread_tile = my_room.request_assignment(self)
		elif my_room.has_method("request_unique_tile"):
			spread_tile = my_room.request_unique_tile(self)
		elif my_room.has_method("find_best_tile_for_faction"):
			spread_tile = my_room.find_best_tile_for_faction(1, [])
		if spread_tile != -1 and spread_tile != my_tile5:
			_navigate_within_room_prereserved(my_room, spread_tile, nav)


## Move the enemy to a specific tile index inside a room it is already in.
## Handles reservation bookkeeping so other enemies immediately see the tile
## as taken and do not pick the same destination.
func _navigate_within_room(room: Node, tile_idx: int, nav: Node) -> void:
	# Release any stale cross-room nav reservation first.
	if is_instance_valid(_nav_reserved_room) and _nav_reserved_room != room:
		_nav_reserved_room.release_unit(self)
		_nav_reserved_room = null
	# Pre-reserve the destination BEFORE starting to walk so concurrent AI
	# ticks in the same physics frame cannot pick the same tile.
	room.reserve_tile(tile_idx, self, false)
	_nav_reserved_room = room
	var target_pos : Vector2 = room.get_tile_center(tile_idx)
	var path : PackedVector2Array = nav.get_enemy_nav_path(global_position, target_pos)
	if path.size() > 0:
		move_along_path(path)


## Variant of _navigate_within_room for when the tile was ALREADY reserved by
## request_assignment / request_unique_tile.  Skips the reserve_tile call so
## the ghost-blocking fix in reserve_tile does not inadvertently clear the
## reservation that was just made.
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


# ===========================================================================
# ANIMATIONS
# ===========================================================================

func _update_animations() -> void:
	match state:
		State.WALKING:
			_sprite.play("Run" + _last_dir)
		State.ATTACKING:
			if is_instance_valid(current_target):
				var to_target := ((current_target as Node2D).global_position - global_position).normalized()
				_last_dir = _dir_from_vec(to_target)
			if not _fire_timer.is_stopped():
				_sprite.flip_h = (_last_dir == "Right")
				_sprite.play("Attacking")
			else:
				_sprite.flip_h = false
				_sprite.play("Idle" + _last_dir)
		State.ATTACK_DOOR:
			if is_instance_valid(current_target):
				# Use the door's stored face index for a snap-to-cardinal direction
				# when available.  The face tells us exactly which way the enemy
				# crossed the tile boundary, preventing diagonal animation drift.
				var face_idx : int = int(
					current_target.get("face_index") \
					if current_target.get("face_index") != null else -1
				)
				const _FACE_TO_DIR : Array[String] = ["Up", "Right", "Down", "Left"]
				if face_idx >= 0 and face_idx < 4:
					_last_dir = _FACE_TO_DIR[face_idx]
				else:
					var to_door := ((current_target as Node2D).global_position \
						- global_position).normalized()
					_last_dir = _dir_from_vec(to_door)
				var door_dist := global_position.distance_to((current_target as Node2D).global_position)
				if door_dist <= _DOOR_ATTACK_RANGE:
					# Attack phase — swing at the door.
					_sprite.flip_h = (_last_dir == "Right")
					_sprite.play("Attacking")
				else:
					# Approach phase — run toward the door.
					_sprite.flip_h = false
					_sprite.play("Run" + _last_dir)
		State.SABOTAGE:
			if is_instance_valid(current_target):
				var to_st := ((current_target as Node2D).global_position - global_position).normalized()
				_sprite.play("Idle" + _dir_from_vec(to_st))


# ===========================================================================
# HELPERS
# ===========================================================================

## Called when the blocking door becomes passable; delegates to re_evaluate_mission().
func _resume_after_door() -> void:
	print("DEBUG: Move through destroyed door")
	current_target     = null
	_door_attack_timer = 0.0
	re_evaluate_mission()


## Centralised re-evaluation: transitions to IDLE, triggers AI scan, and
## resumes any saved destination (e.g. the room behind a now-breached door).
func re_evaluate_mission() -> void:
	# 1. Is there an enemy (player) nearby to fight?
	if _scan_for_targets():
		change_state(State.ATTACKING)
		return
	# 2. Is there a room I'm supposed to be heading toward?
# 1. Get the ship instance first
	var ship = get_tree().get_first_node_in_group("ship")

# 2. Ask the ship for the function
	if ship_ref and ship_ref._has_objective_room(objective_id): 
		change_state(State.WALKING)
		return
	# 3. If nothing else, just idle and wait for a command
	change_state(State.IDLE)

	var dest := _resume_destination
	_resume_destination = Vector2.ZERO
	change_state(State.IDLE)
	_scan_for_targets()   # react immediately — don't wait for the next AI interval
	if dest == Vector2.ZERO:
		return
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if not nav:
		return
	var path : PackedVector2Array = nav.get_enemy_nav_path(global_position, dest)
	if path.size() > 0:
		print("DEBUG: [Unit] Resuming movement through breached door.")
		move_along_path(path)
	else:
		print("DEBUG: Re-scan failed - still no path found for ", name, " to ", dest)


## Called by Door._break() on every unit when a door is destroyed.
## Clears any door-related state and delegates to re_evaluate_mission().
func on_door_destroyed(door: Node) -> void:
	# current_target may already be null — _on_door_destroyed clears it synchronously
	# when the door_destroyed signal fires inside take_damage. That is intentional.
	var was_targeting_door := (state == State.ATTACK_DOOR and current_target == door)
	# 1. IMMEDIATE CHECK (Paste this here)
	# Check if this is the door I was actually attacking
	if door == current_target:
		print("DEBUG: My target door was destroyed. Resetting state.")
		current_target = null
		#state = State.IDLE # Or State.WALKING, depending on your enum
		await get_tree().process_frame
		re_evaluate_mission()
	# 2. YOUR EXISTING LOGIC
	
	if was_targeting_door:
		_door_attack_timer = 0.0

	await get_tree().process_frame
	if not is_instance_valid(self): return
	
	if was_targeting_door:
		_door_attack_timer = 0.0
		# _resume_destination is preserved so re_evaluate_mission() can resume the path.

	# Wait one full frame so the NavigationServer bakes the now-open doorway
	# before any unit tries to path through it.
	await get_tree().process_frame
	if not is_instance_valid(self):
		return

	if was_targeting_door or state == State.WALKING or state == State.ATTACK_DOOR:
		re_evaluate_mission()
		_scan_for_targets()
	else:
		_scan_for_targets()
		


## Refreshes `current_room` to the room that currently contains this unit.
## Call whenever the unit finishes moving to a new tile.
func _update_current_room() -> void:
	print("DEBUG: [", name, "] is in ",
		  current_room.name if is_instance_valid(current_room) else "No Room")
	var ship := get_tree().get_first_node_in_group("ship")
	if is_instance_valid(ship) and ship.has_method("get_room_at_pos"):
		var r = ship.get_room_at_pos(global_position)
		if is_instance_valid(r):
			if r is Room:
				current_room = r
			else:
				current_room = null
			return
	current_room = _get_current_room()




## Returns a tile centre inside the room that holds the nearest functional
## PLAYER-faction station.  Enemies never sabotage their own stations.
func _find_station_room_tile() -> Vector2:
	var best_room    : Node  = null
	var best_dist    : float = INF
	var best_station : Node  = null
	for s in get_tree().get_nodes_in_group("stations"):
		if not is_instance_valid(s) or not s.get("is_functional"):
			continue
		if int(s.get("owner_faction") if s.get("owner_faction") != null else 0) == 1:
			continue   # skip enemy-owned stations
		var s_pos : Vector2 = (s as Node2D).global_position
		var d := global_position.distance_to(s_pos)
		if d < best_dist:
			best_dist    = d
			best_station = s
			# Find which room owns this station.
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
	# Release any existing nav reservation.
	if is_instance_valid(_nav_reserved_room):
		_nav_reserved_room.release_unit(self)
		_nav_reserved_room = null
	# Find the station's tile so the enemy stands adjacent — not on the station seat.
	var s_pos    : Vector2 = (best_station as Node2D).global_position
	var sta_tile : int     = best_room.get_tile_index_at(s_pos)
	if sta_tile == -1:
		var seat := best_station.get("interaction_spot") as Marker2D
		if is_instance_valid(seat):
			sta_tile = best_room.get_tile_index_at(seat.global_position)
	var tile_idx : int = -1
	if best_room.has_method("request_assignment"):
		tile_idx = best_room.request_assignment(self)
	elif best_room.has_method("request_unique_tile"):
		tile_idx = best_room.request_unique_tile(self)
	if tile_idx == -1:
		return Vector2.ZERO   # room is full — skip
	_nav_reserved_room = best_room
	return best_room.get_tile_center(tile_idx)


func _find_player_room_tile() -> Vector2:
	var target_room : Node  = null
	var best_dist   : float = INF
	for room in get_tree().get_nodes_in_group("rooms"):
		if not is_instance_valid(room) or not room.has_method("get_tile_index_at"):
			continue
		var has_player := false
		for pu in get_tree().get_nodes_in_group("player_units"):
			if is_instance_valid(pu) and room.get_tile_index_at((pu as Node2D).global_position) != -1:
				has_player = true
				break
		if not has_player:
			continue
		var d := global_position.distance_to((room as Node2D).global_position)
		if d < best_dist:
			best_dist   = d
			target_room = room
	if not is_instance_valid(target_room):
		return Vector2.ZERO
	# Release any existing nav reservation before booking the new target tile.
	if is_instance_valid(_nav_reserved_room):
		_nav_reserved_room.release_unit(self)
		_nav_reserved_room = null
	# Faction-aware tile selection: melee slot if available, else spread.
	var tile_idx : int = -1
	if target_room.has_method("request_assignment"):
		tile_idx = target_room.request_assignment(self)
	elif target_room.has_method("request_unique_tile"):
		tile_idx = target_room.request_unique_tile(self)
	if tile_idx == -1:
		return Vector2.ZERO   # player room is full — don't pile in
	_nav_reserved_room = target_room
	return target_room.get_tile_center(tile_idx)


func _find_tile_opponent() -> Node:
	for u in get_tree().get_nodes_in_group("player_units"):
		if is_instance_valid(u) and global_position.distance_to((u as Node2D).global_position) < 8.0:
			return u
	return null


func _cleanup_path() -> void:
	_path       = PackedVector2Array()
	_path_index = 0
	velocity    = Vector2.ZERO
	_sprite.play("Idle" + _last_dir)


# ===========================================================================
# ROOM-BASED DOOR TARGETING
# ===========================================================================

## Public: called by an ally enemy to assign this unit to attack a specific door.
func set_door_target(door: Node, resume_dest: Vector2) -> void:
	_resume_destination = resume_dest
	current_target      = door
	change_state(State.ATTACK_DOOR)


## Broadcasts a door-attack order to all idle/walking enemies in `room`.
## Called when one unit identifies a blocking door so the whole squad attacks it.
func _broadcast_door_target_to_room(door: Node, resume_dest: Vector2, room: Node) -> void:
	if not is_instance_valid(room):
		return
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy) or enemy == self:
			continue
		if room.get_tile_index_at((enemy as Node2D).global_position) == -1:
			continue
		var e_state = enemy.get("state")
		if e_state == State.ATTACK_DOOR:
			continue  # already attacking a door
		if e_state == State.ATTACKING or e_state == State.SABOTAGE:
			continue  # in active combat — don't interrupt
		if enemy.has_method("set_door_target"):
			enemy.set_door_target(door, resume_dest)


## Returns the impassable player-faction door that exits `room` most aligned
## toward `destination`. Used as a fallback for room-based door detection.
func _find_exit_door_toward(room: Node, destination: Vector2) -> Node:
	var best_door : Node  = null
	var best_dot  : float = -INF
	var to_dest := (destination - global_position).normalized()
	for door in get_tree().get_nodes_in_group("doors"):
		if not is_instance_valid(door) or door.is_passable():
			continue
		var door_faction := int(door.get("owner_faction") if door.get("owner_faction") != null else 0)
		if door_faction == owner_faction:
			continue  # own-faction — can pass
		var host_pos : Vector2 = door.get("host_tile_world_pos") if door.get("host_tile_world_pos") != null else Vector2.ZERO
		var door_pos : Vector2 = (door as Node2D).global_position
		var connected : Node2D = (host_pos != Vector2.ZERO and room.get_tile_index_at(host_pos) != -1) \
					  or room.get_tile_index_at(door_pos) != -1
		if not connected:
			continue
		var to_door := (door_pos - global_position).normalized()
		var dot := to_door.dot(to_dest)
		if dot > best_dot:
			best_dot  = dot
			best_door = door
	return best_door

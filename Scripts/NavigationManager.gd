## NavigationManager.gd
## Global AStar2D graph built from every ShipTile on the ship.
## Add this node to the ship scene (before Rooms so it is ready first).
## Rooms register their tile world-positions via call_deferred on their own _ready().
extends Node

## Two tile centres are adjacent when at most this many px apart.
## 36 px = 32 px tile size + 4 px tolerance for floating-point imprecision.
const CONNECT_DISTANCE := 36.0

## A door must be within this many px of an A* tile to be mapped to it.
const DOOR_SNAP_RADIUS := 48.0

## Half of one tile (32 px tile ÷ 2).  Used as the along-wall tolerance
## when matching a door to a tile face.
const HALF_TILE := 16.0

## Maximum perpendicular offset (in the movement direction) for a door to be
## counted as guarding a specific tile face.  Keeping this tight (< HALF_TILE)
## prevents a door on one face from suppressing the wall on an adjacent,
## perpendicular face — the root cause of 4-way junction glitches.
const DOOR_PERP_SNAP := 8.0

var _astar   := AStar2D.new()
var _next_id : int = 0

# Maps room Node → Array[int] of AStar point IDs owned by that room.
var _room_ids : Dictionary = {}

# Maps door Node → the AStar point ID nearest to that door's world position.
var _door_point_ids : Dictionary = {}

# Tracks every cross-room connection made so _finalize_walls() can check them.
# Each entry is [id_a: int, id_b: int].
var _cross_room_pairs : Array = []

# Maps door Node → [id_a: int, id_b: int]: the two A* points the door separates.
# Used by _on_door_passability_changed to toggle the cross-room edge precisely,
# rather than disabling one tile point (which would also break intra-room paths).
var _door_connection_pairs : Dictionary = {}

# World-space tile-centre pairs for every wall (no door on that boundary).
# Each entry is [pos_a: Vector2, pos_b: Vector2].
var _wall_segments : Array = []


func _ready() -> void:
	add_to_group("navigation_manager")
	# Double-deferred so _finalize_walls runs AFTER all room _init_room and
	# door _self_register_with_nav deferred calls have completed.
	call_deferred("_post_init")


func _post_init() -> void:
	call_deferred("_finalize_walls")


# ---------------------------------------------------------------------------
# Registration (called by room_base._register_tiles via call_deferred)
# ---------------------------------------------------------------------------

## Register all tile world-positions from one room.
##
## • All tiles inside the same room are fully connected to each other.
## • Each new tile is also connected to any already-registered tile in an
##   adjacent room whose centre is within CONNECT_DISTANCE pixels.
func register_room_tile_positions(room: Node, positions: Array[Vector2]) -> void:
	var new_ids : Array[int] = []

	for pos in positions:
		var id := _next_id
		_next_id += 1
		_astar.add_point(id, pos)
		new_ids.append(id)

	_room_ids[room] = new_ids

	# Connect all tiles within this room to each other.
	for i in new_ids.size():
		for j in range(i + 1, new_ids.size()):
			_astar.connect_points(new_ids[i], new_ids[j])

	# Connect edge tiles of this room to already-registered tiles in adjacent rooms.
	for new_id in new_ids:
		var new_pos := _astar.get_point_position(new_id)
		for existing_id in range(0, _next_id):
			if new_ids.has(existing_id):
				continue   # same room — already handled above
			if not _astar.has_point(existing_id):
				continue
			var existing_pos := _astar.get_point_position(existing_id)
			if new_pos.distance_to(existing_pos) <= CONNECT_DISTANCE:
				if not _astar.are_points_connected(new_id, existing_id):
					_astar.connect_points(new_id, existing_id)
					# Record for wall / door detection in _finalize_walls().
					_cross_room_pairs.append([new_id, existing_id])

	# After new tiles exist, map any unmapped doors to their nearest tile.
	_lazy_register_doors()


# ---------------------------------------------------------------------------
# Door registration
# ---------------------------------------------------------------------------

## Map one door to the nearest A* point and listen for passability changes.
## Called by Door.gd via call_deferred (after tiles are loaded) and lazily
## from register_room_tile_positions for rooms that load after doors.
func register_door(door: Node) -> void:
	if _door_point_ids.has(door):
		return
	if _astar.get_point_count() == 0:
		return  # tiles not yet registered; will retry from _lazy_register_doors

	var door_pos  : Vector2 = (door as Node2D).global_position
	var nearest_id := _astar.get_closest_point(door_pos)
	if nearest_id == -1:
		return
	if door_pos.distance_to(_astar.get_point_position(nearest_id)) > DOOR_SNAP_RADIUS:
		return  # door is not near any registered tile

	_door_point_ids[door] = nearest_id

	# Initial connection state is handled by _finalize_walls() which knows both
	# tiles.  We only wire the signal here; _finalize_walls() runs shortly after.
	if door.has_signal("passability_changed") and \
	   not door.passability_changed.is_connected(_on_door_passability_changed.bind(door)):
		door.passability_changed.connect(_on_door_passability_changed.bind(door))


## Try to register every door that is in the scene but not yet mapped.
func _lazy_register_doors() -> void:
	for door in get_tree().get_nodes_in_group("doors"):
		if is_instance_valid(door) and not _door_point_ids.has(door):
			register_door(door)


func _on_door_passability_changed(is_passable: bool, door: Node) -> void:
	if _door_connection_pairs.has(door):
		# Preferred: toggle the cross-room edge, leaving both tile points active.
		var pair   : Array = _door_connection_pairs[door]
		var id_a   : int   = pair[0]
		var id_b   : int   = pair[1]
		if not (_astar.has_point(id_a) and _astar.has_point(id_b)):
			return
		if is_passable:
			if not _astar.are_points_connected(id_a, id_b):
				_astar.connect_points(id_a, id_b)
		else:
			if _astar.are_points_connected(id_a, id_b):
				_astar.disconnect_points(id_a, id_b)
	elif _door_point_ids.has(door):
		# Fallback for doors not matched to a cross-room pair (should not occur).
		_astar.set_point_disabled(_door_point_ids[door], not is_passable)


# ---------------------------------------------------------------------------
# Wall finalisation (runs once after all rooms and doors have registered)
# ---------------------------------------------------------------------------

## Converts a world-space direction vector to a face index.
## Face indices: 0 = North, 1 = East, 2 = South, 3 = West.
func _vec_to_face(v: Vector2) -> int:
	if abs(v.x) >= abs(v.y):
		return 1 if v.x > 0.0 else 3   # East : West
	return 2 if v.y > 0.0 else 0       # South : North


## Scans every cross-room A* connection.  Any boundary that lacks a door on
## that exact tile face is disconnected (permanent wall) and recorded for
## WallManager.  Door detection uses a directional tolerance so a door on one
## face cannot accidentally suppress the wall on an adjacent, perpendicular
## face (the root cause of 4-way junction glitches).
func _finalize_walls() -> void:
	for pair in _cross_room_pairs:
		var id_a : int = pair[0]
		var id_b : int = pair[1]
		if not _astar.has_point(id_a) or not _astar.has_point(id_b):
			continue
		var pos_a    : Vector2 = _astar.get_point_position(id_a)
		var pos_b    : Vector2 = _astar.get_point_position(id_b)
		var mid      : Vector2 = (pos_a + pos_b) * 0.5
		# move_dir: direction a unit travels to cross this boundary (A → B).
		# wall_dir: the direction the wall/door line runs along the edge.
		var move_dir : Vector2 = (pos_b - pos_a).normalized()
		var wall_dir : Vector2 = Vector2(-move_dir.y, move_dir.x)

		var found_door : Node = null
		for door in get_tree().get_nodes_in_group("doors"):
			if not is_instance_valid(door):
				continue
			var door_pos : Vector2 = (door as Node2D).global_position
			var to_door  : Vector2 = door_pos - mid
			# along_move: offset in the movement direction (perp to the wall line).
			# along_wall: offset along the wall line itself.
			var along_move : float = abs(to_door.dot(move_dir))
			var along_wall : float = abs(to_door.dot(wall_dir))
			# A door belongs to this face only when it sits within DOOR_PERP_SNAP
			# of the exact edge line.  The along-wall tolerance of HALF_TILE allows
			# the door to be placed anywhere within the tile's edge segment.
			if along_move <= DOOR_PERP_SNAP and along_wall <= HALF_TILE:
				found_door = door
				break

		if found_door == null:
			if _astar.are_points_connected(id_a, id_b):
				_astar.disconnect_points(id_a, id_b)
			_wall_segments.append([pos_a, pos_b])
		else:
			# Record the two-tile connection this door guards so passability
			# changes toggle the edge precisely (not a whole tile point).
			if not _door_connection_pairs.has(found_door):
				_door_connection_pairs[found_door] = [id_a, id_b]
			# Set initial A* state: disconnect if the door starts closed.
			if found_door.has_method("is_passable") and not found_door.is_passable():
				if _astar.are_points_connected(id_a, id_b):
					_astar.disconnect_points(id_a, id_b)
			# Stamp face metadata onto the door so Enemy.gd can use it for
			# precise targeting and animation direction.
			if found_door.get("face_index") != null and \
			   int(found_door.get("face_index")) == -1:
				found_door.set("face_index", _vec_to_face(move_dir))
				found_door.set("host_tile_world_pos", pos_a)

	# Spawn the WallManager if it does not already exist, then push segments.
	var wm := get_tree().get_first_node_in_group("wall_manager")
	if not is_instance_valid(wm):
		var script = load("res://Scripts/WallManager.gd")
		if script:
			wm = Node2D.new()
			wm.set_script(script)
			wm.name = "WallManager"
			get_parent().call_deferred("add_child", wm)
			# Segments will be pushed once the node is in the tree.
			wm.set_meta("_pending_segments", _wall_segments)
	elif wm.has_method("set_wall_segments"):
		wm.set_wall_segments(_wall_segments)


## Returns the list of wall tile-centre pairs built during _finalize_walls().
func get_wall_segments() -> Array:
	return _wall_segments


# ---------------------------------------------------------------------------
# Path query (called by SelectionManager for player units)
# ---------------------------------------------------------------------------

## Returns a world-space path for PLAYER units.
## Door points are temporarily enabled so player units can always path through
## doors — Unit.gd auto-opens any closed door as it arrives at that waypoint.
func get_nav_path(from_pos: Vector2, to_pos: Vector2) -> PackedVector2Array:
	if _astar.get_point_count() == 0:
		return PackedVector2Array([to_pos])

	# Ally privilege: temporarily reconnect every closed door edge so player
	# units always receive a valid path through doors (Unit.gd auto-opens them).
	var reconnected : Array = []
	for door in _door_connection_pairs:
		var pair : Array = _door_connection_pairs[door]
		var id_a : int   = pair[0]
		var id_b : int   = pair[1]
		if _astar.has_point(id_a) and _astar.has_point(id_b) and \
		   not _astar.are_points_connected(id_a, id_b):
			_astar.connect_points(id_a, id_b)
			reconnected.append(pair)

	var from_id := _astar.get_closest_point(from_pos)
	var to_id   := _astar.get_closest_point(to_pos)
	var path    := _astar.get_point_path(from_id, to_id)

	# Restore disconnected state for closed doors.
	for pair in reconnected:
		var id_a : int = pair[0]
		var id_b : int = pair[1]
		if _astar.are_points_connected(id_a, id_b):
			_astar.disconnect_points(id_a, id_b)

	if path.is_empty():
		return PackedVector2Array([to_pos])
	return path


## Returns a world-space path for ENEMY units.
## Impassable doors disable their A* point, so this path routes around them.
## Returns an empty array when the only route is blocked (enemy should attack).
func get_enemy_nav_path(from_pos: Vector2, to_pos: Vector2) -> PackedVector2Array:
	if _astar.get_point_count() == 0:
		return PackedVector2Array()
	var from_id := _astar.get_closest_point(from_pos)
	var to_id   := _astar.get_closest_point(to_pos)
	if from_id == -1 or to_id == -1:
		return PackedVector2Array()
	return _astar.get_point_path(from_id, to_id)


func get_astar_path(start_world_pos, end_world_pos):
	var start_id = _astar.get_closest_point(start_world_pos)
	var end_id   = _astar.get_closest_point(end_world_pos)

	if start_id == -1 or end_id == -1:
		return PackedVector2Array()

	return _astar.get_point_path(start_id, end_id)


## Returns the first impassable door on the direct boundary between room_a and
## room_b.  Looks up _door_connection_pairs so it works even when the path-scan
## approach fails (e.g. the door was not snapped to a segment midpoint).
## Call after get_enemy_nav_path returns empty and you already know both rooms.
func get_door_blocking_room(room_a: Node, room_b: Node) -> Node:
	if not _room_ids.has(room_a) or not _room_ids.has(room_b):
		return null
	var ids_a : Array = _room_ids[room_a]
	var ids_b : Array = _room_ids[room_b]
	for door in _door_connection_pairs:
		if not is_instance_valid(door):
			continue
		if door.has_method("is_passable") and door.is_passable():
			continue
		var pair : Array = _door_connection_pairs[door]
		var id0  : int   = pair[0]
		var id1  : int   = pair[1]
		if (ids_a.has(id0) and ids_b.has(id1)) or \
		   (ids_a.has(id1) and ids_b.has(id0)):
			return door
	return null


## For enemy AI targeting scan: returns the first door that is currently
## impassable along the door-ignoring path from from_pos to to_pos.
##
## The door-ignoring path (get_nav_path) lets the enemy 'see' the station
## behind a closed door.  Scanning that path's segment midpoints against
## _door_connection_pairs then pinpoints exactly which door is in the way,
## so the enemy never has to guess by direction heuristic.
func get_door_blocking_enemy_path(from_pos: Vector2, to_pos: Vector2) -> Node:
	if _astar.get_point_count() == 0:
		return null
	var full_path := get_nav_path(from_pos, to_pos)
	if full_path.size() < 2:
		return null
	# 20 px > HALF_TILE (16 px) so doors placed anywhere along the tile face
	# are reliably matched against segment midpoints.
	const SEG_DOOR_RADIUS := 20.0
	for i in range(1, full_path.size()):
		var seg_mid := (full_path[i - 1] + full_path[i]) * 0.5
		for door in _door_connection_pairs:
			if not is_instance_valid(door):
				continue
			if door.has_method("is_passable") and door.is_passable():
				continue   # already open — not a blocker
			if (door as Node2D).global_position.distance_to(seg_mid) <= SEG_DOOR_RADIUS:
				return door
	return null


# ---------------------------------------------------------------------------
# Runtime rebuild (called when a room is moved or rotated)
# ---------------------------------------------------------------------------

## Remove all AStar points owned by this room and erase its registry entry.
func _unregister_room(room: Node) -> void:
	if not _room_ids.has(room):
		return
	for id in _room_ids[room]:
		if _astar.has_point(id):
			_astar.remove_point(id)   # also removes all connections to this point
	_room_ids.erase(room)


## Rebuild nav points for one room at its current transform, then reconnect
## to neighbours and recalculate paths for any units heading to this room.
func rebuild_room(room: Node) -> void:
	_unregister_room(room)
	if room.has_method("get_walkable_tiles"):
		var positions : Array[Vector2] = room.get_walkable_tiles()
		if not positions.is_empty():
			register_room_tile_positions(room, positions)
	_recalculate_affected_units(room)


## For every unit that was walking toward a tile inside the rebuilt room,
## recompute their path so they follow the new tile positions.
func _recalculate_affected_units(room: Node) -> void:
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		var path : PackedVector2Array = unit.get("_path")
		if path == null or path.is_empty():
			continue
		var dest : Vector2 = path[path.size() - 1]
		# Only bother with units whose destination is inside the rebuilt room.
		if not room.has_method("get_tile_index_at"):
			continue
		if room.get_tile_index_at(dest) == -1:
			continue
		var new_path := get_nav_path(unit.global_position, dest)
		if unit.has_method("move_along_path"):
			unit.move_along_path(new_path)

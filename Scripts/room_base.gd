## room_base.gd
## Shared base for all room types (square, line, L-shaped, etc.).
## Handles hover/selection visuals, input, HP, and the slot API.
##
## Two tile-source modes are supported automatically:
##   GridContainer mode  — a child node named "GridContainer" exists (rectangular rooms).
##   Flat mode           — tiles are direct Control children of this node (L-shaped rooms).
##
## Usage: in your room script write  extends "res://Scripts/room_base.gd"
extends Control
class_name Room

@export var max_hp             : int            = 100
@export var current_hp         : int            = 100
@export var is_functional      : bool           = true
## 0 = PLAYER ship room, 1 = ENEMY ship room.
## Doors and stations inside this room inherit this value so opposing-faction
## units are treated as hostile (locked out of stations, blocked by doors).
@export var owner_faction      : int            = 0
## Leave empty for a standard rectangular room.
## For non-rectangular rooms (e.g. L-shapes), list every active tile coordinate.
## Example 3-tile L: [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1)]
@export var custom_tile_layout : Array[Vector2i] = []

## GridContainer child — null for flat-tile rooms.
@onready var _grid : GridContainer = get_node_or_null("GridContainer")

## Ordered tile list used only in flat mode (no GridContainer).
var _flat_tiles : Array[Control] = []

## Cached tile index of the station's interaction spot (-1 if no station).
var _station_tile_index : int  = -1
var _station            : Node = null
## All stations that belong to this room (supports rooms with multiple stations).
var _stations           : Array = []   # Array of {node: Station, tile_index: int}

const COLOR_BROKEN := Color(0.2, 0.2, 0.2)

const _BORDER_SHADER   := "res://Scripts/room_border.gdshader"
const _COLOR_HOVER     := Color(1.0, 1.0, 0.0)
const _COLOR_MOVEMENT  := Color(0.0, 1.0, 0.1)

## The four visual states a room can be in, driven entirely by game logic —
## never by which room was last left-clicked.
enum RoomVisualState { NONE, HOVER, TARGET }

var is_selected       : bool           = false   # kept for external info-panel use only
var is_hovering       : bool           = false
var _hover_suppressed : bool           = false
var _pending_units    : Array          = []       # units currently travelling here
var _border_mat       : ShaderMaterial = null
var _pulse_tween      : Tween          = null

## Used by _draw() when custom_tile_layout is active (replaces shader overlay).
var _draw_border_color : Color = Color.TRANSPARENT

var active_highlights : Dictionary = {}  # tile_index (int)  → ColorRect node
var _highlight_tweens : Dictionary = {}  # tile_index (int)  → Tween
var _unit_to_tile     : Dictionary = {}  # unit (Node)       → tile_index (int)
var _tile_occupants   : Dictionary = {}  # tile_index (int)  → Array[Node]

## Set by the first unit to identify a blocking hostile door in this room.
## All other units in this room check this variable and join the breach attack
## instead of each independently trying to path through the blocked waypoint.
var active_target : Node = null
var room_size : Vector2
var room_data : RoomData = RoomData.new()

## Set to true after initial nav registration so transform changes trigger a rebuild.
var _nav_registered  : bool = false
var _rebuild_queued  : bool = false


func _ready() -> void:
	add_to_group("rooms")
	call_deferred("_init_room")


# ===========================================================================
# TILE SOURCE ABSTRACTION
# Everywhere the old code called _grid.get_child_count() / _grid.get_child(i),
# now calls _tile_count() / _get_tile_node(i) instead.
# ===========================================================================

## Total number of (potentially active) tile slots.
func _tile_count() -> int:
	if _grid != null:
		return _grid.get_child_count()
	return _flat_tiles.size()


## Returns the Control tile node at logical index, or null.
func _get_tile_node(index: int) -> Control:
	if _grid != null:
		if index < 0 or index >= _grid.get_child_count():
			return null
		return _grid.get_child(index) as Control
	if index < 0 or index >= _flat_tiles.size():
		return null
	return _flat_tiles[index]


## Collects and sorts direct-child tile nodes for flat mode.
## Tiles are identified by their "TileCenter" Marker2D child (ship_tile.tscn).
## Sort order: top-to-bottom, then left-to-right (row-major).
func _collect_flat_tiles() -> void:
	for child in get_children():
		if child is Control and child.has_node("TileCenter"):
			_flat_tiles.append(child as Control)
	_flat_tiles.sort_custom(func(a: Control, b: Control) -> bool:
		if abs(a.position.y - b.position.y) > 1.0:
			return a.position.y < b.position.y
		return a.position.x < b.position.x
	)


## Computes the bounding size from the flat tile positions (used when no GridContainer).
func _compute_flat_size() -> Vector2:
	var max_x := 0.0
	var max_y := 0.0
	for tile in _flat_tiles:
		max_x = max(max_x, tile.position.x + tile.size.x)
		max_y = max(max_y, tile.position.y + tile.size.y)
	return Vector2(max_x, max_y)


## Returns the pixel size of one tile.
func _get_tile_pixel_size() -> Vector2:
	var first := _get_tile_node(0)
	if first:
		return first.size
	return Vector2(32.0, 32.0)


## Returns the tile rect in the room's LOCAL coordinate space.
## Works correctly even when the room is rotated.
func _tile_local_rect(index: int) -> Rect2:
	var tile := _get_tile_node(index)
	if tile == null:
		return Rect2()
	if _grid != null:
		return Rect2(_grid.position + tile.position, tile.size)
	return Rect2(tile.position, tile.size)


## Returns true when the tile at index should be treated as active.
## Flat-mode tiles are all active by definition (user placed only active tiles).
## GridContainer-mode filters against custom_tile_layout when set.
func _is_tile_active(index: int) -> bool:
	if _grid == null:
		return index >= 0 and index < _flat_tiles.size()
	if custom_tile_layout.is_empty():
		return true
	var cols := _grid.columns
	return Vector2i(index % cols, floori(float(index) / cols)) in custom_tile_layout


# ===========================================================================
# HOVER / SELECTION VISUALS
# ===========================================================================

func set_hover_suppressed(value: bool) -> void:
	if _hover_suppressed == value:
		return
	_hover_suppressed = value
	_update_visuals()


## Called by SelectionManager when the selection state changes.
## Rooms no longer store a separate flag — they query the manager directly.
func set_hover_enabled(_value: bool) -> void:
	_update_visuals()


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion):
		return
	var local_mouse := get_global_transform().affine_inverse() * get_global_mouse_position()
	var hovered := false
	if not _flat_tiles.is_empty():
		# Flat mode: check each tile's local rect (rotation-safe).
		for i in _flat_tiles.size():
			if _tile_local_rect(i).has_point(local_mouse):
				hovered = true
				break
	elif _grid != null and not custom_tile_layout.is_empty():
		# GridContainer with a custom (non-rectangular) layout: only active tiles count.
		var cols := _grid.columns
		for i in _grid.get_child_count():
			if Vector2i(i % cols, floori(float(i) / cols)) not in custom_tile_layout:
				continue
			if _tile_local_rect(i).has_point(local_mouse):
				hovered = true
				break
	else:
		# Full rectangular room: bounding rect is fine.
		hovered = Rect2(Vector2.ZERO, size).has_point(local_mouse)
	if hovered != is_hovering:
		is_hovering = hovered
		_update_visuals()


## Computes the correct visual state without any shared mutable flags.
## TARGET beats HOVER; HOVER requires SelectionManager to have units selected.
func _get_visual_state() -> RoomVisualState:
	if not _pending_units.is_empty():
		return RoomVisualState.TARGET
	if is_hovering and not _hover_suppressed:
		var sm := get_tree().get_first_node_in_group("selection_manager")
		if is_instance_valid(sm) and sm.has_method("has_selected_units") \
				and sm.has_selected_units():
			return RoomVisualState.HOVER
	return RoomVisualState.NONE


func _update_visuals() -> void:
	if not custom_tile_layout.is_empty():
		_update_draw_visuals()
		return
	if _border_mat == null:
		return
	match _get_visual_state():
		RoomVisualState.TARGET:
			_border_mat.set_shader_parameter("is_active", true)
			_border_mat.set_shader_parameter("border_color", _COLOR_MOVEMENT)
			_start_pulse()
		RoomVisualState.HOVER:
			_stop_pulse()
			_border_mat.set_shader_parameter("is_active", true)
			_border_mat.set_shader_parameter("border_color", _COLOR_HOVER)
			_border_mat.set_shader_parameter("intensity", 1.0)
		RoomVisualState.NONE:
			_stop_pulse()
			_border_mat.set_shader_parameter("is_active", false)


func _update_draw_visuals() -> void:
	match _get_visual_state():
		RoomVisualState.TARGET:
			_draw_border_color = _COLOR_MOVEMENT
			_start_pulse()
		RoomVisualState.HOVER:
			_stop_pulse()
			_draw_border_color = _COLOR_HOVER
			queue_redraw()
		RoomVisualState.NONE:
			_stop_pulse()
			_draw_border_color = Color.TRANSPARENT
			queue_redraw()


func _start_pulse() -> void:
	if _pulse_tween and _pulse_tween.is_running():
		return
	_stop_pulse()
	_pulse_tween = create_tween().set_loops()
	if not custom_tile_layout.is_empty():
		_pulse_tween.tween_method(
			func(a: float):
				_draw_border_color.a = a
				queue_redraw(),
			1.0, 0.4, 0.6)
		_pulse_tween.tween_method(
			func(a: float):
				_draw_border_color.a = a
				queue_redraw(),
			0.4, 1.0, 0.6)
	else:
		_pulse_tween.tween_method(
			func(v: float): _border_mat.set_shader_parameter("intensity", v),
			1.0, 0.4, 0.6)
		_pulse_tween.tween_method(
			func(v: float): _border_mat.set_shader_parameter("intensity", v),
			0.4, 1.0, 0.6)


func _stop_pulse() -> void:
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null


## Draws the outer perimeter border for custom-layout rooms.
## Only edges without a neighbour in the layout are drawn.
func _draw() -> void:
	if custom_tile_layout.is_empty() or _draw_border_color.a < 0.01:
		return

	var tile_size  : Vector2    = _get_tile_pixel_size()
	var layout_set : Dictionary = {}
	for c in custom_tile_layout:
		layout_set[c] = true

	var dirs : Array[Vector2i] = [
		Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)
	]

	for coord in custom_tile_layout:
		var bx : float = coord.x * tile_size.x
		var by : float = coord.y * tile_size.y
		if not layout_set.has(coord + dirs[0]):
			draw_line(Vector2(bx, by), Vector2(bx + tile_size.x, by), _draw_border_color, 2.0)
		if not layout_set.has(coord + dirs[1]):
			draw_line(Vector2(bx + tile_size.x, by), Vector2(bx + tile_size.x, by + tile_size.y), _draw_border_color, 2.0)
		if not layout_set.has(coord + dirs[2]):
			draw_line(Vector2(bx, by + tile_size.y), Vector2(bx + tile_size.x, by + tile_size.y), _draw_border_color, 2.0)
		if not layout_set.has(coord + dirs[3]):
			draw_line(Vector2(bx, by), Vector2(bx, by + tile_size.y), _draw_border_color, 2.0)


func begin_movement(units: Array) -> void:
	# Additive — never overwrites units already en route to this room from a
	# previous dispatch so that separate clicks to the same room don't lose
	# earlier travellers and clear the green border prematurely.
	for unit in units:
		if unit not in _pending_units:
			_pending_units.append(unit)
	_update_visuals()


## Called by SelectionManager when a unit is redirected to a different room
## before arriving here.  Clears the tile reservation and removes the unit
## from the en-route list so the green border turns off immediately if no
## other units are still coming.
func cancel_unit_routing(unit: Node) -> void:
	_pending_units.erase(unit)
	release_unit(unit)   # removes tile-occupant meta, tile highlight, _unit_to_tile entry
	if _pending_units.is_empty():
		_update_visuals()


## Called when a unit physically enters this room (via Area2D or manual trigger).
## Sets unit.current_room = self so units don't need to poll every frame.
func _on_body_entered(body: Node) -> void:
	if is_instance_valid(body) and body.has_method("_on_entered_room"):
		body._on_entered_room(self)


## Called when a unit leaves this room.
## Clears unit.current_room if it still points to this room.
func _on_body_exited(body: Node) -> void:
	if is_instance_valid(body) and body.has_method("_on_exited_room"):
		body._on_exited_room(self)


func on_unit_arrived(unit: Node) -> void:
	_pending_units.erase(unit)
	if _unit_to_tile.has(unit):
		_remove_tile_highlight(_unit_to_tile[unit])
		_unit_to_tile.erase(unit)
	if _pending_units.is_empty():
		_update_visuals()
	# Release the unit's _target_room reference now that it has arrived.
	if unit.get("_target_room") == self:
		unit.set("_target_room", null)
	# Station assignment is now driven by the unit calling check_for_available_assignments()
	# directly after arrival, so the arriving unit always gets first priority.
	# _reevaluate_station_priority() is reserved for the manning_changed signal path.
	if unit.get("team") == 0:
		var all_enemies : Array = get_tree().get_nodes_in_group("enemy_units")
		for e in get_tree().get_nodes_in_group("enemies"):
			if not all_enemies.has(e):
				all_enemies.append(e)
		for enemy in all_enemies:
			if get_tile_index_at((enemy as Node2D).global_position) != -1:
				enemy.set("_ai_think_cooldown", 0.0)
				enemy.set("_ai_timer", 0.0)


func remove_pending_unit(unit: Node) -> void:
	_pending_units.erase(unit)
	if _pending_units.is_empty():
		_update_visuals()


# ===========================================================================
# HP / STATE
# ===========================================================================

func take_damage(amount: int) -> void:
	current_hp = max(0, current_hp - amount)
	if current_hp == 0:
		_set_broken()


func _set_broken() -> void:
	is_functional = false
	for i in _tile_count():
		if not _is_tile_active(i):
			continue
		var tile = _get_tile_node(i)
		if tile is ColorRect:
			tile.color = COLOR_BROKEN


# ===========================================================================
# SLOT API
# ===========================================================================

func get_tile_count() -> int:
	if not custom_tile_layout.is_empty():
		return custom_tile_layout.size()
	return _tile_count()


func _get_tile(index: int) -> Control:
	return _get_tile_node(index)


func get_tile_center(index: int) -> Vector2:
	var tile := _get_tile_node(index)
	if tile == null:
		return global_position
	var local_center := _tile_local_rect(index).get_center()
	return get_global_transform() * local_center


func get_tile_index_at(world_pos: Vector2) -> int:
	var local_pos := get_global_transform().affine_inverse() * world_pos
	for i in _tile_count():
		if not _is_tile_active(i):
			continue
		if _tile_local_rect(i).has_point(local_pos):
			return i
	return -1


func is_tile_available(index: int) -> bool:
	if not _is_tile_active(index):
		return false
	var occs : Array = _tile_occupants.get(index, [])
	var valid_count := 0
	for u in occs:
		if is_instance_valid(u):
			valid_count += 1
	return valid_count < 2


## Returns faction integer (0 = player, 1 = enemy) for any unit node.
func _get_unit_faction(unit: Node) -> int:
	var t = unit.get("team")
	if t != null:
		return int(t)
	return 1   # Enemy.gd nodes have no 'team' — always enemy faction


## Returns true when a unit of the given faction may occupy the tile at index.
## Max 2 per tile, and only if both units are from opposing factions.
func can_unit_occupy_tile(index: int, faction: int) -> bool:
	if not _is_tile_active(index):
		return false
	var occs : Array = _tile_occupants.get(index, [])
	var valid : Array = []
	for u in occs:
		if is_instance_valid(u):
			valid.append(u)
	if valid.size() >= 2:
		return false
	if valid.is_empty():
		return true
	return _get_unit_faction(valid[0]) != faction


## Returns the best tile index for a unit of attacker_faction to move to.
## Priority 1 — melee: a tile holding exactly one opposing-faction unit with a free slot.
## Priority 2 — spread: the first tile that can_unit_occupy_tile() accepts.
## exclude_indices: tile indices to skip (e.g. station seat for saboteurs).
func find_best_tile_for_faction(attacker_faction: int, exclude_indices: Array = []) -> int:
	# Pass 1 — melee slot.
	for i in range(_tile_count()):
		if not _is_tile_active(i) or i in exclude_indices:
			continue
		var occs : Array = _tile_occupants.get(i, [])
		var valid : Array = []
		for u in occs:
			if is_instance_valid(u):
				valid.append(u)
		if valid.size() == 1 and _get_unit_faction(valid[0]) != attacker_faction:
			return i
	# Pass 2 — spread: strictly a tile with 0 same-faction occupants.
	for i in range(_tile_count()):
		if not _is_tile_active(i) or i in exclude_indices:
			continue
		var occs2 : Array = _tile_occupants.get(i, [])
		var has_same := false
		for u in occs2:
			if is_instance_valid(u) and _get_unit_faction(u) == attacker_faction:
				has_same = true
				break
		if not has_same:
			return i
	# No valid tile — return -1 so callers know not to navigate.
	# Never fall back to tile 0: that would silently stack same-faction units.
	return -1


## Distance-aware unique tile assignment.  Picks the tile NEAREST to `unit`
## that has zero same-faction occupants (or a melee slot with exactly one
## opposing unit).  Station seat tiles are excluded for opposing-faction units.
## The chosen tile is pre-reserved atomically so concurrent AI ticks in the
## same physics frame cannot double-book the same index.
## Returns -1 when no valid tile is available (room is full for this faction).
func request_unique_tile(unit: Node) -> int:
	var faction  : int     = _get_unit_faction(unit)
	var unit_pos : Vector2 = (unit as Node2D).global_position
	var exclude  : Array   = []
	if faction != owner_faction:
		for entry in _stations:
			exclude.append(entry["tile_index"])

	# Pass 1 — melee slot: tile with exactly one opposing-faction unit.
	var best_tile : int   = -1
	var best_dist : float = INF
	for i in range(_tile_count()):
		if not _is_tile_active(i) or i in exclude:
			continue
		var valid : Array = []
		for u in _tile_occupants.get(i, []):
			if is_instance_valid(u):
				valid.append(u)
		if valid.size() == 1 and _get_unit_faction(valid[0]) != faction:
			var d := unit_pos.distance_to(get_tile_center(i))
			if d < best_dist:
				best_dist = d
				best_tile = i
	if best_tile != -1:
		reserve_tile(best_tile, unit, false)
		return best_tile

	# Pass 2 — spread: nearest tile with no same-faction occupants.
	best_dist = INF
	for i in range(_tile_count()):
		if not _is_tile_active(i) or i in exclude:
			continue
		var has_same := false
		for u in _tile_occupants.get(i, []):
			if is_instance_valid(u) and _get_unit_faction(u) == faction:
				has_same = true
				break
		if not has_same:
			var d := unit_pos.distance_to(get_tile_center(i))
			if d < best_dist:
				best_dist = d
				best_tile = i
	if best_tile != -1:
		reserve_tile(best_tile, unit, false)
	return best_tile


## Backward-compat wrapper — delegates to request_unique_tile.
func get_next_available_tile(unit: Node) -> int:
	return request_unique_tile(unit)


## Synchronous dispatcher used by Enemy AI.
## A tile is "available" only when reserved_count + occupant_count for the
## requesting faction is 0.  Combat rooms additionally expose a melee slot
## (1 player + 1 enemy on the same tile).  The chosen tile is atomically
## pre-reserved so the next unit asking 0.001 s later sees it as Pending.
## Returns -1 when no tile is available.
func request_assignment(unit: Node) -> int:
	return request_unique_tile(unit)


## Releases a pending reservation (or occupancy) for `unit` without any
## other side-effects.  Call this whenever a unit abandons its target so
## the tile is immediately visible as free to other requesters.
func release_reservation(unit: Node) -> void:
	release_unit(unit)


## Batch-assigns unique tiles to every unit in `units`.
## Each tile is pre-reserved before moving on to the next unit so concurrent
## AI ticks in the same physics frame cannot pick the same destination.
func assign_optimal_tiles(units: Array) -> void:
	var nav = get_tree().get_first_node_in_group("navigation_manager")
	if nav == null:
		return
	for unit in units:
		if not is_instance_valid(unit):
			continue
		# release first so the unit's current tile doesn't block its own scan
		release_unit(unit)
		var tile_idx : int = request_unique_tile(unit)   # atomically claims the tile
		if tile_idx == -1:
			continue
		var target_pos := get_tile_position_by_index(tile_idx)
		var path : PackedVector2Array
		if unit.get("team") == null:   # Enemy.gd — no team property
			path = nav.get_enemy_nav_path(unit.global_position, target_pos)
		else:
			path = nav.get_nav_path(unit.global_position, target_pos)
		if path.size() > 0 and unit.has_method("move_along_path"):
			unit.move_along_path(path)


## Called when a unit physically arrives on `tile_index`.
## Marks the tile occupied, then scans ALL units that have any pre-reservation
## in this room (_unit_to_tile covers both player and enemy units).  Any
## same-faction unit that pre-reserved this same slot is immediately redirected
## to a new tile.  Units in active states (ATTACKING / SABOTAGE etc.) are left
## alone so we don't interrupt ongoing actions.
func _on_tile_entered(unit: Node, tile_index: int) -> void:
	reserve_tile(tile_index, unit, false)
	var faction : int = _get_unit_faction(unit)
	var nav = get_tree().get_first_node_in_group("navigation_manager")
	for other in _unit_to_tile.keys().duplicate():
		if not is_instance_valid(other) or other == unit:
			continue
		if _get_unit_faction(other) != faction:
			continue   # opposing factions may share a tile (melee pairing)
		if _unit_to_tile.get(other, -1) != tile_index:
			continue
		# Only redirect IDLE (0) or WALKING (1) units — never interrupt combat.
		var s = other.get("state")
		if s != null and int(s) > 1:
			continue
		# Claim a new slot atomically before evicting from the old one.
		var new_tile : int = request_unique_tile(other)
		if new_tile == -1 or new_tile == tile_index:
			continue
		# Evict other from the conflicted tile (new_tile is already reserved).
		if _tile_occupants.has(tile_index):
			_tile_occupants[tile_index].erase(other)
			if _tile_occupants[tile_index].is_empty():
				_tile_occupants.erase(tile_index)
		if nav == null:
			continue
		var tp : Vector2 = get_tile_position_by_index(new_tile)
		var path : PackedVector2Array
		if other.get("team") == null:
			path = nav.get_enemy_nav_path(other.global_position, tp)
		else:
			path = nav.get_nav_path(other.global_position, tp)
		if path.size() > 0 and other.has_method("move_along_path"):
			other.move_along_path(path)


func get_first_available_tile() -> int:
	if _station_tile_index != -1 and is_instance_valid(_station) and not _station.get("is_manned"):
		if is_tile_available(_station_tile_index):
			return _station_tile_index
	for i in range(_tile_count()):
		if i == _station_tile_index:
			continue
		if not _is_tile_active(i):
			continue
		if is_tile_available(i):
			return i
	return -1


func reserve_tile(index: int, unit: Node2D, show_highlight: bool = true) -> void:
	if index == -1:
		return
	var tile := _get_tile_node(index)
	if tile == null:
		return
	# Clear any previous reservation this unit held in a DIFFERENT tile to
	# prevent ghost-blocked tiles when a unit changes destination mid-route.
	var old_idx : int = _unit_to_tile.get(unit, -1)
	if old_idx != -1 and old_idx != index:
		if _tile_occupants.has(old_idx):
			_tile_occupants[old_idx].erase(unit)
			if _tile_occupants[old_idx].is_empty():
				_tile_occupants.erase(old_idx)
		_remove_tile_highlight(old_idx)
	tile.set_meta("occupant", unit)
	# Multi-occupant tracking (max 2 opposing-faction units per tile).
	if not _tile_occupants.has(index):
		_tile_occupants[index] = []
	var occs : Array = _tile_occupants[index]
	for i in range(occs.size() - 1, -1, -1):
		if not is_instance_valid(occs[i]):
			occs.remove_at(i)
	if unit not in occs:
		occs.append(unit)
	# Always track which tile each unit pre-reserved so _on_tile_entered can
	# detect same-faction collisions even when highlights are suppressed.
	_unit_to_tile[unit] = index
	if show_highlight:
		_spawn_tile_highlight(index)


func get_tile_position_by_index(index: int) -> Vector2:
	var tile := _get_tile_node(index)
	if tile == null:
		return global_position
	var local_center := _tile_local_rect(index).get_center()
	return get_global_transform() * local_center


func release_unit(unit: Node2D) -> void:
	# Remove from multi-occupant tracking.
	for idx in _tile_occupants.keys():
		var occs : Array = _tile_occupants[idx]
		occs.erase(unit)
		if occs.is_empty():
			_tile_occupants.erase(idx)
	# Clear legacy single-occupant meta.
	for i in range(_tile_count()):
		var tile := _get_tile_node(i)
		if tile and tile.has_meta("occupant") and tile.get_meta("occupant") == unit:
			tile.set_meta("occupant", null)
	if _unit_to_tile.has(unit):
		_remove_tile_highlight(_unit_to_tile[unit])
		_unit_to_tile.erase(unit)


## Like release_unit but only removes the unit from the single tile that
## contains world_pos.  Pre-reserved destination tiles in the same room are
## left intact, which is critical for same-room navigation (station routing,
## enemy spreading) where the destination is reserved before move_along_path
## is called but change_state(WALKING) fires in the same call stack.
func release_unit_from_position(unit: Node, world_pos: Vector2) -> void:
	var tile_idx := get_tile_index_at(world_pos)
	if tile_idx == -1:
		return
	if _tile_occupants.has(tile_idx):
		var occs : Array = _tile_occupants[tile_idx]
		occs.erase(unit)
		if occs.is_empty():
			_tile_occupants.erase(tile_idx)
	var tile := _get_tile_node(tile_idx)
	if tile and tile.has_meta("occupant") and tile.get_meta("occupant") == unit:
		tile.set_meta("occupant", null)
	if _unit_to_tile.get(unit, -1) == tile_idx:
		_remove_tile_highlight(tile_idx)
		_unit_to_tile.erase(unit)


func _spawn_tile_highlight(index: int) -> void:
	_remove_tile_highlight(index)
	var tile := _get_tile_node(index)
	if tile == null:
		return
	var local_rect := _tile_local_rect(index)

	var highlight         := ColorRect.new()
	highlight.color        = Color(0.0, 1.0, 0.1, 0.45)
	highlight.size         = local_rect.size
	highlight.position     = local_rect.position
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	highlight.z_index      = 5
	add_child(highlight)
	active_highlights[index] = highlight

	var tween := create_tween().set_loops()
	tween.tween_property(highlight, "color:a", 0.15, 0.6)
	tween.tween_property(highlight, "color:a", 0.45, 0.6)
	_highlight_tweens[index] = tween


func _remove_tile_highlight(index: int) -> void:
	if active_highlights.has(index):
		var node = active_highlights[index]
		if is_instance_valid(node):
			node.queue_free()
		active_highlights.erase(index)
	if _highlight_tweens.has(index):
		var tw = _highlight_tweens[index]
		if tw:
			tw.kill()
		_highlight_tweens.erase(index)


func get_random_tile() -> Vector2:
	var count := get_tile_count()
	if count == 0:
		return global_position
	if not custom_tile_layout.is_empty():
		var coord := custom_tile_layout[randi() % count]
		if _grid != null:
			return get_tile_center(coord.y * _grid.columns + coord.x)
		# Flat mode: find the tile matching this coord by position.
		var ts := _get_tile_pixel_size()
		var target_pos := Vector2(coord.x * ts.x, coord.y * ts.y)
		for i in _flat_tiles.size():
			if _flat_tiles[i].position.distance_to(target_pos) < 1.0:
				return get_tile_center(i)
	return get_tile_center(randi() % count)


# ===========================================================================
# FIRE GIMMICK
# ===========================================================================

func start_fire(tile_index: int) -> void:
	var tile := _get_tile_node(tile_index)
	if tile == null:
		push_warning("BaseRoom.start_fire: index %d out of range" % tile_index)
		return
	if tile.has_method("start_fire"):
		tile.start_fire()
	var cols     := _grid.columns if _grid else 1
	var grid_pos := Vector2i(tile_index % cols, floori(float(tile_index) / cols))
	if grid_pos not in room_data.fires:
		room_data.fires.append(grid_pos)


func _build_room_data() -> void:
	if not custom_tile_layout.is_empty():
		for coord in custom_tile_layout:
			room_data.tiles.append(coord)
	elif _grid != null:
		var cols := _grid.columns
		for i in _grid.get_child_count():
			room_data.tiles.append(Vector2i(i % cols, floori(float(i) / cols)))
	else:
		for i in _flat_tiles.size():
			room_data.tiles.append(Vector2i(i, 0))


# ===========================================================================
# INITIALIZATION
# ===========================================================================

func _init_room() -> void:
	if _grid == null:
		_collect_flat_tiles()
		size = _compute_flat_size()
	else:
		size = _grid.get_combined_minimum_size()
	_apply_custom_layout()
	_setup_border_overlay()
	_register_tiles()
	_setup_station_priority()
	_build_room_data()
	# Enable transform notifications AFTER registration so initial layout
	# positioning doesn't trigger spurious nav rebuilds.
	_nav_registered = true
	set_notify_transform(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and _nav_registered:
		_request_nav_rebuild()


## Debounced nav rebuild — coalesces multiple transform events in one frame.
func _request_nav_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_do_nav_rebuild")


func _do_nav_rebuild() -> void:
	_rebuild_queued = false
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if nav and nav.has_method("rebuild_room"):
		nav.rebuild_room(self)


func _apply_custom_layout() -> void:
	# Flat-mode rooms have only active tiles as children — nothing to hide.
	if _grid == null:
		return
	if custom_tile_layout.is_empty():
		return
	var cols := _grid.columns
	for i in _grid.get_child_count():
		var coord := Vector2i(i % cols, floori(float(i) / cols))
		if coord not in custom_tile_layout:
			var tile := _grid.get_child(i) as Control
			tile.visible      = false
			tile.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _setup_border_overlay() -> void:
	if not custom_tile_layout.is_empty():
		return  # custom shapes use _draw() instead
	var overlay         := ColorRect.new()
	overlay.name         = "BorderOverlay"
	overlay.color        = Color.WHITE
	overlay.size         = size
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat    := ShaderMaterial.new()
	mat.shader  = load(_BORDER_SHADER)
	overlay.material = mat
	_border_mat      = mat
	add_child(overlay)


# ===========================================================================
# NAVIGATION REGISTRATION
# ===========================================================================

## Returns the world-space centre of every walkable tile, correctly accounting
## for the room's current rotation and position via the global transform.
func get_walkable_tiles() -> Array[Vector2]:
	var result : Array[Vector2] = []
	var xform  := get_global_transform()
	for i in _tile_count():
		if not _is_tile_active(i):
			continue
		if _get_tile_node(i) == null:
			continue
		var local_center := _tile_local_rect(i).get_center()
		result.append(xform * local_center)
	return result


func _register_tiles() -> void:
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if nav == null:
		push_warning("room_base: NavigationManager not found — tiles not registered for %s." % name)
		return
	var positions := get_walkable_tiles()
	if not positions.is_empty():
		nav.register_room_tile_positions(self, positions)


# ===========================================================================
# INPUT
# ===========================================================================

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var sm := get_tree().get_first_node_in_group("selection_manager")
	if event.button_index == MOUSE_BUTTON_LEFT:
		for door in get_tree().get_nodes_in_group("doors"):
			if door.global_position.distance_to(get_global_mouse_position()) < 24.0:
				return
		accept_event()
		if sm and sm.has_method("select_room"):
			sm.select_room(self)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		var index := get_tile_index_at(get_global_mouse_position())
		if sm and sm.has_method("distribute_units_to_tiles"):
			sm.distribute_units_to_tiles(self, index)


func get_unit_slot_position(_unit) -> Vector2:
	return global_position + (size / 2)


# ===========================================================================
# STATION PRIORITY
# ===========================================================================

func _setup_station_priority() -> void:
	for s in get_tree().get_nodes_in_group("stations"):
		if not is_instance_valid(s):
			continue
		# Test both the station's Area2D origin and its InteractionSpot.
		# For some room shapes the root origin may fall outside all tile rects,
		# so checking the seat position as a fallback is required.
		var origin_tile : int      = get_tile_index_at((s as Node2D).global_position)
		var seat        : Marker2D = s.get("interaction_spot")
		var seat_tile   : int      = -1
		if is_instance_valid(seat):
			seat_tile = get_tile_index_at(seat.global_position)
		if origin_tile == -1 and seat_tile == -1:
			continue
		var tile_idx := seat_tile if seat_tile != -1 else origin_tile
		_stations.append({"node": s, "tile_index": tile_idx})
		s.manning_changed.connect(_on_station_manning_changed)
		# Keep single-station backward-compat refs pointing to the first station.
		if _station == null:
			_station            = s
			_station_tile_index = tile_idx


func _on_station_manning_changed(occupied: bool, _unit: Node2D) -> void:
	if not occupied:
		_reevaluate_station_priority()


## Called by a unit the moment it finishes walking into this room.
## Finds the first available (unmanned) station and routes that specific unit there.
## Never bumps a unit that is already manning or repairing a station.
func check_for_available_assignments(unit: Node) -> void:
	# Skip units already at a station or already holding a manning target.
	var unit_state = unit.get("state")
	if unit_state == 2 or unit_state == 4:   # STATION_ACTIVE or REPAIRING
		return
	if unit.get("_manning_target") != null:
		return
	# Only route units to stations of their own faction.
	var unit_faction : int = int(unit.get("team") if unit.get("team") != null else 1)
	for entry in _stations:
		var station : Node = entry["node"]
		var tile_idx : int = entry["tile_index"]
		if not is_instance_valid(station):
			continue
		var s_faction = station.get("owner_faction")
		if s_faction != null and int(s_faction) != unit_faction:
			continue                          # never route enemies to player stations
		if station.get("is_manned"):
			continue                          # already occupied — never bump
		if not can_unit_occupy_tile(tile_idx, unit_faction):
			continue                          # tile full or same-faction unit already there
		_route_unit_to_tile(unit, tile_idx)
		return


## Routes a specific unit to a tile by index using AStar navigation.
func _route_unit_to_tile(unit: Node2D, tile_idx: int) -> void:
	var nav = get_tree().get_first_node_in_group("navigation_manager")
	if nav == null:
		return
	release_unit(unit)
	reserve_tile(tile_idx, unit)
	var target_pos := get_tile_position_by_index(tile_idx)
	var path : PackedVector2Array = nav.get_nav_path(unit.global_position, target_pos)
	unit.move_along_path(path)


## Called when any station in this room becomes unmanned (via manning_changed signal).
## Routes the first idle unit already in the room to fill the vacancy.
func _reevaluate_station_priority() -> void:
	for entry in _stations:
		var station : Node = entry["node"]
		var tile_idx : int = entry["tile_index"]
		if not is_instance_valid(station):
			continue
		if station.get("is_manned"):
			continue
		if not is_tile_available(tile_idx):
			continue
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.get("current_room") != self:
				continue
			if unit.get("state") != 0:            # must be IDLE
				continue
			if unit.get("_manning_target") != null:
				continue
			if _unit_to_tile.get(unit, -1) == tile_idx:
				continue                           # already en route here
			_route_unit_to_tile(unit, tile_idx)
			break                                  # one unit per station per call


func get_combatants() -> Dictionary:
	var players : Array = []
	var enemies : Array = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		if get_tile_index_at((unit as Node2D).global_position) != -1:
			if unit.get("team") == 0:
				players.append(unit)
			else:
				enemies.append(unit)
	return {"players": players, "enemies": enemies}


func _route_unit_to_station(unit: Node2D) -> void:
	_route_unit_to_tile(unit, _station_tile_index)

func is_position_inside(pos: Vector2) -> bool:
	# If using a simple Rect2 for the room size:
	var room_rect = Rect2(global_position, room_size)
	return room_rect.has_point(pos)
	# Alternatively, if you have a CollisionShape2D named "Area":
	# return $Area.get_shape().get_rect().has_point(to_local(pos))
		#pass # Replace with your specific collision/area logic
		
		
## Returns all impassable doors whose host_tile is inside this room and whose
## owner_faction matches `hostile_faction`. Used by units to find the exit door
## that blocks their path without relying solely on adjacent-tile detection.
func get_exit_doors(hostile_faction: int) -> Array:
	var result : Array = []
	for door in get_tree().get_nodes_in_group("doors"):
		if not is_instance_valid(door) or door.is_passable():
			continue
		if int(door.get("owner_faction") if door.get("owner_faction") != null else 0) != hostile_faction:
			continue
		var host_pos : Vector2 = door.get("host_tile_world_pos") if door.get("host_tile_world_pos") != null else Vector2.ZERO
		var door_pos : Vector2 = (door as Node2D).global_position
		var connected := (host_pos != Vector2.ZERO and get_tile_index_at(host_pos) != -1) \
					  or get_tile_index_at(door_pos) != -1
		if connected:
			result.append(door)
	return result

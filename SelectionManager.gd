## SelectionManager.gd
## Handles unit selection (click + drag-box) and slot-based movement.
##
## Input Map: "Select" (Left Mouse Button)
## Right-click is handled by BaseRoom → distribute_units_to_tiles().
extends Node2D

# ── constants ─────────────────────────────────────────────────────────────────
const CLICK_RADIUS   := 24.0
const DRAG_THRESHOLD := 8.0
const BOX_FILL       := Color(0.2, 0.8, 0.2, 0.12)
const BOX_BORDER     := Color(0.2, 0.9, 0.2, 0.85)

const FLASH_COLOR_VALID := Color(0.2, 1.0, 0.3, 0.65)
const FLASH_DURATION    := 0.45
const TILE_SIZE         := Vector2(32.0, 32.0)

# ── state ─────────────────────────────────────────────────────────────────────
var active_unit              : CharacterBody2D = null
var _selected_units          : Array           = []
var _drag_start              : Vector2         = Vector2.ZERO
var _drag_end                : Vector2         = Vector2.ZERO
var _is_dragging             : bool            = false
var _unit_selected_on_press  : bool            = false


# ── lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("selection_manager")


# ── input ─────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action("Select"):
		_handle_select(event)
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		if _handle_right_click_door(get_global_mouse_position()):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if _is_dragging:
			_drag_end = get_global_mouse_position()
			queue_redraw()
		_update_door_hover(get_global_mouse_position())


func _handle_select(event: InputEvent) -> void:
	if event.is_pressed():
		_drag_start  = get_global_mouse_position()
		_drag_end    = _drag_start
		_is_dragging = true
	else:
		_is_dragging = false
		queue_redraw()
		# Priority check: if a unit was atomically selected on press, honour that
		# result unconditionally — even if the mouse drifted past DRAG_THRESHOLD.
		# Checking this FIRST prevents _box_select() from clobbering the press-time
		# selection, which was the cause of the group→single flicker.
		if _unit_selected_on_press:
			pass   # selection already committed on press; nothing more to do
		elif (_drag_end - _drag_start).length() > DRAG_THRESHOLD:
			_box_select()
		else:
			_click_select(_drag_start)
		_unit_selected_on_press = false


# ── movement API (called by BaseRoom) ─────────────────────────────────────────

## Distribute selected units into sequential slots starting at start_index.
##
## Unit 0 → tile[start_index], Unit 1 → tile[start_index+1], …
## When the clicked room's tiles are exhausted, overflow to the nearest other room
## starting at tile 0.  Units are ghosts (no physics collision) so multiple units
## can physically share a tile without issue.
## preferred_index: the tile the player right-clicked (-1 = no preference).
## The first selected unit is routed there; remaining units fill sequentially.
func distribute_units_to_tiles(target_room, preferred_index: int = -1):
	var nav = get_tree().get_first_node_in_group("navigation_manager")

	if not nav:
		print("Error: NavigationManager group not found!")
		return

	var dispatched_units  : Array = []
	var preferred_used    : bool  = false

	for unit in _selected_units:
		# ── Cancel previous routing ──────────────────────────────────────────
		# 1. Release the tile in the unit's current/anticipatory room.
		if "current_room" in unit and unit.current_room != null:
			var old_room = unit.current_room
			old_room.release_unit(unit)
			if old_room != target_room and old_room.has_method("remove_pending_unit"):
				old_room.remove_pending_unit(unit)

		# 2. Cancel any separate _target_room (set by station auto-routing or a
		#    previous dispatch that didn't go through _current_room).
		var prev_target = unit.get("_target_room")
		if is_instance_valid(prev_target) and prev_target != target_room \
				and prev_target.has_method("cancel_unit_routing"):
			prev_target.cancel_unit_routing(unit)

		# ── Dispatch to new room ─────────────────────────────────────────────
		var index: int
		if not preferred_used and preferred_index != -1 \
				and target_room.is_tile_available(preferred_index):
			index = preferred_index
			preferred_used = true
		else:
			index = target_room.get_first_available_tile()

		if index != -1:
			target_room.reserve_tile(index, unit)
			var target_pos = target_room.get_tile_position_by_index(index)
			var path       = nav.get_nav_path(unit.global_position, target_pos)
			unit.current_room = target_room
			unit.set("_target_room", target_room)   # stamp so redirects can clean up
			unit.move_along_path(path)
			dispatched_units.append(unit)
			print("Moving ", unit.name, " to slot ", index)
		else:
			print("No room left!")

	if not dispatched_units.is_empty() and target_room.has_method("begin_movement"):
		target_room.begin_movement(dispatched_units)

## Returns the nearest room to from_room (any room with at least one tile).
## Used for overflow when the clicked room is full.
func _find_overflow_room(from_room: Node) -> Node:
	var best_room : Node  = null
	var best_dist : float = INF
	var origin    : Vector2 = from_room.global_position

	for room in get_tree().get_nodes_in_group("rooms"):
		if not room.has_method("get_tile_count"):
			continue
		if room == from_room:
			continue
		if room.get_tile_count() == 0:
			continue
		var d : float = room.global_position.distance_to(origin)
		if d < best_dist:
			best_dist = d
			best_room = room

	return best_room

# Inside SelectionManager.gd

func _on_room_clicked(target_room):
	# 'selected_units' should be your array of crew members
	for unit in _selected_units:
		# 1. Ask the room for a free spot index (0, 1, 2, or 3)
		var tile_index = target_room.get_first_available_tile()

		if tile_index != -1:
			# 2. Tell the room this unit is occupying this tile
			target_room.reserve_tile(tile_index, unit)

			# 3. Get the actual world position of that specific tile
			var world_pos = target_room.get_tile_position_by_index(tile_index)

			# 4. Move the unit
			unit.move_to(world_pos) 
		else:
			print("Room is full!")

## If selected player units right-click a hostile door, order them to breach it.
## Returns true when the click was consumed (door found and units ordered).
func _handle_right_click_door(point: Vector2) -> bool:
	if _selected_units.is_empty():
		return false
	for door in get_tree().get_nodes_in_group("doors"):
		if (door as Node2D).global_position.distance_to(point) > CLICK_RADIUS:
			continue
		var door_faction : int = int(door.get("owner_faction") if door.get("owner_faction") != null else 0)
		var ordered := false
		for unit in _selected_units:
			if not is_instance_valid(unit):
				continue
			var unit_team : int = int(unit.get("team") if unit.get("team") != null else 0)
			if door_faction != unit_team and unit.has_method("attack_door"):
				unit.attack_door(door)
				ordered = true
		return ordered   # consumed whether or not any unit could target it
	return false


## Returns true when at least one player unit is currently selected.
## Queried directly by rooms so they don't need a stored _hover_enabled flag.
func has_selected_units() -> bool:
	return not _selected_units.is_empty()


## Select a room, deselecting all others.
func select_room(room: Node) -> void:
	for r in get_tree().get_nodes_in_group("rooms"):
		if not r.has_method("_update_visuals"):
			continue
		r.is_selected = false
		r._update_visuals()
	room.is_selected = true
	room._update_visuals()


## Remove unit's reservation from every room on the ship.
func _release_unit_globally(unit: Node) -> void:
	for room in get_tree().get_nodes_in_group("rooms"):
		if room.has_method("release_unit"):
			room.release_unit(unit)


# ── visual feedback ───────────────────────────────────────────────────────────

func flash_tile(world_pos: Vector2,
		color: Color    = FLASH_COLOR_VALID,
		duration: float = FLASH_DURATION) -> void:

	var rect     := ColorRect.new()
	rect.color    = color
	rect.size     = TILE_SIZE
	rect.position = world_pos - TILE_SIZE * 0.5
	rect.z_index  = 10
	add_child(rect)

	var tween := create_tween()
	tween.tween_property(rect, "color:a", 0.0, duration) \
		 .set_ease(Tween.EASE_IN) \
		 .set_trans(Tween.TRANS_QUAD)
	tween.tween_callback(rect.queue_free)


# ── selection helpers ─────────────────────────────────────────────────────────

## Highlights the nearest door within CLICK_RADIUS; clears all others.
## Suppresses room hover while any door is highlighted so both effects
## never show at the same time.
func _update_door_hover(point: Vector2) -> void:
	var nearest_door: Node  = null
	var nearest_dist: float = CLICK_RADIUS
	for door in get_tree().get_nodes_in_group("doors"):
		var d := (door as Node2D).global_position.distance_to(point)
		if d < nearest_dist:
			nearest_dist = d
			nearest_door = door
	for door in get_tree().get_nodes_in_group("doors"):
		door.set_hovered(door == nearest_door)
	var suppress := nearest_door != null
	for room in get_tree().get_nodes_in_group("rooms"):
		room.set_hover_suppressed(suppress)


## Select a player unit.
##
## clear_existing = true  (default, normal click): atomically deselect_all() then
##   set the target unit to SELECTED.  Since GDScript is single-threaded and Godot
##   renders after all logic in a frame, the deselect→select transition is invisible.
## clear_existing = false (box-select append): append to current selection without
##   disturbing the rest of the group.
func select_unit(unit: CharacterBody2D, clear_existing: bool = true) -> void:
	_unit_selected_on_press = true   # tells _handle_select to skip _click_select
	if clear_existing:
		# Step 1: atomically clear the old selection (all units → UNSELECTED).
		deselect_all()
	# Step 2: add target and mark SELECTED.  The is_selected setter is the only
	# place that writes modulate, so the visual change is instantaneous and exact.
	if unit not in _selected_units:
		_selected_units.append(unit)
	unit.is_selected = true
	active_unit = unit
	for room in get_tree().get_nodes_in_group("rooms"):
		room.set_hover_enabled(true)


## Order all selected player units to engage an enemy (called by enemy ClickArea).
func target_enemy(enemy: Node) -> void:
	for unit in _selected_units:
		if is_instance_valid(unit) and unit.has_method("engage"):
			unit.engage(enemy)


func _click_select(point: Vector2) -> void:
	# Priority 1: Doors.
	for door in get_tree().get_nodes_in_group("doors"):
		if (door as Node2D).global_position.distance_to(point) < CLICK_RADIUS:
			door.toggle()
			return

	# Priority 2: Enemies — target without deselecting player units.
	for group_name in ["enemy_units", "enemies"]:
		for enemy in get_tree().get_nodes_in_group(group_name):
			if is_instance_valid(enemy) \
					and (enemy as Node2D).global_position.distance_to(point) < CLICK_RADIUS:
				target_enemy(enemy)
				return

	# Priority 3: Player units.
	# Find the nearest unit BEFORE deciding to deselect anything.  Deselecting
	# first caused a deselect→reselect cycle every time a unit was clicked, which
	# manifested as a one-frame green→white→green modulate flash and broke the
	# multi-to-single transition (B and C were deselected even when clicking A
	# failed the unit-found check).
	var best_unit : CharacterBody2D = null
	var best_dist : float           = CLICK_RADIUS
	for unit in get_tree().get_nodes_in_group("player_units"):
		var d : float = (unit as Node2D).global_position.distance_to(point)
		if d < best_dist:
			best_dist = d
			best_unit = unit

	if is_instance_valid(best_unit):
		select_unit(best_unit)   # handles exclusive deselect internally
	else:
		deselect_all()           # genuine click on empty space


func _box_select() -> void:
	deselect_all()
	var rect := Rect2(_drag_start, _drag_end - _drag_start).abs()
	for unit in get_tree().get_nodes_in_group("player_units"):
		if rect.has_point((unit as Node2D).global_position):
			select_unit(unit as CharacterBody2D, false)   # append without clearing


## Deselect every unit and disable room hover.
## Public so external code (e.g. cutscenes, UI) can clear selection cleanly.
func deselect_all() -> void:
	for unit in _selected_units:
		if is_instance_valid(unit):
			(unit as CharacterBody2D).is_selected = false
	_selected_units.clear()
	active_unit = null
	for room in get_tree().get_nodes_in_group("rooms"):
		room.set_hover_enabled(false)


## Backward-compat alias so any code still calling _deselect() keeps working.
func _deselect() -> void:
	deselect_all()


# ── drag-box drawing ──────────────────────────────────────────────────────────

func _draw() -> void:
	if _is_dragging:
		var rect := Rect2(
				to_local(_drag_start),
				to_local(_drag_end) - to_local(_drag_start))
		draw_rect(rect, BOX_FILL,   true)
		draw_rect(rect, BOX_BORDER, false, 1.5)

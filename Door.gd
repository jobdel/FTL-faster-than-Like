## Door.gd
## Attach to the VDoor (Node2D) root in v_door.tscn.
## Expected scene structure:
##   VDoor (Node2D)           ← this script
##   ├── Sprite2D             ← visual; opacity indicates open/closed
##   ├── Area2D
##   │   └── CollisionShape2D (RectangleShape2D) ← sizes the hover overlay
##   └── StaticBody2D         ← physically blocks units when closed
##       ├── CollisionShape2D
##       └── NavigationObstacle2D
extends Node2D

const _BORDER_SHADER := "res://Scripts/room_border.gdshader"
const _COLOR_HOVER   := Color(1.0, 1.0, 0.0)

# ── health ───────────────────────────────────────────────────────────────────
@export var max_health : float = 50.0
var health    : float = 50.0   # shared interface — read directly as target.health
var is_broken : bool  = false

# ── damage visuals ────────────────────────────────────────────────────────────
var _blink_tween : Tween = null
const _COLOR_HEALTHY : Color = Color(1.0, 1.0, 1.0, 1.0)
const _COLOR_DAMAGED : Color = Color(0.8, 0.0, 0.0, 1.0)

# ── faction ───────────────────────────────────────────────────────────────────
## 0 = PLAYER ship door, 1 = ENEMY ship door.
## Units whose team matches owner_faction may reserve (auto-open) this door.
## Opposing-faction units are blocked and must breach it via take_damage().
@export var owner_faction : int = 0

## Emitted when a unit of the opposing faction attempts to pass through.
signal blocked(unit: Node)

# ── face data (set by NavigationManager._finalize_walls) ─────────────────────
## Which face of which tile this door guards.
## Face indices: 0 = North, 1 = East, 2 = South, 3 = West.  -1 = unassigned.
var face_index          : int     = -1
var host_tile_world_pos : Vector2 = Vector2.ZERO

# ── state ─────────────────────────────────────────────────────────────────────
var is_open     : bool           = false
var _border_mat : ShaderMaterial = null
var door_is_broken: bool = false

# Tracks which bodies are physically inside the Area2D right now.
# Door stays open as long as at least one friendly unit is present.
var _units_in_area : Array = []
var _close_timer   : Timer = null

## Emitted whenever is_passable() changes value (open/close toggle, or break).
signal passability_changed(is_passable: bool)

## Emitted when this door is fully destroyed (health reaches 0).
## All units respond by clearing their door target and re-scanning paths.
#signal door_destroyed(door: Node)
signal door_destroyed(door_ref)




func _ready() -> void:
	add_to_group("doors")
	health = max_health
	_setup_hover_overlay()
	_apply_visuals()
	# Deferred so all rooms have already registered their A* tiles.
	call_deferred("_self_register_with_nav")
	# Enable Area2D to detect units entering the trigger zone for auto-open.
	$Area2D.monitoring     = true
	$Area2D.collision_mask = 1   # layer 1 = CharacterBody2D units
	$Area2D.body_entered.connect(_on_area_body_entered)
	$Area2D.body_exited.connect(_on_area_body_exited)
	_close_timer = Timer.new()
	_close_timer.wait_time = 0.2
	_close_timer.one_shot  = true
	_close_timer.timeout.connect(_on_close_timer_timeout)
	add_child(_close_timer)


## Returns true when units may freely walk through this door.
func is_passable() -> bool:
	return is_open or is_broken


## Called by SelectionManager when the player clicks this door.
func toggle() -> void:
	if is_broken:
		return
	_set_open(not is_open)


## Called by Enemy.gd (and player units breaching enemy doors) to chip the door.
func take_damage(amount: float) -> void:
	if is_broken:
		return
	health = maxf(0.0, health - amount)
	print("DOOR: Received damage, health is ", health)
	_apply_visuals()
	if health <= 0.0:
		_break()


func _set_open(value: bool) -> void:
	var was_passable := is_passable()
	is_open = value
	$StaticBody2D/CollisionShape2D.set_deferred("disabled", is_open)
	$StaticBody2D/NavigationObstacle2D.affect_navigation_mesh = not is_open
	$StaticBody2D/NavigationObstacle2D.avoidance_enabled = not is_open
	NavigationServer2D.map_force_update(get_world_2d().get_navigation_map())
	_apply_visuals()
	if is_passable() != was_passable:
		passability_changed.emit(is_passable())




func _break() -> void:
	if is_broken:
		return
	is_broken = true
	# Emit signal so connected units can clear their target reference immediately,
	# before this node is removed from the scene tree.
	# EMIT THE SIGNAL FIRST
	# This tells everyone listening "I am gone, and here is where I was"
	door_destroyed.emit(self)
	# Force open and disable collision — _set_open handles nav + passability_changed.
	# IMPORTANT: nav map is updated here BEFORE we notify units so pathfinding works.
	_set_open(true)
	# Ask the parent ship to rebake its navigation region if it supports that.
	_rebake_ship_navigation()
	# Spark burst to signal the breach.
	_spawn_spark_effect()
	# Slow red blink to signal the breached state.
	if is_instance_valid(_blink_tween):
		_blink_tween.kill()
	_blink_tween = create_tween().set_loops()
	_blink_tween.tween_property($Sprite2D, "modulate", Color(1.0, 0.0, 0.0, 1.0), 0.5)
	_blink_tween.tween_property($Sprite2D, "modulate", Color(0.4, 0.0, 0.0, 0.5), 0.5)
	# Second explicit map flush — ensures pathfinder sees the tile as walkable
	# before any unit callback tries to re-path through it.
	NavigationServer2D.map_force_update(get_world_2d().get_navigation_map())
	
	
	# Notify ALL units deferred so callbacks run after the nav map update commits.
	call_deferred("_notify_units_door_broken")
	# Remove this node after notifications are delivered — deferred so it runs
	# after _notify_units_door_broken (which was queued first in the same frame).
	call_deferred("queue_free")


## Deferred: called one frame after _break() so the NavigationServer has fully
## processed the nav-obstacle removal before units attempt to re-path.
func _notify_units_door_broken() -> void:
	for grp in ["enemies", "enemy_units", "units"]:
		for unit in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(unit):
				continue
			# 1 Duck-typed: call on_door_destroyed (preferred) or _recalculate_path as fallback.
			if unit.has_method("on_door_destroyed"):
				unit.on_door_destroyed(self)
			# 2. Fallback: If no specific handler, just force a re-path
			elif unit.has_method("_recalculate_path"):
				unit._recalculate_path()


## Finds the nearest ancestor that exposes rebake_navigation() and calls it.
## Falls back gracefully if the ship does not implement that method.
func _rebake_ship_navigation() -> void:
	var node := get_parent()
	while is_instance_valid(node):
		if node.has_method("rebake_navigation"):
			node.rebake_navigation()
			return
		node = node.get_parent() if node.get_parent() != node else null


func _spawn_spark_effect() -> void:
	var sparks := CPUParticles2D.new()
	sparks.emitting              = false
	sparks.one_shot              = true
	sparks.explosiveness         = 1.0
	sparks.amount                = 24
	sparks.lifetime              = 0.7
	sparks.initial_velocity_min  = 40.0
	sparks.initial_velocity_max  = 110.0
	sparks.gravity               = Vector2(0.0, 60.0)
	sparks.color                 = Color(1.0, 0.75, 0.1, 1.0)
	add_child(sparks)
	sparks.emitting = true
	get_tree().create_timer(1.2).timeout.connect(
		func() -> void:
			if is_instance_valid(sparks):
				sparks.queue_free()
	)


func _apply_visuals() -> void:
	if is_broken:
		return  # blink tween owns the visuals after breach
	# Red-fade: Color(1, pct, pct) — white at full health, red at 0 hp.
	var pct := health / max_health
	var health_color := Color(1.0, pct, pct, 1.0)
	if is_open:
		health_color.a = 0.35
	$Sprite2D.modulate = health_color


## Register this door with NavigationManager after A* tiles are loaded.
func _self_register_with_nav() -> void:
	var nav := get_tree().get_first_node_in_group("navigation_manager")
	if nav and nav.has_method("register_door"):
		nav.register_door(self)


# ---------------------------------------------------------------------------
# Path-based door API — called by Unit.gd, not by Area2D signals
# ---------------------------------------------------------------------------

## Called when a unit wants to open this door (e.g. from path scan or DoorSensor).
## Opens for same-faction units; emits `blocked` for opposing faction.
func reserve(unit: Node) -> void:
	if is_broken:
		return
	if _get_body_faction(unit) != int(owner_faction):
		blocked.emit(unit)
		return
	_close_timer.stop()
	if not is_open:
		_set_open(true)


## Kept for API compatibility — close timing is now handled by Area2D body_exited.
func unit_passed_through(_unit: Node) -> void:
	pass


## Kept for API compatibility — reservation tracking removed.
func release_reservation(_unit: Node) -> void:
	pass


func _on_close_timer_timeout() -> void:
	# Re-verify: only close if no friendly unit is still physically inside the area.
	for u in _units_in_area:
		if is_instance_valid(u) and _get_body_faction(u) == int(owner_faction):
			return  # a friendly is still present — stay open
	if is_open and not is_broken:
		_set_open(false)


# ---------------------------------------------------------------------------
# Area2D proximity handlers — faction-aware auto-open
# ---------------------------------------------------------------------------

func _on_area_body_entered(body: Node) -> void:
	if is_broken:
		return
	var body_faction := _get_body_faction(body)
	if body_faction == int(owner_faction):
		if not _units_in_area.has(body):
			_units_in_area.append(body)
		_close_timer.stop()
		if not is_open:
			_set_open(true)

func _on_area_body_exited(body: Node) -> void:
	if is_broken:
		return
	_units_in_area.erase(body)
	# Close only when the last friendly unit leaves the area.
	for u in _units_in_area:
		if is_instance_valid(u) and _get_body_faction(u) == int(owner_faction):
			return  # at least one friendly still inside — stay open
	if is_open and not is_broken:
		_close_timer.start()

## Extract the faction of any unit, supporting both owner_faction and team variables.
func _get_body_faction(body: Node) -> int:
	var of = body.get("owner_faction")
	if of != null:
		return int(of)
	var t = body.get("team")
	if t != null:
		return int(t)
	return -1


# ---------------------------------------------------------------------------
# Hover overlay — reuses room_border.gdshader, sized from Area2D/CollisionShape2D
# ---------------------------------------------------------------------------

func _setup_hover_overlay() -> void:
	var shape_node := $Area2D/CollisionShape2D
	if not (shape_node.shape is RectangleShape2D):
		return
	var door_size: Vector2 = (shape_node.shape as RectangleShape2D).size

	var overlay         := ColorRect.new()
	overlay.size         = door_size
	overlay.position     = shape_node.position - door_size * 0.5
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index      = 5

	var mat    := ShaderMaterial.new()
	mat.shader  = load(_BORDER_SHADER)
	overlay.material = mat
	_border_mat      = mat

	add_child(overlay)

func on_door_destroyed():
	if door_is_broken: return # Don't destroy it twice

	is_broken = true
	door_destroyed.emit(self)

	# 1. Change appearance (hide the door sprite, show a 'broken' one or sparks)
	# Assuming you have an AnimatedSprite2D or Sprite2D named 'sprite'
	$AnimatedSprite2D.modulate = Color(0.3, 0.3, 0.3, 1.0) # Make it dark/burnt

	# 2. Disable collisions so units can walk through
	# Assuming your door is an Area2D or StaticBody2D
	$CollisionShape2D.set_deferred("disabled", true)

	# 3. Notify the navigation system to bake a new path
	_rebake_ship_navigation() 

	# DO NOT CALL queue_free() anymore!

## Called by SelectionManager on every MouseMotion event.
func set_hovered(value: bool) -> void:
	if _border_mat == null:
		return
	if value:
		_border_mat.set_shader_parameter("is_active",    true)
		_border_mat.set_shader_parameter("border_color", _COLOR_HOVER)
		_border_mat.set_shader_parameter("intensity",    1.0)
	else:
		_border_mat.set_shader_parameter("is_active", false)

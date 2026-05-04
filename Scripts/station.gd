class_name Station
extends Area2D

## Emitted the moment occupancy changes.  unit is null when occupied = false.
signal manning_changed(occupied: bool, unit: Node2D)
## Emitted when the station becomes functional (true) or is destroyed (false).
signal functional_changed(functional: bool)

@export var system_name  : String  = "Station"
## Skill awarded to the occupying unit while they man this station.
@export var xp_skill     : String  = ""
## Must match TileSet tile size — used to size the highlight overlay.
@export var tile_size    : Vector2 = Vector2(32.0, 32.0)
## Maximum station health.
@export var max_health   : float   = 100.0
## 0 = PLAYER-owned station, 1 = ENEMY-owned station.
## Only units whose team matches owner_faction may man this station.
## Opposing-faction units that enter will be treated as saboteurs (ignored by
## the manning system; Enemy.gd / Unit.gd handle damage autonomously).
@export var owner_faction : int = 0

@onready var interaction_spot : Marker2D = $InteractionSpot

var health : float = 100.0   # shared interface — read directly as target.health
var is_functional  : bool  = true
var is_manned    : bool  = false
var occupant     : Node2D = null

## Derived from is_functional — true when health has been depleted.
var is_broken : bool:
	get: return not is_functional

# Health bar nodes (built at runtime)
var _health_bar_bg   : ColorRect = null
var _health_bar_fill : ColorRect = null

# Blue highlight overlay — built at runtime, no Inspector setup required.
var _highlight   : ColorRect = null
var _pulse_tween : Tween     = null

const _HB_WIDTH  : float = 20.0
const _HB_HEIGHT : float = 3.0
const _HB_Y_OFF  : float = -20.0


func _ready() -> void:
	add_to_group("stations")
	health = max_health
	# body_entered is intentionally NOT connected for manning.
	# Manning is driven exclusively by Unit._check_seat_proximity() so that
	# opposing-faction units walking through the Area2D can never accidentally
	# trigger a manning transition.
	body_exited.connect(_on_body_exited)
	input_event.connect(_on_input_event)
	_build_highlight()
	_build_health_bar()


func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		print("[Station] Selected: ", system_name)


# ── Health Bar ─────────────────────────────────────────────────────────────────

func _build_health_bar() -> void:
	_health_bar_bg             = ColorRect.new()
	_health_bar_bg.size        = Vector2(_HB_WIDTH, _HB_HEIGHT)
	_health_bar_bg.position    = Vector2(-_HB_WIDTH * 0.5, _HB_Y_OFF)
	_health_bar_bg.color       = Color(0.1, 0.1, 0.1, 0.85)
	_health_bar_bg.z_index     = 6
	_health_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_health_bar_bg)

	_health_bar_fill             = ColorRect.new()
	_health_bar_fill.size        = Vector2(_HB_WIDTH, _HB_HEIGHT)
	_health_bar_fill.position    = Vector2.ZERO
	_health_bar_fill.color       = Color(0.2, 0.9, 0.2, 1.0)
	_health_bar_fill.z_index     = 7
	_health_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_health_bar_bg.add_child(_health_bar_fill)
	_update_health_bar()


func _update_health_bar() -> void:
	if not is_instance_valid(_health_bar_bg) or not is_instance_valid(_health_bar_fill):
		return
	var pct := health / max_health
	_health_bar_bg.visible      = pct < 1.0
	_health_bar_fill.size.x     = _HB_WIDTH * pct
	if pct > 0.5:
		_health_bar_fill.color = Color(0.2, 0.9, 0.2, 1.0)   # green
	elif pct > 0.0:
		_health_bar_fill.color = Color(0.9, 0.5, 0.1, 1.0)   # orange
	else:
		_health_bar_fill.color = Color(0.6, 0.1, 0.1, 1.0)   # red


# ── Damage & Repair ────────────────────────────────────────────────────────────

func take_damage(amount: float) -> void:
	if not is_functional:
		return
	health = maxf(0.0, health - amount)
	_update_health_bar()
	if health <= 0.0:
		_destroy()


func repair(amount: float) -> void:
	if is_functional:
		return
	health = minf(max_health, health + amount)
	_update_health_bar()
	if health >= max_health:
		_restore()


## Called from Unit's REPAIRING enter block — marks the station as occupied so
## no second unit tries to also repair it.
func on_unit_repairing(unit: Node2D) -> void:
	if occupant != null:
		return
	# Hard faction gate — only same-faction units may repair this station.
	var unit_faction : int = int(unit.get("team") if unit.get("team") != null else -1)
	if unit_faction != int(owner_faction):
		return
	occupant  = unit
	is_manned = true
	_drive_shader(true)
	print("[Station] ", unit.name, " repairing ", system_name)


## Called when the repairing unit leaves without completing the repair.
func on_unit_stopped_repairing(unit: Node2D) -> void:
	if occupant == unit:
		occupant  = null
		is_manned = false
		_drive_shader(false)


func _destroy() -> void:
	is_functional = false
	# Evict current occupant so the unit can transition to REPAIRING.
	if is_manned and is_instance_valid(occupant):
		_vacate(occupant)
	# Grey out sprite to signal broken state.
	var spr := get_node_or_null("Sprite2D") as Sprite2D
	if spr:
		spr.modulate = Color(0.45, 0.45, 0.45, 1.0)
	functional_changed.emit(false)
	print("[Station] ", system_name, " destroyed!")


func _restore() -> void:
	is_functional  = true
	health = max_health
	_update_health_bar()
	var spr := get_node_or_null("Sprite2D") as Sprite2D
	if spr:
		spr.modulate = Color.WHITE
	functional_changed.emit(true)
	print("[Station] ", system_name, " restored!")


# ── highlight setup ────────────────────────────────────────────────────────────

func _build_highlight() -> void:
	_highlight              = ColorRect.new()
	_highlight.size         = tile_size
	_highlight.position     = -tile_size * 0.5
	_highlight.z_index      = 5
	_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat  := ShaderMaterial.new()
	mat.shader = preload("res://Scripts/station_highlight.gdshader")
	_highlight.material = mat
	add_child(_highlight)
	_drive_shader(false)


# ── body detection (Phase 1 of 2) ─────────────────────────────────────────────
#
# Phase 1 — body enters the station's Area2D.
#   We tell the unit to *watch* this station.  The unit checks its distance to
#   the InteractionSpot every physics frame and calls on_unit_seated() as soon
#   as it is within SEAT_SNAP_DIST pixels.  This prevents the unit from snapping
#   into STATION_ACTIVE before it has physically walked to the seat.
#
# Broken stations are also targetable so units can repair them.
# Phase 2 — unit reaches the seat → _check_seat_proximity() branches on
#           is_functional: functional → STATION_ACTIVE, broken → REPAIRING.

## body_entered manning removed — see _ready() comment.
## Retained as a no-op so callsites in external code don't break.
func _on_body_entered(_body: Node) -> void:
	pass


func _on_body_exited(body: Node) -> void:
	if not body.is_in_group("units"):
		return
	if body.has_method("clear_manning_target"):
		body.clear_manning_target(self)
	if body == occupant:
		_vacate(body as Node2D)


# ── Unit → Station callbacks ──────────────────────────────────────────────────

## Called by the Unit the frame it reaches the InteractionSpot (Phase 2).
## Allows re-entry from the same unit that was previously repairing.
func on_unit_seated(unit: Node2D) -> void:
	if not is_functional:
		return
	# Hard faction gate — opposing-faction units can never man this station.
	var unit_faction : int = int(unit.get("team") if unit.get("team") != null else -1)
	if unit_faction != int(owner_faction):
		return
	# Allow the unit that was repairing to transition to manning without re-check.
	if is_manned and occupant != unit:
		return
	occupant  = unit
	is_manned = true
	print("[Station] ", unit.name, " occupied ", system_name)
	apply_bonus()
	manning_changed.emit(true, unit)
	_drive_shader(true)


## Called immediately when the Unit leaves STATION_ACTIVE (before it walks away).
func on_unit_departing(unit: Node2D) -> void:
	if occupant != unit:
		return
	_vacate(unit)


# ── internal ──────────────────────────────────────────────────────────────────

func _vacate(unit: Node2D) -> void:
	if not is_manned:
		return
	occupant  = null
	is_manned = false
	remove_bonus()
	manning_changed.emit(false, unit)
	_drive_shader(false)


func _drive_shader(active: bool) -> void:
	if not is_instance_valid(_highlight):
		return
	var mat := _highlight.material as ShaderMaterial
	if mat == null:
		return

	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null

	mat.set_shader_parameter("is_active", active)

	if active:
		mat.set_shader_parameter("intensity", 1.0)
		_pulse_tween = create_tween().set_loops()
		var tw1 := _pulse_tween.tween_method(
			func(v: float) -> void: mat.set_shader_parameter("intensity", v),
			1.0, 0.55, 0.8)
		tw1.set_trans(Tween.TRANS_SINE)
		tw1.set_ease(Tween.EASE_IN_OUT)
		var tw2 := _pulse_tween.tween_method(
			func(v: float) -> void: mat.set_shader_parameter("intensity", v),
			0.55, 1.0, 0.8)
		tw2.set_trans(Tween.TRANS_SINE)
		tw2.set_ease(Tween.EASE_IN_OUT)
	else:
		mat.set_shader_parameter("intensity", 0.0)


# ── subclass API ──────────────────────────────────────────────────────────────
# Override these in PilotStation, ShieldStation, etc. to apply system bonuses.

func apply_bonus() -> void:
	pass

func remove_bonus() -> void:
	pass

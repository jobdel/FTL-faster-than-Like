extends CharacterBody2D

@export var speed: float = 100.0

var is_selected: bool = false:
	set(value):
		is_selected = value
		modulate = Color(0.4, 1.0, 0.4) if is_selected else Color.WHITE

var _path    : PackedVector2Array = []
var _path_idx: int = 0

const WAYPOINT_DIST := 4.0

@onready var _path_line: Line2D = $PathLine


func _ready() -> void:
	add_to_group("monk_pink")


func _physics_process(_delta: float) -> void:
	if _path_idx >= _path.size():
		velocity = Vector2.ZERO
		move_and_slide()
		_update_line()
		return

	var target    : Vector2 = _path[_path_idx]
	var to_target : Vector2 = target - global_position

	if to_target.length() < WAYPOINT_DIST:
		_path_idx += 1
		if _path_idx >= _path.size():
			global_position = target
			velocity        = Vector2.ZERO
			move_and_slide()
			_update_line()
			return

	velocity = to_target.normalized() * speed
	move_and_slide()
	_update_line()


func follow_path(path: PackedVector2Array) -> void:
	_path     = path
	_path_idx = 0
	_update_line()


# Rebuilds the Line2D each frame in local space so it follows the unit.
func _update_line() -> void:
	if _path_idx >= _path.size():
		_path_line.points = PackedVector2Array()
		return

	var pts := PackedVector2Array()
	pts.append(Vector2.ZERO)                          # unit's own origin
	for i in range(_path_idx, _path.size()):
		pts.append(to_local(_path[i]))                # remaining waypoints
	_path_line.points = pts

extends Node2D

var speed  : float = 500.0
var damage : float = 10.0
var shooter_team       # set by the unit that fires this bullet

@onready var _area : Area2D = $Area2D

func _ready() -> void:
	_area.body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	position += Vector2(speed * delta, 0.0).rotated(rotation)

func _on_body_entered(body: Node) -> void:
	if body.has_method("take_damage") and body.get("team") != shooter_team:
		body.take_damage(damage)
	queue_free()

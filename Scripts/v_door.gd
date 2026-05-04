extends Node2D

@onready var collision_wall = $StaticBody2D/CollisionShape2D
@onready var sprite = $Sprite2D # Or AnimatedSprite2D

var units_inside = 0

func _ready():
	# Connect signals from the Area2D
	$Area2D.body_entered.connect(_on_unit_entered)
	$Area2D.body_exited.connect(_on_unit_exited)

func _on_unit_entered(body):
	if body.is_in_group("units"): # Make sure your units are in a group
		units_inside += 1
		open_door()

func _on_unit_exited(body):
	if body.is_in_group("units"):
		units_inside -= 1
		if units_inside <= 0:
			close_door()

func open_door():
	# Disable the physics wall so the unit can pass
	collision_wall.set_deferred("disabled", true)
	# Make it disappear or play "open" animation
	sprite.modulate.a = 0.3 # Make it see-through
	# sprite.play("open") # If using AnimatedSprite

func close_door():
	collision_wall.set_deferred("disabled", false)
	sprite.modulate.a = 1.0 # Make it solid again

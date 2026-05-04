## WeaponHit.gd
## Plays the hit animation once then removes the effect from the scene.
## Root node (WeaponHit) manages lifetime; child AnimatedSprite2D owns the frames.
extends AnimatedSprite2D

var is_critical : bool = false

@onready var _sprite : AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	# Random rotation and slight scale variation for visual variety.
	_sprite.rotation = randf_range(0.0, TAU)
	scale *= randf_range(0.9, 1.1)

	_sprite.speed_scale = 24
	_sprite.play("Weapon hit")

	# Flash red three times when the target is below 25% health.
	if is_critical:
		var tw := create_tween().set_loops(3)
		tw.tween_property(_sprite, "modulate", Color(1.0, 0.1, 0.1, 1.0), 0.08)
		tw.tween_property(_sprite, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.08)

	var frames : int   = _sprite.sprite_frames.get_frame_count("Weapon hit")
	var fps    : float = _sprite.sprite_frames.get_animation_speed("Weapon hit")
	get_tree().create_timer(frames / (fps * _sprite.speed_scale)).timeout.connect(queue_free)

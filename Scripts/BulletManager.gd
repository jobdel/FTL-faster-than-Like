## BulletManager.gd  –  Autoload singleton
##
## Owns a fixed pool of Line2D visuals that are reused every shot.
## No bullet nodes are ever created or destroyed at runtime — only reset.
##
## Usage (from any node inside the SubViewport world):
##   BulletManager.fire(self, target_node, team, damage,
##                       get_world_2d().direct_space_state)
extends Node

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
const POOL_SIZE    : int   = 100
const BULLET_COLOR : Color = Color(1.0, 0.75, 0.1, 1.0)   # FTL orange-yellow
const BULLET_WIDTH : float = 2.0
const TRAVEL_TIME  : float = 0.07   # seconds for bolt to cross the room

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _hit_effect : PackedScene  = null
var _layer      : Node2D       = null
var _pool       : Array[Line2D] = []


## Called by BulletsLayer._ready() once the SubViewport world is ready.
func setup(layer: Node2D) -> void:
	_layer      = layer
	_hit_effect = load("res://Scenes/weapon_hit.tscn")
	for i in POOL_SIZE:
		var line := Line2D.new()
		line.width         = BULLET_WIDTH
		line.default_color = BULLET_COLOR
		line.visible       = false
		line.z_index       = 20
		_layer.add_child(line)
		_pool.append(line)


## Fire a hitscan shot.
## space_state must come from get_world_2d().direct_space_state on the caller,
## which guarantees we query the SubViewport's physics world.
func fire(
		shooter      : Node2D,
		target       : Node2D,
		shooter_team,
		damage       : float,
		space_state  : PhysicsDirectSpaceState2D
) -> void:
	if _layer == null or space_state == null:
		return

	var from : Vector2 = shooter.global_position
	var to   : Vector2 = target.global_position

	# --- Hit detection ---
	var query := PhysicsRayQueryParameters2D.create(from, to)
	query.exclude        = [shooter.get_rid()]
	query.collision_mask = 1   # layer 1 covers both units and walls

	var result    := space_state.intersect_ray(query)
	var hit_point : Vector2 = to
	var hp_pct    : float   = 1.0

	if result:
		hit_point = result.position
		var body = result.collider
		if body.has_method("take_damage") and body.get("team") != shooter_team:
			body.take_damage(damage)
			if body.get("stats") != null:
				hp_pct = body.stats.health_percent()

	# --- Visual ---
	_spawn_hit_effect(hit_point, hp_pct)
	_show_bolt(from, hit_point)


# ---------------------------------------------------------------------------
# Private
# ---------------------------------------------------------------------------

## Animate a pooled Line2D as a short traveling bolt.
## Both points start at `from`; the leading edge travels to `to`, then the
## trailing edge follows — creating a moving segment without any physics body.
func _show_bolt(from: Vector2, to: Vector2) -> void:
	var line := _get_free()
	if line == null:
		return   # pool exhausted — raise POOL_SIZE if this fires often

	line.clear_points()
	line.add_point(from)
	line.add_point(from)
	line.modulate.a = 1.0
	line.visible    = true

	var tw := create_tween()
	# Leading edge advances to hit point
	tw.tween_method(
		func(p: Vector2): line.set_point_position(1, p),
		from, to, TRAVEL_TIME
	)
	# Trailing edge catches up (bolt passes)
	tw.tween_method(
		func(p: Vector2): line.set_point_position(0, p),
		from, to, TRAVEL_TIME
	)
	tw.tween_callback(func(): line.visible = false)


func _spawn_hit_effect(world_pos: Vector2, health_percent: float) -> void:
	if _layer == null or _hit_effect == null:
		return
	var fx : AnimatedSprite2D = _hit_effect.instantiate()
	fx.is_critical = health_percent < 0.25
	_layer.add_child(fx)
	fx.global_position = world_pos


func _get_free() -> Line2D:
	for line in _pool:
		if not line.visible:
			return line
	return null

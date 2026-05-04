## WallManager.gd
## Node2D that draws visual walls on every boundary between adjacent rooms
## that has no door.  Created and populated by NavigationManager._finalize_walls()
## at startup — no manual scene placement required.
##
## Coordinate note: _draw() uses LOCAL space.  Because this node is added as a
## child of the ship root at (0,0) identity, local == parent-local.  A* stores
## GLOBAL positions, so each position is converted with to_local() before use.
extends Node2D

## Colour of wall boundary lines.
const WALL_COLOR := Color(0.15, 0.15, 0.18, 1.0)
## Thickness in pixels.
const WALL_WIDTH := 4.0
## Half of a 32 px tile — controls how far the wall line extends from the midpoint.
const HALF_TILE  := 16.0

## Each entry is [pos_a: Vector2, pos_b: Vector2] in world space.
var _segments : Array = []


func _ready() -> void:
	add_to_group("wall_manager")
	z_index = 4
	# Consume pending segments if NavigationManager stored them before this
	# node entered the scene tree.
	if has_meta("_pending_segments"):
		set_wall_segments(get_meta("_pending_segments"))
		remove_meta("_pending_segments")


## Called by NavigationManager with the finalized list of wall tile pairs.
func set_wall_segments(segs: Array) -> void:
	_segments = segs
	queue_redraw()


func _draw() -> void:
	for pair in _segments:
		var pos_a : Vector2 = pair[0]
		var pos_b : Vector2 = pair[1]
		# Convert global A* positions to this node's local draw space.
		var la    : Vector2 = to_local(pos_a)
		var lb    : Vector2 = to_local(pos_b)
		var mid   : Vector2 = (la + lb) * 0.5
		var dir   : Vector2 = (lb - la).normalized()
		# Perpendicular to the adjacency direction — this spans the tile edge.
		var perp  : Vector2 = Vector2(-dir.y, dir.x)
		draw_line(
			mid + perp * HALF_TILE,
			mid - perp * HALF_TILE,
			WALL_COLOR,
			WALL_WIDTH,
			true   # antialiased
		)

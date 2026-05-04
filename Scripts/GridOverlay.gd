## GridOverlay.gd — attach to a Node2D placed after floor tiles in the scene tree.
##
## Draws a 32×32 grid over the area where floor tiles exist.
## Set z_index on the node itself to control draw order (e.g. 1 = above floor, below units).
extends Node2D

@export var show_grid: bool = true:
	set(value):
		show_grid = value
		queue_redraw()

@export var tile_map_layer: TileMapLayer

const GRID_SIZE   := 32
const LINE_COLOR  := Color(0.2, 0.2, 0.4, 0.5)
const LINE_WIDTH  := 1.0


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	if not show_grid or tile_map_layer == null:
		return

	# get_used_rect() is in tile coords; multiply by GRID_SIZE for pixel coords.
	var used: Rect2i = tile_map_layer.get_used_rect()
	if used.size == Vector2i.ZERO:
		return

	var origin := Vector2(used.position) * GRID_SIZE
	var size   := Vector2(used.size)   * GRID_SIZE

	# Vertical lines
	var x := origin.x
	while x <= origin.x + size.x:
		draw_line(Vector2(x, origin.y), Vector2(x, origin.y + size.y), LINE_COLOR, LINE_WIDTH)
		x += GRID_SIZE

	# Horizontal lines
	var y := origin.y
	while y <= origin.y + size.y:
		draw_line(Vector2(origin.x, y), Vector2(origin.x + size.x, y), LINE_COLOR, LINE_WIDTH)
		y += GRID_SIZE

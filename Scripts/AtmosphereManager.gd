## AtmosphereManager.gd
## Simulates fire spreading and oxygen drain across all rooms each tick.
## Add one instance to your ship scene. Set tick_interval in the Inspector.
class_name AtmosphereManager
extends Node

const FIRE_SPREAD_CHANCE    := 0.10
const OXYGEN_DRAIN_PER_FIRE := 0.5

const _ADJACENT_DIRS: Array[Vector2i] = [
	Vector2i( 1,  0),
	Vector2i(-1,  0),
	Vector2i( 0,  1),
	Vector2i( 0, -1),
]

@export var tick_interval: float = 1.0

var _timer: Timer


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = tick_interval
	_timer.autostart = true
	_timer.timeout.connect(_on_tick)
	add_child(_timer)


func _on_tick() -> void:
	for room in get_tree().get_nodes_in_group("rooms"):
		var data: RoomData = room.get("room_data")
		if data == null:
			continue
		_tick_fire(room, data)
	_tick_doors()


## Spreads active fires and drains oxygen for one room on one tick.
## New fires are collected into a buffer first so mid-tick positions
## cannot cascade within the same tick.
func _tick_fire(room: Node, data: RoomData) -> void:
	var new_fires: Array[Vector2i] = []

	for fire_pos: Vector2i in data.fires:
		for dir: Vector2i in _ADJACENT_DIRS:
			var neighbor: Vector2i = fire_pos + dir
			if neighbor not in data.tiles:
				continue
			if neighbor in data.fires or neighbor in new_fires:
				continue
			if randf() < FIRE_SPREAD_CHANCE:
				new_fires.append(neighbor)

	for pos: Vector2i in new_fires:
		data.fires.append(pos)
		var index: int = _grid_pos_to_index(room, pos)
		if index >= 0:
			room.start_fire(index)

	data.oxygen = maxf(0.0, data.oxygen - data.fires.size() * OXYGEN_DRAIN_PER_FIRE)


## For every open door, finds the two rooms on either side and equalizes oxygen.
## Uses four cardinal probe points (half a tile out) to detect adjacent rooms,
## so it works for both horizontal and vertical door orientations automatically.
func _tick_doors() -> void:
	var rooms := get_tree().get_nodes_in_group("rooms")
	for door in get_tree().get_nodes_in_group("doors"):
		if not door.get("is_open"):
			continue
		var adjacent := _find_rooms_adjacent_to_door(door, rooms)
		if adjacent.size() != 2:
			continue
		var data_a: RoomData = adjacent[0].get("room_data")
		var data_b: RoomData = adjacent[1].get("room_data")
		if data_a == null or data_b == null:
			continue
		var avg := (data_a.oxygen + data_b.oxygen) * 0.5
		data_a.oxygen = avg
		data_b.oxygen = avg


## Probes four cardinal directions from the door's world position and returns
## the unique room nodes whose rects contain each probe point.
## Probe distance is 32 px — half a standard 64 px tile.
func _find_rooms_adjacent_to_door(door: Node, rooms: Array) -> Array:
	const PROBE_DIST := 32.0
	var door_pos: Vector2 = door.get("global_position")
	var probes := [
		door_pos + Vector2( PROBE_DIST,  0.0),
		door_pos + Vector2(-PROBE_DIST,  0.0),
		door_pos + Vector2( 0.0,  PROBE_DIST),
		door_pos + Vector2( 0.0, -PROBE_DIST),
	]
	var found: Array = []
	for probe in probes:
		for room in rooms:
			if room in found:
				continue
			var rect: Rect2 = (room as Control).get_global_rect()
			if rect.has_point(probe):
				found.append(room)
				break
	return found


## Converts a Vector2i grid coordinate to the room's GridContainer child index.
func _grid_pos_to_index(room: Node, pos: Vector2i) -> int:
	var grid: GridContainer = room.get_node_or_null("GridContainer")
	if grid == null:
		return -1
	return pos.y * grid.columns + pos.x

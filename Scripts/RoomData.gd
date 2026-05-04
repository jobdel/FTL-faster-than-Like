## RoomData.gd
## Resource holding per-room tile layout and runtime atmosphere state.
class_name RoomData
extends Resource

## Grid coordinates (col, row) of every valid tile in this room.
var tiles: Array[Vector2i] = []

## Grid coordinates of tiles currently on fire.
var fires: Array[Vector2i] = []

## Current oxygen level (0–100).
var oxygen: float = 100.0

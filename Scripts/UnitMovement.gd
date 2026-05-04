extends CharacterBody2D

const TILE_SIZE := 32
const STATION_OFFSET := Vector2(0, 6)  # nudge unit slightly above console center

@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D

# --- NavigationAgent2D settings (also set these in the Inspector) ---
# path_desired_distance      = 4.0
# target_desired_distance    = 6.0
# agent_radius               = 10.0  (< half a tile so corners are passable)
# neighbor_distance          = 50.0
# max_neighbors              = 10
# avoidance_enabled          = true

func _ready() -> void:
	nav_agent.path_desired_distance = 4.0
	nav_agent.target_desired_distance = 6.0

	# 7.0 = half the unit's 14 px visual width.
	# The NavigationServer erodes the navmesh inward by this amount on each wall.
	# With 12 px wall art and a 32 px tile, the clear gap in a 1-tile hallway is
	# 32 - 12 - 12 = 8 px after physics trimming, but the NavigationRegion covers
	# the full floor tile (32 px).  Erosion = 7 + 7 = 14 px < 32 px, so a valid
	# 18 px-wide path remains.  The old radius of 10 eroded 20 px, which swallowed
	# narrow corridor polygons entirely and returned no path.
	nav_agent.radius = 7.0

	nav_agent.neighbor_distance = 50.0
	nav_agent.max_neighbors = 10
	nav_agent.avoidance_enabled = true

	# PATH SMOOTHING — prevents the agent from hugging wall corners.
	# CORRIDORFUNNEL pulls waypoints toward the centre of each corridor opening,
	# producing straighter lines instead of a wall-skimming zigzag.
	nav_agent.path_postprocessing = NavigationPathQueryParameters2D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	# Remove collinear waypoints whose deviation from the straight line is under
	# this many pixels — reduces tick-tock jitter on long straight corridors.
	nav_agent.simplify_path    = true
	nav_agent.simplify_epsilon = 2.0

	nav_agent.velocity_computed.connect(_on_velocity_computed)


# ── Target Snapping ────────────────────────────────────────────────────────────

## Snaps a world-space click position to the nearest tile center.
## Pass is_station=true when the click hits a Station/console object so the
## unit stops just in front of it instead of trying to walk into the object.
func get_snapped_target(click_pos: Vector2, is_station: bool = false) -> Vector2:
	# Snap to tile center
	var snapped := Vector2(
		floor(click_pos.x / TILE_SIZE) * TILE_SIZE + TILE_SIZE * 0.5,
		floor(click_pos.y / TILE_SIZE) * TILE_SIZE + TILE_SIZE * 0.5
	)
	if is_station:
		snapped += STATION_OFFSET
	return snapped


# ── Movement ───────────────────────────────────────────────────────────────────

func move_to(world_pos: Vector2, is_station: bool = false) -> void:
	nav_agent.target_position = get_snapped_target(world_pos, is_station)


func _physics_process(_delta: float) -> void:
	if nav_agent.is_navigation_finished():
		return

	var next_pos: Vector2 = nav_agent.get_next_path_position()
	var desired_vel: Vector2 = (next_pos - global_position).normalized() * 80.0
	# Feed into avoidance; _on_velocity_computed will apply the result
	nav_agent.set_velocity(desired_vel)


func _on_velocity_computed(safe_velocity: Vector2) -> void:
	velocity = safe_velocity
	move_and_slide()

## ship_ui.gd  —  attach to HUDPanel inside ship_ui.tscn.
##
## Everything is painted with _draw() — no external textures required.
## Colors are hand-picked from FTL's actual UI palette.
## The script finds the ship node via the "ship" group on the first frame.
extends Control

# =============================================================================
# FTL COLOUR PALETTE
# =============================================================================

const C_BG          := Color(0.047, 0.075, 0.133)   # #0C1322  panel fill
const C_BORDER      := Color(0.173, 0.310, 0.545)   # #2C4F8B  top accent line
const C_DIVIDER     := Color(0.086, 0.153, 0.275)   # #162737  section dividers
const C_PANEL_EDGE  := Color(0.098, 0.176, 0.318)   # #192D51  inner glow under border

const C_TEXT        := Color(0.698, 0.808, 0.945)   # #B2CEF1  bright labels
const C_TEXT_DIM    := Color(0.345, 0.435, 0.565)   # #586F90  dimmed sub-labels
const C_TEXT_SYS    := Color(0.475, 0.635, 0.839)   # #79A2D6  system name labels

# Power boxes — on / off per system
const C_SHLD_ON     := Color(0.196, 0.549, 0.949)   # #3280E8  shields on
const C_SHLD_OFF    := Color(0.059, 0.110, 0.216)   # #0F1C37  shields off
const C_ENG_ON      := Color(0.898, 0.616, 0.075)   # #E59D13  engines on
const C_ENG_OFF     := Color(0.173, 0.114, 0.016)   # #2C1D04  engines off
const C_OXY_ON      := Color(0.149, 0.718, 0.478)   # #26B77A  oxygen on
const C_OXY_OFF     := Color(0.035, 0.169, 0.110)   # #092B1C  oxygen off
const C_WPN_ON      := Color(0.949, 0.345, 0.118)   # #F2581E  weapons on
const C_WPN_OFF     := Color(0.235, 0.082, 0.027)   # #3C1507  weapons off

# Shield bubbles
const C_SHLD_FILL   := Color(0.196, 0.549, 0.949)   # bubble fill (same as box)
const C_SHLD_RING   := Color(0.176, 0.373, 0.671)   # bubble ring
const C_SHLD_BG     := Color(0.051, 0.098, 0.196)   # bubble empty background

# Hull segments
const C_HULL_ON     := Color(0.780, 0.176, 0.110)   # #C72D1C  segment alive
const C_HULL_HILIT  := Color(0.878, 0.278, 0.176)   # #E0472D  top highlight stripe
const C_HULL_SHADE  := Color(0.000, 0.000, 0.000)   # shadow stripe (alpha applied)
const C_HULL_OFF    := Color(0.188, 0.055, 0.043)   # #30100B  segment dead

# Crew
const C_CREW_HP     := Color(0.267, 0.741, 0.384)   # #44BD62  healthy (green)
const C_CREW_MED    := Color(0.898, 0.780, 0.118)   # #E5C71E  wounded (yellow)
const C_CREW_LOW    := Color(0.878, 0.318, 0.055)   # #E0510E  critical (red-orange)
const C_CREW_BG     := Color(0.051, 0.071, 0.122)   # bar background

# =============================================================================
# LAYOUT  (all units in pixels, tuned for 1920×1080)
# =============================================================================

const PANEL_H       := 152.0

# Section widths (proportional of total width, computed in _draw)
const SEC1_FRAC     := 0.215   # systems section ends at this fraction
const SEC2_FRAC     := 0.855   # crew section starts at this fraction

const SECT_PAD      := 14.0   # horizontal padding inside each section
const TITLE_Y       := 14.0   # y of section title text baseline
const ROW_Y0        := 26.0   # y of first data row
const ROW_H         := 28.0   # vertical spacing between system rows

# System name column
const SYS_LBL_W    := 72.0

# Power boxes
const BOX_W         := 11.0
const BOX_H         := 18.0
const BOX_GAP       := 2.0
const N_BOXES       := 8

# Shield bubbles
const SHLD_R        := 12.0
const SHLD_GAP      := 8.0

# Hull segments
const H_SEG_W       := 13.0
const H_SEG_H       := 16.0
const H_SEG_GAP     := 2.0
const H_SEGS        := 30     # max hull displayed as individual blocks

# Crew bars
const CREW_LBL_W    := 66.0
const CREW_BAR_W    := 52.0
const CREW_BAR_H    := 13.0
const CREW_ROW_H    := 18.0

# =============================================================================
# RUNTIME STATE
# =============================================================================

var _ship       : Node  = null
var _hull_cur   : int   = 30
var _hull_max   : int   = 30
var _shld_cur   : float = 2.0
var _shld_max   : int   = 2
var _engine     : float = 0.5
var _oxygen     : float = 1.0
var _weapons    : int   = 0

## Live crew tracking — player units only, updated via signals.
var _crew_units       : Array      = []   # Array of Unit nodes
var _crew_hp          : Dictionary = {}   # instance_id → hp_pct float
var _selected_unit_id : int        = -1   # instance_id of the currently selected unit


func _ready() -> void:
	_connect_ship()


func _connect_ship() -> void:
	# Wait one physics frame so all nodes (including ship.gd) have run _ready().
	await get_tree().process_frame

	var ships := get_tree().get_nodes_in_group("ship")
	if ships.is_empty():
		push_warning("ShipUI: no node found in group 'ship'.")
		return
	_ship = ships[0]
	_pull_all()

	# Connect signals so we only redraw when values actually change.
	if _ship.has_signal("hull_changed"):
		_ship.hull_changed.connect(
			func(c: int, m: int) -> void: _hull_cur = c; _hull_max = m; queue_redraw())
	if _ship.has_signal("shields_changed"):
		_ship.shields_changed.connect(
			func(c: float, m: int) -> void: _shld_cur = c; _shld_max = m; queue_redraw())
	if _ship.has_signal("engine_changed"):
		_ship.engine_changed.connect(func(v: float) -> void: _engine = v; queue_redraw())
	if _ship.has_signal("oxygen_changed"):
		_ship.oxygen_changed.connect(func(v: float) -> void: _oxygen = v; queue_redraw())


func _pull_all() -> void:
	if not is_instance_valid(_ship):
		return
	_hull_cur  = _ship.hull_current
	_hull_max  = _ship.hull_max
	_shld_cur  = _ship.shields_current
	_shld_max  = _ship.shields_max
	_engine    = _ship.engine
	_oxygen    = _ship.oxygen
	_weapons   = _ship.weapons_power
	refresh_crew_list()


## Rebuilds the crew list from all nodes in 'player_units', ignoring 'enemies'.
## Call this whenever units are added or when the HUD is first connected.
func refresh_crew_list() -> void:
	# Disconnect existing signals so we don't leak listeners.
	for unit in _crew_units:
		if not is_instance_valid(unit):
			continue
		if unit.health_changed.is_connected(_on_unit_health_changed):
			unit.health_changed.disconnect(_on_unit_health_changed)
		if unit.tree_exiting.is_connected(_on_unit_died):
			unit.tree_exiting.disconnect(_on_unit_died)

	_crew_units.clear()
	_crew_hp.clear()

	var enemy_ids := {}
	for e in get_tree().get_nodes_in_group("enemies"):
		enemy_ids[e.get_instance_id()] = true

	for unit in get_tree().get_nodes_in_group("player_units"):
		if enemy_ids.has(unit.get_instance_id()):
			continue
		var id := unit.get_instance_id()
		var s  = unit.get("stats")
		_crew_hp[id] = (s.health_percent() as float) if s else 1.0
		unit.health_changed.connect(_on_unit_health_changed.bind(unit))
		unit.tree_exiting.connect(_on_unit_died.bind(unit))
		_crew_units.append(unit)

	queue_redraw()


func _on_unit_health_changed(hp_pct: float, unit: Node) -> void:
	_crew_hp[unit.get_instance_id()] = hp_pct
	queue_redraw()


func _on_unit_died(unit: Node) -> void:
	_crew_units.erase(unit)
	_crew_hp.erase(unit.get_instance_id())
	queue_redraw()


func _process(_delta: float) -> void:
	# Shield charge is a continuous float — poll it every frame.
	if is_instance_valid(_ship):
		var sc : float = _ship.shields_current
		if abs(sc - _shld_cur) > 0.004:
			_shld_cur = sc
			queue_redraw()

	# Detect crew selection changes so the highlight updates immediately.
	var new_selected_id := -1
	for unit in _crew_units:
		if is_instance_valid(unit) and unit.get("is_selected") == true:
			new_selected_id = unit.get_instance_id()
			break
	if new_selected_id != _selected_unit_id:
		_selected_unit_id = new_selected_id
		queue_redraw()


# =============================================================================
# DRAWING
# =============================================================================

func _draw() -> void:
	if size.x < 10.0 or size.y < 10.0:
		return
	var W := size.x
	var H := size.y
	var sec1 := W * SEC1_FRAC
	var sec2 := W * SEC2_FRAC

	_draw_panel(W, H, sec1, sec2)
	_draw_systems(H, sec1)
	_draw_center(H, sec1, sec2)
	_draw_crew(H, sec2, W)


# ── Panel background ──────────────────────────────────────────────────────────

func _draw_panel(W: float, H: float, sec1: float, sec2: float) -> void:
	# Base fill.
	draw_rect(Rect2(0.0, 0.0, W, H), C_BG)

	# Top accent line — the bright 2-pixel stripe that makes the panel look
	# like a physical console lifted off the floor.
	draw_rect(Rect2(0.0, 0.0, W, 2.0), C_BORDER)
	# Soft glow just below.
	draw_rect(Rect2(0.0, 2.0, W, 1.0), C_PANEL_EDGE)

	# Scanline texture — every other 2-pixel band is subtly darker.
	var y := 4.0
	while y < H:
		draw_rect(Rect2(0.0, y, W, 1.0), Color(0.0, 0.0, 0.0, 0.045))
		y += 4.0

	# Section dividers — thin vertical rules between systems / hull / crew.
	_vline(sec1, H)
	_vline(sec2, H)


func _vline(x: float, H: float) -> void:
	draw_rect(Rect2(x, 6.0, 1.0, H - 12.0), C_DIVIDER)


# ── Left section: Ship systems ────────────────────────────────────────────────

func _draw_systems(H: float, sec1: float) -> void:
	var x := SECT_PAD
	_section_title(x, "SHIP SYSTEMS")

	# Each row: [label, box-on-color, box-off-color, filled-count]
	var rows : Array = [
		["SHIELDS",
		 C_SHLD_ON, C_SHLD_OFF,
		 int(round((_shld_cur / float(maxi(_shld_max, 1))) * N_BOXES))],
		["ENGINES",
		 C_ENG_ON,  C_ENG_OFF,
		 int(round(_engine * N_BOXES))],
		["OXYGEN",
		 C_OXY_ON,  C_OXY_OFF,
		 int(round(_oxygen * N_BOXES))],
		["WEAPONS",
		 C_WPN_ON,  C_WPN_OFF,
		 _weapons],
	]

	for i in rows.size():
		var r  : Array = rows[i]
		var ry : float = ROW_Y0 + i * ROW_H
		_system_row(x, ry, r[0] as String,
				r[1] as Color, r[2] as Color, r[3] as int)


func _system_row(x: float, y: float, lbl: String,
		col_on: Color, col_off: Color, filled: int) -> void:
	var fnt := ThemeDB.fallback_font

	# System name.
	draw_string(fnt, Vector2(x, y + BOX_H * 0.73),
			lbl, HORIZONTAL_ALIGNMENT_LEFT, SYS_LBL_W, 11, C_TEXT_SYS)

	# Power boxes — drawn to the right of the label.
	var bx := x + SYS_LBL_W
	for i in N_BOXES:
		var on  : bool  = i < filled
		var col : Color = col_on if on else col_off
		var r   := Rect2(bx + i * (BOX_W + BOX_GAP), y + 1.0, BOX_W, BOX_H - 2.0)

		draw_rect(r, col)

		if on:
			# Top highlight — gives the "glowing block" look.
			draw_rect(Rect2(r.position.x, r.position.y,
					BOX_W, 3.0), Color(1.0, 1.0, 1.0, 0.28))
			# Bottom shadow strip.
			draw_rect(Rect2(r.position.x, r.end.y - 2.0,
					BOX_W, 2.0), Color(0.0, 0.0, 0.0, 0.50))
		else:
			# Hair-thin dark border on dark boxes so they read as distinct units.
			draw_rect(r, Color(0.0, 0.0, 0.0, 0.45), false, 1.0)


# ── Centre section: Shields + Hull integrity ──────────────────────────────────

func _draw_center(H: float, sec1: float, sec2: float) -> void:
	var x  := sec1 + SECT_PAD
	var aw := sec2 - sec1 - SECT_PAD * 2.0   # available width

	# ── Shields (upper half) ──────────────────────────────────────────────────
	_section_title(x, "SHIELDS")
	_draw_shields(x, ROW_Y0, aw)

	# ── Hull integrity (lower half) ───────────────────────────────────────────
	var hull_y := H * 0.52
	draw_string(ThemeDB.fallback_font,
			Vector2(x, hull_y),
			"HULL INTEGRITY", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, C_TEXT_DIM)
	_draw_hull(x, hull_y + 10.0, aw)


func _draw_shields(x: float, y: float, aw: float) -> void:
	var total     : int   = maxi(_shld_max, 1)
	var diam      : float = SHLD_R * 2.0
	var row_w     : float = total * diam + (total - 1) * SHLD_GAP
	# Centre the bubble row within the section.
	var bx        : float = x + (aw - row_w) * 0.5

	for i in total:
		var cx : float = bx + i * (diam + SHLD_GAP) + SHLD_R
		var cy : float = y + SHLD_R + 2.0

		var charge : float = clampf(_shld_cur - float(i), 0.0, 1.0)

		# Background (empty) circle.
		draw_circle(Vector2(cx, cy), SHLD_R, C_SHLD_BG)

		# Fill circle — alpha proportional to charge so partially-filled bubbles
		# look like a translucent energy field building up.
		if charge > 0.005:
			var fill_a := lerpf(0.30, 1.0, charge)   # partial = dim, full = bright
			draw_circle(Vector2(cx, cy), SHLD_R - 1.0,
					Color(C_SHLD_FILL.r, C_SHLD_FILL.g, C_SHLD_FILL.b, fill_a))
			# Specular highlight on full / near-full bubbles.
			if charge > 0.70:
				var hilit_a := (charge - 0.70) / 0.30 * 0.28
				draw_circle(Vector2(cx - SHLD_R * 0.28, cy - SHLD_R * 0.28),
						SHLD_R * 0.32, Color(1.0, 1.0, 1.0, hilit_a))

		# Outer ring — always visible so empty bubbles still read as "slots".
		draw_arc(Vector2(cx, cy), SHLD_R, 0.0, TAU, 48, C_SHLD_RING, 1.5)

	# Charge count centred below the bubbles.
	draw_string(ThemeDB.fallback_font,
			Vector2(x, y + diam + 16.0),
			"%.0f / %d" % [_shld_cur, _shld_max],
			HORIZONTAL_ALIGNMENT_CENTER, aw, 9, C_TEXT_DIM)


func _draw_hull(x: float, y: float, _aw: float) -> void:
	# Current / max counter above the segments.
	draw_string(ThemeDB.fallback_font,
			Vector2(x, y),
			"%d / %d" % [_hull_cur, _hull_max],
			HORIZONTAL_ALIGNMENT_LEFT, _aw, 9, C_TEXT_DIM)

	var seg_y := y + 8.0
	for i in _hull_max:
		var alive : bool  = i < _hull_cur
		var col   : Color = C_HULL_ON if alive else C_HULL_OFF
		var r     := Rect2(x + i * (H_SEG_W + H_SEG_GAP), seg_y, H_SEG_W, H_SEG_H)

		draw_rect(r, col)

		if alive:
			# Bright top stripe — FTL's segments have a distinct highlight edge.
			draw_rect(Rect2(r.position.x, r.position.y, H_SEG_W, 3.0),
					Color(C_HULL_HILIT.r, C_HULL_HILIT.g, C_HULL_HILIT.b, 0.85))
			# Dark bottom shadow.
			draw_rect(Rect2(r.position.x, r.end.y - 2.0, H_SEG_W, 2.0),
					Color(0.0, 0.0, 0.0, 0.55))
		else:
			# Dead segments: faint border so they still read as "missing" slots.
			draw_rect(r, Color(0.0, 0.0, 0.0, 0.35), false, 1.0)


# ── Right section: Crew status ────────────────────────────────────────────────

func _draw_crew(H: float, sec2: float, W: float) -> void:
	var x  := sec2 + SECT_PAD
	_section_title(x, "CREW")

	var row := 0
	for unit in _crew_units:
		if not is_instance_valid(unit):
			continue
		var id  : int = unit.get_instance_id()
		var hp  : float = _crew_hp.get(id, 1.0)
		var sel : bool  = (id == _selected_unit_id)
		_crew_row(x, ROW_Y0 + row * CREW_ROW_H, unit.name, hp, sel)
		row += 1


func _crew_row(x: float, y: float, unit_name: String, hp: float, is_sel: bool) -> void:
	var fnt := ThemeDB.fallback_font

	# Selection highlight — drawn first so the bar renders on top.
	if is_sel:
		var total_w := CREW_LBL_W + CREW_BAR_W
		draw_rect(Rect2(x - 2.0, y - 2.0, total_w + 4.0, CREW_BAR_H + 4.0),
				Color(1.0, 1.0, 1.0, 0.55), false, 1.5)

	# Name label (truncated to fit).
	draw_string(fnt, Vector2(x, y + CREW_BAR_H * 0.82),
			unit_name.left(9), HORIZONTAL_ALIGNMENT_LEFT,
			CREW_LBL_W, 9, C_TEXT_SYS)

	# HP bar.
	var bx := x + CREW_LBL_W
	draw_rect(Rect2(bx, y, CREW_BAR_W, CREW_BAR_H), C_CREW_BG)

	if hp > 0.0:
		# Green → Yellow → Red based on health percentage (mirrors FTL thresholds).
		var fill_col : Color
		if hp > 0.6:
			fill_col = C_CREW_HP
		elif hp > 0.35:
			fill_col = C_CREW_MED
		else:
			fill_col = C_CREW_LOW
		draw_rect(Rect2(bx, y, CREW_BAR_W * hp, CREW_BAR_H), fill_col)
		# Top highlight.
		draw_rect(Rect2(bx, y, CREW_BAR_W * hp, 2.0), Color(1.0, 1.0, 1.0, 0.22))

	# Bar border.
	draw_rect(Rect2(bx, y, CREW_BAR_W, CREW_BAR_H), C_DIVIDER, false, 1.0)


# ── Utility ───────────────────────────────────────────────────────────────────

func _section_title(x: float, text: String) -> void:
	draw_string(ThemeDB.fallback_font,
			Vector2(x, TITLE_Y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, C_TEXT_DIM)

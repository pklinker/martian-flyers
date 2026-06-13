class_name SSDPanel
extends Control
## Ship System Display: renders any ShipState as a Star Fleet Battles-style
## damage sheet. Fully data-driven from ShipDef — new ship classes get a
## working SSD for free. Connects to the ship's signals and redraws live;
## contains zero rules logic (it only ever *asks* the ShipState).

const PANEL_W := 420.0
const BOX := 14.0
const GAP := 3.0
const ROW_H := 24.0
const MARGIN := 14.0

const PAPER := Color(0.95, 0.93, 0.86)
const INK := Color(0.13, 0.11, 0.09)
const FAINT := Color(0.13, 0.11, 0.09, 0.35)
const PENCIL := Color(0.42, 0.40, 0.38)        # shading on destroyed boxes
const DAMAGE_X := Color(0.62, 0.13, 0.10)
const FLASH := Color(0.85, 0.25, 0.15)
const GOOD := Color(0.18, 0.45, 0.20)

const FACING_LABELS := ["BOW", "FWD STBD", "AFT STBD", "STERN", "AFT PORT", "FWD PORT"]

const SYSTEM_ORDER: Array = [
	ShipDef.SystemType.BUOYANCY,
	ShipDef.SystemType.ENGINE,
	ShipDef.SystemType.PROPELLER,
	ShipDef.SystemType.RUDDER,
	ShipDef.SystemType.BRIDGE,
	ShipDef.SystemType.CREW,
	ShipDef.SystemType.MAGAZINE,
	ShipDef.SystemType.DAMAGE_CONTROL,
]
const SYSTEM_LABELS := {
	ShipDef.SystemType.BUOYANCY: "BUOYANCY",
	ShipDef.SystemType.ENGINE: "ENGINE",
	ShipDef.SystemType.PROPELLER: "PROPELLER",
	ShipDef.SystemType.RUDDER: "RUDDER",
	ShipDef.SystemType.BRIDGE: "BRIDGE",
	ShipDef.SystemType.CREW: "CREW",
	ShipDef.SystemType.MAGAZINE: "MAGAZINE",
	ShipDef.SystemType.DAMAGE_CONTROL: "DMG CONTROL",
}

var ship: ShipState
var _flash_facing := -1
var _flash_timer: Timer


func _ready() -> void:
	_flash_timer = Timer.new()
	_flash_timer.one_shot = true
	_flash_timer.wait_time = 0.6
	_flash_timer.timeout.connect(func() -> void:
		_flash_facing = -1
		queue_redraw()
	)
	add_child(_flash_timer)


func set_ship(s: ShipState) -> void:
	if ship != null and ship.damage_taken.is_connected(_on_damage):
		ship.damage_taken.disconnect(_on_damage)
		ship.destroyed.disconnect(_on_destroyed)
	ship = s
	ship.damage_taken.connect(_on_damage)
	ship.destroyed.connect(_on_destroyed)
	custom_minimum_size = Vector2(PANEL_W, _layout_height())
	queue_redraw()

func refresh() -> void:
	queue_redraw()

func _on_damage(report: Dictionary) -> void:
	_flash_facing = int(report.get("facing_struck", -1))
	_flash_timer.start()
	queue_redraw()

func _on_destroyed(_reason: String) -> void:
	queue_redraw()


func _layout_height() -> float:
	if ship == null:
		return 200.0
	var h := MARGIN + 44.0                     # title block
	h += 18.0 + 4.0 * (16.0 + BOX + 10.0)      # armor grid: header + 4 rows
	h += 18.0 + (SYSTEM_ORDER.size() + 1) * ROW_H    # systems (+1 for buoyancy port/stbd split)
	h += 18.0 + ship.def.gun_mounts.size() * 30.0  # guns
	h += 34.0 + MARGIN                          # status footer
	return h


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	# Paper background and border, always.
	draw_rect(Rect2(Vector2.ZERO, size), PAPER, true)
	draw_rect(Rect2(Vector2.ZERO, size), INK, false, 2.0)
	if ship == null:
		return

	var font := get_theme_default_font()
	var y := MARGIN + 4.0

	# --- Title block ---
	draw_string(font, Vector2(MARGIN, y + 14.0), ship.def.display_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 17, INK)
	draw_string(font, Vector2(MARGIN, y + 32.0),
			"%s  —  Flyer of %s" % [str(ship.def.id).to_upper(), ship.def.faction],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, PENCIL)
	y += 44.0

	# --- Armor grid (spatial: bow top, stern bottom, port left, stbd right) ---
	y = _draw_section_header(font, y, "ARMOR")
	var col_w := (PANEL_W - 2.0 * MARGIN) / 2.0
	var cell_h := 16.0 + BOX + 10.0
	# Row 0: bow, centered
	_draw_armor_cell(font, Vector2(PANEL_W / 2.0 - col_w / 2.0, y), col_w, 0, true)
	# Rows 1-2: port column left-aligned, starboard column right-aligned
	_draw_armor_cell(font, Vector2(MARGIN, y + cell_h), col_w, 5, false)
	_draw_armor_cell(font, Vector2(MARGIN + col_w, y + cell_h), col_w, 1, true)
	_draw_armor_cell(font, Vector2(MARGIN, y + 2.0 * cell_h), col_w, 4, false)
	_draw_armor_cell(font, Vector2(MARGIN + col_w, y + 2.0 * cell_h), col_w, 2, true)
	# Row 3: stern, centered
	_draw_armor_cell(font, Vector2(PANEL_W / 2.0 - col_w / 2.0, y + 3.0 * cell_h), col_w, 3, true)
	y += 4.0 * cell_h

	# --- Systems ---
	y = _draw_section_header(font, y, "SYSTEMS")
	for t in SYSTEM_ORDER:
		var total := ship.def.system_count(t)
		if total == 0:
			continue
		if t == ShipDef.SystemType.BUOYANCY:
			y = _draw_buoyancy_rows(font, y)
			continue
		draw_string(font, Vector2(MARGIN, y + BOX), SYSTEM_LABELS[t],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK)
		_draw_box_row(Vector2(MARGIN + 104.0, y), total, ship.sys(t), false)
		y += ROW_H

	# --- Gun mounts ---
	y = _draw_section_header(font, y, "DECK GUNS")
	for i in ship.def.gun_mounts.size():
		_draw_gun_row(font, y, i)
		y += 30.0

	# --- Status footer ---
	y += 4.0
	draw_line(Vector2(MARGIN, y), Vector2(PANEL_W - MARGIN, y), INK, 1.0)
	y += 18.0
	var list_info := ""
	var ls := ship.list_side()
	if ls != "":
		list_info = "  LIST %s +%d" % [ls.to_upper(), ship.list_severity()]
	var status := "SPD %d/%d   BUOY %d+%d (falls at %d)   TM %d%s" % [
		ship.speed, ship.effective_max_speed(),
		ship.port_buoyancy, ship.stbd_buoyancy,
		ship.def.grounding_threshold, ship.turn_mode(), list_info]
	draw_string(font, Vector2(MARGIN, y), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK)
	# Critical-state banner line: fires burning and a fouled rudder, in alarm red.
	var crit := ""
	if ship.fires > 0:
		crit += "  %d FIRE%s" % [ship.fires, "" if ship.fires == 1 else "S"]
	if ship.steering_jammed > 0:
		crit += "  STEERING JAMMED"
	if crit != "":
		draw_string(font, Vector2(MARGIN, y + 16.0), crit.strip_edges(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DAMAGE_X)
	if ship.is_destroyed:
		_draw_banner(font, "DESTROYED")
	elif ship.grounded:
		_draw_banner(font, "GROUNDED")


## Draws the BUOYANCY section as two sub-rows (PORT and STBD) instead of one,
## so the player can see which side is taking flooding damage and how badly
## the ship is listing. Returns y advanced past both rows.
func _draw_buoyancy_rows(font: Font, y: float) -> float:
	var total := ship.def.system_count(ShipDef.SystemType.BUOYANCY)
	var port_max := (total + 1) / 2
	var stbd_max := total / 2
	# Port row — main section label + side tag + boxes
	draw_string(font, Vector2(MARGIN, y + BOX), "BUOYANCY",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK)
	draw_string(font, Vector2(MARGIN + 62.0, y + BOX), "PORT",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, PENCIL)
	_draw_box_row(Vector2(MARGIN + 104.0, y), port_max, ship.port_buoyancy, false)
	y += ROW_H
	# Starboard row — side tag + boxes + falling-line annotation
	draw_string(font, Vector2(MARGIN + 62.0, y + BOX), "STBD",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, PENCIL)
	_draw_box_row(Vector2(MARGIN + 104.0, y), stbd_max, ship.stbd_buoyancy, false)
	if ship.def.grounding_threshold > 0:
		var ann_x := MARGIN + 104.0 + stbd_max * (BOX + GAP) + 6.0
		draw_string(font, Vector2(ann_x, y + BOX), "falls at %d total" % ship.def.grounding_threshold,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, DAMAGE_X)
	y += ROW_H
	return y


func _draw_section_header(font: Font, y: float, title: String) -> float:
	draw_string(font, Vector2(MARGIN, y + 11.0), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, PENCIL)
	draw_line(Vector2(MARGIN + 78.0, y + 7.0), Vector2(PANEL_W - MARGIN, y + 7.0), FAINT, 1.0)
	return y + 18.0


## One armor facing: label plus its box row. `right_align` mirrors the layout
## for starboard cells so boxes hug the sheet edge like a real SSD.
func _draw_armor_cell(font: Font, pos: Vector2, cell_w: float, facing: int,
		right_align: bool) -> void:
	var total: int = ship.def.armor[facing]
	var row_w := total * (BOX + GAP) - GAP
	var label := "#%d %s" % [facing, FACING_LABELS[facing]]
	var flash := facing == _flash_facing
	var label_color := FLASH if flash else PENCIL
	if right_align:
		var lx := pos.x + cell_w - row_w
		# Label ends at the row's right edge so short rows (thin armor) never
		# push the text past the panel border.
		var label_w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		draw_string(font, Vector2(lx + row_w - label_w, pos.y + 12.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, label_color)
		_draw_box_row(Vector2(lx, pos.y + 16.0), total, ship.armor_remaining[facing], flash)
	else:
		draw_string(font, Vector2(pos.x, pos.y + 12.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, label_color)
		_draw_box_row(Vector2(pos.x, pos.y + 16.0), total, ship.armor_remaining[facing], flash)


## A row of `total` boxes with `remaining` intact: surviving boxes are clean
## outlines; destroyed ones get pencil shading and a red X, marked off from
## the right end of the row — just like working down a strip on paper.
func _draw_box_row(pos: Vector2, total: int, remaining: int, flash: bool) -> void:
	for i in total:
		var r := Rect2(pos + Vector2(i * (BOX + GAP), 0.0), Vector2(BOX, BOX))
		var dead := i >= remaining
		if dead:
			draw_rect(r, PENCIL, true)
			draw_line(r.position, r.end, DAMAGE_X, 2.0)
			draw_line(Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y),
					DAMAGE_X, 2.0)
		draw_rect(r, FLASH if flash else INK, false, 1.5 if flash else 1.0)


func _draw_gun_row(font: Font, y: float, i: int) -> void:
	var mount: Dictionary = ship.def.gun_mounts[i]
	var gun: GunDef = ShipLibrary.gun(mount["gun_id"])
	var st: Dictionary = ship.gun_states[i]
	var dead: bool = st["destroyed"]
	var color := PENCIL if dead else INK

	# Arc rose, then label, then reload pips, then crew/status.
	_draw_arc_rose(Vector2(MARGIN + 13.0, y + 13.0), mount["arcs"], dead)
	var size_letter := "T" if gun.is_torpedo else PackedStringArray(["L", "M", "H"])[gun.size]
	draw_string(font, Vector2(MARGIN + 32.0, y + 11.0),
			"%s  [%s]" % [str(mount["label"]), size_letter],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	var sub := "rng %d   crew %d" % [gun.max_range(), gun.crew_required]
	if gun.is_torpedo:
		sub += "   AP %d" % gun.armor_piercing
	draw_string(font, Vector2(MARGIN + 32.0, y + 24.0), sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, PENCIL)

	# Reload pips: one circle per reload turn; filled = still cooling down.
	var px := PANEL_W - MARGIN - 90.0
	for p in gun.reload_turns:
		var c := Vector2(px + p * 14.0, y + 13.0)
		if p < int(st["reload"]):
			draw_circle(c, 4.5, DAMAGE_X)
		draw_arc(c, 4.5, 0.0, TAU, 16, color, 1.0)

	# Torpedo ammo: one diamond per torpedo carried; filled = still in the rack,
	# hollow = loosed. The player watches the salvo drain away.
	if gun.is_torpedo:
		var remaining := int(st.get("ammo", 0))
		for p in gun.ammo:
			var c := Vector2(px + p * 14.0, y + 24.0)
			var loaded := p < remaining
			_draw_diamond(c, 4.5, DAMAGE_X if loaded else PENCIL, loaded)

	# Manned indicator / destroyed strike-through.
	if dead:
		draw_line(Vector2(MARGIN + 4.0, y + 14.0), Vector2(PANEL_W - MARGIN - 4.0, y + 14.0),
				DAMAGE_X, 2.0)
		draw_string(font, Vector2(PANEL_W - MARGIN - 36.0, y + 17.0), "DEST",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, DAMAGE_X)
	else:
		var manned: bool = st["manned"]
		draw_circle(Vector2(PANEL_W - MARGIN - 28.0, y + 13.0), 4.0,
				GOOD if manned else FAINT)
		draw_string(font, Vector2(PANEL_W - MARGIN - 20.0, y + 17.0),
				"M" if manned else "-", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				GOOD if manned else PENCIL)


## A small torpedo pip: filled when a warhead is still racked, outline once spent.
func _draw_diamond(c: Vector2, r: float, color: Color, filled: bool) -> void:
	var pts := PackedVector2Array([
		c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
	if filled:
		draw_colored_polygon(pts, color)
	draw_polyline(pts + PackedVector2Array([pts[0]]), color, 1.0)


## Tiny six-sector rose: sectors in this mount's firing arc are inked solid.
## Sector 0 points up (dead ahead in the ship's own frame).
func _draw_arc_rose(center: Vector2, arcs: Array, dead: bool) -> void:
	var radius := 11.0
	for k in 6:
		var a0 := deg_to_rad(k * 60.0 - 30.0)
		var a1 := deg_to_rad(k * 60.0)
		var a2 := deg_to_rad(k * 60.0 + 30.0)
		var pts := PackedVector2Array([
			center,
			center + radius * Vector2(sin(a0), -cos(a0)),
			center + radius * Vector2(sin(a1), -cos(a1)),
			center + radius * Vector2(sin(a2), -cos(a2)),
		])
		if k in arcs and not dead:
			draw_colored_polygon(pts, INK)
		else:
			draw_polyline(pts.slice(1), FAINT, 1.0)
	draw_arc(center, radius, 0.0, TAU, 24, PENCIL if dead else INK, 1.0)


func _draw_banner(font: Font, text: String) -> void:
	var r := Rect2(Vector2(0.0, size.y / 2.0 - 22.0), Vector2(size.x, 44.0))
	draw_rect(r, Color(0.62, 0.13, 0.10, 0.88), true)
	draw_string(font, Vector2(size.x / 2.0 - 60.0, size.y / 2.0 + 7.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)

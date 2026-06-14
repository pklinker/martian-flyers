class_name UiTheme
## Shared retro sci-fi UI styling for the HUD and menus — one palette and a set of
## StyleBoxFlat-driven widget builders so every screen reads as the same game.
## Pure presentation; holds no state. All colours are 0..1 literals so they can be
## `const`. The map keeps its own parchment look — this is only for the overlays.

# --- Palette ----------------------------------------------------------------
const COL_HUD := Color(0.055, 0.078, 0.145, 0.93)   # translucent glass over the map
const COL_PANEL := Color(0.086, 0.122, 0.220, 0.95) # opaque panels (modals)
const COL_SUB := Color(0.114, 0.157, 0.271, 0.85)   # sub-section panels
const COL_ROW := Color(0.118, 0.161, 0.275, 0.92)
const COL_BORDER := Color(0.243, 0.337, 0.525)
const COL_TEXT := Color(0.886, 0.918, 0.957)
const COL_MUTED := Color(0.560, 0.644, 0.776)
const COL_ACCENT := Color(0.204, 0.820, 0.788)      # cyan — selection / info
const COL_POINTS := Color(0.941, 0.690, 0.220)      # amber — numbers / costs
const COL_WARN := Color(0.886, 0.333, 0.294)        # red — over budget / leave
const COL_OK := Color(0.200, 0.820, 0.478)          # green — primary action
const COL_BTN := Color(0.133, 0.188, 0.322)         # neutral button
const COL_BTN_HOVER := Color(0.188, 0.259, 0.424)


# --- Panels -----------------------------------------------------------------

## Glass HUD strip (top bar / bottom bar). `pad` is the inner content margin.
static func hud_style(pad: int = 12) -> StyleBoxFlat:
	return _box(COL_HUD, COL_BORDER, 10, 1, pad)

## Opaque panel for modals (game over).
static func panel_style(pad: int = 16) -> StyleBoxFlat:
	return _box(COL_PANEL, COL_BORDER, 12, 1, pad)

## A grouped sub-section inside a control row (Crew / Stats / Action).
static func sub_style(pad: int = 10) -> StyleBoxFlat:
	return _box(COL_SUB, COL_BORDER.darkened(0.1), 8, 1, pad)

## A single list/row card.
static func row_style(pad: int = 10) -> StyleBoxFlat:
	return _box(COL_ROW, COL_BORDER, 8, 1, pad)

static func _box(bg: Color, border: Color, radius: int, bw: int, pad: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(bw)
	s.border_color = border
	s.set_content_margin_all(pad)
	return s


# --- Labels -----------------------------------------------------------------

static func label(text: String, color: Color = COL_TEXT, size: int = 14, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size + (1 if bold else 0))
	return l


# --- Buttons ----------------------------------------------------------------

## A styled button. `kind`: "primary" (green action), "accent" (cyan), "warn"
## (red, "leave" actions), "system" (compact neutral), "stepper" (tiny square),
## or "neutral". Every state gets a StyleBox so the button responds to the mouse.
static func button(text: String, kind: String = "neutral") -> Button:
	var fill := COL_BTN
	var hover := COL_BTN_HOVER
	var press := COL_BTN.darkened(0.15)
	var border := COL_BORDER
	var fg := COL_TEXT
	var pad_h := 12
	match kind:
		"primary":
			fill = COL_OK.darkened(0.05); hover = COL_OK.lightened(0.12)
			press = COL_OK.darkened(0.2); border = COL_OK.lightened(0.2)
			fg = Color(0.04, 0.10, 0.06); pad_h = 16
		"accent":
			fill = COL_ACCENT.darkened(0.08); hover = COL_ACCENT.lightened(0.1)
			press = COL_ACCENT.darkened(0.22); border = COL_ACCENT.lightened(0.15)
			fg = Color(0.03, 0.10, 0.10)
		"warn":
			fill = Color(0.34, 0.13, 0.13, 0.7); hover = Color(0.55, 0.18, 0.16, 0.9)
			press = Color(0.28, 0.10, 0.10, 0.95); border = COL_WARN.darkened(0.1)
			fg = Color(0.97, 0.82, 0.80)
		"system":
			pad_h = 10
		"stepper":
			pad_h = 10

	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", _btn(fill, border, pad_h))
	b.add_theme_stylebox_override("hover", _btn(hover, border, pad_h))
	b.add_theme_stylebox_override("pressed", _btn(press, border, pad_h))
	b.add_theme_stylebox_override("focus", _btn(fill, border, pad_h))
	b.add_theme_stylebox_override("disabled",
			_btn(Color(0.16, 0.20, 0.30, 0.5), Color(0.30, 0.36, 0.48, 0.35), pad_h))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg.lightened(0.12))
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_disabled_color", COL_MUTED.darkened(0.2))
	b.add_theme_font_size_override("font_size", 14)
	return b


## A toggle button (gun manning / fire selection): dim when off, accent when on.
static func toggle(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Off = neutral, On = the "pressed" stylebox (accent), so state reads at a glance.
	b.add_theme_stylebox_override("normal", _btn(COL_BTN.darkened(0.1), COL_BORDER.darkened(0.1), 10))
	b.add_theme_stylebox_override("hover", _btn(COL_BTN_HOVER, COL_BORDER, 10))
	b.add_theme_stylebox_override("pressed", _btn(COL_ACCENT.darkened(0.1), COL_ACCENT.lightened(0.15), 10))
	b.add_theme_stylebox_override("hover_pressed", _btn(COL_ACCENT, COL_ACCENT.lightened(0.2), 10))
	b.add_theme_stylebox_override("disabled", _btn(Color(0.16, 0.20, 0.30, 0.5), Color(0.3, 0.36, 0.48, 0.3), 10))
	b.add_theme_color_override("font_color", COL_MUTED)
	b.add_theme_color_override("font_pressed_color", Color(0.03, 0.10, 0.10))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.03, 0.10, 0.10))
	b.add_theme_color_override("font_disabled_color", COL_MUTED.darkened(0.25))
	b.add_theme_font_size_override("font_size", 13)
	return b


## A fleet "tab": prominent (accent border/glow) when active, dim when not.
static func tab(text: String, active: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if active:
		var on := _btn(COL_ACCENT.darkened(0.45), COL_ACCENT, 8)
		on.set_border_width_all(2)               # bright accent frame = "selected"
		b.add_theme_stylebox_override("normal", on)
		b.add_theme_stylebox_override("hover", on)
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_color_override("font_color", COL_ACCENT.lightened(0.3))
	else:
		b.add_theme_stylebox_override("normal", _btn(COL_BTN.darkened(0.15), COL_BORDER.darkened(0.2), 8))
		b.add_theme_stylebox_override("hover", _btn(COL_BTN_HOVER, COL_BORDER, 8))
		b.add_theme_stylebox_override("pressed", _btn(COL_BTN, COL_BORDER, 8))
		b.add_theme_color_override("font_color", COL_MUTED)
		b.add_theme_color_override("font_hover_color", COL_TEXT)
	b.add_theme_font_size_override("font_size", 14)
	return b


static func _btn(col: Color, border: Color, pad_h: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(8)
	s.set_border_width_all(1)
	s.border_color = border
	s.set_content_margin_all(7)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	return s

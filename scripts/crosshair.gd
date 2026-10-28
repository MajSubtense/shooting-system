class_name Crosshair
extends Control

## Pure UI: draws a dynamic crosshair whose gap/ring expands with spread.
## Position is driven by the consumer (aim + recoil displacement); this node
## owns no recoil logic -- it just renders state handed to it.
##
## The spread it is given is the SAME ellipse the bullets scatter in
## (RecoilController.get_spread_radius()), so the ring you see is literally the
## cone the next round can land inside -- not a separate guess.

@export var base_gap := 8.0
@export var line_length := 11.0
@export var line_thickness := 2.0
@export var idle_color := Color(1, 1, 1, 0.9)
@export var firing_color := Color(1, 0.35, 0.3, 1.0)

## Half-axes (h, v) of the spread ellipse, in screen units.
var spread := Vector2.ZERO
var firing := false
var show_bloom := true

## Per-shot "punch": driven to 1 on fire and decayed by the consumer. It is the
## whole reason a shot reads as a shot instead of a spreadsheet update -- the
## sight snaps open, flashes and settles, all without touching any ballistics.
var punch := 0.0

func set_spread(v: Vector2) -> void:
	if spread != v:
		spread = v
		queue_redraw()

func set_firing(v: bool) -> void:
	if firing != v:
		firing = v
		queue_redraw()

func set_punch(v: float) -> void:
	if absf(punch - v) > 0.002:
		punch = v
		queue_redraw()

func _draw() -> void:
	var p := clampf(punch, 0.0, 1.5)
	var col := firing_color if firing else idle_color
	# flash towards white on the shot, then fall back to the stance colour
	col = col.lerp(Color(1.0, 0.97, 0.9, 1.0), minf(p, 1.0) * 0.8)
	var gap_h := base_gap + spread.x + p * 7.0
	var gap_v := base_gap + spread.y + p * 7.0
	var len := line_length + p * 6.0
	var th := line_thickness + p * 1.1

	# muzzle ring: a bright circle that snaps outward and fades in ~0.2s
	if p > 0.02:
		draw_arc(Vector2.ZERO, base_gap + 3.0 + (1.0 - minf(p, 1.0)) * 15.0,
			0.0, TAU, 28, Color(1, 1, 1, 0.30 * minf(p, 1.0)), 2.0)

	# spread cone: the exact ellipse the bullet scatters in
	if show_bloom and (spread.x > 0.5 or spread.y > 0.5):
		draw_polyline(_ellipse(spread, 36), Color(col.r, col.g, col.b, 0.28), 1.0)

	# four gap lines (horizontal gap follows h, vertical gap follows v)
	draw_line(Vector2(-gap_h - len, 0), Vector2(-gap_h, 0), col, th)
	draw_line(Vector2(gap_h, 0), Vector2(gap_h + len, 0), col, th)
	draw_line(Vector2(0, -gap_v - len), Vector2(0, -gap_v), col, th)
	draw_line(Vector2(0, gap_v), Vector2(0, gap_v + len), col, th)

	# center dot, swelling on the shot
	draw_circle(Vector2.ZERO, 1.5 + p * 1.6, col)

func _ellipse(r: Vector2, segments: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(segments + 1):
		var a := float(i) / float(segments) * TAU
		pts.append(Vector2(cos(a) * r.x, sin(a) * r.y))
	return pts

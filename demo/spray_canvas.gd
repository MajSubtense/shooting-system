class_name SprayCanvas
extends Control

## Visualises the actual bullet impacts (spray pattern) and the crosshair's
## path as it recoils. Pure drawing surface -- holds no recoil logic.
##
## Impact "juice" lives here on purpose: it is presentation, so the framework
## (RecoilController) stays untouched by anything a player merely sees. A fresh
## impact flares big and bright, throws a short spark cross and shrinks onto its
## final size within ~0.18s -- that flash is most of what makes a shot feel like
## it connected rather than like a number being recorded.

const IMPACT_FLASH := 0.18     ## seconds a new impact spends flaring
const SPARK_TIME := 0.10       ## the spark cross is shorter-lived than the flare

var dots: Array = []      # {pos: Vector2, color: Color, t: float}
var trail: Array = []     # Array of Vector2 (crosshair positions over time)
var _time := 0.0

func _ready() -> void:
	set_process(true)

func add_dot(p: Vector2, c: Color) -> void:
	dots.append({"pos": p, "color": c, "t": _time})
	if dots.size() > 4000:
		dots.pop_front()
	queue_redraw()

func add_trail(p: Vector2) -> void:
	trail.append(p)
	if trail.size() > 4000:
		trail.pop_front()
	queue_redraw()

func clear() -> void:
	dots.clear()
	trail.clear()
	queue_redraw()

## Keep redrawing while at least one impact is still flaring, otherwise the
## animation would freeze on whatever frame happened to be drawn last.
func _process(delta: float) -> void:
	_time += delta
	if not dots.is_empty():
		var d: Dictionary = dots[dots.size() - 1]
		if _time - float(d["t"]) < IMPACT_FLASH:
			queue_redraw()

func _draw() -> void:
	if trail.size() > 1:
		for i in range(trail.size() - 1):
			draw_line(trail[i], trail[i + 1], Color(0.4, 0.8, 1.0, 0.5), 1.5)
	for d in dots:
		var age := _time - float(d["t"])
		var col: Color = d["color"]
		var rad := 2.5
		if age < IMPACT_FLASH:
			var f := 1.0 - age / IMPACT_FLASH          # 1 -> 0
			rad = 2.5 + f * 3.4
			col = col.lerp(Color(1.0, 0.96, 0.86, 1.0), f)
			if age < SPARK_TIME:
				_draw_spark(d["pos"], 1.0 - age / SPARK_TIME)
		draw_circle(d["pos"], rad, col)

## Four short rays flung out of a fresh impact, gone in a tenth of a second.
func _draw_spark(p: Vector2, f: float) -> void:
	var r := 3.0 + f * 8.0
	var c := Color(1.0, 0.92, 0.75, 0.75 * f)
	var w := 1.0 + f
	for dir in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		draw_line(p + dir * (r * 0.35), p + dir * r, c, w)

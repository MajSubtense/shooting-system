extends SceneTree

func _initialize() -> void:
	var tree := self
	var root := tree.root
	var scene: Node = load("res://demo/main.tscn").instantiate()
	root.add_child(scene)
	# wait one idle so _ready runs
	await process_frame
	var dc := scene as Control
	# force-fire
	dc.firing = true
	dc.controller.begin_fire()
	var size := dc.size
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	print("LOCK: aim fixed = (%s, %s)  screen centre y = %s" % [dc.aim.x, dc.aim.y, cy])
	var minx := INF; var maxx := -INF
	for i in range(120):
		dc._process(1.0 / 60.0)
		minx = minf(minx, dc.crosshair.position.x)
		maxx = maxf(maxx, dc.crosshair.position.x)
	var cp := dc.crosshair.position
	print("LOCK: after 120 frames crosshair.pos = (%s, %s)" % [snapped(cp.x, 0.2), snapped(cp.y, 0.2)])
	print("LOCK: aim still centre? %s   horizontal drift = %s px (should be ~0 + recoil x)" % [dc.aim.is_equal_approx(size * 0.5), snapped(maxx - minx, 0.2)])
	print("LOCK: crosshair climbed UP off centre (y < centre)? %s" % [cp.y < cy - 5.0])
	quit()

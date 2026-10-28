extends Control

## 2D abstract demo for the shooting-system recoil framework.
##
## Shows how recoil (deterministic pattern + randomized spread) and bloom
## push the player's *virtual crosshair* off the intended aim point, and how
## equipping attachments re-shapes the predicted spray trajectory in real time.
##
## Controls:
##   - Move mouse        : move the virtual crosshair (cursor locked to centre)
##   - Hold LMB / Space  : fire (auto, at the weapon's fire_rate)
##   - 1 ... 4         : switch weapon (one key per loaded profile)
##   - C                 : clear spray dots & reset the spray pattern
##   - T                 : toggle the crosshair trail
##   - P                 : toggle the trajectory preview (fixed corner panel: white = base, green = current build)
##   - R                 : cycle the recovery curve (ease_out / ease_in / smooth / linear)
##   - Esc               : quit the demo (the OS cursor is hidden during play)
##   - Click attachment buttons : equip / unequip an attachment
##
## Bridge to 3D: in a real FPS you apply get_aim_displacement() to the camera
## rotation (pitch = -y, yaw = x) and use get_bloom() as the raycast spread
## cone. The framework is identical; only the consumer changes.

@onready var crosshair: Crosshair
@onready var spray: SprayCanvas

var controller: RecoilController
var profiles: Array[RecoilProfile] = []
var active_index := 0

var firing := false
var fire_timer := 0.0
var aim := Vector2.ZERO
var show_trail := true
var preview_on := true

## Only the drawn VIRTUAL crosshair is shown -- the OS cursor is hidden AND
## pinned to the window centre (MOUSE_MODE_CAPTURED), so it never wanders and
## never appears on screen. The mouse's RELATIVE motion is what moves the virtual
## crosshair (the player aims by moving the mouse); the recoil kick is added ON
## TOP of that aim. "The cursor is locked to the centre" is literally true --
## what travels is the crosshair, not the cursor. Hold Alt to release the cursor
## (VISIBLE) and operate the UI; release Alt re-captures it.
var ui_mode := false

## Capturing the mouse emits one bogus motion event (the cursor teleports to the
## centre); swallow it so the crosshair never jumps on startup / Alt release.
var _suppress_motion := true

## --- game feel (presentation only; the framework never sees any of this) ---
## Screen shake uses the trauma model: add trauma per shot, decay it, and use
## trauma^2 as the amplitude so small hits stay subtle and big ones punch.
var shake_trauma := 0.0
var shake_t := 0.0
var crosshair_punch := 0.0
const SHAKE_DECAY := 2.4
const SHAKE_MAX := 8.0
const SHAKE_PER_SHOT := 0.22
const PUNCH_DECAY := 5.5

var stats_label: Label
var weapon_label: Label
var preview_btn: Button
var _pview_title: Label
var _pview_legend: Label

const WEAPON_PATHS := [
	"res://demo/weapons/ak_deterministic.tres",
	"res://demo/weapons/vandal_randomized.tres",
	"res://demo/weapons/pistol.tres",
	"res://demo/weapons/m4_functional.tres",
]
const ATTACHMENT_PATHS := [
	"res://demo/attachments/muzzle_brake.tres",
	"res://demo/attachments/compensator.tres",
	"res://demo/attachments/vertical_grip.tres",
	"res://demo/attachments/angled_grip.tres",
	"res://demo/attachments/heavy_stock.tres",
]
## How many rounds the preview draws. Long on purpose: a spray does not stop
## being interesting at round 30, and "why does the climb flatten out so soon?"
## is only answerable by looking at the tail as well as the first magazine.
const PREVIEW_SHOTS := 60
const PREVIEW_TICK_EVERY := 10        ## numbered marker every N rounds

var attachment_catalog: Array[Attachment] = []
var active_attachments: Array[Attachment] = []
var attachment_buttons: Array[Button] = []

## Live "gunfeel" tuning. These are the three gameplay words a designer spends
## their day moving; they are fed through Attachment.from_tuning() so the
## sliders use EXACTLY the same resolve() maths as a real attachment.
var tuning_recoil := 1.0        ## vertical recoil   (<1 = climbs less)
var tuning_stability := 1.0     ## horizontal sway   (<1 = steadier)
var tuning_hipfire := 1.0       ## hip-fire spread   (<1 = tighter)
var tuning_value_labels: Array[Label] = []

const TUNING_DEFS := [
	{"key": "recoil", "text": "垂直后座 recoil", "min": 0.6, "max": 1.4},
	{"key": "stability", "text": "据枪稳定 (水平摆幅)", "min": 0.6, "max": 1.4},
	{"key": "hipfire", "text": "腰射扩散 hip-fire", "min": 0.5, "max": 1.5},
]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	profiles = load_profiles()
	if profiles.is_empty():
		push_error("Demo: no recoil profiles available; demo cannot start.")
		return
	attachment_catalog = load_attachments()

	spray = SprayCanvas.new()
	spray.name = "SprayCanvas"
	spray.set_anchors_preset(Control.PRESET_FULL_RECT)
	spray.set_offsets_preset(Control.PRESET_FULL_RECT)
	spray.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(spray)

	crosshair = Crosshair.new()
	crosshair.name = "Crosshair"
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair)

	build_hud()
	switch_weapon(0)
	# CAPTURED mode is what literally locks the OS cursor to the window centre:
	# the cursor is hidden, pinned there, and only its RELATIVE motion is
	# reported -- that delta drives the virtual crosshair (see _apply_look).
	# Confined mode merely hid the cursor and let it roam, which is not "locked".
	# Alt flips to VISIBLE so the real cursor can drive the UI.
	aim = get_viewport_rect().size * 0.5
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_suppress_motion = true


# --------------------------------------------------------------------------- #
# Profile & attachment loading
# --------------------------------------------------------------------------- #
func load_profiles() -> Array[RecoilProfile]:
	var arr: Array[RecoilProfile] = []
	for p in WEAPON_PATHS:
		var res := load(p)
		if res is RecoilProfile:
			arr.append(res)
	if arr.is_empty():
		arr = build_fallback_profiles()
	return arr

func load_attachments() -> Array[Attachment]:
	var arr: Array[Attachment] = []
	for p in ATTACHMENT_PATHS:
		var res := load(p)
		if res is Attachment:
			arr.append(res)
	if arr.is_empty():
		arr = build_fallback_attachments()
	return arr

## Mirror of the .tres data so the demo still runs if a .tres fails to load.
func build_fallback_profiles() -> Array[RecoilProfile]:
	var mk := func(name: String, mode: String, pat: Array[Vector2], loop: bool, hr: float, vr: float,
			pr: float, bs: float, ms: float, sps: float, srr: float,
			vkv: float, vkh: float, vkr: float, rd: float, vkr2: float, vkd: float, rr: float, rf: float, fr: float, mc: float) -> RecoilProfile:
		var r := RecoilProfile.new()
		r.weapon_name = name
		r.pattern_mode = mode
		r.pattern = pat
		r.loop_pattern = loop
		r.horizontal_rng = hr
		r.vertical_rng = vr
		r.pattern_randomness = pr
		r.base_spread = bs
		r.max_spread = ms
		r.spread_per_shot = sps
		r.spread_recovery_rate = srr
		r.viewkick_vertical = vkv
		r.viewkick_horizontal = vkh
		r.viewkick_rng = vkr
		r.reset_delay = rd
		r.viewkick_recovery = vkr2
		r.viewkick_damping = vkd
		r.recovery_rate = rr
		r.recovery_fraction = rf
		r.recovery_curve = "ease_out"
		r.fire_rate = fr
		r.climb_soft_cap = mc
		return r

	# AK: one table entry per round in the magazine (30), CS-style three phases:
	# shots 1-6 straight up, 7-18 sweeping left then right, 19-30 wide messy S.
	var ak_pat: Array[Vector2] = []
	for v in [
		[0, 5], [1, 6], [1, 7], [2, 7], [2, 6], [2, 5],
		[-1, 4], [-3, 3], [-5, 3], [-6, 2], [-7, 2], [-8, 1],
		[-5, 1], [-2, 1], [1, 1], [4, 1], [7, 1], [9, 1],
		[6, 1], [2, 1], [-2, 1], [-6, 1], [-9, 1], [-11, 1],
		[-7, 1], [-3, 1], [1, 1], [5, 1], [8, 1], [10, 1],
	]:
		ak_pat.append(Vector2(v[0], v[1]))
	# Vandal: Valorant-shaped hook -- straight up for 3, sweep right, hook left.
	var van_pat: Array[Vector2] = []
	for v in [[0, 5], [0.6, 5.5], [-0.6, 5], [1.6, 4], [3.6, 3], [5, 2.5],
			[5.5, 2], [4, 2], [1, 2], [-2.5, 2], [-5.5, 2], [-8, 2]]:
		van_pat.append(Vector2(v[0], v[1]))
	var pis_pat: Array[Vector2] = []
	for v in [[0, 3], [0.9, 3], [-0.7, 2.5], [1.1, 2], [-1.3, 1.5]]:
		pis_pat.append(Vector2(v[0], v[1]))

	var arr: Array[RecoilProfile] = []
	var ak: RecoilProfile = mk.call("AK-47 (Deterministic Pattern)", "deterministic", ak_pat, false, 0.0, 0.0, 0.6, 7.0, 55.0, 4.0, 55.0, 3.0, 1.3, 0.8, 0.12, 115.0, 17.0, 0.85, 0.15, 10.0, 100.0)
	ak.sustain_delta = Vector2(0, 2.4)
	ak.sustain_sway_amp = 4.5
	arr.append(ak)
	var van: RecoilProfile = mk.call("Vandal (Randomized Spread)", "randomized", van_pat, true, 9.0, 1.5, 0.0, 9.0, 65.0, 4.5, 50.0, 2.5, 1.1, 0.7, 0.12, 110.0, 16.0, 0.95, 0.15, 9.75, 95.0)
	van.sustain_delta = Vector2(0, 2.2)
	van.sustain_sway_amp = 5.0
	van.sustain_sway_period = 11.0
	arr.append(van)
	var pis: RecoilProfile = mk.call("Pistol (Small Kick, Tapping)", "deterministic", pis_pat, false, 0.0, 0.0, 1.0, 5.0, 28.0, 5.5, 70.0, 2.4, 0.9, 0.6, 0.06, 140.0, 19.0, 1.5, 0.12, 6.0, 32.0)
	pis.sustain_delta = Vector2(0, 1.8)
	pis.sustain_sway_amp = 2.0
	pis.sustain_sway_period = 7.0
	arr.append(pis)

	# functional-source weapon (closed-form spray, defined for any magazine size)
	var m4 := RecoilProfile.new()
	m4.weapon_name = "M4 (Functional Pattern)"
	m4.pattern_mode = "deterministic"
	m4.pattern_source = "function"
	m4.base_spread = 7.0
	m4.max_spread = 52.0
	m4.spread_per_shot = 4.0
	m4.spread_recovery_rate = 55.0
	m4.viewkick_vertical = 2.8
	m4.viewkick_horizontal = 1.1
	m4.viewkick_rng = 0.7
	m4.reset_delay = 0.12
	m4.viewkick_recovery = 115.0
	m4.viewkick_damping = 17.0
	m4.recovery_rate = 0.9
	m4.recovery_fraction = 0.15
	m4.recovery_curve = "ease_out"
	m4.climb_soft_cap = 85.0
	m4.fire_rate = 11.0
	m4.func_climb_amp = 38.0
	m4.func_climb_rate = 0.45
	m4.func_sway_amp = 4.0
	m4.func_sway_freq = 0.55
	m4.func_drift = Vector2(0.6, 0.4)
	arr.append(m4)
	return arr

## Fallback mirror of the attachment catalogue (same three gameplay axes).
func build_fallback_attachments() -> Array[Attachment]:
	var mk := func(name: String, slot: String, rec: float, stab: float, hip: float,
			vk: float, recov: float, rda: float) -> Attachment:
		var a := Attachment.new()
		a.attachment_name = name
		a.slot = slot
		a.recoil_mult = rec
		a.stability_mult = stab
		a.hipfire_spread_mult = hip
		a.viewkick_mult = vk
		a.recovery_speed_mult = recov
		a.reset_delay_add = rda
		return a
	var arr: Array[Attachment] = []
	arr.append(mk.call("Muzzle Brake", "Muzzle", 0.85, 1.0, 1.0, 0.65, 1.0, 0.0))
	arr.append(mk.call("Compensator", "Muzzle", 0.85, 0.75, 0.8, 0.9, 1.0, 0.0))
	arr.append(mk.call("Vertical Grip", "Grip", 0.7, 1.0, 1.0, 0.9, 1.15, 0.0))
	arr.append(mk.call("Angled Grip", "Grip", 1.0, 0.7, 0.9, 1.0, 1.0, 0.0))
	arr.append(mk.call("Heavy Stock", "Stock", 0.92, 0.92, 1.0, 0.85, 1.3, -0.05))
	return arr


# --------------------------------------------------------------------------- #
# HUD
# --------------------------------------------------------------------------- #
func build_hud() -> void:
	var hud := Control.new()
	hud.name = "HUD"
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.set_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_TOP_LEFT)
	vbox.position = Vector2(16, 16)
	vbox.size = Vector2(440, 0)
	vbox.add_theme_constant_override("separation", 8)
	hud.add_child(vbox)

	weapon_label = Label.new()
	weapon_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(weapon_label)

	stats_label = Label.new()
	stats_label.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0, 0.95))
	vbox.add_child(stats_label)

	# weapon switch row
	var wrow := HBoxContainer.new()
	vbox.add_child(wrow)
	for i in range(profiles.size()):
		var b := Button.new()
		b.text = "%d:%s" % [i + 1, profiles[i].weapon_name.get_slice(" ", 0)]
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		# never take keyboard focus: a focused Button would swallow Space
		# (ui_accept) and the trigger would stop working after a UI click
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(switch_weapon.bind(i))
		wrow.add_child(b)

	# attachment row
	var att_label := Label.new()
	att_label.text = "配件 (点击装备 / 卸下):"
	att_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	vbox.add_child(att_label)
	var arow := GridContainer.new()
	arow.columns = 3
	vbox.add_child(arow)
	attachment_buttons.clear()
	for i in range(attachment_catalog.size()):
		var b := Button.new()
		b.text = attachment_catalog[i].attachment_name
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.pressed.connect(_toggle_attachment.bind(i))
		arow.add_child(b)
		attachment_buttons.append(b)

	# --- live gunfeel tuning sliders ---
	var t_label := Label.new()
	t_label.text = "调校滑块 (实时作用于弹道预览):"
	t_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	vbox.add_child(t_label)
	tuning_value_labels.clear()
	for def in TUNING_DEFS:
		_add_tuning_slider(vbox, def)

	# preview toggle
	var prow := HBoxContainer.new()
	vbox.add_child(prow)
	preview_btn = Button.new()
	preview_btn.text = "轨迹预览 (P): 开"
	preview_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	preview_btn.focus_mode = Control.FOCUS_NONE
	preview_btn.pressed.connect(_toggle_preview)
	prow.add_child(preview_btn)

	var instr := Label.new()
	instr.text = "鼠标锁定屏幕中心(隐藏) · 移动鼠标=移动虚拟准心(后座把它推开) · 按住左键/空格=开火 · 按住右键=瞄准(ADS,无扩散) · 按住Alt=呼出鼠标操作UI · 1~4=换枪 · 滑块=调校(后座/据枪稳定/腰射) · R=回落曲线 · C=清除 · T=轨迹 · P=预览 · Esc=退出"
	instr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instr.custom_minimum_size = Vector2(420, 0)
	instr.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	vbox.add_child(instr)

	var legend := Label.new()
	legend.text = "右下角面板 = 弹道预览(60发): 白=原厂  绿=当前  方块=单发落点  带状=散布范围"
	legend.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 0.85))
	vbox.add_child(legend)

	# fixed-corner preview title / legend (drawn over the preview panel)
	_pview_title = Label.new()
	_pview_title.text = "弹道预览 (P)"
	_pview_title.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0, 0.95))
	_pview_title.visible = preview_on
	hud.add_child(_pview_title)
	_pview_legend = Label.new()
	_pview_legend.text = "白=原厂  绿=当前  方块/数字=单发落点  带状=散布范围"
	_pview_legend.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 0.9))
	_pview_legend.visible = preview_on
	hud.add_child(_pview_legend)
	var _rect0 := _preview_rect()
	_pview_title.position = _rect0.position + Vector2(12, 8)
	_pview_legend.position = Vector2(_rect0.position.x + 12, _rect0.position.y + _rect0.size.y - 22)


# --------------------------------------------------------------------------- #
# Weapon & attachment state
# --------------------------------------------------------------------------- #
func switch_weapon(i: int) -> void:
	if i < 0 or i >= profiles.size():
		return
	active_index = i
	active_attachments.clear()
	for b in attachment_buttons:
		b.button_pressed = false
	if controller != null:
		controller.queue_free()
	controller = RecoilController.new()
	controller.name = "RecoilController"
	# assign before add_child so _ready() sees a profile (it seeds bloom from
	# base_spread); rebuild_profile() then swaps in the resolved build.
	controller.profile = profiles[i]
	add_child(controller)
	rebuild_profile()   # base + attachments + slider tuning, one code path
	spray.clear()
	fire_timer = 0.0
	firing = false
	update_weapon_label()
	crosshair.queue_redraw()

func _add_tuning_slider(parent: Node, def: Dictionary) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var name_l := Label.new()
	name_l.text = String(def["text"])
	name_l.custom_minimum_size = Vector2(160, 0)
	name_l.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0, 0.9))
	row.add_child(name_l)
	var s := HSlider.new()
	s.min_value = float(def["min"])
	s.max_value = float(def["max"])
	s.step = 0.01
	s.value = 1.0
	s.custom_minimum_size = Vector2(180, 0)
	# FOCUS_NONE: a focused slider would swallow the arrow keys (and, worse,
	# Space via ui_accept) and break the trigger after a UI interaction.
	s.focus_mode = Control.FOCUS_NONE
	s.value_changed.connect(_on_tuning_changed.bind(String(def["key"])))
	row.add_child(s)
	var v := Label.new()
	v.text = "×1.00"
	v.custom_minimum_size = Vector2(52, 0)
	v.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 0.95))
	row.add_child(v)
	tuning_value_labels.append(v)

func _on_tuning_changed(value: float, key: String) -> void:
	match key:
		"recoil":
			tuning_recoil = value
		"stability":
			tuning_stability = value
		"hipfire":
			tuning_hipfire = value
	var keys := ["recoil", "stability", "hipfire"]
	var i := keys.find(key)
	if i >= 0 and i < tuning_value_labels.size():
		tuning_value_labels[i].text = "×%.2f" % value
	rebuild_profile()
	if preview_on:
		queue_redraw()

func _toggle_attachment(i: int) -> void:
	var att := attachment_catalog[i]
	if active_attachments.has(att):
		active_attachments.erase(att)
	else:
		active_attachments.append(att)
	rebuild_profile()

func _toggle_preview() -> void:
	preview_on = not preview_on
	if preview_btn:
		preview_btn.text = "轨迹预览 (P): %s" % ("开" if preview_on else "关")
	if _pview_title:
		_pview_title.visible = preview_on
	if _pview_legend:
		_pview_legend.visible = preview_on
	queue_redraw()

## Cycle the active weapon's recovery curve so you can feel the difference
## between uniform / ease-out / ease-in / smooth settle in real time.
const RECOVERY_CURVES := ["ease_out", "ease_in", "smooth", "linear"]

func _cycle_recovery_curve() -> void:
	if controller == null or controller.profile == null:
		return
	var cur := controller.profile.recovery_curve
	var idx := RECOVERY_CURVES.find(cur)
	idx = ((idx + 1) % RECOVERY_CURVES.size() + RECOVERY_CURVES.size()) % RECOVERY_CURVES.size()
	controller.profile.recovery_curve = RECOVERY_CURVES[idx]
	update_stats()

## Re-resolve the current build (base + attachments + slider tuning) and push it
## to the controller. This is the single point where any of them take effect.
##
## The sliders are appended as one synthetic attachment instead of being applied
## separately: one code path means the preview can never disagree with a real
## attachment doing the same thing.
func rebuild_profile() -> void:
	if controller == null:
		return
	var list: Array = []
	list.append_array(active_attachments)
	if tuning_recoil != 1.0 or tuning_stability != 1.0 or tuning_hipfire != 1.0:
		list.append(Attachment.from_tuning(tuning_recoil, tuning_stability, tuning_hipfire))
	controller.profile = Attachment.resolve(profiles[active_index], list)
	update_weapon_label()

func update_weapon_label() -> void:
	var label := profiles[active_index].weapon_name
	for a in active_attachments:
		label += " + " + a.attachment_name
	label += "  [后座×%.2f 稳定×%.2f 腰射×%.2f]" % [
		tuning_recoil, tuning_stability, tuning_hipfire]
	weapon_label.text = "Build: " + label + "  [%s]" % profiles[active_index].pattern_mode


# --------------------------------------------------------------------------- #
# Input
# --------------------------------------------------------------------------- #
## Mouse-look. The OS cursor is captured (hidden + pinned to the centre); only
## its RELATIVE motion reaches us. That delta moves the VIRTUAL crosshair, which
## is the thing the player sees travelling -- the cursor itself never moves.
## Handled in _input so a HUD control can never swallow the motion.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not ui_mode:
		_apply_look((event as InputEventMouseMotion).relative)

## Apply one raw mouse delta to the virtual crosshair, clamped to the viewport so
## it can never be pushed fully off-screen.
func _apply_look(rel: Vector2) -> void:
	if _suppress_motion:
		# capturing the mouse emits one bogus motion event (the cursor teleports
		# to the centre); swallow it so the crosshair never jumps on startup or
		# when Alt is released.
		_suppress_motion = false
		return
	aim += rel
	var vp := get_viewport_rect().size
	var m := 40.0
	aim.x = clampf(aim.x, m, vp.x - m)
	aim.y = clampf(aim.y, m, vp.y - m)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				firing = true
				if controller: controller.begin_fire()
			else:
				firing = false
				if controller: controller.end_fire()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Hold RMB = aim (ADS): no random spread, the bullet follows the
			# (recoil-displaced) crosshair exactly. Release = back to hip-fire.
			if controller: controller.set_ads(event.pressed)
	elif event is InputEventKey:
		var ek := event as InputEventKey
		var k := ek.keycode
		if k == KEY_ALT:
			# Hold Alt = take the OS cursor back to operate the UI. Swallow the
			# event so it never reaches the gameplay keys below.
			_set_ui_mode(event.pressed)
			get_viewport().set_input_as_handled()
			return
		# While the cursor is out you are driving the UI, not the gun: gameplay
		# keys (including the trigger) must not fire.
		if ui_mode:
			return
		if k == KEY_SPACE:
			if event.pressed:
				firing = true
				if controller: controller.begin_fire()
			else:
				firing = false
				if controller: controller.end_fire()
		elif event.pressed:
			# Weapon slots: one number key per loaded profile (1 ... N). Handled
			# as a range so adding a 5th weapon needs no extra key branch.
			if k >= KEY_1 and k <= KEY_9:
				switch_weapon(k - KEY_1)
			elif k == KEY_C:
				spray.clear()
				if controller: controller.reset_pattern()
			elif k == KEY_T:
				show_trail = not show_trail
			elif k == KEY_P:
				_toggle_preview()
			elif k == KEY_R:
				_cycle_recovery_curve()
			elif k == KEY_ESCAPE:
				get_tree().quit()

## Hold Alt: release the cursor so it can drive the UI. Release Alt: re-capture
## it (hidden + locked back to the centre). The VIRTUAL crosshair does not move
## during any of this -- only the OS cursor is released and re-captured.
func _set_ui_mode(on: bool) -> void:
	if ui_mode == on:
		return
	ui_mode = on
	if on:
		# let go of the trigger -- you are clicking buttons now
		if firing:
			firing = false
			if controller: controller.end_fire()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# the cursor was pinned at the centre while captured, so put it there
		# explicitly -- Alt should make the mouse appear in the middle, not
		# wherever it happened to be last.
		Input.warp_mouse(get_viewport_rect().size * 0.5)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# re-capturing fires one bogus motion event; swallow it so the crosshair
		# does not jump when control returns to the gun
		_suppress_motion = true

func _process(delta: float) -> void:
	if controller == null:
		return
	# `aim` is advanced by the mouse's RELATIVE motion in _apply_look(); recoil is
	# layered on top in the crosshair.position assignment below.

	# --- game feel decay (presentation only) ---
	shake_t += delta
	shake_trauma = maxf(shake_trauma - delta * SHAKE_DECAY, 0.0)
	crosshair_punch = maxf(crosshair_punch - delta * PUNCH_DECAY, 0.0)
	var amp := shake_trauma * shake_trauma
	var shake := Vector2(sin(shake_t * 47.0), sin(shake_t * 61.0 + 1.7)) * amp * SHAKE_MAX

	var disp := controller.get_aim_displacement()
	var screen_disp := Vector2(disp.x, -disp.y)  # our y is up-positive
	# shake the WHOLE picture (spray + crosshair) like a camera -- the recorded
	# impact coordinates stay untouched, only what you see moves
	spray.position = shake
	crosshair.position = aim + screen_disp + shake
	# the crosshair ring IS the cone the next bullet can land in -- same ellipse
	crosshair.set_spread(controller.get_spread_radius())
	crosshair.set_firing(firing)
	crosshair.set_punch(crosshair_punch)
	queue_redraw()

	if firing:
		fire_timer -= delta
		if fire_timer <= 0.0:
			fire_timer = 1.0 / controller.profile.fire_rate
			do_shot()
	else:
		fire_timer = 0.0

	update_stats()
	# preview is a fixed corner panel; redraw when on (and keep labels positioned)
	if preview_on:
		queue_redraw()
		var rect := _preview_rect()
		if _pview_title:
			_pview_title.position = rect.position + Vector2(12, 8)
		if _pview_legend:
			_pview_legend.position = Vector2(rect.position.x + 12, rect.position.y + rect.size.y - 22)

func do_shot() -> void:
	# --- game feel: a shot must be felt, not just registered ---
	shake_trauma = minf(shake_trauma + SHAKE_PER_SHOT, 1.0)
	crosshair_punch = minf(crosshair_punch + 1.0, 1.4)
	var shot := controller.fire()
	# The round leaves the barrel BEFORE the kick, so its origin is the
	# pre-kick offset fire() reports -- NOT get_pattern_offset(), which by now
	# already includes this shot's kick. Using the latter is what pushed the
	# first round off the aim point.
	var po: Vector2 = shot.get("impact_offset", Vector2.ZERO)
	var shot_origin := aim + Vector2(po.x, -po.y)
	# per-bullet random spread, already rolled inside fire() against the cone
	# that was live at that instant (NOT accumulated into the pattern): the dots
	# scatter AROUND the pattern line, which is what keeps the preview honest.
	var spread: Vector2 = shot.get("spread", Vector2.ZERO)
	var impact := shot_origin + Vector2(spread.x, -spread.y)
	spray.add_dot(impact, Color(1.0, 0.45, 0.35, 0.9))
	if show_trail:
		spray.add_trail(shot_origin)

func update_stats() -> void:
	var off := controller.get_aim_displacement()
	var cone := controller.get_spread_radius()
	stats_label.text = (
		"shots / heat : %d\n" % controller.get_heat() +
		"spread cone  : (%.1f, %.1f)   bloom %.1f\n" % [cone.x, cone.y, controller.get_bloom()] +
		"recoil off   : (%.1f, %.1f)\n" % [off.x, off.y] +
		"  perm/temp  : %.1f / %.1f\n" % [controller.get_permanent_offset().y, controller.get_temporary_offset().y] +
		"viewkick     : (%.1f, %.1f)\n" % [controller.get_viewkick().x, controller.get_viewkick().y] +
		"recovery     : %s\n" % controller.profile.recovery_curve +
		"stance       : %s\n" % ("ADS (no spread)" if controller.is_ads() else "HIP-FIRE (spread)") +
		"fire rate    : %.2f /s  (RPM %.0f)" % [controller.profile.fire_rate, controller.profile.fire_rate * 60.0]
	)


# --------------------------------------------------------------------------- #
# Trajectory preview (attachment-aware, fixed corner panel -- NOT following aim)
# --------------------------------------------------------------------------- #
func _preview_rect() -> Rect2:
	var s := Vector2(330, 470)
	return Rect2(Vector2(size.x - s.x - 20, size.y - s.y - 20), s)

func _draw() -> void:
	if preview_on and controller != null and controller.profile != null:
		_draw_preview_panel()

## NOTE: the faint aim-point reticle was removed -- the user wants only the one
## drawn VIRTUAL crosshair on screen, with no extra small marker at any point.

## Draw the spray pattern as a self-contained mini-diagram in the bottom-right
## corner: a framed box with the spray origin at the bottom and the predicted
## paths growing upward from it.
##
## Two rules keep it honest against the live spray:
##   1. The paths come from RecoilController.simulate_offsets(), i.e. the same
##      split + climb_soft_cap maths fire() runs -- not a raw cumulative sum.
##   2. Base and build share ONE scale, and that scale is 1:1 (world px = panel
##      px) whenever the pattern fits. So the picture has the same shape AND the
##      same size as the dots you see on screen.
func _draw_preview_panel() -> void:
	var rect := _preview_rect()
	var inner := Rect2(rect.position + Vector2(16, 34), rect.size - Vector2(32, 58))

	# panel background + border
	draw_rect(rect, Color(0.04, 0.06, 0.10, 0.88))
	draw_rect(rect, Color(0.4, 0.85, 0.95, 0.45), false, 1.5)

	var base_path := RecoilController.simulate_offsets(profiles[active_index], PREVIEW_SHOTS)
	var build_path := RecoilController.simulate_offsets(controller.profile, PREVIEW_SHOTS)
	# the spread ellipse of EVERY bullet of the current build -- same maths the
	# live impacts use, so the envelope is the cone the dots really scatter in.
	var build_spreads := RecoilController.simulate_spreads(controller.profile, PREVIEW_SHOTS)

	# --- one shared scale for both paths (1:1 whenever it fits) ---
	# The origin sits low so the first (resting) cone still fits underneath it.
	var origin := Vector2(inner.get_center().x, inner.position.y + inner.size.y * 0.88)
	var max_x := 0.0
	var max_up := 0.0
	for path in [base_path, build_path]:
		for i in range(path.size()):
			max_x = maxf(max_x, absf(path[i].x) + build_spreads[i].x)
			max_up = maxf(max_up, path[i].y + build_spreads[i].y)
	var rest_cone := build_spreads[0].y if not build_spreads.is_empty() else 0.0
	var sc := 1.0
	var avail_x := inner.size.x * 0.5 - 8.0
	var avail_up := origin.y - inner.position.y - 6.0
	var avail_down := inner.position.y + inner.size.y - origin.y - 6.0
	if max_x > 0.001:
		sc = minf(sc, avail_x / max_x)
	if max_up > 0.001:
		sc = minf(sc, avail_up / max_up)
	if rest_cone > 0.001:
		sc = minf(sc, avail_down / rest_cone)

	# spread envelope: two nested CONTINUOUS ribbons (one per round was an
	# unreadable string of rings). Outer = widest axis, inner = narrowest, so the
	# anisotropy of the ellipse still shows without drawing 60 ovals.
	_draw_spread_band(build_path, build_spreads, origin, sc)

	# paths: base = dim white, build = bright green
	_draw_path(base_path, origin, sc, Color(1, 1, 1, 0.30), false)
	_draw_path(build_path, origin, sc, Color(0.45, 1.0, 0.6, 0.95), true)

	# spray origin (where bullet #1 leaves the muzzle) sits at the panel bottom
	draw_circle(origin, 3.0, Color(1, 1, 1, 0.9))
	draw_line(origin - Vector2(10, 0), origin + Vector2(10, 0), Color(1, 1, 1, 0.45), 1.0)
	draw_line(origin - Vector2(0, 10), origin + Vector2(0, 1), Color(1, 1, 1, 0.45), 1.0)

	# scale read-out: the panel is only 1:1 while the pattern fits, and saying so
	# is what keeps "the preview is smaller than the real spray" from being a lie
	var font := ThemeDB.fallback_font
	var sc_txt := "1:1" if sc > 0.999 else "1:%.2f" % sc
	draw_string(font, Vector2(rect.position.x + rect.size.x - 62, rect.position.y + 22),
		sc_txt, HORIZONTAL_ALIGNMENT_RIGHT, 50, 12, Color(0.7, 0.9, 1.0, 0.8))

## pattern space (x = right, y = up) -> panel space (y flipped, anchored origin)
func _to_panel(p: Vector2, origin: Vector2, sc: float) -> Vector2:
	return origin + Vector2(p.x * sc, -p.y * sc)

## The trajectory: one continuous polyline (where the muzzle is pointing, round
## by round) PLUS a discrete marker per round (where that round actually lands).
## The line alone hides the per-shot spacing; the dots alone hide the shape.
func _draw_path(path: Array[Vector2], origin: Vector2, sc: float, col: Color, with_dots: bool) -> void:
	if path.is_empty():
		return
	var pts := PackedVector2Array()
	for p in path:
		pts.append(_to_panel(p, origin, sc))
	if pts.size() > 1:
		draw_polyline(pts, col, 2.0)
	if not with_dots:
		return
	var font := ThemeDB.fallback_font
	for i in range(pts.size()):
		var pt := pts[i]
		var major := (i + 1) % PREVIEW_TICK_EVERY == 0
		if major:
			# every Nth round gets a bigger marker + its round number, so you can
			# read "round 30 is here" straight off the picture
			draw_circle(pt, 3.6, Color(0.75, 1.0, 0.85, 0.95))
			draw_string(font, pt + Vector2(6, 4), str(i + 1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 1.0, 0.85, 0.9))
		else:
			draw_rect(Rect2(pt - Vector2(1.6, 1.6), Vector2(3.2, 3.2)), col)

## TWO nested continuous ribbons = the cone every round can land in. The
## half-axes come straight from RecoilController.simulate_spreads(), i.e. the
## same bloom+RNG composition the live impacts roll in.
##
## One oval per round was technically correct and visually useless: 60 stacked
## rings read as noise. A ribbon shows the same information as a shape you can
## follow -- and the two nested widths keep the ellipse's anisotropy visible.
func _draw_spread_band(path: Array[Vector2], cones: Array[Vector2], origin: Vector2, sc: float) -> void:
	if path.is_empty() or cones.is_empty():
		return
	# Aiming: there is no random spread at all, so there is no envelope to draw.
	# Drawing one here would make the preview lie about where bullets really go.
	if controller != null and controller.is_ads():
		return
	var outer_fill := Color(0.35, 0.95, 0.55, 0.10)
	var inner_fill := Color(0.45, 1.0, 0.60, 0.13)
	var edge := Color(0.55, 1.0, 0.70, 0.30)
	_fill_ribbon(path, cones, origin, sc, false, outer_fill, edge)
	_fill_ribbon(path, cones, origin, sc, true, inner_fill, Color(0.55, 1.0, 0.70, 0.16))

## One pass over the path, filling a ribbon of half-width `cone.x` (widest axis)
## or `cone.y` (narrowest), plus its two outline edges.
func _fill_ribbon(path: Array[Vector2], cones: Array[Vector2], origin: Vector2, sc: float,
		use_narrow: bool, fill: Color, edge: Color) -> void:
	var n := mini(path.size(), cones.size())
	var prev_l := Vector2.ZERO
	var prev_r := Vector2.ZERO
	for i in range(n):
		var c := _to_panel(path[i], origin, sc)
		var w := (minf(cones[i].x, cones[i].y) if use_narrow else maxf(cones[i].x, cones[i].y)) * sc
		var l := c + Vector2(-w, 0)
		var r := c + Vector2(w, 0)
		if i > 0:
			# raw triangles, NOT draw_colored_polygon: a sharp hook in the pattern
			# makes one segment's quad self-intersect (a bow-tie), and the
			# triangulator then silently drops the whole fill.
			_tri(prev_l, prev_r, r, fill)
			_tri(prev_l, r, l, fill)
			draw_line(prev_l, l, edge, 1.0)
			draw_line(prev_r, r, edge, 1.0)
		prev_l = l
		prev_r = r

func _tri(a: Vector2, b: Vector2, c: Vector2, col: Color) -> void:
	draw_primitive(PackedVector2Array([a, b, c]), PackedColorArray([col, col, col]),
		PackedVector2Array())

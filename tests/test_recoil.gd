extends Node

## Headless regression suite for the recoil framework. Run with:
##   Godot --headless --path . res://tests/test_recoil.tscn
## Exits 0 on all-passed, 1 on any failure. Locks in the bugs we have already
## fixed so they cannot silently return.
##
## Frames are driven manually via c._process(1/60) instead of awaiting
## process_frame, because headless does not advance the main loop reliably.

const PATHS := [
	"res://demo/weapons/ak_deterministic.tres",
	"res://demo/weapons/vandal_randomized.tres",
	"res://demo/weapons/pistol.tres",
	"res://demo/weapons/m4_functional.tres",
]

func _ready() -> void:
	var ok := true
	ok = _sustained() and ok
	ok = _preview_match() and ok
	ok = _first_shot_on_aim() and ok
	ok = _kick_rise() and ok
	ok = _settle() and ok
	ok = _bloom_floor() and ok
	ok = _spread_consistent() and ok
	ok = _ads_modes() and ok
	ok = _resolve_preserves_fields() and ok
	ok = _attachment_axes() and ok
	ok = _spray_is_not_a_straight_line() and ok
	ok = _long_tail_keeps_climbing() and ok
	print("=== TEST RESULT: %s ===" % ("ALL PASS" if ok else "FAILURES PRESENT"))
	get_tree().quit(0 if ok else 1)

## Regression 1: "hold the trigger and recoil stops working". A sustained burst
## must NEVER freeze -- every shot keeps moving the offset (no zero-delta run).
## Each shot is followed by one full shot interval of ticks, because the kick is
## now a short TRAVEL rather than an instant jump (see _kick_rise).
func _sustained() -> bool:
	var all_ok := true
	for p in _profiles():
		var c := RecoilController.new()
		c.profile = p
		add_child(c)
		c.reset_pattern()
		c.begin_fire()
		var prev := c.get_pattern_offset()
		var frozen := 0
		for i in range(90):
			c.fire()
			_tick_shot_interval(c)
			var cur := c.get_pattern_offset()
			if (cur - prev).length() < 1e-4:
				frozen += 1
			prev = cur
		c.queue_free()
		var passed := frozen == 0
		all_ok = all_ok and passed
		print("sustained  [%s] frozen=%d -> %s" % [p.weapon_name, frozen, "PASS" if passed else "FAIL"])
	return all_ok

## Regression 2: the preview (simulate_offsets) must match the live fire() path
## shot-for-shot, otherwise the preview picture lies about the real spray.
## Both are read as "where the round lands", i.e. the pre-kick muzzle state.
func _preview_match() -> bool:
	var all_ok := true
	for p in _profiles():
		var c := RecoilController.new()
		c.profile = p
		add_child(c)
		c.reset_pattern()
		c.begin_fire()
		var live: Array[Vector2] = []
		for i in range(30):
			var shot := c.fire()
			live.append(shot.get("impact_offset", Vector2.ZERO))
			_tick_shot_interval(c)
		c.queue_free()
		var sim := RecoilController.simulate_offsets(p, 30)
		var max_dev := 0.0
		for i in range(30):
			max_dev = maxf(max_dev, (live[i] - sim[i]).length())
		var passed := max_dev < 1e-4
		all_ok = all_ok and passed
		print("preview    [%s] max_dev=%.4f -> %s" % [p.weapon_name, max_dev, "PASS" if passed else "FAIL"])
	return all_ok

## Regression 3: shot #1 must land exactly on the aim point. The round leaves
## the barrel BEFORE the kick, so its inherited offset is zero. Sampling the
## offset after the kick (the old order) put every round one kick ahead.
func _first_shot_on_aim() -> bool:
	var all_ok := true
	for p in _profiles():
		var c := RecoilController.new()
		c.profile = p
		add_child(c)
		c.reset_pattern()
		c.begin_fire()
		var shot := c.fire()
		var off: Vector2 = shot.get("impact_offset", Vector2.ZERO)
		var sp: Vector2 = shot.get("spread", Vector2.ZERO)
		c.queue_free()
		# the offset must be exactly zero; the scatter must fit in the cone
		var passed := off.length() < 1e-9
		all_ok = all_ok and passed
		print("firstshot  [%s] impact_offset=(%.4f,%.4f) spread=(%.2f,%.2f) -> %s" % [
			p.weapon_name, off.x, off.y, sp.x, sp.y, "PASS" if passed else "FAIL"])
	return all_ok

## Regression 4: one shot's kick must be a visible TRAVEL, not a teleport.
## right after fire() the offset has NOT moved; it reaches the target over
## kick_rise_time, and no single tick covers the whole distance.
func _kick_rise() -> bool:
	var p := load(PATHS[0]) as RecoilProfile
	var c := RecoilController.new()
	c.profile = p
	add_child(c)
	c.reset_pattern()
	c.begin_fire()
	# the CROSSHAIR (aim displacement = pattern + viewkick) must not jump on the
	# fire frame: both the ballistic kick and the visual punch travel.
	var before := c.get_aim_displacement()
	c.fire()
	var just_after := c.get_aim_displacement()
	var pat0 := c.get_pattern_offset()
	var dur := c._rise_duration()
	var steps := maxi(int(ceili(dur * 240.0)), 2)
	var mid := 0.0
	var max_tick := 0.0
	var prev := just_after
	for i in range(steps):
		c._process(1.0 / 240.0)
		var cur := c.get_aim_displacement()
		max_tick = maxf(max_tick, (cur - prev).length())
		prev = cur
		if i == steps / 2:
			mid = c.get_pattern_offset().y
	var end := c.get_pattern_offset()
	c.queue_free()
	var no_teleport := (just_after - before).length() < 1e-9
	var travelled := end.y > mid + 1e-6 and mid > pat0.y + 1e-6
	var smooth := max_tick < (end.y - pat0.y) * 0.9
	var passed := no_teleport and travelled and smooth and dur > 0.0
	print("kickrise   [AK] dur=%.3fs jump_on_fire=%.4f pat %.2f->mid %.2f->%.2f max_tick=%.3f -> %s" % [
		dur, (just_after - before).length(), pat0.y, mid, end.y, max_tick,
		"PASS" if passed else "FAIL"])
	return passed

## Regression 5: after firing a burst and releasing, the view must stay UP
## (permanent aim punch), only the temporary share settles back. Not a return to
## the origin, and not frozen either.
func _settle() -> bool:
	var p := load(PATHS[0]) as RecoilProfile
	var c := RecoilController.new()
	c.profile = p
	add_child(c)
	c.reset_pattern()
	c.begin_fire()
	for i in range(10):
		c.fire()
		for k in range(5):
			c._process(1.0 / 60.0)   # let the kick land before the next round
	var peak := c.get_pattern_offset().y
	c.end_fire()
	for i in range(240):
		c._process(1.0 / 60.0)
	var rest := c.get_pattern_offset().y
	c.queue_free()
	var kept := rest / peak
	var passed := kept > 0.7
	print("settle     [AK] peak=%.1f rest=%.1f kept=%.0f%% -> %s" % [peak, rest, kept * 100.0, "PASS" if passed else "FAIL"])
	return passed

## Regression 6: bloom must start at AND floor at `base_spread` (the resting
## cone) -- never at 0, otherwise the first shot out of rest is laser accurate
## and `base_spread` is a dead parameter that silently does nothing.
func _bloom_floor() -> bool:
	var p := load(PATHS[0]) as RecoilProfile
	var c := RecoilController.new()
	c.profile = p
	add_child(c)
	c.reset_pattern()
	var at_rest := c.get_bloom()
	c.begin_fire()
	c.fire()
	c.end_fire()
	for i in range(600):
		c._process(1.0 / 60.0)   # let bloom fully recover
	var after := c.get_bloom()
	c.queue_free()
	var passed := absf(at_rest - p.base_spread) < 1e-3 and absf(after - p.base_spread) < 1e-3
	print("bloom      [AK] rest=%.2f base=%.2f after_recovery=%.2f -> %s" % [
		at_rest, p.base_spread, after, "PASS" if passed else "FAIL"])
	return passed

## Regression 7: ONE spread ellipse, three consumers. Every rolled scatter must
## stay inside get_spread_radius(), and the preview sequence
## (simulate_spreads) must start from exactly that resting cone and grow.
func _spread_consistent() -> bool:
	var p := load(PATHS[0]) as RecoilProfile
	var c := RecoilController.new()
	c.profile = p
	add_child(c)
	c.reset_pattern()
	var cone := c.get_spread_radius()
	var worst := 0.0
	for i in range(2000):
		var s := c.roll_spread()
		worst = maxf(worst, absf(s.x) / maxf(cone.x, 1e-6))
		worst = maxf(worst, absf(s.y) / maxf(cone.y, 1e-6))
	var seq := RecoilController.simulate_spreads(p, 3)
	var start_ok := absf(seq[0].x - cone.x) < 1e-6 and absf(seq[0].y - cone.y) < 1e-6
	var grows := seq[2].x > seq[0].x
	c.queue_free()
	var passed := worst <= 1.0 + 1e-6 and start_ok and grows and cone.x > 1.0
	print("spread     [AK] cone=(%.2f,%.2f) worst_sample=%.3f start_matches=%s grows=%s -> %s" % [
		cone.x, cone.y, worst, "yes" if start_ok else "NO", "yes" if grows else "NO",
		"PASS" if passed else "FAIL"])
	return passed

## Regression 8: two firing stances. Aiming (ADS) must remove ALL random spread
## (bloom cone + per-bullet RNG -> 0) so the bullet follows the crosshair, while
## the deterministic ballistics stay IDENTICAL in both stances.
func _ads_modes() -> bool:
	var p := load(PATHS[0]) as RecoilProfile
	# --- hip-fire: bloom grows above the resting cone ---
	var hip := RecoilController.new()
	hip.profile = p
	add_child(hip)
	hip.reset_pattern()
	var hip_rest := hip.get_bloom()
	hip.begin_fire()
	hip.fire()
	var hip_bloom := hip.get_bloom()
	hip.queue_free()
	# --- ADS: no spread at all ---
	var ads := RecoilController.new()
	ads.profile = p
	add_child(ads)
	ads.set_ads(true)
	ads.reset_pattern()
	ads.begin_fire()
	ads.fire()
	var ads_bloom := ads.get_bloom()
	var ads_spread := ads.roll_spread()
	var ads_cone := ads.get_spread_radius()
	ads.queue_free()
	# --- ballistics must not change with the stance ---
	var a := _offsets_for(p, false)
	var b := _offsets_for(p, true)
	var identical := a.size() == b.size()
	for i in range(mini(a.size(), b.size())):
		if (a[i] - b[i]).length() > 1e-6:
			identical = false
	var passed := (
		absf(hip_rest - p.base_spread) < 1e-3 and hip_bloom > hip_rest and
		absf(ads_bloom) < 1e-6 and ads_spread == Vector2.ZERO and
		ads_cone == Vector2.ZERO and identical)
	print("stance     [AK] hip_bloom=%.2f ads_bloom=%.2f ads_spread=(%.2f,%.2f) pattern_identical=%s -> %s" % [
		hip_bloom, ads_bloom, ads_spread.x, ads_spread.y,
		"yes" if identical else "NO", "PASS" if passed else "FAIL"])
	return passed

## Regression 9: Attachment.resolve() must be a faithful full copy. The historic
## bug was hand-copying fields, which silently reset every untouched field to the
## class default ("equipping an attachment resets my weapon tuning").
func _resolve_preserves_fields() -> bool:
	var base := load(PATHS[0]) as RecoilProfile
	# (a) resolving with NO attachments must reproduce the base field-for-field
	var empty := Attachment.resolve(base, [])
	var diff := 0
	for d in base.get_property_list():
		var n := String(d["name"])
		if n in ["resource_name", "resource_path", "script", "Resource"]:
			continue
		var a = base.get(n)
		var b = empty.get(n)
		if a is Array and b is Array:
			if a.size() != b.size():
				diff += 1
			else:
				for i in range(a.size()):
					if a[i] != b[i]:
						diff += 1
		elif a != b:
			diff += 1
	# (b) with attachments, fields the catalogue does NOT scale must survive
	var att := load("res://demo/attachments/compensator.tres") as Attachment
	var built := Attachment.resolve(base, [att])
	var survives := (
		built.climb_soft_cap == base.climb_soft_cap and
		built.climb_hard_cap == base.climb_hard_cap and
		built.recovery_fraction == base.recovery_fraction and
		built.recovery_curve == base.recovery_curve and
		built.viewkick_damping == base.viewkick_damping and
		built.kick_rise_time == base.kick_rise_time and
		built.fire_rate == base.fire_rate)
	var passed := diff == 0 and survives
	print("resolve    [AK] differing=%d untouched_survive=%s -> %s" % [
		diff, "yes" if survives else "NO", "PASS" if passed else "FAIL"])
	return passed

## Regression 10: the three gameplay attachment axes must each move ONLY their
## own axis, on a table weapon AND on a function weapon.
##   recoil    (vertical grip)  -> climb shrinks, horizontal span untouched
##   stability (angled grip)    -> horizontal span shrinks, climb untouched
##   hip-fire  (compensator)    -> the spread cone shrinks
func _attachment_axes() -> bool:
	var all_ok := true
	for p in _profiles():
		var base := Attachment.resolve(p, [])
		var vg := Attachment.resolve(p, [load("res://demo/attachments/vertical_grip.tres") as Attachment])
		var ag := Attachment.resolve(p, [load("res://demo/attachments/angled_grip.tres") as Attachment])
		var cp := Attachment.resolve(p, [load("res://demo/attachments/compensator.tres") as Attachment])
		var n := 20
		var b := RecoilController.simulate_offsets(base, n)
		var v := RecoilController.simulate_offsets(vg, n)
		var a := RecoilController.simulate_offsets(ag, n)
		var base_up := absf(b[n - 1].y)
		var base_side := _span_x(b)
		var vg_up := absf(v[n - 1].y)
		var vg_side := _span_x(v)
		var ag_up := absf(a[n - 1].y)
		var ag_side := _span_x(a)
		var base_cone := RecoilController.simulate_spreads(base, 1)[0]
		var cp_cone := RecoilController.simulate_spreads(cp, 1)[0]
		# Weapons whose horizontal scatter lives in the RNG rather than in the
		# pattern (Vandal: pattern x is 0 everywhere) have no pattern-side span to
		# compare; their side axis is tuned through hip-fire spread instead.
		var side_applies := base_side > 1.0
		var passed := (
			vg_up < base_up * 0.85 and absf(ag_up - base_up) < 1e-6 and
			(not side_applies or absf(vg_side - base_side) < 1e-6) and
			(not side_applies or ag_side < base_side * 0.85) and
			cp_cone.x < base_cone.x * 0.95)
		all_ok = all_ok and passed
		print("attch axes [%s] up %.1f->vg %.1f/ag %.1f  side %.1f->vg %.1f/ag %.1f  cone %.1f->%.1f -> %s" % [
			p.weapon_name, base_up, vg_up, ag_up, base_side, vg_side, ag_side,
			base_cone.x, cp_cone.x, "PASS" if passed else "FAIL"])
	return all_ok

## Regression 11: no weapon may spray a straight vertical line. Two of them
## (Vandal, Pistol) literally did -- their authored pattern had x = 0 on every
## entry, which is not a spray, it is an elevator. Every gun needs some
## horizontal signature in its ballistics.
func _spray_is_not_a_straight_line() -> bool:
	var all_ok := true
	for p in _profiles():
		var path := RecoilController.simulate_offsets(p, 30)
		var lo := 0.0
		var hi := 0.0
		for q in path:
			lo = minf(lo, q.x)
			hi = maxf(hi, q.x)
		var span := hi - lo
		var passed := span > 3.0
		all_ok = all_ok and passed
		print("not-vert   [%s] horizontal span=%.1fpx over 30 rounds -> %s" % [
			p.weapon_name, span, "PASS" if passed else "FAIL"])
	return all_ok

## Regression 12: the tail of a long burst must keep climbing AND keep moving.
## The AK used to degenerate into a purely vertical line past its 30-round table
## (sustain_delta was (0, 2) with no sway), and the climb cap used to flatten it
## out entirely. A sustained burst has to stay a spray that goes somewhere.
func _long_tail_keeps_climbing() -> bool:
	var all_ok := true
	for p in _profiles():
		var path := RecoilController.simulate_offsets(p, 90)
		var first_mag := path[29]
		var mag_end := path[59]
		var long_end := path[89]
		# horizontal movement must continue past the authored table
		var tail_lo := 0.0
		var tail_hi := 0.0
		for i in range(30, 90):
			tail_lo = minf(tail_lo, path[i].x)
			tail_hi = maxf(tail_hi, path[i].x)
		var tail_span := tail_hi - tail_lo
		var passed := (long_end.y > mag_end.y and mag_end.y > first_mag.y and tail_span > 1.5)
		all_ok = all_ok and passed
		print("long-tail  [%s] y 30->60->90 = %.1f->%.1f->%.1f  tail span=%.1f -> %s" % [
			p.weapon_name, first_mag.y, mag_end.y, long_end.y, tail_span,
			"PASS" if passed else "FAIL"])
	return all_ok

## Advance one full shot interval so a fired kick has time to land (mirroring
## what a real game loop does between two rounds).
func _tick_shot_interval(c: RecoilController) -> void:
	var dt := 1.0 / 60.0
	var need := 1.0 / maxf(c.profile.fire_rate, 0.1)
	var steps := maxi(int(ceili(need / dt)), 1)
	for i in range(steps):
		c._process(dt)

func _span_x(path: Array[Vector2]) -> float:
	var lo := 0.0
	var hi := 0.0
	for p in path:
		lo = minf(lo, p.x)
		hi = maxf(hi, p.x)
	return hi - lo

## Fire 20 shots and collect the deterministic pattern offsets. These must be
## stance-independent: the stance only gates RANDOM spread, never the ballistics.
func _offsets_for(p: RecoilProfile, use_ads: bool) -> Array[Vector2]:
	var c := RecoilController.new()
	c.profile = p
	add_child(c)
	if use_ads:
		c.set_ads(true)
	c.reset_pattern()
	c.begin_fire()
	var out: Array[Vector2] = []
	for i in range(20):
		c.fire()
		out.append(c.get_pattern_offset())
		_tick_shot_interval(c)
	c.queue_free()
	return out

func _profiles() -> Array[RecoilProfile]:
	var arr: Array[RecoilProfile] = []
	for path in PATHS:
		arr.append(load(path) as RecoilProfile)
	return arr

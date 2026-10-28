class_name RecoilController
extends Node

## Core recoil state machine. Deliberately decoupled from any camera / UI:
## it only tracks heat, bloom, the recoil offset and a springy viewkick, and
## exposes getters the consumer (crosshair / camera) reads each frame.
##
## Three layers are kept separate, exactly like modern tactical shooters:
##   1. recoil offset  -> the learnable spray (where bullets actually go).
##                        Fully DETERMINISTIC, so it is predictable & previewable.
##   2. viewkick       -> immediate visual kick that springs back (pure feel)
##   3. bloom + spread -> spread cone + per-bullet RNG. roll_spread() gives the
##                        scatter of ONE bullet and is NEVER accumulated into the
##                        offset (accumulated RNG = random walk = unpreviewable).
##
## In a 3D FPS you'd apply get_aim_displacement() to the camera rotation
## (pitch = -y, yaw = x) and use get_bloom() as the raycast spread cone.
## In this 2D demo we just move a crosshair with it.
##
## ---------------------------------------------------------------------------
## RECOIL OFFSET MODEL (permanent / temporary split)
## ---------------------------------------------------------------------------
## This mirrors how CS:GO actually composites recoil:
##     visual = view_punch  +  aim_punch * recoil_scale * view_recoil_tracking
## i.e. only a FRACTION of the aim punch is ever given back, the rest is
## permanent displacement the player must compensate by hand.
##
## So every shot's kick is split in two parts:
##   * permanent = kick * (1 - recovery_fraction)  -> NEVER returns.
##                   This is why, after a full magazine with no compensation,
##                   the view is still pointing UP.
##   * temporary = kick * recovery_fraction         -> settles back to zero
##                   after `reset_delay`, eased by `recovery_curve`.
##
## Splitting per shot (instead of recovering a percentage of the running
## total) also removes a nasty artefact of the old model: when tap-firing,
## every shot multiplied the residual by (1 - fraction), so rapid tapping
## decayed recoil faster than the pattern implies. With the split the
## permanent part can only ever grow, and the temporary part is exactly the
## kick that is allowed to fall back.
##
## ---------------------------------------------------------------------------
## WHO INTERPOLATES THE KICK BETWEEN TWO BALLISTIC SAMPLES?  -> THE FRAMEWORK
## ---------------------------------------------------------------------------
## A shot's recoil is not a teleport: the impulse travels over tens of
## milliseconds. The Ubisoft/GDC "layered weapon response" material describes
## the industry answer -- author a SHORT CURVE per shot, accumulate those curves
## during sustained fire, and let a recovery curve remove them again.
##
## So the interpolation lives HERE, in the shooting system, not in the consumer:
##   * the framework already owns the states it needs (per-shot target, the
##     rise timer, the settle progress) -- a consumer would have to duplicate
##     the split/climb/settle maths to interpolate correctly, and any copy
##     drifts (that is exactly how the preview diverged from the live spray);
##   * the consumer should not have to know that ballistics are sampled per
##     shot at all: it ticks the controller and reads one offset.
##
## `fire()` therefore only moves the TARGET; `_process()`/`_advance_rise()`
## walks the APPLIED offset toward it every frame. Every tick the consumer gets
## the crosshair offset the shooting system wants right now -- during the kick
## AND during the settle. Tuning stays data (kick_rise_time / kick_rise_curve).

signal shot_fired(result: Dictionary)

@export var profile: RecoilProfile

var _heat := 0
var _bloom := 0.0
var _ads := false                    ## aiming (ADS) stance: kills random spread

## Permanent recoil displacement:
##   _carry     = permanent offset left behind by PREVIOUS bursts (never resets
##                until reset_pattern()). This is what makes burst #2 start from
##                where burst #1 left the view -- pointing higher.
## The current burst's permanent share is one of the two layers below. The soft
## ceiling (`climb_soft_cap` + `climb_floor`) only damps the gain of one spray,
## so a fresh burst always climbs again instead of being frozen by a lifetime
## total that already hit the ceiling.
var _carry := Vector2.ZERO
## The recoil offset exists in TWO layers per shot:
##   _permanent/_temporary        = APPLIED: where the aim actually is now.
##                                  This is what the crosshair and the bullet
##                                  impact read. It eases toward the target over
##                                  `kick_rise_time` -- it never teleports.
##   _permanent_target/_temporary_target
##                               = TARGET: where the shots fired so far want
##                                  the aim to be. Set instantly by fire().
## Keeping them apart is what makes the kick a short TRAVEL instead of a jump.
var _permanent := Vector2.ZERO
var _temporary := Vector2.ZERO
var _permanent_target := Vector2.ZERO
var _temporary_target := Vector2.ZERO
var _temp_base := Vector2.ZERO        ## temporary snapshot at the last shot
var _burst_open := false              ## a burst is in progress (not yet folded)
var _time_since_fire := 999.0
var _recovery_p := 0.0                ## normalized settle progress (0..1)

## Interpolation state for the kick currently travelling (rise).
var _rise_from_perm := Vector2.ZERO
var _rise_from_temp := Vector2.ZERO
var _rise_t := 0.0
var _rise_dur := 0.0
## The viewkick rides the SAME rise: an impulse added all at once snaps the
## muzzle, which is the visible half of the "teleporting recoil" problem. It is
## fed in progressively instead, so the punch still peaks but arrives over the
## same travel time as the ballistic kick.
var _vk_pending := Vector2.ZERO
var _vk_applied := Vector2.ZERO

var _rng := RandomNumberGenerator.new()
var _viewkick := Spring2D.new()
var _firing := false

func _ready() -> void:
	if profile == null:
		push_warning("RecoilController: no profile assigned")
	else:
		# A weapon always has SOME inaccuracy at rest (the resting / hip-fire
		# cone). Bloom starts here instead of at 0 -- otherwise the first shot out
		# of rest would be perfectly accurate and `base_spread` would be a dead
		# parameter that silently does nothing.
		_bloom = profile.base_spread
	_rng.randomize()

func _process(delta: float) -> void:
	if profile == null:
		return

	# --- bloom recovery (grows per shot, decays at rest) ---
	# Floors at `base_spread`, NOT at 0: a settled weapon is still only as
	# accurate as its resting cone. Recovering to 0 would make `base_spread`
	# meaningless and give a laser-accurate first shot after every settle.
	_bloom = maxf(_bloom - profile.spread_recovery_rate * delta, profile.base_spread)

	# --- viewkick spring return (target stays 0: this layer is pure feel) ---
	_viewkick.stiffness = profile.viewkick_recovery
	_viewkick.damping = profile.viewkick_damping
	_viewkick.update(delta)

	# --- temporary recoil settle (only after the fire grace period) ---
	# The permanent part is intentionally NOT touched here: it is the whole
	# point of the split. Only the temporary share eases back to zero.
	# The settle drives the TARGET; the applied offset follows it through the
	# same rise step below, so everything the consumer reads stays continuous.
	_time_since_fire += delta
	if not _firing and _time_since_fire > profile.reset_delay:
		if _temporary_target != Vector2.ZERO:
			_recovery_p = minf(_recovery_p + profile.recovery_rate * delta, 1.0)
			var e := _ease(_recovery_p, profile.recovery_curve)
			_temporary_target = _temp_base.lerp(Vector2.ZERO, e)
			if _recovery_p >= 1.0:
				_temporary_target = Vector2.ZERO
		# close the burst: its permanent part becomes carry (view stays high),
		# the spray index resets so the next burst restarts at shot 1.
		_fold_burst()
		_heat = 0

	# --- kick rise: the applied offset travels toward the target each frame ---
	_advance_rise(delta)

## Per-frame "tick": move the APPLIED offset toward the TARGET. This is what
## turns one shot's impulse into a short visible TRAVEL instead of an instant
## teleport of the crosshair, and it is also how the settle (whose target is
## being eased to zero above) reaches the consumer smoothly.
##
## Every tick therefore reports the crosshair offset the shooting system wants
## RIGHT NOW -- the consumer just reads get_aim_displacement(), it never has to
## interpolate between two ballistic samples itself.
func _advance_rise(delta: float) -> void:
	var f := 1.0
	if _rise_dur > 0.0 and _rise_t < _rise_dur:
		_rise_t += delta
		f = _ease(clampf(_rise_t / _rise_dur, 0.0, 1.0), profile.kick_rise_curve)
		_permanent = _rise_from_perm.lerp(_permanent_target, f)
		_temporary = _rise_from_temp.lerp(_temporary_target, f)
	elif _permanent != _permanent_target or _temporary != _temporary_target:
		# rise finished (or disabled): lock onto the target
		_permanent = _permanent_target
		_temporary = _temporary_target
	# feed the viewkick in over the same travel, so it punches instead of snapping
	if _vk_applied != _vk_pending:
		var want := _vk_pending * f
		var add := want - _vk_applied
		if add.length_squared() > 1e-12:
			_viewkick.impulse(add)
		_vk_applied = want

## How long one shot's kick takes to travel. Clamped to the shot interval so a
## fast weapon cannot start the next round before the previous kick landed --
## otherwise the impacts would drift away from the preview, which is built from
## the settled positions.
func _rise_duration() -> float:
	var t := profile.kick_rise_time
	if t <= 0.0:
		return 0.0
	if profile.fire_rate > 0.0:
		t = minf(t, 0.9 / profile.fire_rate)
	return t

## End the current burst: hand its permanent displacement to `_carry` so it is
## no longer subject to the burst ceiling (which only damps one spray's climb)
## and the next burst can climb again on top of it.
func _fold_burst() -> void:
	if not _burst_open:
		return
	# Subtract the folded amount from BOTH layers (and from the rise start) so
	# an in-flight rise keeps its shape -- folding only the target would make
	# the crosshair jump by whatever the rise had not delivered yet.
	var p := _permanent_target
	_carry += p
	_permanent_target -= p
	_permanent -= p
	_rise_from_perm -= p
	_burst_open = false

func begin_fire() -> void:
	_firing = true

func end_fire() -> void:
	_firing = false

## Register one logical shot. Call at the weapon's fire_rate cadence.
##
## ORDER OF EVENTS (this is the whole point of the function):
##   1. close out the previous shot's kick rise
##   2. snapshot the muzzle state -- the round leaves the barrel NOW
##   3. only then apply this shot's kick, and start its rise
##   4. bloom grows afterwards (this shot's inaccuracy is not its own problem)
##
## Step 2 before step 3 is what makes shot #1 land exactly on the aim point.
## Sampling the offset AFTER the kick (the old order) put every round one kick
## ahead of where the player was actually pointing.
func fire() -> Dictionary:
	if profile == null:
		return {}
	_time_since_fire = 0.0
	var idx := _heat
	if idx == 0:
		# shot 1 of a new burst: fold the previous burst first (safety net for
		# the case where the grace period elapsed without a _process frame).
		_fold_burst()
		_burst_open = true
	_heat += 1

	# --- 1. finish the previous rise ----------------------------------------
	# By construction the previous kick has already landed (the rise is clamped
	# to the shot interval), so this only closes a sub-pixel remainder -- it is
	# NOT the jump. If the player taps faster than fire_rate it also guarantees
	# the impact below matches the preview instead of lagging behind it.
	_permanent = _permanent_target
	_temporary = _temporary_target

	# --- 2. the bullet leaves: snapshot what it inherits ---------------------
	var impact_offset := get_pattern_offset()
	var impact_cone := get_spread_radius()
	var jitter := _roll_in(impact_cone)

	# --- 3. then the kick ---------------------------------------------------
	# Pattern sampling (delegated to the profile, which knows its source) is
	# DETERMINISTIC on purpose. Random spread is rolled separately (above) and
	# applied to the bullet IMPACT, never accumulated into the recoil offset --
	# accumulating RNG turns the spray into a random walk that no fixed pattern
	# (and therefore no preview) can ever match.
	var delta_offset := profile.pattern_delta(idx)

	# permanent / temporary split + soft burst ceiling
	var st := split_shot(profile, _permanent_target, _temporary_target, delta_offset)
	_permanent_target = st[0]
	_temporary_target = st[1]

	# the temporary share that is allowed to settle, snapshotted at this shot
	_temp_base = _temporary_target
	_recovery_p = 0.0

	# start the rise: the aim travels from the position it just fired from to
	# the kick's destination, over kick_rise_time, instead of teleporting.
	_rise_from_perm = _permanent
	_rise_from_temp = _temporary
	_rise_t = 0.0
	_rise_dur = _rise_duration()
	if _rise_dur <= 0.0:
		_permanent = _permanent_target
		_temporary = _temporary_target

	# --- 4. bloom grows after the round has left -----------------------------
	_bloom = minf(_bloom + profile.spread_per_shot, profile.max_spread)

	# --- viewkick impulse (visual punch, springs back fully) ---
	var vk_h := profile.viewkick_horizontal + _rng.randf_range(-profile.viewkick_rng, profile.viewkick_rng)
	var vk_v := profile.viewkick_vertical + _rng.randf_range(-profile.viewkick_rng, profile.viewkick_rng)
	_vk_pending = Vector2(vk_h, vk_v)
	_vk_applied = Vector2.ZERO
	if _rise_dur <= 0.0:
		_viewkick.impulse(_vk_pending)
		_vk_applied = _vk_pending

	var result := {
		"heat": _heat,
		"pattern_delta": delta_offset,
		## Where THIS round lands, relative to the player's aim point. Read this
		## (not get_pattern_offset()) for impacts -- it is the pre-kick state.
		"impact_offset": impact_offset,
		## The (h, v) spread ellipse this round was rolled in.
		"impact_cone": impact_cone,
		## The already-rolled scatter: impact = aim + impact_offset + spread.
		## Use THIS rather than calling roll_spread() after fire() -- by then
		## bloom has already grown to the NEXT shot's cone.
		"spread": jitter,
		"pattern_offset": _permanent_target + _temporary_target,  ## post-kick
		"bloom": get_bloom(),      ## stance-scaled, same value get_bloom() reports
		"viewkick": _viewkick.value,
	}
	shot_fired.emit(result)
	return result

## The ONE authoritative spread ellipse (half-axes h = horizontal, v = vertical)
## of the bullet that is about to leave. Three consumers read THIS SAME number
## so they can never disagree:
##   * the impact roll        (roll_spread / fire()'s "spread")
##   * the crosshair gap/ring (demo feeds it to Crosshair.set_spread)
##   * the preview envelope   (RecoilController.simulate_spreads)
## (0, 0) while aiming -- the bullet follows the crosshair exactly.
func get_spread_radius() -> Vector2:
	if profile == null:
		return Vector2.ZERO
	var s := _spread_scale()
	var rng := profile.spread_rng_axes() * s
	var b := _bloom * s
	return Vector2(b + rng.x, b + rng.y)

## Uniform sample inside an ellipse of half-axes `cone`. NOT accumulated into
## the recoil offset: the dots scatter AROUND the pattern line instead of
## wandering off it, which is what keeps the deterministic spray (and any
## preview drawn from it) actually predictive.
func _roll_in(cone: Vector2) -> Vector2:
	if cone.x <= 0.0 or cone.y <= 0.0:
		return Vector2.ZERO
	var a := _rng.randf() * TAU
	var m := sqrt(_rng.randf())     ## sqrt = uniform over the area, not the centre
	return Vector2(cos(a) * m * cone.x, sin(a) * m * cone.y)

## Random spread offset for the bullet that is about to land.
## Fire() already rolls this for the round it reports (result["spread"]) using
## the cone AT THAT INSTANT; calling this afterwards samples the NEXT shot's
## cone, because bloom has grown since.
func roll_spread() -> Vector2:
	return _roll_in(get_spread_radius())

## Apply ONE shot's kick to the accumulated permanent / temporary parts, with the
## burst ceiling acting as a SOFT knee. Pure function -- returns [perm, temp].
##
## This is the SINGLE place the split + ceiling maths lives. fire() and
## simulate_offsets() both call it, so the live spray, the bullet impacts and
## the preview can never drift apart.
##
## The gain is damped from 1.0 down to `climb_floor` (30% by default) as the
## burst approaches `climb_soft_cap`, and STAYS at `climb_floor` beyond it. Note what
## is NOT done here: the accumulated offset is never scaled back to the limit.
## Doing that (the old behaviour) hard-clamped the spray, so from the moment the
## ceiling was reached every further shot cancelled itself out and the crosshair
## simply froze -- "hold the trigger and the recoil stops working". Real games
## damp the accumulation instead and only use a clamp as a safety net
## (see WeaponMechanics' Damping vs Max_Accumulation, Kokku's Max recoil
## distance): the climb slows down, it never stops.
##
## The knee is PER AXIS. One scalar gain taken from |perm+temp| couples the two
## gameplay stats: fitting a vertical grip shrinks the climb, the shorter total
## then raises the gain, and the raised gain WIDENS the horizontal sway -- so
## "recoil -30%" would quietly make the gun swing more. Vertical recoil and
## horizontal stability are separate stats, so they are capped separately.
static func split_shot(p: RecoilProfile, perm: Vector2, temp: Vector2, kick: Vector2) -> Array[Vector2]:
	var rec := clampf(p.recovery_fraction, 0.0, 1.0)
	var g := _climb_gains(p, perm + temp)
	perm += Vector2(kick.x * (1.0 - rec) * g.x, kick.y * (1.0 - rec) * g.y)
	temp += Vector2(kick.x * rec * g.x, kick.y * rec * g.y)
	# Optional hard safety net: a true ceiling that bounds runaway growth (e.g. a
	# held trigger in a demo with no magazine limit) WITHOUT freezing it -- the
	# offset is pulled back to the cap each shot but still moves by ~kick, so it
	# hovers at the cap instead of sticking. Also per axis, for the same reason.
	# 0 = disabled.
	if p.climb_hard_cap > 0.0:
		var cap := p.climb_hard_cap
		perm.x = clampf(perm.x, -cap, cap)
		perm.y = clampf(perm.y, -cap, cap)
		temp.x = clampf(temp.x, -cap, cap)
		temp.y = clampf(temp.y, -cap, cap)
	return [perm, temp]

## Per-axis damping of one shot's kick: 1.0 at the origin, easing to
## `climb_floor` as that axis approaches the ceiling.
static func _climb_gains(p: RecoilProfile, acc: Vector2) -> Vector2:
	var limit := p.climb_soft_cap
	if limit <= 0.0:
		return Vector2.ONE
	# climb_floor is the gain AT/OVER the ceiling. If it were 0, every further
	# shot would be multiplied by 0 -- the exact "hold the trigger and recoil
	# dies" freeze this soft knee exists to prevent. Guard it to a tiny
	# positive floor: the climb may slow down, it must never stop.
	var f := clampf(maxf(p.climb_floor, 0.01), 0.0, 1.0)
	return Vector2(
		lerpf(1.0, f, clampf(absf(acc.x) / limit, 0.0, 1.0)),
		lerpf(1.0, f, clampf(absf(acc.y) / limit, 0.0, 1.0)))

## Deterministic prediction of where each bullet LANDS while you hold the
## trigger -- identical maths to fire() (split + soft burst ceiling), no RNG
## and no settle (the temporary part has not started recovering while firing).
##
## Index i is the muzzle state at the moment round i+1 leaves, i.e. the
## accumulated offset of the FIRST i kicks (bullet first, then recoil). So
## index 0 is the origin: shot #1 goes exactly where you were aiming. That is
## also how every published spray-pattern chart is read.
##
## The demo's preview draws THIS instead of the raw pattern, which is what makes
## the picture match the real spray (raw cumulative sums ignore both the
## 85/15 split and the climb cap, so a long spray used to diverge completely).
static func simulate_offsets(p: RecoilProfile, shots: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if p == null or shots <= 0:
		return out
	out.append(Vector2.ZERO)      ## round #1: no kick applied yet
	var perm := Vector2.ZERO
	var temp := Vector2.ZERO
	for i in range(shots - 1):
		var st := split_shot(p, perm, temp, p.pattern_delta(i))
		perm = st[0]
		temp = st[1]
		out.append(perm + temp)
	return out

## The spread ellipse (h, v) of each bullet, in the same bullet-first order as
## simulate_offsets(): round #1 inherits the resting cone, every later round
## inherits the bloom accumulated by the shots before it. The preview envelope
## is drawn from this, so it is the same shape the impacts really scatter in.
static func simulate_spreads(p: RecoilProfile, shots: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if p == null or shots <= 0:
		return out
	var rng := p.spread_rng_axes()
	var b := p.base_spread
	out.append(Vector2(b + rng.x, b + rng.y))
	for i in range(shots - 1):
		b = minf(b + p.spread_per_shot, p.max_spread)
		out.append(Vector2(b + rng.x, b + rng.y))
	return out

## ===========================================================================
## CRITICAL CORRECTNESS RULE -- which offset feeds what
## ===========================================================================
## There are TWO consumers of the recoil state, and they must NOT be confused:
##
##   * BULLET IMPACTS follow `get_pattern_offset()`  (aka the "aim punch").
##     It is fully DETERMINISTIC (no viewkick, no RNG), so the spray is
##     learnable and the preview matches it shot-for-shot.
##
##   * THE CROSSHAIR / CAMERA VISUAL follows `get_aim_displacement()`, which is
##     get_pattern_offset() PLUS the springy `viewkick`. The viewkick is pure
##     feel -- it springs back and is NEVER allowed into the bullet impact point,
##     otherwise every shot would inherit a random ±viewkick jitter. This is the
##     exact CS:GO split:  visual = view_punch + aim_punch * scale * tracking.
##
## Rule of thumb: anything that decides WHERE a bullet lands uses
## get_pattern_offset(); anything that decides what the PLAYER SEES uses
## get_aim_displacement(). Do not feed viewkick into impacts.
## ===========================================================================

## Total recoil displacement (previous bursts + this burst, minus what settled).
## This is the AIM PUNCH -- what bullet impacts follow.
func get_pattern_offset() -> Vector2:
	return _carry + _permanent + _temporary

## Displacement that will NEVER be given back (the "aim punch"), including the
## permanent residue of every earlier burst.
func get_permanent_offset() -> Vector2:
	return _carry + _permanent

## How much of the current recoil is still going to settle back.
func get_temporary_offset() -> Vector2:
	return _temporary

## Total crosshair displacement from the player's intended aim point.
func get_aim_displacement() -> Vector2:
	return _carry + _permanent + _temporary + _viewkick.value

func get_viewkick() -> Vector2:
	return _viewkick.value

## Spread cone radius for the NEXT bullet, already stance-scaled: 0 when aiming
## (bullet is pinpoint), the live bloom value when hip-firing.
func get_bloom() -> float:
	return _bloom * _spread_scale()

## Aiming (ADS) stance. When on, ALL random spread disappears -- no bloom cone,
## no per-bullet RNG -- so the bullet lands exactly where the recoil-displaced
## crosshair points. The deterministic spray pattern is NOT affected, so you
## still have to control the recoil while aiming.
func set_ads(on: bool) -> void:
	_ads = on

func is_ads() -> bool:
	return _ads

## Multiplier applied to every random spread term (bloom cone + per-bullet RNG).
## Hip-fire = 1.0; aiming = `profile.ads_spread_mult` (0 = pinpoint).
func _spread_scale() -> float:
	if profile == null or not _ads:
		return 1.0
	return clampf(profile.ads_spread_mult, 0.0, 1.0)

func get_heat() -> int:
	return _heat

## Hard reset (e.g. on weapon switch or "clear"): forget the whole spray.
func reset_pattern() -> void:
	_heat = 0
	# bloom must go back to the resting cone too, not stay at whatever the last
	# spray left behind.
	if profile != null:
		_bloom = profile.base_spread
	_carry = Vector2.ZERO
	_permanent = Vector2.ZERO
	_temporary = Vector2.ZERO
	_permanent_target = Vector2.ZERO
	_temporary_target = Vector2.ZERO
	_temp_base = Vector2.ZERO
	_burst_open = false
	_time_since_fire = 999.0
	_recovery_p = 0.0
	_rise_from_perm = Vector2.ZERO
	_rise_from_temp = Vector2.ZERO
	_rise_t = 0.0
	_rise_dur = 0.0
	_vk_pending = Vector2.ZERO
	_vk_applied = Vector2.ZERO
	_viewkick.snap_to(Vector2.ZERO)

## Easing applied to the settle progress `p` (0..1). Drives the shape of the
## downward recovery so it is NOT uniform speed. See RecoilProfile.recovery_curve.
func _ease(p: float, curve: String) -> float:
	match curve:
		"linear":
			return p
		"ease_in":
			return p * p                          # 先慢后快 (gravity-like)
		"smooth":
			return p * p * (3.0 - 2.0 * p)        # smoothstep ease-in-out
		_:  # "ease_out" (default, recommended)
			var inv := 1.0 - p
			return 1.0 - inv * inv                # 先快后慢

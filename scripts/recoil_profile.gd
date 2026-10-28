class_name RecoilProfile
extends Resource

## Data-driven description of ONE weapon's recoil behaviour.
##
## Pure data -- no logic. All weapons share the same RecoilController;
## you only swap this resource (in the editor or by code). This is the
## "data-driven weapon" pattern every modern shooter uses (ScriptableObject
## in Unity, Resource here).
##
## Coordinate convention used by the whole framework:
##   * pattern x = horizontal, right is + (left is -)
##   * pattern y = vertical,   UP is +   (screen-space consumers flip y)

@export var weapon_name := "Weapon"

@export_enum("deterministic", "randomized") var pattern_mode := "deterministic"

## Incremental recoil delta applied per shot index: (x = horizontal, y = up).
## The controller ACCUMULATES these into a cumulative spray offset, so the
## nth entry is the kick of the nth bullet in a continuous spray.
## e.g. an AK-style "7" hook: climbs up, drifts right, then hooks left.
@export var pattern: Array[Vector2] = []

## If true, indices beyond pattern.size() wrap around (itch.io trick) so a
## long spray keeps cycling the same shape instead of freezing on the last entry.
## If false, the gun keeps kicking by `sustain_delta` past the table instead.
@export var loop_pattern := false

## Per-shot kick used once the authored `pattern` table is exhausted (and
## loop_pattern is off) -- the steady-state tail of a very long burst.
##
## Why this exists: an authored table covers ONE MAGAZINE (CS:GO ships a
## 30-entry table for the 30-round AK, and the index simply advances shot by
## shot while the trigger is held). If a spray runs past the table the recoil
## must NOT silently turn into zero -- that is exactly the "hold the trigger
## long enough and the gun stops kicking" bug. Keep this small but non-zero
## (e.g. (0, 2)) so a sustained burst keeps climbing, just more calmly.
@export var sustain_delta := Vector2(0.0, 2.0)

## Horizontal sway of that long tail. IMPORTANT: a purely vertical
## `sustain_delta` turns the whole tail into a straight vertical line -- past
## the table the gun climbs forever with zero sideways motion, which no real
## spray does and which reads as "the recoil became an elevator, not a spray".
## Give the tail a slow side-to-side sway instead (a few units, one cycle every
## `sustain_sway_period` rounds) and it still looks like a gun fighting you.
## 0 = tail goes straight up (only sensible for a genuinely vertical weapon).
@export var sustain_sway_amp := 0.0
@export var sustain_sway_period := 9.0   ## rounds per full left-right cycle

## ---------------------------------------------------------------------------
## Random bullet spread -- ONE authoritative ellipse, three consumers
## ---------------------------------------------------------------------------
## The scatter of a single bullet is an ELLIPSE with half-axes (h, v):
##
##     h = bloom + rng.x      v = bloom + rng.y
##
## `bloom` is the shared cone (grows per shot, decays at rest) and `rng` is the
## weapon's fixed per-bullet RNG. They are composed ONCE, here, so the three
## places that must agree can all read the same number:
##   1. the actual impact point  (RecoilController.roll_spread)
##   2. the crosshair gap / ring (demo passes get_spread_radius() to Crosshair)
##   3. the preview envelope     (RecoilController.simulate_spreads)
## Keeping three independent formulas for "how wide is the spread" is how the
## picture ends up lying about where bullets really go.
@export var horizontal_rng := 0.0   ## extra horizontal scatter (randomized)
@export var vertical_rng := 0.0     ## extra vertical scatter (randomized)
@export var pattern_randomness := 0.0  ## uniform jitter (deterministic)

## The per-bullet RNG half-axes, resolved from whichever mode is active.
## `randomized` uses the explicit per-axis values (Valorant-style wide flat
## cone); `deterministic` uses one uniform jitter.
func spread_rng_axes() -> Vector2:
	if pattern_mode == "randomized":
		return Vector2(horizontal_rng, vertical_rng)
	return Vector2(pattern_randomness, pattern_randomness)

## Which representation backs the spray pattern.
##   "array"    : per-shot deltas indexed by heat (CS:GO / Valorant style; authored, learnable)
##   "function" : closed-form cumulative offset sampled by heat (procedural / physics style;
##                defined for ANY magazine size, easy to scale with attachments)
@export_enum("array", "function") var pattern_source := "array"

## Functional pattern parameters (used when pattern_source == "function").
@export var func_climb_amp := 6.0
@export var func_climb_rate := 0.5
@export var func_sway_amp := 3.0
@export var func_sway_freq := 0.6
@export var func_sway_phase := 0.0
@export var func_drift := Vector2.ZERO

## Bloom / spread (screen units). Crosshair gap grows as bloom grows; the
## actual bullet lands uniformly inside a disk of this radius.
## `base_spread` is the weapon's RESTING inaccuracy -- it is both the starting
## bloom and the floor bloom recovers down to (never 0), so the first shot out
## of rest is not laser-accurate.
@export var base_spread := 7.0
@export var max_spread := 55.0
@export var spread_per_shot := 4.0
@export var spread_recovery_rate := 55.0  # units recovered per second

## Firing stance: how much of the RANDOM spread survives while AIMING (ADS).
##
##   0.0 (default) = pinpoint: no bloom cone and no per-bullet RNG at all, so the
##                   bullet lands exactly where the recoil-displaced crosshair
##                   points ("the bullet follows the crosshair").
##   1.0            = hip-fire behaviour (full random spread) even when aiming.
##
## IMPORTANT: this scales ONLY the random spread. The deterministic ballistics
## (the spray pattern / recoil offset) are identical in both stances -- you still
## have to control the recoil when aiming, there is just no random deviation.
## Raise above 0 only for weapons that stay slightly imprecise even when aimed.
@export_range(0.0, 1.0, 0.01) var ads_spread_mult := 0.0

## ---------------------------------------------------------------------------
## Kick rise: the SHORT TRAVEL of one shot's recoil (no teleporting)
## ---------------------------------------------------------------------------
## A real gun does not teleport the muzzle to the new position at the instant
## the round leaves -- the impulse travels over a few tens of milliseconds. The
## Ubisoft/GDC "layered weapon response" material describes exactly this: author
## a SHORT CURVE per shot, accumulate the curves during sustained fire, and let
## the recovery curve remove them again.
##
## So the controller keeps two layers per shot:
##   target  = where this shot's kick wants the aim to end up (set instantly)
##   applied = where the aim actually is right now, easing toward `target`
##
## `kick_rise_time` is how long that travel takes. It is clamped to the shot
## interval (0.9 / fire_rate) so a fast weapon cannot start the next round
## before the previous kick landed -- otherwise impact points would drift away
## from the preview, which is built from the settled positions.
##
## 0 disables the interpolation (instant jump -- the old behaviour).
@export var kick_rise_time := 0.05
## Shape of one shot's rise: "ease_out" punches hard then eases onto the target
## (recommended), "linear" is constant-speed, "ease_in" ramps up.
@export_enum("ease_out", "ease_in", "smooth", "linear") var kick_rise_curve := "ease_out"

## Per-shot viewkick impulse (springs back via Spring2D). Up + horizontal + RNG.
## This is the VISUAL recoil (camera/weapon kick) -- a feel tool, distinct from
## the deterministic spray pattern. It gives the shot its "punch".
@export var viewkick_vertical := 9.0
@export var viewkick_horizontal := 4.0
@export var viewkick_rng := 2.5

## Spring tuning for the viewkick return. Lower damping = more overshoot/settle
## (heavier, punchier feel); higher = snappier, more robotic. ~2*sqrt(stiffness)
## is critical damping, so keep this a bit below that for a satisfying bounce.
@export var viewkick_recovery := 115.0  ## spring stiffness for the return
@export var viewkick_damping := 17.0    ## spring damping for the return

## ---------------------------------------------------------------------------
## Spray recovery: permanent / temporary split (CS:GO-style aim punch).
## ---------------------------------------------------------------------------
## Reference (CS:GO, per analysis of mAimPunchAngle / mViewPunchAngle):
##     visual = view_punch + aim_punch * recoil_scale * view_recoil_tracking
## `view_recoil_tracking` is ~0.45, i.e. only PART of the aim punch is ever
## given back -- the remainder is permanent displacement the player must pull
## down manually. That is why, after a full magazine without compensation, the
## view is still pointing UP instead of returning to the start point.
##
## Here every shot's kick is split into:
##   permanent = kick * (1 - recovery_fraction)  -> never returns
##   temporary = kick * recovery_fraction        -> settles after reset_delay
##
## `recovery_fraction` is the share of ONE shot's kick that is allowed to fall
## back. Keep it small (0.10 - 0.25): it is a *settle*, not a return to origin.
##   e.g. 0.15 -> 85% of the climb stays as residual upward aim.
##
## The split is applied per shot on purpose: recovering a percentage of the
## running total would multiply the residual down on every tap-fired shot.
@export var reset_delay := 0.12      ## grace period (s) after last shot before recovery + pattern reset
## Shape of the downward settle after you stop firing. Constant-speed ("linear")
## recovery is exactly what feels dead; real shooters ease it.
##   "ease_out" : fast at first, slows as it nears the residual   (先快后慢, recommended)
##   "ease_in"  : slow at first, accelerates downward             (先慢后快, gravity-like)
##   "smooth"   : smoothstep ease-in-out                         (smooth)
##   "linear"   : constant speed (legacy uniform behaviour)
## `recovery_rate` controls overall speed: it takes ~1/recovery_rate seconds
## to fully settle to the residual target (the partial, still-up position).
@export_enum("ease_out", "ease_in", "smooth", "linear") var recovery_curve := "ease_out"
@export var recovery_rate := 0.9     ## recovery speed: ~1/recovery_rate seconds to fully settle
@export var recovery_fraction := 0.15 ## share of EACH shot's kick that may settle back (rest is permanent)

## A SOFT ceiling on how far ONE burst climbs (same units as the pattern) --
## the "max recoil distance" every weapon designer exposes, to stop the view
## from rotating to an unnatural angle.
##
## It is soft on purpose. Once the burst reaches the ceiling the per-shot gain
## is damped down to `climb_floor` (30% by default) but never to zero, so a held
## trigger always keeps kicking. This is exactly what we WANT: the climb slows,
## it never stops -- a hard clamp that scales the accumulated offset back to the
## limit on every shot is the "hold the trigger and recoil dies" bug.
##
## This limits the reach of the CURRENT burst only. Once you stop firing, that
## burst's permanent part is folded into a "carry" that is NOT capped, so the
## next burst starts from where the previous one left the view and climbs again
## (in CS you keep pointing higher after every magazine you spray without
## compensating). 0 disables the ceiling entirely (pure linear climb).
@export var climb_soft_cap := 60.0

## Fraction of the per-shot kick that is STILL applied at/over `climb_soft_cap`.
## 0.3 = "the climb keeps going, at 30% speed". Must stay > 0.
@export_range(0.0, 1.0, 0.01) var climb_floor := 0.3

## OPTIONAL hard safety net (default 0 = off). A true ceiling that bounds
## pathological growth -- e.g. an unattended held trigger in a demo with no
## magazine limit -- WITHOUT freezing it. When the accumulated offset exceeds
## this, it is pulled back to the limit each shot but still moves by ~kick, so it
## hovers at the cap instead of sticking. Set it WELL ABOVE `climb_soft_cap`
## (e.g. 2x) so it only ever catches runaway growth, never normal sprays.
@export var climb_hard_cap := 0.0

## Fire control.
@export var fire_rate := 10.0  ## shots per second

## Cumulative aim offset after `n` shots for the *functional* pattern source.
## Defined for ANY n, so magazine size is never a limit:
##   v = climb_amp * (1 - e^(-climb_rate * n)) + drift.y * n
##   h = sway_amp * sin(sway_freq * n + sway_phase) + drift.x * n
func _func_cumulative(n: int) -> Vector2:
	var nf := float(n)
	var v := func_climb_amp * (1.0 - exp(-func_climb_rate * nf)) + func_drift.y * nf
	var h := func_sway_amp * sin(func_sway_freq * nf + func_sway_phase) + func_drift.x * nf
	return Vector2(h, v)

## Per-shot delta at `index` for the *array* pattern source.
##
## The authored table is sized for ONE MAGAZINE (CS:GO's AK table is 30 entries
## for a 30-round magazine). Past the end the recoil must never fall to zero --
## see `sustain_delta`. Two behaviours:
##   * loop_pattern = true  -> wrap the table (a longer spray repeats the shape)
##   * loop_pattern = false -> keep kicking at `sustain_delta` (steady state)
func _array_delta(n: int) -> Vector2:
	if pattern.is_empty():
		return _sustain(0)
	if n < pattern.size():
		return pattern[n]
	if loop_pattern:
		return pattern[n % pattern.size()]
	return _sustain(n - pattern.size())

## The steady-state kick for the k-th round past the authored table: the fixed
## `sustain_delta` plus a slow horizontal sway, so the tail of a very long burst
## is still a spray and not a vertical elevator.
func _sustain(k: int) -> Vector2:
	if sustain_sway_amp == 0.0:
		return sustain_delta
	var a := TAU * float(k + 1) / maxf(sustain_sway_period, 1.0)
	return sustain_delta + Vector2(sin(a) * sustain_sway_amp, 0.0)

## Per-shot delta at `index`, dispatching on the active pattern source.
## Deterministic (no RNG) -- RNG is applied separately by RecoilController.fire().
## Shared by both fire() and predict_path(), so the live spray and the preview
## always agree.
func pattern_delta(index: int) -> Vector2:
	if pattern_source == "function":
		return _func_cumulative(index + 1) - _func_cumulative(index)
	return _array_delta(index)

## Editor-only warnings shown on the Resource so mis-tuning is caught at author
## time, not at runtime. These are the silent no-op traps: a parameter that is
## completely ignored because another mode is active.
func _get_configuration_warnings() -> PackedStringArray:
	var w: PackedStringArray = []
	if pattern_source == "function":
		if loop_pattern:
			w.append("loop_pattern has no effect when pattern_source = 'function' (use the func_* parameters instead).")
		if not pattern.is_empty():
			w.append("pattern array is ignored when pattern_source = 'function' (use the func_* parameters instead).")
		if sustain_delta != Vector2.ZERO:
			w.append("sustain_delta is ignored when pattern_source = 'function'.")
	else:  # array source
		if pattern.is_empty() and sustain_delta == Vector2.ZERO:
			w.append("pattern is empty AND sustain_delta is zero: the spray will produce no recoil at all.")
	if climb_soft_cap > 0.0 and climb_floor <= 0.0:
		w.append("climb_floor = 0 with climb_soft_cap > 0 FREEZES the spray at the ceiling (per-shot gain drops to 0). Keep climb_floor > 0.")
	if kick_rise_time > 0.0 and fire_rate > 0.0 and kick_rise_time > 0.9 / fire_rate:
		w.append("kick_rise_time (%.3fs) is longer than 0.9/fire_rate (%.3fs): it is clamped to the shot interval, so the next round would fire before this kick lands." % [kick_rise_time, 0.9 / fire_rate])
	return w

## NOTE: there used to be a `predict_path()` here that summed `pattern_delta()`
## raw. That is NOT where bullets land, because it ignores the permanent /
## temporary split and `climb_soft_cap` -- so any preview built from it drifted away
## from the real spray the longer you held the trigger. Use
## `RecoilController.simulate_offsets()` instead, which runs the exact same
## maths as fire().

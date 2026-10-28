class_name Attachment
extends Resource

## A weapon attachment that *modifies* a RecoilProfile to produce a "build" --
## the resolved, post-attachment recoil profile the controller actually runs.
##
## Attachments are pure data (just like RecoilProfile). The framework composes
## a base profile + a set of attachments via Attachment.resolve(); the
## RecoilController never knows attachments existed. This is exactly how modern
## shooters expose a "trajectory preview" when you swap attachments in the
## loadout screen: they re-resolve the profile and redraw the predicted spray.
##
## ---------------------------------------------------------------------------
## THE STATS ARE THE GAMEPLAY WORDS, NOT THE MATHS WORDS
## ---------------------------------------------------------------------------
## A designer thinks in three numbers; the framework thinks in amplitudes:
##
##   recoil_mult    "vertical recoil"   < 1 = the gun climbs less
##   stability_mult "horizontal stability / 据枪稳定" < 1 = it swings less
##   hipfire_spread_mult "hip-fire spread"  < 1 = hip fire is tighter
##
## resolve() is the only place that translates them, and it routes by
## `pattern_source`. The reason BOTH representations survive the translation is
## that both are LINEAR IN THEIR AMPLITUDES:
##
##   * table (array) source -- a per-shot delta table is just samples of a
##     trajectory, and the cumulative offset is the SUM of those deltas. Scaling
##     each delta's y by k scales the whole summed trajectory's y by exactly k.
##     So "vertical recoil -30%" is literally `delta.y *= 0.7` per entry: the
##     shape (the AK's hook, the S-bend) is preserved, it just gets squashed on
##     that axis. Also scale `sustain_delta` (the tail past the table) or the
##     long burst would keep climbing at the old rate.
##
##   * function source -- the closed form is a sum of amplitude terms
##     (climb_amp, sway_amp, drift). Scaling the vertical amplitudes
##     (func_climb_amp, func_drift.y) and the horizontal ones (func_sway_amp,
##     func_drift.x) does the same job analytically, and stays correct for ANY
##     shot index because the formula is defined for all n.
##
## The important thing is where the transform is applied: on the AMPLITUDE
## (per-shot delta / curve coefficient), never on the accumulated result.
## Scaling the accumulated offset instead would fight the climb ceiling and the
## permanent/temporary split, and the preview would stop matching the live spray.
##
## Deliberately NOT modelled here: magazines, ammo, damage, drop, slots,
## incompatibilities. This is a ballistics-tuning layer, not a weapon system.

@export var attachment_name := "Attachment"
@export var slot := "Muzzle"   # Muzzle / Grip / Stock ... (display only)

## Vertical recoil. < 1 = more vertical stability: the gun climbs less.
## This is what a muzzle brake / vertical grip is for.
@export var recoil_mult := 1.0

## Horizontal stability ("据枪稳定"). < 1 = the spray swings less left/right.
## This is what an angled grip / compensator is for.
@export var stability_mult := 1.0

## Hip-fire spread: scales the resting cone, its growth per shot and its cap.
## < 1 = tighter hip fire. Aiming already zeroes spread, so ADS is unaffected.
@export var hipfire_spread_mult := 1.0

## Visual camera kick scale (feel only -- never moves the bullet).
@export var viewkick_mult := 1.0

## How fast the temporary share settles back after you stop firing.
## > 1 = the sight picture returns sooner.
@export var recovery_speed_mult := 1.0

## Fire control.
@export var fire_rate_mult := 1.0
@export var reset_delay_add := 0.0   # negative = pattern resets faster

## Compose a base profile with a list of attachments into a resolved profile.
## Pure: does not mutate the inputs. Multipliers accumulate left-to-right, so
## two muzzle attachments stack their effects.
static func resolve(base: RecoilProfile, attachments: Array) -> RecoilProfile:
	if base == null:
		return null
	# Start from a FULL copy of the base. Hand-copying field by field is how the
	# "equipping an attachment silently resets my weapon tuning" bug happens:
	# any field added later is forgotten here and falls back to the class
	# default (climb_soft_cap, recovery_*, viewkick_damping were all lost this way,
	# which made the preview and the real spray disagree).
	var r := base.duplicate() as RecoilProfile
	r.pattern = base.pattern.duplicate()

	for att in attachments:
		if not (att is Attachment):
			continue
		# --- ballistics: the same three words, routed per representation ---
		if base.pattern_source == "array":
			for i in range(r.pattern.size()):
				r.pattern[i] = Vector2(
					r.pattern[i].x * att.stability_mult,
					r.pattern[i].y * att.recoil_mult)
			r.sustain_delta = Vector2(
				r.sustain_delta.x * att.stability_mult,
				r.sustain_delta.y * att.recoil_mult)
			# the tail's sway is horizontal, so it belongs to "stability" too --
			# leaving it out would make an angled grip tighten the authored table
			# while the long tail kept swinging at full width.
			r.sustain_sway_amp *= att.stability_mult
		else:  # function source
			r.func_climb_amp *= att.recoil_mult
			r.func_sway_amp *= att.stability_mult
			r.func_drift = Vector2(
				r.func_drift.x * att.stability_mult,
				r.func_drift.y * att.recoil_mult)
		# --- hip-fire spread: cone, growth and cap move together ---
		r.base_spread *= att.hipfire_spread_mult
		r.spread_per_shot *= att.hipfire_spread_mult
		r.max_spread *= att.hipfire_spread_mult
		if r.max_spread < r.base_spread:
			r.max_spread = r.base_spread
		# --- feel ---
		r.viewkick_vertical *= att.viewkick_mult
		r.viewkick_horizontal *= att.viewkick_mult
		r.recovery_rate *= att.recovery_speed_mult
		r.fire_rate *= att.fire_rate_mult
		r.reset_delay = maxf(0.0, r.reset_delay + att.reset_delay_add)
	return r

## Build a throwaway attachment from raw tuning numbers -- used by the demo's
## "gunfeel" sliders so they go through exactly the same maths as real
## attachments (one code path, no chance of the two drifting apart).
static func from_tuning(recoil: float, stability: float, hipfire: float) -> Attachment:
	var a := Attachment.new()
	a.attachment_name = "Tuning"
	a.slot = "Tuning"
	a.recoil_mult = recoil
	a.stability_mult = stability
	a.hipfire_spread_mult = hipfire
	return a

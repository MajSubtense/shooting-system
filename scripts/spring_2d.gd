class_name Spring2D
extends RefCounted

## Second-order dynamics (spring-damper) for a Vector2.
##
## Used for the viewkick / crosshair return. A spring-damper gives natural
## overshoot and "punch" instead of a robotic lerp -- this is the trick
## t3ssel8r popularised for game-feel (f = frequency, zeta = damping).
## The target stays at zero so the value always springs *back* to rest,
## while impulses kick it away (per shot).

var value := Vector2.ZERO
var velocity := Vector2.ZERO
var target := Vector2.ZERO
var stiffness := 120.0
var damping := 14.0

func _init(p_stiffness: float = 120.0, p_damping: float = 14.0) -> void:
	stiffness = p_stiffness
	damping = p_damping

func update(delta: float) -> Vector2:
	# clamp dt so a frame spike can't blow the integrator up
	var dt := minf(delta, 0.033)
	var force := (target - value) * stiffness - velocity * damping
	velocity += force * dt
	value += velocity * dt
	return value

## Add an instantaneous kick (e.g. a recoil impulse).
## The kick is applied to the VALUE (a velocity-only impulse gets swallowed by
## the damper and reads as invisible on screen) plus a small velocity share on
## top, which is what produces the over-shoot "punch" before it settles.
func impulse(p: Vector2) -> void:
	value += p
	velocity += p * 4.0

func snap_to(p: Vector2) -> void:
	value = p
	velocity = Vector2.ZERO

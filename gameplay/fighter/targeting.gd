class_name Targeting
extends RefCounted
## Target selection among several enemies (SPEC.md §3.3). Pure, deterministic
## and data-only: callers pass positions, forward vectors and flags, so this
## is testable without fighters. Only the horizontal plane (XZ) counts.
##
## A candidate is a Dictionary:
##   {slot: int, pos: Vector3, attacking_me: bool, targetable: bool}
## Untargetable candidates (downed, out, vanished, entering, KO'd) are skipped.
## Functions return a slot, or -1 when no candidate is targetable.
##
## How Fighter is meant to use it (each sim_tick, humans only; CPUs pick
## their own target in CpuBrain):
##   - Saved state: `_target_locked: bool` (manual lock) and
##     `_retarget_timer: int` (frames until the next auto check), plus the
##     target's slot (resolve the Fighter by slot after load_state).
##   - TARGET just_pressed -> target = cycle(..., cycle_dir(frame.move_x))
##     and set the manual lock. The lock sticks until that target dies or
##     becomes untargetable (then drop the lock and auto-pick), or TARGET is
##     tapped again (cycles to the next one, still locked).
##   - Not locked: re-run pick_auto() when the target is null or
##     untargetable (immediately), or when _retarget_timer runs out (reset it
##     to retarget_check_frames).
##   - Fighter-side rule: never change target mid dodge flick (while dodging)
##     or while a HEAVY's stick height is latched, because stick space
##     (+Y = toward target) would rotate under the input. Defer the change
##     to the first tick after; an explicit TARGET tap is deferred the same way.
##   - `attacking_me`: the candidate is in an attack whose target is this
##     fighter (attack_phase() > 0 and target == me).


## Higher = better. Penalizes the angle off `self_fwd` and distance, and
## rewards a candidate that is attacking this fighter.
static func score(self_pos: Vector3, self_fwd: Vector3, cand_pos: Vector3, attacking_me: bool,
		t: TargetingTuning = null) -> float:
	if t == null:
		t = Tuning.targeting
	var d := _flat(cand_pos - self_pos)
	var f := _flat(self_fwd)
	var ang := 0.0
	if d.length_squared() > 0.0 and f.length_squared() > 0.0:
		ang = absf(f.angle_to(d))
	var s := -t.angle_weight * ang - t.distance_weight * d.length()
	if attacking_me:
		s += t.attacking_bonus
	return s


## Best targetable candidate by score (ties -> lower slot). Keeps
## `current_slot` while it is targetable unless another candidate beats it by
## hysteresis_margin.
static func pick_auto(self_pos: Vector3, self_fwd: Vector3, candidates: Array[Dictionary],
		current_slot: int, t: TargetingTuning = null) -> int:
	if t == null:
		t = Tuning.targeting
	var best := -1
	var best_score := -INF
	var current_score := -INF
	for c in candidates:
		if not c.get("targetable", true):
			continue
		var s := score(self_pos, self_fwd, c["pos"], c.get("attacking_me", false), t)
		var slot: int = c["slot"]
		if slot == current_slot:
			current_score = s
		if s > best_score or (s == best_score and slot < best):
			best = slot
			best_score = s
	if best != current_slot and current_score > -INF \
			and best_score < current_score + t.hysteresis_margin:
		return current_slot
	return best


## Next targetable candidate by angle around the fighter, seen from above.
## dir +1 = clockwise (forward -> right), -1 = counter-clockwise. Starts from
## the current target's bearing (or straight ahead, inclusive, when the
## current target isn't a targetable candidate). Equal bearings break by
## distance, then slot. Returns current_slot when it is the only candidate.
static func cycle(self_pos: Vector3, self_fwd: Vector3, candidates: Array[Dictionary],
		current_slot: int, dir: int) -> int:
	var sgn := -1.0 if dir < 0 else 1.0
	var from := 0.0
	var have_current := false
	for c in candidates:
		if c["slot"] == current_slot and c.get("targetable", true):
			from = bearing(self_pos, self_fwd, c["pos"])
			have_current = true
	var best := -1
	var best_key := Vector3(INF, INF, INF)  # (angular step, distance, slot)
	for c in candidates:
		var slot: int = c["slot"]
		if not c.get("targetable", true) or (have_current and slot == current_slot):
			continue
		var step := fposmod(sgn * (bearing(self_pos, self_fwd, c["pos"]) - from), TAU)
		if have_current and step == 0.0:
			step = TAU  # same bearing as the current target: comes last
		var key := Vector3(step, _flat(c["pos"] - self_pos).length(), slot)
		if key < best_key:
			best_key = key
			best = slot
	if best == -1 and have_current:
		return current_slot
	return best


## Cycle direction from the fighter-space stick x (InputFrame.move_x):
## stick left = -1 (counter-clockwise), neutral / right = +1.
static func cycle_dir(move_x: int, t: TargetingTuning = null) -> int:
	if t == null:
		t = Tuning.targeting
	return -1 if move_x < -t.cycle_stick_threshold * InputFrame.MOVE_SCALE else 1


## Clockwise bearing of `pos` from `self_fwd`, in [0, TAU). With Godot's
## Y-up / -Z-forward, clockwise from above = toward the fighter's right.
static func bearing(self_pos: Vector3, self_fwd: Vector3, pos: Vector3) -> float:
	var f := _flat(self_fwd)
	var d := _flat(pos - self_pos)
	if f.length_squared() == 0.0 or d.length_squared() == 0.0:
		return 0.0
	var right := Vector2(-f.y, f.x)  # fwd (0,-1) -> right (1,0)
	return fposmod(atan2(d.dot(right), d.dot(f)), TAU)


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)

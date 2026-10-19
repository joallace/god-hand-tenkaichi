class_name EncounterDirector
extends RefCounted
## Co-op attack coordination (SPEC.md §4.1). Owned by MatchDirector, ticked
## once per non-frozen sim tick after combat, saved with it. Disabled (every
## request granted) outside Mode.COOP.
##
## Each team-0 fighter (human or CPU ally) has a pool of melee tokens
## (Tuning.coop.melee_tokens_per_player) and ranged tokens
## (ranged_tokens_per_player: ki blasts, beams, supers, ultimates), plus a
## grab lock (one grabber at a time). A CPU enemy must hold the right token on
## its target before starting an attack (CpuBrain asks; fighters never check).
## Team-0 attackers, and attacks on fighters outside team 0, are never limited.
##
## Requests queue: request_token() registers / renews a request and returns
## false until sim_tick() grants it, longest-waiting first (ties: lower slot).
## A request not renewed within token_request_frames is dropped. A token goes
## back to the pool when the holder is hit / stunned / KO'd, changes target,
## its victim goes down, the attack it started ends, it isn't used within
## token_unused_frames, or after token_timeout_frames.
##
## Optional offscreen_attack_rule: an attacker outside the victim's view cone
## (victim facing +- offscreen_cone_half_angle) is refused outright.

enum Kind { MELEE, RANGED }

## The holder is reeling / out of the fight: its tokens go back.
const INTERRUPTED: Array[int] = [
	Fighter.State.HITSTUN, Fighter.State.KNOCKDOWN, Fighter.State.GUARD_BREAK, Fighter.State.KO,
	Fighter.State.THROWN, Fighter.State.WAKEUP, Fighter.State.VANISH_WAIT, Fighter.State.RECOIL,
	Fighter.State.DOWNED, Fighter.State.OUT, Fighter.State.ENTERING,
]
## States in which the holder is carrying out the attack it was granted.
const ATTACKING: Array[int] = [Fighter.State.ATTACK, Fighter.State.THROW, Fighter.State.TELEPORT]
## Team whose fighters the tokens protect.
const PROTECTED_TEAM := 0

# Token / request / grab records (PackedInt32Array so snapshots are cheap):
const T_HOLDER := 0
const T_VICTIM := 1
const T_KIND := 2
const T_SINCE := 3
const T_STARTED := 4
const R_HOLDER := 0
const R_VICTIM := 1
const R_KIND := 2
const R_FIRST := 3
const R_LAST := 4
const G_VICTIM := 0
const G_HOLDER := 1
const G_SINCE := 2
const G_STARTED := 3

var director: MatchDirector
var enabled := false

var _tokens: Array[PackedInt32Array] = []
var _requests: Array[PackedInt32Array] = []
var _grabs: Array[PackedInt32Array] = []


func _init(p_director: MatchDirector) -> void:
	director = p_director
	enabled = director.config != null and director.config.mode == MatchConfig.Mode.COOP


## Ask for a `kind` token to attack `victim`. True = granted (or already
## held). Call every tick the attack is wanted; grants are deterministic.
func request_token(attacker: Fighter, victim: Fighter, kind: Kind) -> bool:
	if not _limited(attacker, victim):
		return true
	if _token_index(attacker.slot, victim.slot, kind) >= 0:
		return true
	if not _in_view(attacker, victim):
		return false
	var now := director.tick
	for i in _requests.size():
		var r := _requests[i]
		if r[R_HOLDER] == attacker.slot and r[R_KIND] == kind:
			if r[R_VICTIM] != victim.slot:
				r[R_VICTIM] = victim.slot  # new target: the wait starts over
				r[R_FIRST] = now
			r[R_LAST] = now
			_requests[i] = r
			return false
	_requests.append(PackedInt32Array([attacker.slot, victim.slot, kind, now, now]))
	return false


## Whether `attacker` currently holds a `kind` token (on any victim).
## Unlimited attackers (disabled, or team 0) always do.
func holds_token(attacker: Fighter, kind: Kind) -> bool:
	if not enabled or attacker == null or attacker.team == PROTECTED_TEAM:
		return true
	for t in _tokens:
		if t[T_HOLDER] == attacker.slot and t[T_KIND] == kind:
			return true
	return false


## Give back every token `attacker` holds and drop its requests.
func release(attacker: Fighter) -> void:
	if attacker == null:
		return
	_drop_holder(attacker.slot)


## Grab lock: true if `attacker` may start a throw on `victim` (no one else
## is grabbing that victim). Claimed until release_grab or the throw ends.
func request_grab(attacker: Fighter, victim: Fighter) -> bool:
	if not _limited(attacker, victim):
		return true
	for g in _grabs:
		if g[G_VICTIM] == victim.slot:
			return g[G_HOLDER] == attacker.slot
	if victim.state == Fighter.State.THROWN:
		return false
	_grabs.append(PackedInt32Array([victim.slot, attacker.slot, director.tick, 0]))
	return true


func release_grab(attacker: Fighter) -> void:
	if attacker == null:
		return
	for i in range(_grabs.size() - 1, -1, -1):
		if _grabs[i][G_HOLDER] == attacker.slot:
			_grabs.remove_at(i)


## Tokens of `kind` still free on `victim` (0 when tokens don't apply).
func free_tokens(victim: Fighter, kind: Kind) -> int:
	if not enabled or victim == null or victim.team != PROTECTED_TEAM:
		return 0
	return maxi(_cap(kind) - holders(victim, kind).size(), 0)


## Slots holding a `kind` token on `victim`, in grant order.
func holders(victim: Fighter, kind: Kind) -> Array[int]:
	var out: Array[int] = []
	if victim == null:
		return out
	for t in _tokens:
		if t[T_VICTIM] == victim.slot and t[T_KIND] == kind:
			out.append(t[T_HOLDER])
	return out


## Slot grabbing `victim` under the grab lock (-1 = none).
func grab_holder(victim: Fighter) -> int:
	if victim != null:
		for g in _grabs:
			if g[G_VICTIM] == victim.slot:
				return g[G_HOLDER]
	return -1


func sim_tick(_tick: int) -> void:
	if not enabled:
		return
	var now := director.tick
	_expire_tokens(now)
	_expire_grabs(now)
	_expire_requests(now)
	_grant(now)


func save_state() -> Dictionary:
	return {"tokens": _tokens.duplicate(true), "requests": _requests.duplicate(true), "grabs": _grabs.duplicate(true)}


func load_state(s: Dictionary) -> void:
	_tokens.assign((s.get("tokens", []) as Array).duplicate(true))
	_requests.assign((s.get("requests", []) as Array).duplicate(true))
	_grabs.assign((s.get("grabs", []) as Array).duplicate(true))


# --- internals ----------------------------------------------------------------

## Tokens apply: co-op, a non-team-0 attacker going after a team-0 fighter.
func _limited(attacker: Fighter, victim: Fighter) -> bool:
	return enabled and attacker != null and victim != null and attacker.team != PROTECTED_TEAM \
		and victim.team == PROTECTED_TEAM and attacker.team != victim.team


func _cap(kind: Kind) -> int:
	return Tuning.coop.melee_tokens_per_player if kind == Kind.MELEE else Tuning.coop.ranged_tokens_per_player


func _in_view(attacker: Fighter, victim: Fighter) -> bool:
	if not Tuning.coop.offscreen_attack_rule:
		return true
	var to := attacker.global_position - victim.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return true
	var fwd := -victim.global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return true
	return rad_to_deg(fwd.normalized().angle_to(to.normalized())) <= Tuning.coop.offscreen_cone_half_angle


func _token_index(holder: int, victim: int, kind: int) -> int:
	for i in _tokens.size():
		var t := _tokens[i]
		if t[T_HOLDER] == holder and t[T_VICTIM] == victim and t[T_KIND] == kind:
			return i
	return -1


func _drop_holder(holder: int) -> void:
	for i in range(_tokens.size() - 1, -1, -1):
		if _tokens[i][T_HOLDER] == holder:
			_tokens.remove_at(i)
	for i in range(_requests.size() - 1, -1, -1):
		if _requests[i][R_HOLDER] == holder:
			_requests.remove_at(i)


## A victim the tokens no longer need to protect (gone, KO'd, downed, out).
func _victim_gone(v: Fighter) -> bool:
	return v == null or v.is_ko() or v.is_downed() or v.is_out()


func _expire_tokens(now: int) -> void:
	var c := Tuning.coop
	for i in range(_tokens.size() - 1, -1, -1):
		var t := _tokens[i]
		var h := director.fighter_for_slot(t[T_HOLDER])
		var v := director.fighter_for_slot(t[T_VICTIM])
		var age := now - t[T_SINCE]
		var drop := h == null or _victim_gone(v) or h.state in INTERRUPTED or h.target != v \
			or age > c.token_timeout_frames
		if not drop:
			if h.state in ATTACKING:
				t[T_STARTED] = 1
				_tokens[i] = t
			elif t[T_STARTED] == 1 or age > c.token_unused_frames:
				drop = true  # the attack ended, or was never started
		if drop:
			_tokens.remove_at(i)


func _expire_grabs(now: int) -> void:
	for i in range(_grabs.size() - 1, -1, -1):
		var g := _grabs[i]
		var h := director.fighter_for_slot(g[G_HOLDER])
		var v := director.fighter_for_slot(g[G_VICTIM])
		var drop := h == null or _victim_gone(v) or h.state in INTERRUPTED or h.target != v
		if not drop:
			if h.state == Fighter.State.THROW:
				g[G_STARTED] = 1
				_grabs[i] = g
			elif g[G_STARTED] == 1 or now - g[G_SINCE] > Tuning.coop.token_unused_frames:
				drop = true
		if drop:
			_grabs.remove_at(i)


func _expire_requests(now: int) -> void:
	for i in range(_requests.size() - 1, -1, -1):
		var r := _requests[i]
		var h := director.fighter_for_slot(r[R_HOLDER])
		var v := director.fighter_for_slot(r[R_VICTIM])
		if h == null or h.is_ko() or _victim_gone(v) or now - r[R_LAST] > Tuning.coop.token_request_frames:
			_requests.remove_at(i)


## Hand free tokens to waiting requests: per victim (slot order) and kind,
## longest wait first, ties to the lower slot.
func _grant(now: int) -> void:
	if _requests.is_empty():
		return
	var victims: Array[int] = []
	for r in _requests:
		if not r[R_VICTIM] in victims:
			victims.append(r[R_VICTIM])
	victims.sort()
	for vs in victims:
		var v := director.fighter_for_slot(vs)
		for kind: int in [Kind.MELEE, Kind.RANGED]:
			var free := free_tokens(v, kind)
			if free <= 0:
				continue
			var waiting: Array[PackedInt32Array] = []
			for r in _requests:
				if r[R_VICTIM] == vs and r[R_KIND] == kind:
					waiting.append(r)
			waiting.sort_custom(func(a: PackedInt32Array, b: PackedInt32Array) -> bool:
				return a[R_FIRST] < b[R_FIRST] or (a[R_FIRST] == b[R_FIRST] and a[R_HOLDER] < b[R_HOLDER]))
			for r in waiting.slice(0, free):
				_tokens.append(PackedInt32Array([r[R_HOLDER], vs, kind, now, 0]))
				_requests.erase(r)

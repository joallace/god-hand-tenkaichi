class_name CpuBrain
extends RefCounted
## The CPU opponent. Every sim tick it looks at the match through the
## MatchDirector and returns the InputFrame a player would have produced, so
## fighters need no AI-specific code paths (CpuInput wraps it).
##
## Fairness: it reads only public fighter state, and a new opponent state or
## move is not "seen" until a reaction delay has passed. Difficulty
## (CpuTuning, by level) scales reaction time, decision rate and the odds of
## picking good options; it never touches damage, frame data or ki.
##
## think() runs one layer per tick, first match wins:
##   1. reflexes in special states (hitstun vanish escape, vanish battles,
##      perfect-dodge counters, throw breaks, mashing out of a guard crash)
##   2. defense against a noticed attack, throw, ki blast or beam (guard in
##      the pose that suits the move, timed dodge, guard vanish, counter
##      guard, throw pre-break)
##   3. follow-ups for the move it is performing (string links, finishers,
##      super cancels, teleport chases)
##   4. punishes, then the neutral game every think_interval frames (spacing,
##      attacks, throws, ki charging, blasts, supers, taunts)
## Decisions become timed button holds in `_plan` that `_emit()` turns into
## this tick's frame.
##
## Clock: `_clock` counts its own fighter's simulated ticks only. While that
## fighter is in hitstop (or the world is frozen) it doesn't simulate, so the
## brain freezes too (keeps holding long presses, lets taps go) and its
## timings stay in step with the fighter's frame counters.
##
## Determinism: seeded RandomNumberGenerator; every decision variable
## round-trips through save_state()/load_state().

const S := Fighter.State
const B := InputFrame.Btn
const D := InputFrame.Dodge
## `_plan` entry: [start_clock, end_clock (exclusive), button (0 = stick
## only), stick_y, stick_x] (stick in InputFrame.MOVE_SCALE units).
const NO_STICK := 1 << 16
const CAN_ACT: Array[int] = [S.IDLE, S.WALK, S.GUARD, S.DASH, S.CHARGE]
const CAN_DODGE: Array[int] = [S.IDLE, S.WALK, S.GUARD, S.DASH]
## Entering these drops every plan: whatever was queued no longer applies.
const INTERRUPTED: Array[int] = [
	S.HITSTUN, S.KNOCKDOWN, S.GUARD_BREAK, S.KO, S.WAKEUP, S.VANISH_WAIT, S.THROWN, S.RECOIL,
]
## Opponent states that leave it open to a punish.
const OPEN_STATES: Array[int] = [S.GUARD_BREAK, S.HITSTUN, S.RECOIL, S.TAUNT]
## Opponent states a throw goes through (a guard can't stop it).
const GUARDING: Array[int] = [S.GUARD, S.GUARD_STUN, S.COUNTER]
## How good each MoveData.GuardResult is for the defender (higher = better).
const GUARD_RESULT_RANK: Array[int] = [2, 1, 3, 4, 0]  # PLAIN, KI_GUARD, PUSH_OFF, PUSH_STOP, UNBLOCKABLE
## Variables saved for rollback (see save_state).
const SAVED: Array[StringName] = [
	&"_clock", &"_plan", &"_dodge_at", &"_dodge_dir", &"_walk", &"_walk_until",
	&"_next_think", &"_opp_state", &"_opp_serial", &"_opp_known_at", &"_opp_seen_state",
	&"_threat_serial", &"_my_serial", &"_my_state", &"_my_frame", &"_reflex_done", &"_rise_done",
	&"_string_left", &"_chase", &"_followup", &"_counter_until", &"_contact_serial",
	&"_contact_blocked", &"_punish_key", &"_last_held", &"_last_move", &"_mash_next",
]

var level: int
## 0 (weakest) .. 1 (strongest), from the level.
var skill: float
var cfg: CpuTuning
var rng := RandomNumberGenerator.new()
var director: MatchDirector
var slot: int = -1
var me: Fighter
var opp: Fighter

# --- decision state (everything below round-trips through save/load) -------
var _clock: int = 0
var _plan: Array[PackedInt32Array] = []
var _dodge_at: int = -1
var _dodge_dir: int = D.NONE
var _walk: Vector2 = Vector2.ZERO
var _walk_until: int = 0
var _next_think: int = 0
## Opponent state/move as last observed, and when that becomes perceived.
var _opp_state: int = S.IDLE
var _opp_serial: int = -1
var _opp_known_at: int = 0
var _opp_seen_state: int = S.IDLE
## Opponent move serial already answered defensively.
var _threat_serial: int = -1
## Own move serial whose follow-up was already decided.
var _my_serial: int = -1
## Own state entry tracking (re-entering the same state counts as new).
var _my_state: int = S.IDLE
var _my_frame: int = 0
var _reflex_done: bool = false
## Get-up choice already made for the current knockdown (after landing).
var _rise_done: bool = false
## LIGHT presses left before the finisher in the current string.
var _string_left: int = 0
## The finisher being planned is a launcher to teleport after.
var _chase: bool = false
## Attack as soon as control returns (after a teleport chase).
var _followup: bool = false
var _counter_until: int = -1
## Last of my move serials that touched the opponent, and whether blocked.
var _contact_serial: int = -1
var _contact_blocked: bool = false
var _punish_key: int = -1
var _last_held: int = 0
var _last_move: Vector2 = Vector2.ZERO
## Next mash press while guard crashed / staggered (-1 = not mashing).
var _mash_next: int = -1


func _init(p_level: int = -1, seed_value: int = 0) -> void:
	cfg = Tuning.cpu
	level = cfg.clamp_level(p_level)
	skill = cfg.level_skill(level)
	rng.seed = seed_value


func attach(p_director: MatchDirector, p_slot: int) -> void:
	director = p_director
	slot = p_slot


## Clear decisions between rounds (the RNG keeps its sequence).
func reset() -> void:
	var rng_state := rng.state
	var keep := [director, slot, me, opp]
	var fresh := CpuBrain.new(level)
	for k in SAVED:
		set(k, fresh.get(k))
	rng.state = rng_state
	director = keep[0]
	slot = keep[1]
	me = keep[2]
	opp = keep[3]


func think() -> InputFrame:
	if not _resolve() or director.phase != MatchDirector.Phase.FIGHT:
		return _idle_frame()
	if me.hitstop_left() > 0 or director.world_freeze > 0:
		return _frozen_frame()
	_clock += 1
	_perceive()
	_track_my_state()
	_decide()
	return _emit()


# =============================================================================
# Perception
# =============================================================================

func _resolve() -> bool:
	if me != null and opp != null:
		return true
	if director == null:
		return false
	me = director.fighter_for_slot(slot)
	if me == null or me.opponent == null:
		me = null
		return false
	opp = me.opponent
	me.event.connect(_on_my_event)
	opp.event.connect(_on_opp_event)
	return true


## A new opponent state or move becomes known after the reaction delay.
func _perceive() -> void:
	var st := opp.state
	var serial := opp.current_move_serial()
	if st != _opp_state or (st == S.ATTACK and serial != _opp_serial):
		_opp_state = st
		_opp_serial = serial
		_opp_known_at = _clock + _reaction()
	if _clock >= _opp_known_at:
		_opp_seen_state = _opp_state


func _seen() -> bool:
	return _clock >= _opp_known_at


func _track_my_state() -> void:
	var st := me.state
	if st != _my_state or me.state_frame() < _my_frame:
		_my_state = st
		_reflex_done = false
		_rise_done = false
		if st in INTERRUPTED:
			_clear_plan()
			_followup = false
			_chase = false
	_my_frame = me.state_frame()


func _on_my_event(kind: StringName, data: Dictionary) -> void:
	if kind == &"perfect_dodge" and data.get("slot", -1) == slot:
		_counter_until = _clock + me.tuning.perfect_dodge_counter_frames


func _on_opp_event(kind: StringName, data: Dictionary) -> void:
	if kind == &"hit" and data.get("attacker_slot", -1) == slot:
		_contact_serial = me.current_move_serial()
		_contact_blocked = data.get("blocked", false)


# =============================================================================
# Decisions
# =============================================================================

func _decide() -> void:
	match me.state:
		S.HITSTUN:
			_hitstun_reflex()
		S.KNOCKDOWN:
			_knockdown_reflex()
		S.VANISH_WAIT:
			_vanish_reflex()
		S.THROWN:
			_throw_reflex()
		S.GUARD_BREAK:
			_mash_reflex()
		S.DODGE:
			_dodge_counter()
		S.ATTACK:
			_follow_up()
		S.GUARD_STUN:
			_defend()
		_:
			if me.state not in CAN_ACT:
				return
			if me.state == S.CHARGE and _keep_charging():
				return
			if _defend():
				return
			if me.state == S.DASH:
				return
			if _press_followup() or _punish():
				return
			if _clock >= _next_think:
				_next_think = _clock + maxi(roundi(_p(cfg.think_interval)) + rng.randi_range(-cfg.think_jitter_frames, cfg.think_jitter_frames), 1)
				_neutral()


# --- 1. Reflexes --------------------------------------------------------------

## Vanish out of a combo (GUARD in hitstun), once per hitstun.
func _hitstun_reflex() -> void:
	if _reflex_done:
		return
	_reflex_done = true
	if me.ki < VanishBattle.cost_for(me.tuning, 0) or opp.combo_hits < 1:
		return
	if _roll(cfg.vanish_escape_chance):
		_tap(B.GUARD, _clock + _reaction())


## Knocked down: flip out in the air, or pick a get-up once on the floor.
func _knockdown_reflex() -> void:
	var t := me.tuning
	if me.is_airborne():
		if _reflex_done:
			return
		_reflex_done = true
		if _roll(cfg.air_tech_chance):
			_dodge_dir = D.BACK
			_dodge_at = _clock + maxi(t.air_tech_min_frames - me.state_frame(), 0) + _reaction()
		return
	if _rise_done or me.lying_frames() < 0:
		return
	_rise_done = true
	if not _roll(cfg.wakeup_option_chance):
		return  # stay down until the automatic get-up
	var at := _clock + maxi(t.knockdown_min_frames - me.lying_frames(), 0) + _reaction()
	if _roll(cfg.wakeup_roll_chance):
		_dodge_dir = [D.LEFT, D.RIGHT, D.BACK][rng.randi_range(0, 2)]
		_dodge_at = at
	else:
		_tap(B.GUARD, at)


## Answer a vanish within the (shrinking) window, if fast enough.
func _vanish_reflex() -> void:
	if _reflex_done:
		return
	_reflex_done = true
	if _roll(cfg.vanish_respond_chance):
		_tap(B.GUARD, _clock + maxi(me.tuning.teleport_frames - me.state_frame(), 0) + _reaction())


## Grabbed: break with one clean GUARD press inside the break window (a
## press soon after an earlier one isn't clean, so it either fits or skips).
func _throw_reflex() -> void:
	if _reflex_done:
		return
	_reflex_done = true
	if not _roll(cfg.throw_break_chance):
		return
	var t := me.tuning
	var wait := maxi(_reaction(), 1)
	# A press emitted `wait` ticks from now is read on state frame state_frame() + 1 + wait.
	if me.state_frame() + 1 + wait >= t.throw_break_frames:
		return  # too slow: the throw lands first
	if me.frames_since_guard_press() + wait < t.guard_vanish_rearm_frames:
		return
	_tap(B.GUARD, _clock + wait)


## Guard crash / stagger: mash LIGHT to shorten it.
func _mash_reflex() -> void:
	if not _reflex_done:
		_reflex_done = true
		_mash_next = _clock + _reaction() if _roll(cfg.stun_mash_chance) else -1
	if _mash_next < 0 or _clock < _mash_next:
		return
	_tap(B.LIGHT, _clock)
	# A button needs a release between presses: every other frame at most.
	_mash_next = _clock + maxi(roundi(_p(cfg.stun_mash_interval_frames)), 2)


## After a perfect dodge: counter attack (heavy; a full string if they reel).
func _dodge_counter() -> void:
	if _reflex_done or _clock >= _counter_until:
		return
	_reflex_done = true
	if not _roll(cfg.punish_chance):
		return
	var at := mini(_clock + _reaction(), _counter_until - 1)
	if opp.state == S.GUARD_BREAK:
		_start_string(at)
	else:
		_tap(B.HEAVY, at, _rand_height_stick())


# --- 2. Defense ---------------------------------------------------------------

## Answer a newly noticed opponent attack. True while a defense is underway.
func _defend() -> bool:
	if _opp_state == S.ATTACK and _seen() and _threat_serial != _opp_serial:
		_threat_serial = _opp_serial
		var m := opp.current_move()
		if m != null:
			match m.spawn_kind:
				&"ki_blast":
					_defend_blast(m)
				&"beam":
					_defend_beam(m)
				_:
					if opp.attack_phase() <= 1 and _dist() <= _reach(m) + cfg.reach_margin:
						if m.is_throw:
							_defend_throw(m)
						else:
							_defend_melee(m)
	return _dodge_at >= _clock or _holding(B.GUARD)


func _defend_melee(m: MoveData) -> void:
	if not _roll(cfg.defend_chance):
		return
	var t := me.tuning
	var hit_in := m.startup - opp.state_frame() - 1  # ticks until its first active frame
	var can_dodge := me.state in CAN_DODGE or me.state == S.CHARGE
	var pose := _guard_pose_for(m)
	var res := m.guard_result(pose)
	var can_guard := res != MoveData.GuardResult.UNBLOCKABLE
	# A ki guard with too little ki left crashes the guard: rather dodge.
	var crashes := res == MoveData.GuardResult.KI_GUARD and me.ki <= m.guard_ki_cost
	var stick := _pose_stick(pose)
	var window := me.guard_vanish_window()
	var opener := opp.move_opens_string()
	# Only a string opener can be vanished, and only with a clean (unmashed) press.
	var can_vanish := opener and me.ki >= VanishBattle.cost_from(t, t.guard_vanish_cost_bars, 0)
	var dodge := can_dodge and (not can_guard or crashes or _roll(cfg.dodge_preference))
	_clear_plan()
	if not dodge and can_guard and me.state != S.GUARD_STUN and can_vanish \
			and hit_in > 1 and _roll(cfg.guard_vanish_chance):
		# (Re)press GUARD just before the hit: vanish instead of blocking.
		var at := maxi(_clock + hit_in - rng.randi_range(1, mini(window - 1, hit_in - 1)), _clock + 1)
		if me.frames_since_guard_press() + (at - _clock) >= t.guard_vanish_rearm_frames:
			_hold(B.GUARD, at, hit_in + m.active + t.teleport_frames, stick)
			return
	if not dodge and can_guard and opener and me.state == S.GUARD and hit_in >= 1 \
			and _roll(cfg.counter_guard_chance):
		# Stick forward + LIGHT from the held guard, timed so the hit lands
		# in the counter stance's opening frames.
		var lead := rng.randi_range(0, maxi(t.counter_guard_window_frames - 1, 0))
		_hold(B.GUARD, _clock, hit_in + m.active + m.guard_stun, stick)
		_tap(B.LIGHT, maxi(_clock + hit_in - lead, _clock + 1), 1.0)
		return
	# Pressing GUARD inside the vanish window would vanish instead of block.
	var fresh_guard := me.state != S.GUARD and me.state != S.GUARD_STUN
	var clean_press := me.frames_since_guard_press() >= t.guard_vanish_rearm_frames
	if not dodge and fresh_guard and can_vanish and clean_press and hit_in < window:
		dodge = can_dodge
	if dodge:
		_dodge(_dodge_for(m), _clock + hit_in)
	elif can_guard:
		_hold(B.GUARD, _clock, maxi(hit_in, 0) + m.active + m.guard_stun, stick)


## Guards don't stop a grab: pre-break it with a clean GUARD press just
## before it connects, or dodge it; otherwise it's up to _throw_reflex.
func _defend_throw(m: MoveData) -> void:
	if not _roll(cfg.defend_chance):
		return
	var t := me.tuning
	var hit_in := m.startup - opp.state_frame() - 1
	_clear_plan()
	if hit_in >= 1 and _roll(cfg.throw_break_chance):
		var lead := rng.randi_range(0, mini(t.throw_break_frames - 1, hit_in - 1))
		var at := _clock + hit_in - lead
		if me.frames_since_guard_press() + (at - _clock) >= t.guard_vanish_rearm_frames:
			_tap(B.GUARD, at)
			return
	if (me.state in CAN_DODGE or me.state == S.CHARGE) and _roll(cfg.dodge_preference):
		_dodge(D.BACK, _clock + hit_in)


func _defend_blast(m: MoveData) -> void:
	if m.spawn_move == null or not _roll(cfg.projectile_defend_chance):
		return
	var speed := maxf(m.spawn_move.travel_speed / Tuning.match_rules.tick_rate, 0.01)
	var hit_in := m.spawn_frame - opp.state_frame() - 1 + ceili(maxf(_dist() - m.spawn_move.hitbox_offset.z, 0.0) / speed)
	if hit_in > cfg.blast_look_ahead_frames + m.spawn_frame:
		return  # too far to bother; it may not even reach
	_clear_plan()
	if me.state in CAN_DODGE and _roll(cfg.dodge_preference):
		_dodge(D.LEFT if rng.randf() < 0.5 else D.RIGHT, _clock + hit_in)
	else:
		_hold(B.GUARD, _clock, maxi(hit_in, 0) + m.spawn_move.guard_stun + cfg.guard_tail_frames,
				_pose_stick(_guard_pose_for(m.spawn_move)))


## Beams out-damage a guard; sway off the line as it fires and keep strafing.
func _defend_beam(m: MoveData) -> void:
	if not _roll(cfg.projectile_defend_chance):
		return
	var fire_in := m.spawn_frame - opp.state_frame() - 1
	_clear_plan()
	if not (me.state in CAN_DODGE or me.state == S.CHARGE) or not _roll(cfg.smart_dodge_chance):
		_hold(B.GUARD, _clock, maxi(fire_in, 0) + m.spawn_move.active, _pose_stick(_guard_pose_for(m.spawn_move)))
		return
	var dir := D.LEFT if rng.randf() < 0.5 else D.RIGHT
	_dodge(dir, _clock + fire_in)
	_walk = Vector2(-1.0 if dir == D.LEFT else 1.0, 0.0)
	_walk_until = _clock + maxi(fire_in, 0) + cfg.beam_strafe_frames


## Fire a dodge aimed at the perfect-dodge window of a hit landing at `hit_at`.
func _dodge(dir: int, hit_at: int) -> void:
	var t := me.tuning
	var err := roundi(_p(cfg.dodge_timing_error))
	var at := hit_at - rng.randi_range(0, maxi(t.perfect_dodge_frames - 1, 0)) + rng.randi_range(-err, err)
	if me.state == S.CHARGE:
		at = maxi(at, _clock + 1)  # leave the charge first (CHARGE is released by _clear_plan)
	_dodge_at = maxi(at, _clock)
	_dodge_dir = dir


## The guard pose (MoveData.Height) to hold against `m`: the one its guard
## results favour most (ties: the move's own height) when the read succeeds,
## else a plain mid guard.
func _guard_pose_for(m: MoveData) -> int:
	if m == null or not _roll(cfg.guard_pose_chance):
		return MoveData.Height.MID
	var best: int = m.height
	for pose: int in [MoveData.Height.MID, MoveData.Height.HIGH, MoveData.Height.LOW]:
		if GUARD_RESULT_RANK[m.guard_result(pose)] > GUARD_RESULT_RANK[m.guard_result(best)]:
			best = pose
	return best


## Stick Y that picks a guard pose / strike height.
func _pose_stick(pose: int) -> float:
	match pose:
		MoveData.Height.HIGH:
			return 1.0
		MoveData.Height.LOW:
			return -1.0
	return 0.0


## Duck what passes over a crouch (perfect ducks stagger), sway the rest.
func _dodge_for(m: MoveData) -> int:
	if not _roll(cfg.smart_dodge_chance):
		return [D.FORWARD, D.BACK, D.LEFT, D.RIGHT][rng.randi_range(0, 3)]
	if m.hitbox_offset.y - m.hitbox_radius > me.tuning.duck_height:
		return D.FORWARD
	return D.LEFT if rng.randf() < 0.5 else D.RIGHT


# --- 3. Offense follow-ups ----------------------------------------------------

## Once the current move hit, got blocked or whiffed, plan what comes next.
func _follow_up() -> void:
	var m := me.current_move()
	var serial := me.current_move_serial()
	if m == null or serial == _my_serial or _pressing_long(B.LIGHT | B.HEAVY):
		return  # (a held strike button is a charge strike in progress)
	var f := me.state_frame()
	var landed := _contact_serial == serial and not _contact_blocked
	var blocked := _contact_serial == serial and _contact_blocked
	if not landed and not blocked and f < m.startup + m.active:
		return
	_my_serial = serial
	var t := me.tuning
	if not landed:
		_chase = false
	if landed and _chase and m.knockdown:
		_chase = false
		if me.ki >= t.teleport_cost_bars * t.ki_bar_size:
			# Reappear behind them (neutral stick) or at a flank.
			var side := _strafe_sign() if rng.randf() < cfg.teleport_flank_share else 0.0
			_tap(B.GUARD, _clock + 1 + _link_error() / 2, 0.0, side)
			_followup = true
		return
	if m.cancel_into.is_empty() and not m.special_cancelable:
		return
	if not landed:
		if _roll(cfg.string_discipline):
			_string_left = 0
			if blocked:
				_hold(B.GUARD, _clock + m.total() - f, roundi(_p(cfg.think_interval)) + cfg.guard_tail_frames)
			return
		if blocked and opp.ki / opp.ki_max() < cfg.guard_crush_ratio:
			_link(m, B.HEAVY, -1.0)  # low finisher: ki guard drains the most
			return
	elif _roll(cfg.combo_drop_chance):
		_string_left = 0
		return
	var super_cost := t.super1_cost_bars * t.ki_bar_size
	if landed and m.special_cancelable and me.ki >= super_cost and _roll(cfg.special_chance) \
			and rng.randf() < cfg.super_cancel_share:
		_link_special(m, 0.0 if rng.randf() < cfg.super_cancel_rush_share else 1.0)
		return
	if _string_left > 0 and _cancels_with(m, B.LIGHT):
		_string_left -= 1
		_link(m, B.LIGHT, 0.0)
	elif _cancels_with(m, B.HEAVY):
		_string_left = 0
		_link(m, B.HEAVY, _finisher_stick())


## Launcher (forward) when going for a teleport chase, else any height.
func _finisher_stick() -> float:
	var t := me.tuning
	if me.ki >= t.teleport_cost_bars * t.ki_bar_size and _roll(cfg.teleport_chase_chance):
		_chase = true
		return 1.0
	return _rand_height_stick()


## Press `btn` so it is buffered when m's cancel window opens (plus error).
func _link(m: MoveData, btn: int, stick_y: float) -> void:
	var f := me.state_frame()
	var buffer := Tuning.input.input_buffer_frames
	var target := maxi(f + 1, m.cancel_start - buffer / 2) + _link_error()
	_tap(btn, _clock + target - f - 1, stick_y)


## CHARGE + HEAVY inside the open cancel window (not before: HEAVY alone
## buffered early would read as the finisher).
func _link_special(m: MoveData, stick_y: float) -> void:
	var f := me.state_frame()
	var at := _clock + maxi(m.cancel_start - f - 1, 0) + _link_error() / 2
	_special(at, stick_y)


func _cancels_with(m: MoveData, btn: int) -> bool:
	for id in m.cancel_into:
		var next := me.def.move(id)
		if next != null and next.button == btn:
			return true
	return false


## After a teleport chase: attack on reappearing.
func _press_followup() -> bool:
	if not _followup:
		return false
	_followup = false
	if opp.state != S.HITSTUN or _dist() > _reach(_jab()) + cfg.reach_margin:
		return false
	_start_string(_clock)
	return true


# --- 4. Punishes and neutral --------------------------------------------------

## Open opponent (staggered, guard broken, recovering, reeling) within reach.
func _punish() -> bool:
	if not _seen() or _punish_key == _opp_known_at:
		return false
	var open := _opp_seen_state in OPEN_STATES
	var m := opp.current_move()
	# Taunts and recoils last long enough to dash in on, like attack recovery.
	var recovering := _opp_seen_state == S.TAUNT or _opp_seen_state == S.RECOIL \
			or (_opp_seen_state == S.ATTACK and m != null and opp.attack_phase() == 2
				and m.total() - opp.state_frame() > _jab().startup)
	if not open and not recovering:
		return false
	var d := _dist()
	var in_reach := d <= _reach(_jab())
	var dash_reach := _reach(me.def.move(me.def.dash_attack)) + me.tuning.dash_speed * me.tuning.dash_frames / Tuning.match_rules.tick_rate
	if not in_reach and (not recovering or d > dash_reach):
		return false
	_punish_key = _opp_known_at
	if not _roll(cfg.punish_chance):
		return false
	_release(B.GUARD)
	_release(B.CHARGE)
	if not in_reach:
		_dash_attack(d)
	elif _opp_seen_state == S.GUARD_BREAK and _roll(cfg.mixup_chance):
		_charge_strike(B.LIGHT)
	else:
		_start_string(_clock)
	return true


func _neutral() -> void:
	var d := _dist()
	var t := me.tuning
	var bar := t.ki_bar_size
	_release(B.GUARD)
	if _taunt_safe(d) and me.ki < me.ki_max() and _roll(cfg.taunt_chance):
		_tap(B.TAUNT, _clock)
		return
	if d <= _reach(_jab()):
		if _roll(cfg.aggression):
			_close_attack()
		elif rng.randf() < cfg.close_guard_share:
			_hold(B.GUARD, _clock, roundi(_p(cfg.think_interval)) + cfg.guard_tail_frames)
		else:
			_walk_for(Vector2(_strafe_sign(), -1.0 if not _near_wall() else 0.0))
		return
	var options := {
		&"approach": _p(cfg.aggression),
		&"wait": 1.0 - _p(cfg.aggression),
	}
	if d > t.close_combat_range and me.ki >= t.ki_blast_cost:
		options[&"blast"] = _p(cfg.blast_chance)
	if d >= cfg.safe_charge_distance and me.ki_bars_full() < roundi(_p(cfg.charge_target_bars)) \
			and me.ki < me.ki_max():
		options[&"charge"] = _p(cfg.charge_chance) * cfg.charge_weight
	if me.ki >= t.super2_cost_bars * bar and d > t.close_combat_range:
		options[&"beam"] = _p(cfg.special_chance) * cfg.beam_weight
	if me.ki >= t.ultimate_cost_bars * bar:
		options[&"ultimate"] = _p(cfg.special_chance) * cfg.ultimate_weight
	if me.ki >= t.super1_cost_bars * bar and d <= _reach(me.def.move(me.def.super1)):
		options[&"rush"] = _p(cfg.special_chance) * cfg.rush_weight
	match _pick(options):
		&"approach":
			if d > cfg.dash_distance:
				_tap(B.DASH, _clock)
			elif d <= _dash_attack_range() and rng.randf() < _p(cfg.mixup_chance):
				_dash_attack(d)
			else:
				_walk_for(Vector2(_strafe_sign() * rng.randf_range(0.0, cfg.approach_strafe), 1.0))
		&"blast":
			_tap(B.BLAST, _clock)
		&"charge":
			var need := (roundi(_p(cfg.charge_target_bars)) * bar - me.ki) / t.ki_charge_per_frame
			_hold(B.CHARGE, _clock, maxi(ceili(need), 1))
		&"beam":
			_special(_clock, 1.0)
		&"ultimate":
			_special(_clock, -1.0)
		&"rush":
			_special(_clock, 0.0)
		_:
			_walk_for(Vector2(_strafe_sign(), 0.0))


func _close_attack() -> void:
	var t := me.tuning
	if _opp_seen_state in GUARDING and _roll(cfg.throw_chance):
		_throw()
		return
	if _opp_seen_state == S.COUNTER and _roll(cfg.counter_respect_chance):
		# Don't swing into a counter stance: guard until it runs out.
		_hold(B.GUARD, _clock, t.counter_guard_stance_frames + cfg.guard_tail_frames)
		return
	if _opp_seen_state == S.GUARD and _roll(cfg.mixup_chance):
		if rng.randf() < cfg.guard_crush_charge_share:
			_charge_strike(B.HEAVY if _dist() <= t.close_combat_range else B.LIGHT)
		else:
			_tap(B.HEAVY, _clock, -1.0)  # low kick: guard damage
	elif _roll(cfg.mixup_chance):
		if rng.randf() < cfg.charge_strike_share:
			_charge_strike(B.LIGHT)
		else:
			_tap(B.HEAVY, _clock, _rand_height_stick())
	elif me.ki >= t.super1_cost_bars * t.ki_bar_size and _roll(cfg.special_chance) and rng.randf() < cfg.close_rush_share:
		_special(_clock, 0.0)
	else:
		_start_string(_clock)


## Grab (stick back = throw behind), stepping in first if out of grab reach.
func _throw() -> void:
	var t := me.tuning
	var gap := _dist() - _reach(me.def.move(me.def.throw))
	var at := _clock
	if gap > 0.0:
		at += ceili(gap / (t.walk_speed / Tuning.match_rules.tick_rate))
		_walk = Vector2(0.0, 1.0)
		_walk_until = at
	_string_left = 0
	_tap(B.THROW, at, -1.0 if rng.randf() < cfg.back_throw_share else 0.0)


## Taunting is safe-ish with the opponent floored, or far away and seen not
## attacking.
func _taunt_safe(d: float) -> bool:
	if not _seen():
		return false
	if _opp_seen_state == S.KNOCKDOWN:
		return true
	return d >= cfg.taunt_safe_distance and _opp_seen_state != S.ATTACK


## Stop charging once the target is met or the opponent closes in.
func _keep_charging() -> bool:
	if _dist() < cfg.charge_abort_distance or not _holding(B.CHARGE):
		_release(B.CHARGE)
		return false
	return true


func _start_string(at: int) -> void:
	var lights := me.def.light_string.size()
	var longest := maxi(lights - 1, 0)
	# Better players finish more of the string before the finisher.
	var jitter := rng.randi_range(-cfg.string_length_jitter, cfg.string_length_jitter)
	_string_left = clampi(roundi(lerpf(0.0, longest, skill)) + jitter, 0, longest)
	_my_serial = -1
	_tap(B.LIGHT, at)


## Hold LIGHT/HEAVY past the charge threshold, releasing at a random charge.
func _charge_strike(btn: int) -> void:
	var t := me.tuning
	var base := me.def.move(me.def.light_string[0] if btn == B.LIGHT else me.def.heavy)
	var cm := me.def.move(base.charge_move) if base != null else null
	if cm == null:
		_start_string(_clock)
		return
	var hold := t.charge_hold_frames + cm.charge_frame + roundi(cfg.charge_strike_hold_frames * rng.randf_range(cfg.charge_strike_min_share, 1.0))
	_string_left = 0
	_hold(btn, _clock, hold, 0.0)
	if not cm.smash_variants.is_empty() and _roll(cfg.smash_direction_chance):
		# Point the stick through the release frame: directional smash
		# (forward launch, back ground bounce, left / right).
		var dir: Vector2 = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT][rng.randi_range(0, 3)]
		_hold(0, _clock + hold - 1, 2, dir.y, dir.x)


func _dash_attack(d: float) -> void:
	var t := me.tuning
	var per_frame := t.dash_speed / Tuning.match_rules.tick_rate
	var travel := maxf(d - _reach(me.def.move(me.def.dash_attack)) * cfg.dash_attack_reach_share, 0.0)
	_tap(B.DASH, _clock)
	_tap(B.LIGHT, _clock + clampi(ceili(travel / per_frame), 2, t.dash_frames - 1))


func _dash_attack_range() -> float:
	var t := me.tuning
	return _reach(me.def.move(me.def.dash_attack)) + t.dash_speed * t.dash_frames / Tuning.match_rules.tick_rate


## CHARGE held with HEAVY pressed: rush (0), beam (forward), ultimate (back).
func _special(at: int, stick_y: float) -> void:
	_hold(B.CHARGE, at, 4, stick_y)
	_tap(B.HEAVY, at + 1, stick_y)


func _walk_for(v: Vector2) -> void:
	_walk = v
	_walk_until = _next_think


# =============================================================================
# Plan / output
# =============================================================================

## Hold `btn` (0 = only the stick) from `at`. stick_y NAN leaves the stick
## alone; otherwise the stick is held at (stick_x, stick_y).
func _hold(btn: int, at: int, frames: int, stick_y: float = NAN, stick_x: float = 0.0) -> void:
	var sy := NO_STICK if is_nan(stick_y) else roundi(stick_y * InputFrame.MOVE_SCALE)
	var sx := roundi(stick_x * InputFrame.MOVE_SCALE)
	_plan.append(PackedInt32Array([at, at + maxi(frames, 1), btn, sy, sx]))


func _tap(btn: int, at: int, stick_y: float = NAN, stick_x: float = 0.0) -> void:
	_hold(btn, at, 1, stick_y, stick_x)


## Stop holding / cancel future presses of `btn` from this tick on.
func _release(btn: int) -> void:
	for i in range(_plan.size() - 1, -1, -1):
		var p := _plan[i]
		if p[2] != btn:
			continue
		if p[0] >= _clock:
			_plan.remove_at(i)
		else:
			p[1] = mini(p[1], _clock)
			_plan[i] = p


func _holding(btn: int) -> bool:
	for p in _plan:
		if p[2] == btn and p[1] > _clock:
			return true
	return false


## A hold (not a tap) of any of `mask` is active this tick.
func _pressing_long(mask: int) -> bool:
	for p in _plan:
		if p[2] & mask and p[0] <= _clock and _clock < p[1] and p[1] - p[0] > 1:
			return true
	return false


func _clear_plan() -> void:
	_plan.clear()
	_dodge_at = -1
	_walk_until = 0


func _emit() -> InputFrame:
	var f := InputFrame.new()
	var mv := _walk if _clock < _walk_until else Vector2.ZERO
	var keep: Array[PackedInt32Array] = []
	for p in _plan:
		if p[0] <= _clock and _clock < p[1]:
			f.held |= p[2]
			if p[3] != NO_STICK:
				mv = Vector2(p[4], p[3]) / float(InputFrame.MOVE_SCALE)
		if p[1] > _clock + 1:
			keep.append(p)
	_plan = keep
	f.set_move(mv)
	if _dodge_at >= 0 and _dodge_at <= _clock:
		f.dodge = _dodge_dir as InputFrame.Dodge
		_dodge_at = -1
	_last_held = f.held
	_last_move = mv
	return f


## Hitstop: keep long holds (no fresh edges), let go of taps, no dodges.
func _frozen_frame() -> InputFrame:
	var f := InputFrame.new()
	for p in _plan:
		if p[0] <= _clock and _clock + 1 < p[1]:
			f.held |= p[2]
	f.held &= _last_held
	f.set_move(_last_move)
	_last_held = f.held
	return f


func _idle_frame() -> InputFrame:
	_clear_plan()
	_last_held = 0
	_last_move = Vector2.ZERO
	return InputFrame.new()


# =============================================================================
# Helpers
# =============================================================================

## Difficulty value for this level (x = weakest, y = strongest).
func _p(v: Vector2) -> float:
	return lerpf(v.x, v.y, skill)


func _roll(v: Vector2) -> bool:
	return rng.randf() < _p(v)


func _reaction() -> int:
	return roundi(_p(cfg.reaction_frames)) + rng.randi_range(0, roundi(_p(cfg.reaction_jitter_frames)))


func _link_error() -> int:
	return rng.randi_range(0, roundi(_p(cfg.link_error_frames)))


## Weighted random key (Dictionary order is insertion order: deterministic).
func _pick(weights: Dictionary) -> StringName:
	var total := 0.0
	for k: StringName in weights:
		total += maxf(weights[k], 0.0)
	var r := rng.randf() * total
	for k: StringName in weights:
		r -= maxf(weights[k], 0.0)
		if r <= 0.0:
			return k
	return weights.keys().back()


func _rand_height_stick() -> float:
	return [1.0, 0.0, -1.0][rng.randi_range(0, 2)]


func _strafe_sign() -> float:
	return -1.0 if rng.randf() < 0.5 else 1.0


func _jab() -> MoveData:
	return me.def.move(me.def.light_string[0])


func _dist() -> float:
	var d := opp.global_position - me.global_position
	d.y = 0.0
	return d.length()


func _near_wall() -> bool:
	var p := me.global_position
	return Vector2(p.x, p.z).length() > Tuning.match_rules.arena_radius - cfg.charge_abort_distance


## How far (ground meters, center to center) `m` can hit, lunge included.
func _reach(m: MoveData) -> float:
	if m == null:
		return 0.0
	var lunge := m.lunge_speed * m.lunge_frames / float(Tuning.match_rules.tick_rate)
	return m.hitbox_offset.z + m.hitbox_length + m.hitbox_radius + lunge + me.tuning.body_radius


# =============================================================================
# Rollback
# =============================================================================

func save_state() -> Dictionary:
	var s := {"rng": rng.state}
	for k in SAVED:
		var v: Variant = get(k)
		s[k] = v.duplicate(true) if v is Array else v
	return s


func load_state(s: Dictionary) -> void:
	rng.state = s["rng"]
	for k in SAVED:
		var v: Variant = s[k]
		if k == &"_plan":
			_plan.assign((v as Array).duplicate(true))
		else:
			set(k, v)

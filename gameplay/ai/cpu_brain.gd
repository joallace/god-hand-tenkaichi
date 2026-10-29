class_name CpuBrain
extends RefCounted
## The CPU fighter. Every sim tick it looks at the match through the
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
##      guard, throw pre-break); out of hitstun at frame disadvantage it
##      guards first (wary_chance) instead of pressing into the next strike,
##      and a habit it has learned is read ahead of time (see Adaptation)
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
## Crowds (co-op / teams): with several enemies the brain picks its target
## by a sticky score (distance, who hit it last, free attack tokens, low
## health) and steers its fighter there with InputFrame.target_request. It
## also defends against the nearest other enemy attacking it. In co-op an
## enemy needs an EncounterDirector token on its (team-0) target before it
## starts an attack (melee: strings, heavies, throws, dash attacks, punishes;
## ranged: blasts, beams, supers); without one it hovers at mid range,
## circling, guarding, charging ki or taunting. With one enemy and tokens off
## (versus) none of this draws from the RNG, so 1v1 decisions are unchanged.
##
## Co-op ally (team 0): a downed teammate nearby is a high-priority goal once
## noticed (reaction + revive_delay_frames): walk to it and hold TAUNT until
## it is up, unless an enemy near either of them is engaging (melee token on
## the ally or the downed mate, grab lock, attack on the ally), which is
## ignored once the mate has bled out past revive_desperate_bleed_ratio. It
## still defends while walking or reviving (a hit cancels the revive; the goal
## is re-checked every tick). The ally also scores targets by their distance
## to its partner, regroups when it strays past ally_leash_distance, and
## (friendly fire on) steps out of a partner's beam line. Versus never has a
## downed teammate or a co-op ally, so none of it runs there.
##
## Adaptation: the brain remembers the opponent's habit (the melee string
## opener it keeps starting in reach, its delay after their previous attack, how
## often it lands), as heat that builds per repeat and fades over
## habit_memory_frames. Heat makes it guard out of hitstun more often, swing
## less at close range, and past habit_read_heat it answers the predicted next
## opener before seeing it (timed dodge, counter guard, back off, guard). It
## only learns from what it perceived (reaction delay included) and keeps the
## habit across rounds.
##
## Determinism: seeded RandomNumberGenerator; every decision variable
## round-trips through save_state()/load_state().

const S := Fighter.State
const B := InputFrame.Btn
const D := InputFrame.Dodge
const K := EncounterDirector.Kind
## `_plan` entry: [start_clock, end_clock (exclusive), button (0 = stick
## only), stick_y, stick_x] (stick in InputFrame.MOVE_SCALE units).
const NO_STICK := 1 << 16
## Buttons that start an attack from neutral (co-op: need a token).
const ATTACK_BUTTONS := B.LIGHT | B.HEAVY | B.THROW | B.BLAST | B.SPECIAL
const CAN_ACT: Array[int] = [S.IDLE, S.WALK, S.GUARD, S.DASH, S.CHARGE, S.CHARGE_END]
const CAN_DODGE: Array[int] = [S.IDLE, S.WALK, S.GUARD, S.DASH, S.CHARGE_END]
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
	&"_next_think", &"_opp_slot", &"_opp_state", &"_opp_serial", &"_opp_known_at", &"_opp_seen_state",
	&"_threat_serial", &"_my_serial", &"_my_state", &"_my_frame", &"_reflex_done", &"_rise_done",
	&"_string_left", &"_chase", &"_followup", &"_counter_until", &"_contact_serial",
	&"_contact_blocked", &"_punish_key", &"_last_held", &"_last_move", &"_mash_next",
	&"_want_slot", &"_want_since", &"_last_hit_by", &"_side_slot", &"_side_serial",
	&"_side_known_at", &"_side_answered_slot", &"_side_answered_serial", &"_had_token",
	&"_down_slot", &"_down_known_at", &"_reviving", &"_revive_threat_at",
	&"_recovered_at", &"_wary_until", &"_habit_move", &"_habit_heat", &"_habit_serial",
	&"_opp_attack_end", &"_habit_delay", &"_read_hit_at", &"_read_until",
]
## Kept by reset() between rounds: what was learned about the opponent.
const KEPT_ON_RESET: Array[StringName] = [&"_habit_move", &"_habit_heat", &"_habit_delay"]

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
## Slot of the fighter being watched as `opp` (me.target; -1 = none).
var _opp_slot: int = -1
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
## Crowds: target slot requested (-1 = none yet) and since when; who hit me
## last.
var _want_slot: int = -1
var _want_since: int = 0
var _last_hit_by: int = -1
## Crowds: another enemy attacking me (slot, move serial), when that is
## noticed, and the last such attack already answered.
var _side_slot: int = -1
var _side_serial: int = -1
var _side_known_at: int = 0
var _side_answered_slot: int = -1
var _side_answered_serial: int = -1
## Co-op: held an attack token last tick (a new grant wakes the neutral game).
var _had_token: bool = false
## Co-op: downed teammate to revive (-1 = none), when that is noticed, and
## whether the revive goal is being carried out.
var _down_slot: int = -1
var _down_known_at: int = 0
var _reviving: bool = false
## Clock of the last tick a revive threat was seen (the coast must stay clear
## for revive_clear_frames before a revive starts).
var _revive_threat_at: int = -(1 << 30)
## Clock of the first actionable tick after the last hitstun, and the end of
## the guard-first window it may have opened.
var _recovered_at: int = -(1 << 30)
var _wary_until: int = 0
## Adaptation: the opponent's habitual opener (move id, &"" = none), heat
## 0..1, the last opener serial counted, when the target's last attack ended
## (my clock), and the habit's usual delay after that end (-1 = unknown).
var _habit_move: StringName = &""
var _habit_heat: float = 0.0
var _habit_serial: int = -1
var _opp_attack_end: int = -(1 << 30)
var _habit_delay: int = -1
## Predicted habit hit already handled, and the end of a read being played
## (the habit's own perceived start doesn't re-plan the defense meanwhile).
var _read_hit_at: int = -(1 << 30)
var _read_until: int = 0


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
		if k not in KEPT_ON_RESET:
			set(k, fresh.get(k))
	rng.state = rng_state
	director = keep[0]
	slot = keep[1]
	me = keep[2]
	opp = keep[3]


func think() -> InputFrame:
	var has_opp := _resolve()
	if me == null or director.phase != MatchDirector.Phase.FIGHT:
		return _idle_frame()
	# No target (every enemy entering / vanished): only a revive to attend to.
	if not has_opp and _downed_mate() == null:
		return _idle_frame()
	if me.hitstop_left() > 0 or director.world_freeze > 0:
		return _frozen_frame()
	_clock += 1
	_habit_heat = maxf(_habit_heat - 1.0 / maxf(_p(cfg.habit_memory_frames), 1.0), 0.0)
	if has_opp:
		_perceive()
		_perceive_side()
	_track_my_state()
	_perceive_downed()
	if has_opp:
		_wake_on_token()
		_decide()
	else:
		_decide_alone()
	var f := _emit()
	f.target_request = _choose_target()
	return f


# =============================================================================
# Perception
# =============================================================================

## Binds `me` and follows its target as `opp` (null target = no thinking).
## A new target is perceived from scratch (reaction delay applies again).
func _resolve() -> bool:
	if director == null:
		return false
	if me == null:
		me = director.fighter_for_slot(slot)
		if me == null:
			return false
		me.event.connect(_on_my_event)
	var want := me.target.slot if me.target else -1
	if want != _opp_slot:
		if _opp_slot >= 0:
			_opp_state = -1
			_opp_serial = -1
		_opp_slot = want
	_bind_opp()
	return opp != null


func _bind_opp() -> void:
	var f := director.fighter_for_slot(_opp_slot) if _opp_slot >= 0 else null
	if f == opp:
		return
	if opp != null and opp.event.is_connected(_on_opp_event):
		opp.event.disconnect(_on_opp_event)
	opp = f
	if opp != null:
		opp.event.connect(_on_opp_event)


## A new opponent state or move becomes known after the reaction delay.
func _perceive() -> void:
	var st := opp.state
	var serial := opp.current_move_serial()
	if st != _opp_state or (st == S.ATTACK and serial != _opp_serial):
		if _opp_state == S.ATTACK and st != S.ATTACK:
			_opp_attack_end = _clock
		_opp_state = st
		_opp_serial = serial
		_opp_known_at = _clock + _reaction()
	if _clock >= _opp_known_at:
		_opp_seen_state = _opp_state
		if _opp_state == S.ATTACK and _habit_serial != _opp_serial:
			_habit_serial = _opp_serial
			_note_opener()


func _seen() -> bool:
	return _clock >= _opp_known_at


func _track_my_state() -> void:
	var st := me.state
	if _my_state == S.HITSTUN and st != S.HITSTUN:
		_recovered_at = _clock
	if st != _my_state or me.state_frame() < _my_frame:
		_my_state = st
		_reflex_done = false
		_rise_done = false
		if st in INTERRUPTED:
			_clear_plan()
			_followup = false
			_chase = false
			_wary_until = 0
			_read_until = 0
	_my_frame = me.state_frame()


func _on_my_event(kind: StringName, data: Dictionary) -> void:
	if kind == &"perfect_dodge" and data.get("slot", -1) == slot:
		_counter_until = _clock + me.tuning.perfect_dodge_counter_frames
	elif kind == &"hit" and data.get("slot", -1) == slot:
		_last_hit_by = data.get("attacker_slot", -1)
		if not data.get("blocked", false) and data.get("combo", 0) == 1:
			_note_habit_hit(director.fighter_for_slot(_last_hit_by))


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
			if not _reflex_done:
				_reflex_done = true
				_on_blocked()
			_defend()
			_keep_wary(true)
		S.REVIVE:
			_revive_hold()
		_:
			if me.state not in CAN_ACT:
				return
			var mate := _revive_wanted()
			if mate == null:
				_stop_revive()
			if me.state == S.CHARGE and mate == null and _keep_charging():
				return
			if mate == null and not _read_habit() and _recovered_at == _clock:
				_on_recover()
			_keep_wary(false)
			if _defend():
				# Only the guard-first window is up: a seen opening still gets punished.
				if _wary_only() and _punish():
					_wary_until = 0
				return
			if me.state == S.DASH or me.state == S.CHARGE_END:
				return  # only a dodge / guard (above) gets out of these
			if _clear_partner_beam():
				return
			if mate != null:
				_go_revive(mate)
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


## Knocked down: flip out in the air, or pick a get-up once on the floor
## (roll, get-up strike with an enemy in its reach, or quick rise).
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
	elif opp != null and _dist() <= _reach(me.def.move(me.def.getup_attack)) and _roll(cfg.wakeup_attack_chance):
		_tap(B.LIGHT, at)  # get-up strike
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
	if not _may_attack(K.MELEE) or not _roll(cfg.punish_chance):
		return
	var at := mini(_clock + _reaction(), _counter_until - 1)
	if opp.state == S.GUARD_BREAK:
		_start_string(at)
	else:
		_tap(B.HEAVY, at, _rand_height_stick())


# --- 2. Defense ---------------------------------------------------------------

## Answer a newly noticed attack: the target's first, else another enemy's
## (crowds). True while a defense is underway.
func _defend() -> bool:
	if _opp_state == S.ATTACK and _seen() and _threat_serial != _opp_serial:
		_threat_serial = _opp_serial
		var m := opp.current_move()
		# A read of this very opener (on time) is already playing out: let it.
		var hit_at := _clock + (m.startup - opp.state_frame() - 1 if m != null else 0)
		if not (_clock < _read_until and m != null and m.id == _habit_move
				and absi(hit_at - _read_hit_at) <= cfg.habit_read_slack_frames):
			if _clock < _read_until:
				_read_until = 0  # off-beat: defend for real
			_answer(opp, false)
	elif _side_slot >= 0 and _clock >= _side_known_at and not _defending() \
			and (_side_answered_slot != _side_slot or _side_answered_serial != _side_serial):
		_side_answered_slot = _side_slot
		_side_answered_serial = _side_serial
		var a := director.fighter_for_slot(_side_slot)
		if a != null and a.state == S.ATTACK and a.current_move_serial() == _side_serial:
			_answer(a, true)
	return _defending()


func _defending() -> bool:
	return _dodge_at >= _clock or _holding(B.GUARD)


## Pick the defense against attacker `a`'s current move (`side`: `a` isn't
## the target, so it may be behind, where guards fail).
func _answer(a: Fighter, side: bool) -> void:
	var m := a.current_move()
	if m == null:
		return
	match m.spawn_kind:
		&"ki_blast":
			_defend_blast(m, a)
		&"beam":
			_defend_beam(m, a)
		_:
			if a.attack_phase() <= 1 and _dist_to(a) <= _reach(m) + cfg.reach_margin:
				if m.is_throw:
					_defend_throw(m, a)
				else:
					_defend_melee(m, a, side)


func _defend_melee(m: MoveData, a: Fighter, side: bool = false) -> void:
	if not _roll(cfg.defend_chance):
		return
	var t := me.tuning
	var hit_in := m.startup - a.state_frame() - 1  # ticks until its first active frame
	var can_dodge := me.state in CAN_DODGE or me.state == S.CHARGE
	var pose := _guard_pose_for(m)
	var res := m.guard_result(pose)
	var can_guard := res != MoveData.GuardResult.UNBLOCKABLE and not (side and _is_behind(a))
	# A ki guard with too little ki left crashes the guard: rather dodge.
	var crashes := res == MoveData.GuardResult.KI_GUARD and me.ki <= m.guard_ki_cost
	var stick := _pose_stick(pose)
	var window := me.guard_vanish_window()
	var opener := a.move_opens_string()
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
func _defend_throw(m: MoveData, a: Fighter) -> void:
	if not _roll(cfg.defend_chance):
		return
	var t := me.tuning
	var hit_in := m.startup - a.state_frame() - 1
	_clear_plan()
	if hit_in >= 1 and _roll(cfg.throw_break_chance):
		var lead := rng.randi_range(0, mini(t.throw_break_frames - 1, hit_in - 1))
		var at := _clock + hit_in - lead
		if me.frames_since_guard_press() + (at - _clock) >= t.guard_vanish_rearm_frames:
			_tap(B.GUARD, at)
			return
	if (me.state in CAN_DODGE or me.state == S.CHARGE) and _roll(cfg.dodge_preference):
		_dodge(D.BACK, _clock + hit_in)


func _defend_blast(m: MoveData, a: Fighter) -> void:
	if m.spawn_move == null or not _roll(cfg.projectile_defend_chance):
		return
	var speed := maxf(m.spawn_move.travel_speed / Tuning.match_rules.tick_rate, 0.01)
	var hit_in := m.spawn_frame - a.state_frame() - 1 + ceili(maxf(_dist_to(a) - m.spawn_move.hitbox_offset.z, 0.0) / speed)
	if hit_in > cfg.blast_look_ahead_frames + m.spawn_frame:
		return  # too far to bother; it may not even reach
	_clear_plan()
	if me.state in CAN_DODGE and _roll(cfg.dodge_preference):
		_dodge(D.LEFT if rng.randf() < 0.5 else D.RIGHT, _clock + hit_in)
	else:
		_hold(B.GUARD, _clock, maxi(hit_in, 0) + m.spawn_move.guard_stun + cfg.guard_tail_frames,
				_pose_stick(_guard_pose_for(m.spawn_move)))


## Beams out-damage a guard; sway off the line as the head arrives (it grows
## out at travel_speed and homes, so an early sway gets tracked) and keep
## strafing.
func _defend_beam(m: MoveData, a: Fighter) -> void:
	if not _roll(cfg.projectile_defend_chance):
		return
	var fire_in := m.spawn_frame - a.state_frame() - 1
	var shot := m.spawn_move
	var hit_in := fire_in
	if shot.travel_speed > 0.0:
		var speed := shot.travel_speed / Tuning.match_rules.tick_rate
		var gap := minf(maxf(_dist_to(a) - shot.hitbox_offset.z - shot.hitbox_radius, 0.0), shot.hitbox_length)
		hit_in += ceili(gap / speed)
	_clear_plan()
	if not (me.state in CAN_DODGE or me.state == S.CHARGE) or not _roll(cfg.smart_dodge_chance):
		_hold(B.GUARD, _clock, maxi(fire_in, 0) + shot.active, _pose_stick(_guard_pose_for(shot)))
		return
	var dir := D.LEFT if rng.randf() < 0.5 else D.RIGHT
	_dodge(dir, _clock + hit_in)
	_walk = Vector2(-1.0 if dir == D.LEFT else 1.0, 0.0)
	_walk_until = _clock + maxi(hit_in, 0) + cfg.beam_strafe_frames


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
		_link_special(m, 1.0 if rng.randf() < cfg.super_cancel_rush_share else 0.0)
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
				and m.total() - opp.state_frame() > _jab().startup and not _string_continues(m))
	if not open and not recovering:
		return false
	var d := _dist()
	var in_reach := d <= _reach(_jab())
	var dash_reach := _dash_attack_range()
	if not in_reach and (not recovering or d > dash_reach or not me.can_dash()):
		return false
	if not _may_attack(K.MELEE):
		return false  # asked for a token; retry while the opening lasts
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
	_release(B.GUARD)
	if _regroup():
		return
	if _limited() and _tokened_neutral(d):
		return
	if _taunt_safe(d) and me.ki < me.ki_max() and _roll(cfg.taunt_chance):
		_tap(B.TAUNT, _clock)
		return
	if d <= _reach(_jab()):
		# A known habit (they keep hitting first up close) makes it swing less.
		if rng.randf() < _p(cfg.aggression) * (1.0 - _habit_bias()):
			_close_attack()
		elif rng.randf() < cfg.close_guard_share:
			_hold(B.GUARD, _clock, roundi(_p(cfg.think_interval)) + cfg.guard_tail_frames)
		else:
			_walk_for(Vector2(_strafe_sign(), -1.0 if not _near_wall() else 0.0))
		return
	var pick := _pick(_neutral_options(d))
	var kind := _option_token(pick)
	if kind >= 0 and not _may_attack(kind):
		_tokenless(d)
		return
	_do_option(pick, d)


## Far-range neutral options and their weights (insertion order matters:
## _pick walks it in order).
func _neutral_options(d: float) -> Dictionary:
	var t := me.tuning
	var bar := t.ki_bar_size
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
	return options


## The attack token a neutral option needs (-1 = none).
func _option_token(option: StringName) -> int:
	match option:
		&"approach":
			return K.MELEE
		&"blast", &"beam", &"ultimate", &"rush":
			return K.RANGED
	return -1


func _do_option(option: StringName, d: float) -> void:
	var t := me.tuning
	var bar := t.ki_bar_size
	match option:
		&"approach":
			if d > cfg.dash_distance and me.can_dash():
				_tap(B.DASH, _clock)
			elif d <= _dash_attack_range() and me.can_dash() and rng.randf() < _p(cfg.mixup_chance):
				_dash_attack(d)
			else:
				_walk_for(Vector2(_strafe_sign() * rng.randf_range(0.0, cfg.approach_strafe), 1.0))
		&"blast":
			_tap(B.BLAST, _clock)
		&"charge":
			var need := (roundi(_p(cfg.charge_target_bars)) * bar - me.ki) / t.ki_charge_per_frame
			_hold(B.CHARGE, _clock, t.charge_windup_frames + maxi(ceili(need), 1))
		&"beam":
			_special(_clock, 0.0)
		&"ultimate":
			_special(_clock, -1.0)
		&"rush":
			_special(_clock, 1.0)
		_:
			_walk_for(Vector2(_strafe_sign(), 0.0))


func _close_attack() -> void:
	if not _may_attack(K.MELEE):
		_tokenless(_dist())
		return
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
		_special(_clock, 1.0)
	else:
		_start_string(_clock)


## Grab (stick back = throw behind), stepping in first if out of grab reach.
func _throw() -> void:
	if director.encounter != null and not director.encounter.request_grab(me, opp):
		_start_string(_clock)  # someone else has them in a grab
		return
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
	var travel := maxf(d - _reach(me.def.move(me.def.dash_attack)) * cfg.dash_attack_reach_share, 0.0)
	_tap(B.DASH, _clock)
	# LIGHT on the dash frame that covers `travel` (inside the dash attack window).
	_tap(B.LIGHT, _clock + me.dash_frames_to_cover(travel))


func _dash_attack_range() -> float:
	return _reach(me.def.move(me.def.dash_attack)) + me.dash_travel_distance()


## CHARGE held with HEAVY pressed: rush (0), beam (forward), ultimate (back).
func _special(at: int, stick_y: float) -> void:
	_hold(B.CHARGE, at, 4, stick_y)
	_tap(B.HEAVY, at + 1, stick_y)


func _walk_for(v: Vector2) -> void:
	_walk = v
	_walk_until = _next_think


# --- 4b. Frame disadvantage and adaptation --------------------------------------

## First actionable tick after hitstun. With the attacker still in reach and
## not seen punishable, they act first: guard (wary_chance, raised by a known
## habit) rather than walk or swing into their next strike. Whatever was seen
## of them before the hitstun is stale for punishing.
func _on_recover() -> void:
	var a := director.fighter_for_slot(_last_hit_by)
	if a == null or a.team == me.team or a.is_ko() or a.def == null or a.def.light_string.is_empty():
		return
	if _dist_to(a) > _reach(a.def.move(a.def.light_string[0])) + cfg.reach_margin:
		return
	if a == opp and _punishable():
		return
	_punish_key = _opp_known_at
	if rng.randf() >= _p(cfg.wary_chance) + _habit_bias():
		return
	_clear_plan()
	_wary_until = _clock + roundi(_p(cfg.wary_frames))
	_next_think = maxi(_next_think, _wary_until)


## The target is seen recovering from the move it is still in, with more
## frames left than my jab needs: no need to be wary, punish it.
func _punishable() -> bool:
	var m := opp.current_move()
	if not _seen() or _opp_state != S.ATTACK or _opp_serial != opp.current_move_serial() or m == null:
		return false
	return opp.attack_phase() == 2 and m.total() - opp.state_frame() > _jab().startup \
		and not _string_continues(m)


## The target's move `m` can still be cancelled into a follow-up that starts
## as fast as my jab (a jab after a jab): pressing now trades at best, so
## its "recovery" is no opening. A follow-up slower than my jab is beaten.
func _string_continues(m: MoveData) -> bool:
	if m.cancel_into.is_empty() or m.cancel_requires_hit or opp.state_frame() >= m.cancel_end:
		return false
	for id in m.cancel_into:
		var next := opp.def.move(id) if opp.def else null
		if next != null and next.startup <= _jab().startup:
			return true
	return false


## Just started blocking: the attacker may be stringing, so (wary_chance)
## keep guarding past the guard stun instead of letting go into the next hit.
func _on_blocked() -> void:
	if _clock < _wary_until or _clock < _read_until:
		return
	if rng.randf() >= _p(cfg.wary_chance) + _habit_bias():
		return
	_wary_until = _clock + roundi(_p(cfg.wary_frames))
	_next_think = maxi(_next_think, _wary_until)


## Keep the guard-first window's guard held (re-pressed after a defense that
## replaced it); a blocked hit (`blocked`: in guard stun) extends the window.
func _keep_wary(blocked: bool) -> void:
	if _clock >= _wary_until:
		return
	if blocked:
		_wary_until = maxi(_wary_until, _clock + roundi(_p(cfg.wary_frames)))
		_next_think = maxi(_next_think, _wary_until)
	if _dodge_at >= _clock or _clock < _read_until or me.state not in [S.IDLE, S.WALK, S.GUARD, S.GUARD_STUN]:
		return
	# Extend the hold without a release in between (a fresh press could vanish).
	var held_until := _clock
	for p in _plan:
		if p[2] == B.GUARD and p[0] <= _clock:
			held_until = maxi(held_until, p[1])
	if held_until < _wary_until:
		_walk_until = 0
		_hold(B.GUARD, maxi(held_until, _clock), _wary_until - maxi(held_until, _clock))


## Only the guard-first window's guard is up (no planned dodge or read).
func _wary_only() -> bool:
	return _clock < _wary_until and _dodge_at < _clock and _clock >= _read_until


## 0..habit_max_bias: how strongly the known habit sways decisions.
func _habit_bias() -> float:
	return _habit_heat * _p(cfg.habit_max_bias)


## A perceived target attack: a melee string opener started in reach. The
## same opener again soon after their previous attack ended (a loop: jab,
## wait, jab) heats the habit and refines its delay; another opener takes
## over (keeping part of the heat).
func _note_opener() -> void:
	var m := opp.current_move()
	if m == null or not opp.move_opens_string() or m.spawn_kind != &"" or m.is_throw \
			or _dist() > _reach(m) + cfg.reach_margin:
		return
	var delay := _clock - opp.state_frame() - _opp_attack_end
	if m.id != _habit_move:
		_habit_heat *= cfg.habit_switch_keep
		_habit_move = m.id
		_habit_delay = -1
	elif delay <= cfg.habit_delay_max_frames:
		_habit_delay = delay if _habit_delay < 0 else (_habit_delay + delay) / 2
		_habit_heat = minf(_habit_heat + _p(cfg.habit_gain), 1.0)


## The habit landed as a fresh combo on me: it works, so it heats faster.
func _note_habit_hit(a: Fighter) -> void:
	if a == null or a != opp or _habit_move == &"":
		return
	var m := a.current_move()
	if m != null and m.id == _habit_move:
		_habit_heat = minf(_habit_heat + _p(cfg.habit_hit_gain), 1.0)


## A hot habit with a known delay: the next opener is expected at the end of
## their attack + delay (the end as seen, or, while their move is seen in
## recovery, where its frame data puts it). If that would hit within
## habit_read_horizon_frames and I'm in its reach, answer it ahead of time
## (once per predicted hit). True if a read was planned this tick.
func _read_habit() -> bool:
	if _habit_delay < 0 or _habit_bias() < cfg.habit_read_heat or _clock < _read_until \
			or me.state not in CAN_DODGE or opp.def == null or not _seen():
		return false
	var m := opp.def.move(_habit_move)
	if m == null:
		return false
	var ends_at := _opp_attack_end
	if _opp_seen_state == S.ATTACK:
		var cur := opp.current_move()
		if cur == null or opp.attack_phase() != 2 or _opp_serial != opp.current_move_serial():
			return false
		ends_at = _clock - opp.state_frame() + cur.total()
	# Ticks to the first active frame of an opener starting at `start`
	# follow _defend_melee's hit_in (start + startup - 1).
	var hit_at := ends_at + _habit_delay + m.startup - 1
	if hit_at <= _clock or hit_at == _read_hit_at or hit_at - _clock > cfg.habit_read_horizon_frames:
		return false
	if _dist() > _reach(m) + cfg.reach_margin:
		return false
	_read_hit_at = hit_at
	if not _roll(cfg.habit_read_chance):
		return false
	var lead := hit_at - _clock
	var options := {&"dodge": cfg.habit_dodge_weight, &"guard": cfg.habit_guard_weight,
		&"backoff": cfg.habit_backoff_weight}
	if lead >= 2:
		options[&"counter"] = cfg.habit_counter_guard_weight
	var pick := _pick(options)
	_clear_plan()
	_wary_until = 0
	_release(B.CHARGE)
	var t := me.tuning
	var end := hit_at + m.active
	match pick:
		&"dodge":
			_dodge(_dodge_for(m), hit_at)
		&"counter":
			var early := rng.randi_range(0, maxi(t.counter_guard_window_frames - 1, 0))
			_hold(B.GUARD, _clock, lead + m.active + m.guard_stun)
			_tap(B.LIGHT, maxi(hit_at - early, _clock + 1), 1.0)
		&"backoff":
			var per_frame := t.walk_speed / Tuning.match_rules.tick_rate
			var need := ceili((_reach(m) + cfg.reach_margin - _dist()) / per_frame)
			if need <= lead:
				_walk = Vector2(0.0, -1.0)
				_walk_until = end
			else:
				_dodge(D.BACK, hit_at)
		_:
			end += m.guard_stun + cfg.guard_tail_frames
			_hold(B.GUARD, _clock, end - _clock)
	_read_until = end
	_next_think = maxi(_next_think, end)
	return true


# --- 5. Crowds (co-op / teams) --------------------------------------------------

## Attack tokens apply to this brain: co-op, me an enemy, my target on team 0.
func _limited() -> bool:
	var enc := director.encounter
	return enc != null and enc.enabled and me.team != EncounterDirector.PROTECTED_TEAM \
		and opp != null and opp.team == EncounterDirector.PROTECTED_TEAM


## May I start a `kind` attack on my target now? Always (and without touching
## the RNG) when tokens don't apply; otherwise asks the EncounterDirector
## (the request queues and is granted on a later tick).
func _may_attack(kind: int) -> bool:
	if not _limited():
		return true
	return director.encounter.request_token(me, opp, kind)


## Neutral with a token in hand: go use it (melee: close in and attack;
## ranged: one of the ranged options). False = no usable token.
func _tokened_neutral(d: float) -> bool:
	var enc := director.encounter
	if enc.holds_token(me, K.MELEE):
		if d <= _reach(_jab()):
			_close_attack()
		elif d > cfg.dash_distance and me.can_dash():
			_tap(B.DASH, _clock)
		elif d <= _dash_attack_range() and me.can_dash() and rng.randf() < _p(cfg.mixup_chance):
			_dash_attack(d)
		else:
			_walk_for(Vector2(_strafe_sign() * rng.randf_range(0.0, cfg.approach_strafe), 1.0))
		return true
	if enc.holds_token(me, K.RANGED):
		var ranged := {}
		var options := _neutral_options(d)
		for k: StringName in options:
			if _option_token(k) == K.RANGED:
				ranged[k] = options[k]
		if not ranged.is_empty():
			_do_option(_pick(ranged), d)
			return true
	return false


## No token: hover at mid range, circling, guarding, charging ki or taunting.
func _tokenless(d: float) -> void:
	if d < cfg.tokenless_min_distance:
		_walk_for(Vector2(_strafe_sign(), -1.0 if not _near_wall() else 0.0))
		return
	if d > cfg.tokenless_max_distance:
		_walk_for(Vector2(_strafe_sign() * rng.randf_range(0.0, cfg.approach_strafe), 1.0))
		return
	var r := rng.randf()
	var guard := cfg.tokenless_guard_share
	var charge := guard + cfg.tokenless_charge_share
	if r < guard:
		_hold(B.GUARD, _clock, roundi(_p(cfg.think_interval)) + cfg.guard_tail_frames)
	elif r < charge and me.ki < me.ki_max() and d >= cfg.charge_abort_distance:
		_hold(B.CHARGE, _clock, maxi(roundi(_p(cfg.think_interval)), 1))
	elif r < charge + cfg.tokenless_taunt_share and _taunt_safe(d) and me.ki < me.ki_max():
		_tap(B.TAUNT, _clock)
	else:
		_walk_for(Vector2(_strafe_sign(), 0.0))


## A token just arrived: think now instead of at the next neutral beat (and
## stop a tokenless ki charge).
func _wake_on_token() -> void:
	if not _limited():
		_had_token = false
		return
	var enc := director.encounter
	var has := enc.holds_token(me, K.MELEE) or enc.holds_token(me, K.RANGED)
	if has and not _had_token and me.state in CAN_ACT:
		_release(B.CHARGE)
		_next_think = mini(_next_think, _clock)
	_had_token = has


## Standing enemies of mine (other teams), in slot order.
func _enemies() -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in director.fighters:
		if f != me and f.team != me.team and f.is_targetable():
			out.append(f)
	return out


## Target to request this tick (-1 = no request: one enemy or none). The
## choice is kept for target_min_hold_frames before it is re-scored.
func _choose_target() -> int:
	var cands := _enemies()
	if cands.size() < 2:
		return -1
	var cur := me.target
	if cur != null and cur.slot == _want_slot and cur in cands \
			and _clock < _want_since + cfg.target_min_hold_frames:
		return _want_slot
	var best: Fighter = null
	var best_score := -INF
	for c in cands:
		var sc := _target_score(c)
		if sc > best_score:
			best = c
			best_score = sc
	if best.slot != _want_slot:
		_want_slot = best.slot
		_want_since = _clock
	return _want_slot


func _target_score(c: Fighter) -> float:
	var sc := -_dist_to(c) * cfg.target_distance_weight
	if c.slot == _last_hit_by:
		sc += cfg.target_last_hit_bonus
	var enc := director.encounter
	if enc != null and (enc.free_tokens(c, K.MELEE) > 0 or me.slot in enc.holders(c, K.MELEE)):
		sc += cfg.target_free_token_bonus
	sc += (1.0 - c.health_ratio()) * cfg.target_low_health_weight
	if _coop_ally():
		var mate := _nearest_mate(c.global_position)
		if mate != null:
			sc -= _flat_dist(c.global_position, mate.global_position) * cfg.ally_partner_distance_weight
	return sc


## Track another enemy (not my target) attacking me; noticed after the
## reaction delay like the target's moves.
func _perceive_side() -> void:
	var a := _side_attacker()
	var s := a.slot if a != null else -1
	var serial := a.current_move_serial() if a != null else -1
	if s != _side_slot or serial != _side_serial:
		_side_slot = s
		_side_serial = serial
		_side_known_at = _clock + _reaction() if s >= 0 else 0


## Nearest enemy other than the target that is attacking me within
## side_threat_range (ties: lower slot).
func _side_attacker() -> Fighter:
	var best: Fighter = null
	var best_d := cfg.side_threat_range
	for f in director.fighters:
		if f == me or f == opp or f.team == me.team or f.state != S.ATTACK or f.target != me:
			continue
		var d := _dist_to(f)
		if d <= best_d:
			best = f
			best_d = d
	return best


## `a` stands behind me (more than 90 degrees off my facing): guards fail.
func _is_behind(a: Fighter) -> bool:
	var to := a.global_position - me.global_position
	to.y = 0.0
	return (-me.global_basis.z).dot(to) < 0.0


# --- 6. Co-op ally: revives, regrouping, partner beams --------------------------

## A team-0 fighter in co-op (tokens on): the human team's CPU ally.
func _coop_ally() -> bool:
	var enc := director.encounter
	return enc != null and enc.enabled and me.team == EncounterDirector.PROTECTED_TEAM


## Closest downed (landed: its bleed-out clock started) teammate within
## revive_max_distance that no other teammate is reviving (ties: lower slot),
## or null. Draws nothing from the RNG.
func _downed_mate() -> Fighter:
	var best: Fighter = null
	var best_d := _p(cfg.revive_max_distance)
	for f in director.fighters:
		if f == me or f.team != me.team or not f.is_downed() or f.bleed_out_ratio() <= 0.0:
			continue
		var r := f.reviving_slot()
		if r >= 0 and r != me.slot:
			continue
		var d := _dist_to(f)
		if d < best_d or (best != null and is_equal_approx(d, best_d) and f.slot < best.slot):
			best = f
			best_d = d
	return best


## A newly downed teammate becomes known after the reaction delay plus
## revive_delay_frames.
func _perceive_downed() -> void:
	var m := _downed_mate()
	var s := m.slot if m != null else -1
	if s != _down_slot:
		_down_slot = s
		_down_known_at = _clock + _reaction() + roundi(_p(cfg.revive_delay_frames)) if s >= 0 else 0


## The downed teammate to go and revive now (noticed, and safe enough), or null.
func _revive_wanted() -> Fighter:
	if _down_slot < 0 or _clock < _down_known_at:
		return null
	var mate := director.fighter_for_slot(_down_slot)
	if mate == null or not mate.is_downed():
		return null
	if _revive_threats(mate) > 0:
		_revive_threat_at = _clock
	var clear := _clock - _revive_threat_at >= roundi(_p(cfg.revive_clear_frames))
	if not clear and mate.bleed_out_ratio() < _p(cfg.revive_desperate_bleed_ratio):
		return null
	return mate


## Enemies within revive_safety_radius of me or `mate` that are engaging:
## holding a melee token on either of us (SPEC §5.1; a downed fighter's own
## tokens are released at once, so in practice the ones on me), grabbing me,
## or attacking me.
func _revive_threats(mate: Fighter) -> int:
	var enc := director.encounter
	var engaged: Array[int] = []
	var grabber := -1
	if enc != null:
		engaged.append_array(enc.holders(me, K.MELEE))
		engaged.append_array(enc.holders(mate, K.MELEE))
		grabber = enc.grab_holder(me)
	var r := cfg.revive_safety_radius
	var n := 0
	for e in director.fighters:
		if e.team == me.team or e.is_ko() or e.is_entering():
			continue
		if _dist_to(e) > r and _flat_dist(e.global_position, mate.global_position) > r:
			continue
		if e.slot in engaged or e.slot == grabber or (e.target == me and e.attack_phase() >= 0):
			n += 1
	return n


## Walk to the downed teammate, then hold TAUNT (from IDLE / WALK) to revive.
func _go_revive(mate: Fighter) -> void:
	if not _reviving:
		_reviving = true
		_release(B.GUARD)
		_release(B.CHARGE)
	if _dist_to(mate) > Tuning.coop.revive_range * cfg.revive_stop_share:
		_release(B.TAUNT)
		_walk = _stick_toward(mate.global_position)
		_walk_until = _clock + 1
		return
	_walk_until = 0
	if me.state != S.IDLE and me.state != S.WALK:
		return
	if _last_held & B.TAUNT:
		_release(B.TAUNT)  # held, yet no revive started: let go and press again
	elif not _holding(B.TAUNT):
		_hold(B.TAUNT, _clock, Tuning.coop.revive_frames + cfg.revive_hold_tail_frames)


## Reviving: keep TAUNT held while the goal stands; defend as usual (an
## answered attack clears the plan, letting TAUNT go).
func _revive_hold() -> void:
	var mate := _revive_wanted()
	if mate == null or mate.reviving_slot() != me.slot:
		_stop_revive()
		return
	_reviving = true
	if opp != null:
		_defend()


func _stop_revive() -> void:
	if not _reviving:
		return
	_reviving = false
	_release(B.TAUNT)
	_walk_until = 0


## No target to fight (every enemy entering or vanished): only revives.
func _decide_alone() -> void:
	if me.state == S.REVIVE:
		_revive_hold()
		return
	if me.state not in CAN_ACT or me.state == S.DASH:
		return
	var mate := _revive_wanted()
	if mate != null:
		_go_revive(mate)
	else:
		_stop_revive()


## Standing teammate nearest to `pos`, or null.
func _nearest_mate(pos: Vector3) -> Fighter:
	var best: Fighter = null
	var best_d := INF
	for f in director.fighters:
		if f == me or f.team != me.team or f.is_ko():
			continue
		var d := _flat_dist(f.global_position, pos)
		if d < best_d:
			best = f
			best_d = d
	return best


## Co-op ally strayed from the team (its target too): walk back to the
## nearest teammate for this think interval.
func _regroup() -> bool:
	if not _coop_ally():
		return false
	var mate := _nearest_mate(me.global_position)
	var leash := cfg.ally_leash_distance
	if mate == null or _dist_to(mate) <= leash or _flat_dist(opp.global_position, mate.global_position) <= leash:
		return false
	_walk_for(_stick_toward(mate.global_position))
	return true


## Friendly fire on: a teammate (seen, after the reaction time) firing a beam
## with me in its line: strafe out of it this tick. Draws nothing from the RNG.
func _clear_partner_beam() -> bool:
	if director.config == null or not director.config.friendly_fire:
		return false
	for f in director.fighters:
		if f == me or f.team != me.team or f.state != S.ATTACK:
			continue
		var m := f.current_move()
		if m == null or m.spawn_kind != &"beam" or f.state_frame() < roundi(_p(cfg.reaction_frames)):
			continue
		var to := me.global_position - f.global_position
		to.y = 0.0
		var along := to.dot(-f.global_basis.z)
		var side := to.dot(f.global_basis.x)
		if along <= 0.0 or along > cfg.ally_beam_clear_range or absf(side) >= cfg.ally_beam_clear_width:
			continue
		var away := f.global_basis.x * (1.0 if side >= 0.0 else -1.0)
		_walk = _stick_toward(me.global_position + away)
		_walk_until = _clock + 1
		return true
	return false


## Fighter-space stick (+Y toward my target, +X strafe right) that walks
## toward world point `p`.
func _stick_toward(p: Vector3) -> Vector2:
	var to := p - me.global_position
	to.y = 0.0
	if to.length_squared() < 0.000001:
		return Vector2.ZERO
	to = to.normalized()
	var b := me.global_basis.orthonormalized()
	return Vector2(to.dot(b.x), to.dot(-b.z))


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
	_gate_attack_presses(f)
	f.set_move(mv)
	if _dodge_at >= 0 and _dodge_at <= _clock:
		f.dodge = _dodge_dir as InputFrame.Dodge
		_dodge_at = -1
	_last_held = f.held
	_last_move = mv
	return f


## Co-op safety net: a fresh attack press from neutral while holding no
## token (one granted earlier may have expired before the planned press) is
## dropped and a token requested again. Presses while defending (counter
## guard from a held guard) are left alone.
func _gate_attack_presses(f: InputFrame) -> void:
	var fresh := f.held & ~_last_held & ATTACK_BUTTONS
	if fresh == 0 or not _limited() or me.state not in CAN_ACT or me.state == S.GUARD:
		return
	var enc := director.encounter
	if enc.holds_token(me, K.MELEE) or enc.holds_token(me, K.RANGED):
		return
	enc.request_token(me, opp, K.MELEE)
	f.held &= ~fresh
	for b: int in [B.LIGHT, B.HEAVY, B.THROW, B.BLAST, B.SPECIAL]:
		if fresh & b:
			_release(b)


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
	return _dist_to(opp)


func _dist_to(f: Fighter) -> float:
	var d := f.global_position - me.global_position
	d.y = 0.0
	return d.length()


func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _near_wall() -> bool:
	var p := me.global_position
	return Vector2(p.x, p.z).length() > director.arena_radius - cfg.charge_abort_distance


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

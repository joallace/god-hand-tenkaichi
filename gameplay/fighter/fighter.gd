class_name Fighter
extends CombatEntity
## A playable fighter: deterministic 60 Hz state machine driven by InputFrames.
##
## PUBLIC CONTRACT (used by MatchDirector, CombatSystem, cameras, HUD) — keep
## these names/signatures stable:
##
##   vars:    slot: int, opponent: Fighter, health: float, ki: float,
##            combo_hits: int, guard_health: float, def: CharacterDef,
##            tuning: FighterTuning
##   signals: health_changed(value: float, max_value: float)
##            ki_changed(value: float, max_value: float)
##            combo_changed(hits: int)          # hits landed BY this fighter
##            state_changed(state_name: StringName)
##            event(kind: StringName, data: Dictionary)
##   funcs:   feed_input(frame: InputFrame), sim_tick(tick: int),
##            reset_for_round(xform: Transform3D), set_control_enabled(bool),
##            is_ko() -> bool, health_ratio() -> float,
##            save_state() -> Dictionary, load_state(Dictionary)
##   added:   ki_max() -> float, ki_bars_full() -> int,
##            current_state_name() -> StringName, is_invulnerable() -> bool,
##            is_vanished() -> bool, is_airborne() -> bool,
##            current_move() -> MoveData, current_pose() -> StringName,
##            state_frame() -> int, attack_phase() -> int,
##            dodge_direction() -> int, tint() -> Color,
##            guard_ratio() -> float, in_vanish_battle() -> bool
##
## `event` kinds (payload keys; every payload also has "slot" = emitter slot):
##   &"hit"            {attacker_slot, damage, position, heavy, blocked, combo}
##                     (emitted by the VICTIM)
##   &"perfect_dodge"  {attacker_slot, dodge: StringName, position}
##   &"dodge"          {dodge: StringName}            (dodge started)
##   &"guard_break"    {position}                     (guard health hit 0)
##   &"stagger"        {position}                     (perfect-ducked attacker)
##   &"teleport"       {target_slot, position}        (offensive vanish start)
##   &"vanish"         {exchange, escape: true, position} (vanish escape/battle)
##   &"vanish_battle_end" {exchanges, winner_slot}
##   &"reappear"       {position}                     (end of any vanish)
##   &"ki_blast"       {position}
##   &"super_start"    {kind: &"rush"|&"beam"|&"ultimate"}
##   &"beam"           {position}                     (beam fired)
##   &"ultimate_start" {freeze_frames}
##   &"not_enough_ki"  {needed, have}
##   &"knockdown"      {position}
##   &"wakeup"         {}
##   &"ko"             {position}
##
## Facing convention: the fighter's -Z (Godot forward) points at the opponent
## while locked on. InputFrame.move +Y = toward opponent, +X = strafe right.
## Fighter-space Vector3 (MoveData offsets): x = right, y = up, z = forward.

signal health_changed(value: float, max_value: float)
signal ki_changed(value: float, max_value: float)
signal combo_changed(hits: int)
signal state_changed(state_name: StringName)
signal event(kind: StringName, data: Dictionary)

enum State {
	IDLE, WALK, DASH, JUMP, ATTACK, DODGE, GUARD, GUARD_STUN, GUARD_BREAK,
	CHARGE, HITSTUN, KNOCKDOWN, WAKEUP, TELEPORT, VANISH_WAIT, KO,
}
enum TeleportKind { OFFENSE, ESCAPE }

const STATE_NAMES: Array[StringName] = [
	&"idle", &"walk", &"dash", &"jump", &"attack", &"dodge", &"guard",
	&"guard_stun", &"guard_break", &"charge", &"hitstun", &"knockdown",
	&"wakeup", &"teleport", &"vanish_wait", &"ko",
]
const DODGE_NAMES: Array[StringName] = [&"none", &"duck", &"backflip", &"sway_l", &"sway_r"]
## Number of InputFrame.Btn bits tracked by the press buffer.
const BUFFER_SIZE := 10
const NEVER := 1 << 20

var slot: int = 0
var opponent: Fighter
var health: float
var ki: float
var combo_hits: int = 0
var guard_health: float
var def: CharacterDef
var tuning: FighterTuning

# --- sim state (everything below round-trips through save/load) -------------
var state: State = State.IDLE
var _state_frame: int = 0
## Duration of timed states (stuns, vanish wait); meaning depends on state.
var _state_len: int = 0
var _yaw: float = 0.0
var _vel: Vector3 = Vector3.ZERO
## True when the current state set horizontal velocity this tick (no friction).
var _driven: bool = false
var _move: MoveData
var _move_serial: int = 0
var _move_connected: bool = false
var _move_hit: bool = false
var _spawned: bool = false
var _damage_mult: float = 1.0
var _air_attack_used: bool = false
var _dodge_dir: int = InputFrame.Dodge.NONE
var _counter_frames: int = 0
var _invuln_frames: int = 0
## Frame (of the current knockdown/KO state) the fighter landed; -1 airborne.
var _land_frame: int = -1
var _since_hit_landed: int = NEVER
var _teleports_in_combo: int = 0
var _tp_kind: int = TeleportKind.OFFENSE
var _vanish_battle: VanishBattle
var _buffer: PackedInt32Array = PackedInt32Array()
var _dodge_buf_dir: int = InputFrame.Dodge.NONE
var _dodge_buf_frames: int = 0
var _input: InputFrame = InputFrame.new()
var _control_enabled := false


func _init() -> void:
	_buffer.resize(BUFFER_SIZE)


func _ready() -> void:
	if def == null:
		def = CharacterRegistry.load_def(&"brawler")
	tuning = def.build_tuning(Tuning.fighter)
	health = tuning.max_health
	ki = tuning.ki_start
	guard_health = tuning.guard_health


# =============================================================================
# Public API
# =============================================================================

func feed_input(frame: InputFrame) -> void:
	if not _control_enabled:
		frame = InputFrame.new()
	_input = frame
	var keep := Tuning.input.input_buffer_frames + 1
	for i in BUFFER_SIZE:
		if frame.pressed & (1 << i):
			_buffer[i] = keep
	if frame.dodge != InputFrame.Dodge.NONE:
		_dodge_buf_dir = frame.dodge
		_dodge_buf_frames = keep


func sim_tick(_tick: int) -> void:
	_state_frame += 1
	_driven = false
	_tick_timers()
	match state:
		State.IDLE, State.WALK: _tick_neutral()
		State.DASH: _tick_dash()
		State.JUMP: _tick_jump()
		State.ATTACK: _tick_attack()
		State.DODGE: _tick_dodge()
		State.GUARD: _tick_guard()
		State.GUARD_STUN: _tick_guard_stun()
		State.GUARD_BREAK: _tick_guard_break()
		State.CHARGE: _tick_charge()
		State.HITSTUN: _tick_hitstun()
		State.KNOCKDOWN, State.KO: _tick_knockdown()
		State.WAKEUP: _tick_wakeup()
		State.TELEPORT: _tick_teleport()
		State.VANISH_WAIT: _tick_vanish_wait()
	_apply_motion()
	_age_buffer()


func reset_for_round(xform: Transform3D) -> void:
	global_position = xform.origin
	var fwd := -xform.basis.z
	_set_yaw(atan2(-fwd.x, -fwd.z))
	health = tuning.max_health
	ki = tuning.ki_start
	guard_health = tuning.guard_health
	combo_hits = 0
	_vel = Vector3.ZERO
	_move = null
	_move_serial = 0
	_move_connected = false
	_move_hit = false
	_spawned = false
	_damage_mult = 1.0
	_air_attack_used = false
	_dodge_dir = InputFrame.Dodge.NONE
	_counter_frames = 0
	_invuln_frames = 0
	_land_frame = -1
	_since_hit_landed = NEVER
	_teleports_in_combo = 0
	_vanish_battle = null
	_last_contact_id = -1
	_clear_buffer()
	_enter(State.IDLE)
	health_changed.emit(health, tuning.max_health)
	ki_changed.emit(ki, ki_max())
	combo_changed.emit(combo_hits)


func set_control_enabled(enabled: bool) -> void:
	_control_enabled = enabled
	if not enabled:
		_input = InputFrame.new()
		_clear_buffer()


func is_ko() -> bool:
	return health <= 0.0


func health_ratio() -> float:
	return health / tuning.max_health


func ki_max() -> float:
	return tuning.ki_bar_size * tuning.ki_bars


func ki_bars_full() -> int:
	return floori(ki / tuning.ki_bar_size)


func guard_ratio() -> float:
	return guard_health / tuning.guard_health


func current_state_name() -> StringName:
	return STATE_NAMES[state]


func is_invulnerable() -> bool:
	if _invuln_frames > 0:
		return true
	match state:
		State.TELEPORT, State.KO:
			return true
		State.DODGE:
			return _state_frame >= tuning.dodge_invuln_start \
				and _state_frame < tuning.dodge_invuln_start + tuning.dodge_invuln_frames
		State.KNOCKDOWN:
			return _land_frame >= 0  # lying on the ground
	return false


func is_vanished() -> bool:
	return state == State.TELEPORT


func is_airborne() -> bool:
	return global_position.y > 0.0 or _vel.y > 0.0


func in_vanish_battle() -> bool:
	return _vanish_battle != null and _vanish_battle.active


## The MoveData being performed (null outside the Attack state).
func current_move() -> MoveData:
	return _move if state == State.ATTACK else null


## Visual pose id: the move's pose in Attack, dodge kind in Dodge, else the
## state name.
func current_pose() -> StringName:
	match state:
		State.ATTACK:
			return _move.pose
		State.DODGE:
			return DODGE_NAMES[_dodge_dir]
		State.KNOCKDOWN, State.KO:
			return &"knockdown" if _land_frame >= 0 else &"launched"
	return STATE_NAMES[state]


func state_frame() -> int:
	return _state_frame


## 0 startup, 1 active, 2 recovery; -1 when not attacking.
func attack_phase() -> int:
	if state != State.ATTACK:
		return -1
	if _state_frame < _move.startup:
		return 0
	return 1 if _state_frame < _move.startup + _move.active else 2


func dodge_direction() -> int:
	return _dodge_dir if state == State.DODGE else InputFrame.Dodge.NONE


func current_move_serial() -> int:
	return _move_serial


## Body color: the character color, shifted for P2 so mirrors are readable.
func tint() -> Color:
	var c := def.color if def else Color.WHITE
	if slot % 2 == 1:
		c = Color.from_hsv(fposmod(c.h + 0.5, 1.0), c.s * 0.9, c.v)
	return c


# =============================================================================
# Combat interface (called by CombatSystem)
# =============================================================================

func get_active_hitboxes() -> Array[Hitbox]:
	var out: Array[Hitbox] = []
	if state != State.ATTACK or not _move.is_active_frame(_state_frame):
		return out
	var m := _move
	var hb := Hitbox.new()
	hb.source = self
	hb.attacker = self
	hb.move = m
	var sub := 0
	if m.multi_hit_interval > 0:
		sub = (_state_frame - m.startup) / m.multi_hit_interval
	hb.hit_id = _move_serial * 256 + sub
	hb.forward = _fwd()
	hb.right = _right()
	hb.a = global_position + _to_world3(m.hitbox_offset)
	hb.b = hb.a + hb.forward * m.hitbox_length
	hb.radius = m.hitbox_radius
	hb.origin = global_position
	hb.damage_mult = _damage_mult
	hb.is_melee = true
	out.append(hb)
	return out


func on_hitbox_contact(hb: Hitbox, _victim: Fighter, outcome: Contact) -> void:
	super.on_hitbox_contact(hb, _victim, outcome)
	if outcome == Contact.HIT or outcome == Contact.BLOCKED:
		_move_connected = true
	if outcome == Contact.HIT:
		_move_hit = true


## Hurtbox capsule [a: Vector3, b: Vector3, radius: float], or [] when the
## fighter can't be touched at all. Invulnerability is checked later in
## receive_hit() so that perfect dodges can still be detected.
func get_hurtbox() -> Array:
	if state == State.TELEPORT or state == State.KO:
		return []
	if state == State.KNOCKDOWN and _land_frame >= 0:
		return []
	var h := tuning.body_height
	if state == State.DODGE and _state_frame >= tuning.perfect_dodge_frames:
		if _dodge_dir == InputFrame.Dodge.FORWARD:
			h = tuning.duck_height
	elif state == State.KNOCKDOWN:
		h = tuning.lying_height
	var r := tuning.body_radius
	h = maxf(h, r * 2.0)
	var base := global_position
	return [base + Vector3.UP * r, base + Vector3.UP * (h - r), r]


## Apply a hitbox that overlapped this fighter. Returns the Contact outcome.
func receive_hit(hb: Hitbox) -> Contact:
	if state == State.DODGE and _state_frame < tuning.perfect_dodge_frames:
		_on_perfect_dodge(hb)
		return Contact.PERFECT_DODGE
	if is_invulnerable() or get_hurtbox().is_empty():
		return Contact.NONE
	if _can_block(hb):
		_take_blocked(hb)
		return Contact.BLOCKED
	_take_hit(hb)
	return Contact.HIT


# =============================================================================
# States
# =============================================================================

func _enter(s: State) -> void:
	var prev := state
	state = s
	_state_frame = 0
	if s != State.ATTACK:
		_damage_mult = 1.0
	if prev != s or s == State.ATTACK or s == State.HITSTUN:
		state_changed.emit(STATE_NAMES[s])


func _tick_neutral() -> void:
	_face_opponent(_turn_step())
	if _try_actions(true):
		return
	var m := _input.move()
	if m.is_zero_approx():
		if state != State.IDLE:
			_enter(State.IDLE)
		return
	if state != State.WALK:
		_enter(State.WALK)
	_set_ground_velocity(_to_world2(m) * tuning.walk_speed)


## Shared action table for Idle/Walk/Guard. Returns true if a new state began.
func _try_actions(allow_guard: bool) -> bool:
	if _try_dodge():
		return true
	if _try_teleport():
		return true
	if _consume(InputFrame.Btn.SPECIAL):
		if _try_special():
			return true
	if _consume(InputFrame.Btn.BLAST):
		if _try_ki_blast():
			return true
	if _consume(InputFrame.Btn.HEAVY):
		return _start_move_id(def.heavy)
	if _consume(InputFrame.Btn.LIGHT):
		return _start_move_id(def.light_string[0] if not def.light_string.is_empty() else &"")
	if _consume(InputFrame.Btn.JUMP):
		_start_jump()
		return true
	if _consume(InputFrame.Btn.DASH):
		_enter(State.DASH)
		return true
	if _input.is_held(InputFrame.Btn.CHARGE):
		_enter(State.CHARGE)
		return true
	if allow_guard and _input.is_held(InputFrame.Btn.GUARD):
		_enter(State.GUARD)
		return true
	return false


func _tick_dash() -> void:
	_face_opponent(_turn_step())
	if _try_dodge():
		return
	if _consume(InputFrame.Btn.LIGHT) or _consume(InputFrame.Btn.HEAVY):
		if _start_move_id(def.dash_attack):
			return
	if _state_frame > tuning.dash_frames:
		_enter(State.IDLE)
		return
	_set_ground_velocity(_fwd() * tuning.dash_speed)


func _start_jump() -> void:
	_enter(State.JUMP)
	_air_attack_used = false
	_vel = _to_world2(_input.move()) * tuning.walk_speed
	_vel.y = tuning.jump_velocity
	global_position.y = maxf(global_position.y, 0.001)


func _tick_jump() -> void:
	_face_opponent(_turn_step())
	if not _air_attack_used and (_consume(InputFrame.Btn.LIGHT) or _consume(InputFrame.Btn.HEAVY)):
		_air_attack_used = true
		_start_move_id(def.jump_attack)


func _tick_attack() -> void:
	var m := _move
	var f := _state_frame
	var track := m.startup if m.track_frames < 0 else m.track_frames
	if f <= track:
		_face_opponent(_turn_step())
	if f < m.lunge_frames:
		_set_ground_velocity(_fwd() * m.lunge_speed)
	if m.spawn_kind != &"" and not _spawned and f >= m.spawn_frame:
		_spawned = true
		_spawn_from(m)
	if _move_hit and m.auto_next_on_hit != &"" and f >= m.startup + m.active:
		_start_move_id(m.auto_next_on_hit)
		return
	if _try_teleport():
		return
	if f >= m.cancel_start and f <= m.cancel_end and (_move_connected or not m.cancel_requires_hit):
		if _try_cancel_into(m):
			return
	if f >= m.total() - tuning.dodge_cancel_recovery_frames and _try_dodge():
		return
	if f >= m.total():
		_enter(State.JUMP if is_airborne() else State.IDLE)
		_air_attack_used = true


func _try_cancel_into(m: MoveData) -> bool:
	for btn: int in [InputFrame.Btn.HEAVY, InputFrame.Btn.LIGHT, InputFrame.Btn.BLAST]:
		if not _buffered(btn):
			continue
		for next_id in m.cancel_into:
			var next := def.move(next_id)
			if next != null and next.button == btn:
				_consume(btn)
				if btn == InputFrame.Btn.BLAST:
					return _try_ki_blast()
				return _start_move_id(next_id)
	if m.special_cancelable and _move_connected and _consume(InputFrame.Btn.SPECIAL):
		return _try_special()
	return false


## Neutral attack buttons (used for perfect-dodge counters).
func _try_attack_buttons_neutral() -> bool:
	if _consume(InputFrame.Btn.HEAVY):
		return _start_move_id(def.heavy)
	if _consume(InputFrame.Btn.LIGHT):
		return _start_move_id(def.light_string[0])
	return false


func _start_move_id(move_id: StringName) -> bool:
	var m := def.move(move_id) if move_id != &"" else null
	if m == null:
		return false
	_start_move(m)
	return true


func _start_move(m: MoveData) -> void:
	var mult := 1.0
	if _counter_frames > 0:
		mult = tuning.perfect_dodge_counter_damage_mult
		_counter_frames = 0
	elif state == State.ATTACK:
		mult = _damage_mult  # keep a counter bonus through auto chains
	_move = m
	_move_serial += 1
	_move_connected = false
	_move_hit = false
	_spawned = false
	_enter(State.ATTACK)
	_damage_mult = mult


func _try_dodge() -> bool:
	if _dodge_buf_frames <= 0 or _dodge_buf_dir == InputFrame.Dodge.NONE:
		return false
	_dodge_dir = _dodge_buf_dir
	_dodge_buf_frames = 0
	_dodge_buf_dir = InputFrame.Dodge.NONE
	_enter(State.DODGE)
	_vel.x = 0.0
	_vel.z = 0.0
	event.emit(&"dodge", {"slot": slot, "dodge": DODGE_NAMES[_dodge_dir]})
	return true


func _tick_dodge() -> void:
	var f := _state_frame
	var move_frames := maxi(tuning.dodge_move_frames, 1)
	match _dodge_dir:
		InputFrame.Dodge.LEFT, InputFrame.Dodge.RIGHT:
			if f <= move_frames:
				_sway_step(tuning.sway_distance / move_frames, _dodge_dir == InputFrame.Dodge.RIGHT)
			_set_ground_velocity(Vector3.ZERO)
		InputFrame.Dodge.BACK:
			var speed := tuning.backflip_distance / (move_frames / float(Tuning.match_rules.tick_rate))
			_set_ground_velocity(-_fwd() * speed if f <= move_frames else Vector3.ZERO)
		_:
			_set_ground_velocity(Vector3.ZERO)
	if _counter_frames > 0 and _try_attack_buttons_neutral():
		return
	if f >= tuning.dodge_total_frames:
		_enter(State.IDLE)


## Move `step` meters along an arc around the opponent (sidestep).
func _sway_step(step: float, to_right: bool) -> void:
	if opponent == null:
		global_position += _right() * (step if to_right else -step)
		return
	var pivot := opponent.global_position
	pivot.y = global_position.y
	var rel := global_position - pivot
	var r := maxf(rel.length(), tuning.body_radius)
	var angle := step / r
	var cand := pivot + rel.rotated(Vector3.UP, angle)
	if ((cand - global_position).dot(_right()) < 0.0) == to_right:
		cand = pivot + rel.rotated(Vector3.UP, -angle)
	global_position = cand


func _tick_guard() -> void:
	_face_opponent(_turn_step())
	if not _input.is_held(InputFrame.Btn.GUARD):
		_enter(State.IDLE)
		return
	_try_actions(false)


func _tick_guard_stun() -> void:
	if _state_frame >= _state_len:
		_enter(State.GUARD if _input.is_held(InputFrame.Btn.GUARD) else State.IDLE)


func _tick_guard_break() -> void:
	if _state_frame >= _state_len:
		guard_health = tuning.guard_health
		_enter(State.IDLE)


func _tick_charge() -> void:
	_face_opponent(_turn_step())
	if not _input.is_held(InputFrame.Btn.CHARGE):
		_enter(State.IDLE)
		return
	_add_ki(tuning.ki_charge_per_frame)


func _tick_hitstun() -> void:
	if _try_vanish_escape():
		return
	if _state_frame >= _state_len and not is_airborne():
		_end_opponent_combo()
		_enter(State.IDLE)


func _tick_knockdown() -> void:
	if _land_frame < 0 and not is_airborne():
		_land_frame = _state_frame
	if state == State.KO or _land_frame < 0:
		return
	if _state_frame - _land_frame >= tuning.knockdown_frames:
		_end_opponent_combo()
		_enter(State.WAKEUP)
		_invuln_frames = tuning.wakeup_invuln_frames
		event.emit(&"wakeup", {"slot": slot})


func _tick_wakeup() -> void:
	_face_opponent(_turn_step())
	if _state_frame >= tuning.wakeup_frames:
		_enter(State.IDLE)


# --- Teleport / vanish ------------------------------------------------------

## Offensive vanish: right after landing a hit, reappear behind the victim.
func _try_teleport() -> bool:
	if not _buffered(InputFrame.Btn.TELEPORT) or opponent == null:
		return false
	if not opponent._is_teleport_target() or _since_hit_landed > tuning.teleport_hit_window:
		return false
	if _teleports_in_combo >= tuning.teleport_max_per_combo:
		return false
	_consume(InputFrame.Btn.TELEPORT)
	if not _spend_ki(tuning.teleport_cost_bars * tuning.ki_bar_size):
		return false
	_teleports_in_combo += 1
	opponent._hold_for_teleport(tuning.teleport_frames + tuning.teleport_followup_window)
	event.emit(&"teleport", {"slot": slot, "target_slot": opponent.slot, "position": global_position})
	_enter_teleport(TeleportKind.OFFENSE)
	return true


func _is_teleport_target() -> bool:
	return state == State.HITSTUN or (state == State.KNOCKDOWN and _land_frame < 0)


## Victim side of an offensive teleport: freeze in hitstun long enough for
## the attacker to reappear and link a follow-up.
func _hold_for_teleport(frames: int) -> void:
	if state != State.HITSTUN:
		_enter(State.HITSTUN)
		_state_len = 0
	_state_len = maxi(_state_len, _state_frame + frames)
	_vel = Vector3.ZERO


## Defensive vanish (from hitstun): starts a vanish battle.
func _try_vanish_escape() -> bool:
	if not _buffered(InputFrame.Btn.TELEPORT) or opponent == null:
		return false
	_consume(InputFrame.Btn.TELEPORT)
	if not _spend_ki(VanishBattle.cost_for(tuning, 0)):
		return false
	var b := VanishBattle.new()
	b.serial = (director.tick if director else 0) * 4 + slot
	_vanish_battle = b
	opponent._vanish_battle = b
	_end_opponent_combo()
	_do_vanish_exchange(0)
	return true


## Responder answering a vanish within the window.
func _try_vanish_respond() -> bool:
	if not _consume(InputFrame.Btn.TELEPORT):
		return false
	var e := _vanish_battle.exchange + 1
	if not _spend_ki(VanishBattle.cost_for(tuning, e)):
		return false
	_do_vanish_exchange(e)
	return true


func _do_vanish_exchange(exchange: int) -> void:
	var b := _vanish_battle
	b.exchange = exchange
	b.vanisher_slot = slot
	b.responder_slot = opponent.slot
	event.emit(&"vanish", {"slot": slot, "exchange": exchange, "escape": true, "position": global_position})
	_enter_teleport(TeleportKind.ESCAPE)
	opponent._enter_vanish_wait(VanishBattle.window_for(tuning, exchange))


func _enter_vanish_wait(window: int) -> void:
	if state == State.TELEPORT:
		_reappear()
	_enter(State.VANISH_WAIT)
	_state_len = tuning.teleport_frames + window
	_vel = Vector3(0.0, minf(_vel.y, 0.0), 0.0)


func _tick_vanish_wait() -> void:
	if _vanish_battle == null or not _vanish_battle.active:
		_enter(State.IDLE)
		return
	if _state_frame >= tuning.teleport_frames:
		_face_opponent(_turn_step())
		if _buffered(InputFrame.Btn.TELEPORT) and _try_vanish_respond():
			return
	if _state_frame >= _state_len:
		_end_vanish_battle(opponent.slot if opponent else -1)
		_enter(State.IDLE)


func _end_vanish_battle(winner_slot: int) -> void:
	var b := _vanish_battle
	if b == null:
		return
	if b.active:
		b.active = false
		event.emit(&"vanish_battle_end", {"slot": slot, "exchanges": b.exchange + 1, "winner_slot": winner_slot})
	_vanish_battle = null
	if opponent and opponent._vanish_battle == b:
		opponent._vanish_battle = null


func _enter_teleport(kind: TeleportKind) -> void:
	_tp_kind = kind
	_enter(State.TELEPORT)
	_vel = Vector3.ZERO


func _tick_teleport() -> void:
	_set_ground_velocity(Vector3.ZERO)
	_vel.y = 0.0
	if _state_frame >= tuning.teleport_frames:
		_reappear()
		_enter(State.IDLE)


## Reappear behind the opponent's back, facing them.
func _reappear() -> void:
	if opponent != null:
		var back := -opponent._fwd()
		var p := opponent.global_position + back * tuning.teleport_behind_distance
		p.y = 0.0
		global_position = p
		_face_opponent(PI)
	event.emit(&"reappear", {"slot": slot, "position": global_position})


# --- Specials ---------------------------------------------------------------

func _try_special() -> bool:
	var y := _input.move().y
	var t := tuning
	var move_id := def.super1
	var cost := t.super1_cost_bars
	var kind := &"rush"
	if y > t.special_dir_threshold:
		move_id = def.ultimate
		cost = t.ultimate_cost_bars
		kind = &"ultimate"
	elif y < -t.special_dir_threshold:
		move_id = def.super2
		cost = t.super2_cost_bars
		kind = &"beam"
	if def.move(move_id) == null or not _spend_ki(cost * t.ki_bar_size):
		return false
	_start_move_id(move_id)
	event.emit(&"super_start", {"slot": slot, "kind": kind})
	if kind == &"ultimate":
		event.emit(&"ultimate_start", {"slot": slot, "freeze_frames": t.ultimate_freeze_frames})
		if director:
			director.request_hitstop(t.ultimate_freeze_frames)
	return true


func _try_ki_blast() -> bool:
	if def.move(def.ki_blast) == null or not _spend_ki(tuning.ki_blast_cost):
		return false
	return _start_move_id(def.ki_blast)


func _spawn_from(m: MoveData) -> void:
	if director == null or m.spawn_move == null:
		return
	match m.spawn_kind:
		&"ki_blast":
			var blast := KiBlast.new()
			director.spawn_entity(blast)
			var target := opponent.global_position + Vector3.UP * m.spawn_move.hitbox_offset.y if opponent else Vector3.ZERO
			blast.launch(self, m.spawn_move, global_position + _to_world3(m.spawn_move.hitbox_offset), target)
			event.emit(&"ki_blast", {"slot": slot, "position": blast.global_position})
		&"beam":
			var beam := Beam.new()
			director.spawn_entity(beam)
			beam.fire(self, m.spawn_move, _move_serial)
			event.emit(&"beam", {"slot": slot, "position": global_position})


# =============================================================================
# Hit reactions
# =============================================================================

func _can_block(hb: Hitbox) -> bool:
	if hb.move.is_unblockable or not (state == State.GUARD or state == State.GUARD_STUN):
		return false
	var to := hb.origin - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return true
	return rad_to_deg(_fwd().angle_to(to.normalized())) <= tuning.guard_half_angle_deg


func _take_blocked(hb: Hitbox) -> void:
	var m := hb.move
	var chip := m.damage * hb.damage_mult * tuning.guard_chip_ratio
	_set_health(health - chip)
	guard_health = maxf(guard_health - m.guard_damage, 0.0)
	var push := hb.world_knockback() * tuning.guard_pushback_ratio
	push.y = 0.0
	if health <= 0.0:
		_enter_ko(push)
	elif guard_health <= 0.0:
		_enter(State.GUARD_BREAK)
		_state_len = tuning.guard_break_stun_frames
		event.emit(&"guard_break", {"slot": slot, "position": global_position})
	else:
		_enter(State.GUARD_STUN)
		_state_len = m.guard_stun
	_vel.x = push.x
	_vel.z = push.z
	_emit_hit(hb, chip, true)


func _take_hit(hb: Hitbox) -> void:
	var m := hb.move
	var attacker := hb.attacker
	var in_combo := state == State.HITSTUN or state == State.KNOCKDOWN or state == State.GUARD_BREAK
	if attacker != null and not in_combo:
		attacker._set_combo(0)
		attacker._teleports_in_combo = 0
	var scale := 1.0
	if attacker != null:
		scale = maxf(pow(tuning.combo_scaling, attacker.combo_hits), tuning.combo_scaling_min)
	var dmg := m.damage * hb.damage_mult * scale
	_set_health(health - dmg)
	_add_ki(tuning.ki_gain_on_hit_taken)
	if _vanish_battle != null:
		_end_vanish_battle(attacker.slot if attacker else -1)
	if attacker != null:
		attacker._on_hit_dealt(m)
	var kb := hb.world_knockback()
	var was_juggle := state == State.KNOCKDOWN
	if health <= 0.0:
		_enter_ko(kb)
	elif m.knockdown or was_juggle:
		_enter(State.KNOCKDOWN)
		_land_frame = -1
		_vel = kb
		if _vel.y > 0.0:
			global_position.y = maxf(global_position.y, 0.001)
		event.emit(&"knockdown", {"slot": slot, "position": global_position})
	else:
		_enter(State.HITSTUN)
		_state_len = m.hitstun
		_vel = Vector3(kb.x, kb.y if is_airborne() else 0.0, kb.z)
	_emit_hit(hb, dmg, false)


func _enter_ko(kb: Vector3) -> void:
	_end_vanish_battle(opponent.slot if opponent else -1)
	_enter(State.KO)
	_land_frame = -1
	_vel = kb
	_vel.y = maxf(_vel.y, 0.0)
	if _vel.y > 0.0:
		global_position.y = maxf(global_position.y, 0.001)
	event.emit(&"ko", {"slot": slot, "position": global_position})


func _on_perfect_dodge(hb: Hitbox) -> void:
	_add_ki(tuning.ki_gain_on_perfect_dodge)
	_counter_frames = tuning.perfect_dodge_counter_frames
	event.emit(&"perfect_dodge", {
		"slot": slot, "attacker_slot": hb.attacker.slot if hb.attacker else -1,
		"dodge": DODGE_NAMES[_dodge_dir], "position": global_position + Vector3.UP,
	})
	if _dodge_dir == InputFrame.Dodge.FORWARD and hb.is_melee and hb.attacker != null:
		hb.attacker._stagger(tuning.perfect_duck_stagger_frames)


## Forced open stance (perfect duck punish). Uses the GuardBreak state.
func _stagger(frames: int) -> void:
	if state == State.KO:
		return
	_enter(State.GUARD_BREAK)
	_state_len = frames
	event.emit(&"stagger", {"slot": slot, "position": global_position})


func _on_hit_dealt(m: MoveData) -> void:
	_since_hit_landed = 0
	_set_combo(combo_hits + 1)
	if m.grants_hit_ki:
		_add_ki(tuning.ki_gain_on_hit_dealt + m.ki_gain)


func _emit_hit(hb: Hitbox, dmg: float, blocked: bool) -> void:
	var chest := global_position + Vector3.UP * (tuning.body_height * 0.6)
	event.emit(&"hit", {
		"slot": slot,
		"attacker_slot": hb.attacker.slot if hb.attacker else -1,
		"damage": dmg,
		"position": Geometry3D.get_closest_point_to_segment(chest, hb.a, hb.b),
		"heavy": hb.move.is_heavy,
		"blocked": blocked,
		"combo": hb.attacker.combo_hits if hb.attacker else 0,
	})


## Victim left hitstun/knockdown: the attacker's combo is over.
func _end_opponent_combo() -> void:
	if opponent == null:
		return
	opponent._set_combo(0)
	opponent._teleports_in_combo = 0


# =============================================================================
# Helpers
# =============================================================================

func _tick_timers() -> void:
	if _counter_frames > 0:
		_counter_frames -= 1
	if _invuln_frames > 0:
		_invuln_frames -= 1
	if _since_hit_landed < NEVER:
		_since_hit_landed += 1
	if state != State.GUARD_STUN and state != State.GUARD_BREAK and guard_health < tuning.guard_health:
		guard_health = minf(guard_health + tuning.guard_regen_per_frame, tuning.guard_health)


func _apply_motion() -> void:
	var dt := 1.0 / Tuning.match_rules.tick_rate
	var was_air := is_airborne()
	if was_air:
		_vel.y -= tuning.gravity * dt
	elif not _driven:
		var h := Vector2(_vel.x, _vel.z)
		h = h.move_toward(Vector2.ZERO, tuning.ground_friction * dt)
		_vel.x = h.x
		_vel.z = h.y
	global_position += _vel * dt
	if global_position.y <= 0.0:
		global_position.y = 0.0
		if _vel.y < 0.0:
			_vel.y = 0.0
		if was_air:
			_on_land()


func _on_land() -> void:
	match state:
		State.JUMP:
			_enter(State.IDLE)
		State.ATTACK:
			if _move == def.move(def.jump_attack):
				_enter(State.IDLE)
		State.KNOCKDOWN, State.KO:
			_vel.x *= 0.5
			_vel.z *= 0.5


func _set_ground_velocity(v: Vector3) -> void:
	_vel.x = v.x
	_vel.z = v.z
	_driven = true


func _turn_step() -> float:
	return deg_to_rad(tuning.turn_speed_deg) / Tuning.match_rules.tick_rate


func _face_opponent(max_step: float) -> void:
	if opponent == null:
		return
	var to := opponent.global_position - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var target := atan2(-to.x, -to.z)
	var diff := wrapf(target - _yaw, -PI, PI)
	_set_yaw(_yaw + clampf(diff, -max_step, max_step))


func _set_yaw(y: float) -> void:
	_yaw = wrapf(y, -PI, PI)
	global_basis = Basis(Vector3.UP, _yaw)


func _fwd() -> Vector3:
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


func _right() -> Vector3:
	return Vector3(cos(_yaw), 0.0, -sin(_yaw))


func _to_world2(v: Vector2) -> Vector3:
	return _right() * v.x + _fwd() * v.y


func _to_world3(v: Vector3) -> Vector3:
	return _right() * v.x + Vector3.UP * v.y + _fwd() * v.z


func _set_health(v: float) -> void:
	health = clampf(v, 0.0, tuning.max_health)
	health_changed.emit(health, tuning.max_health)


func _add_ki(delta: float) -> void:
	var v := clampf(ki + delta, 0.0, ki_max())
	if v != ki:
		ki = v
		ki_changed.emit(ki, ki_max())


## Pay `cost` ki or emit &"not_enough_ki" and return false.
func _spend_ki(cost: float) -> bool:
	if ki + 0.0001 < cost:
		event.emit(&"not_enough_ki", {"slot": slot, "needed": cost, "have": ki})
		return false
	_add_ki(-cost)
	return true


func _set_combo(hits: int) -> void:
	if hits != combo_hits:
		combo_hits = hits
		combo_changed.emit(hits)


static func _bit(btn: int) -> int:
	var i := 0
	while i < BUFFER_SIZE and (1 << i) != btn:
		i += 1
	return i


func _buffered(btn: int) -> bool:
	return _buffer[_bit(btn)] > 0


func _consume(btn: int) -> bool:
	var i := _bit(btn)
	if _buffer[i] > 0:
		_buffer[i] = 0
		return true
	return false


func _age_buffer() -> void:
	for i in BUFFER_SIZE:
		if _buffer[i] > 0:
			_buffer[i] -= 1
	if _dodge_buf_frames > 0:
		_dodge_buf_frames -= 1


func _clear_buffer() -> void:
	_buffer.fill(0)
	_dodge_buf_frames = 0
	_dodge_buf_dir = InputFrame.Dodge.NONE


# =============================================================================
# Rollback
# =============================================================================

func save_state() -> Dictionary:
	var s := super.save_state()
	s.merge({
		"health": health, "ki": ki, "combo_hits": combo_hits, "control": _control_enabled,
		"guard_health": guard_health, "state": state, "state_frame": _state_frame,
		"state_len": _state_len, "yaw": _yaw, "vel": _vel, "driven": _driven,
		"move": _move.id if _move else &"", "move_serial": _move_serial,
		"move_connected": _move_connected, "move_hit": _move_hit, "spawned": _spawned,
		"damage_mult": _damage_mult, "air_attack_used": _air_attack_used,
		"dodge_dir": _dodge_dir, "counter_frames": _counter_frames,
		"invuln_frames": _invuln_frames, "land_frame": _land_frame,
		"since_hit_landed": _since_hit_landed, "teleports": _teleports_in_combo,
		"tp_kind": _tp_kind, "last_contact": _last_contact_id,
		"vanish": _vanish_battle.to_dict() if _vanish_battle else {},
		"buffer": _buffer.duplicate(), "dodge_buf_dir": _dodge_buf_dir,
		"dodge_buf_frames": _dodge_buf_frames, "input": _input.to_array(),
	})
	return s


func load_state(s: Dictionary) -> void:
	super.load_state(s)
	health = s["health"]
	ki = s["ki"]
	combo_hits = s["combo_hits"]
	_control_enabled = s["control"]
	guard_health = s["guard_health"]
	state = s["state"]
	_state_frame = s["state_frame"]
	_state_len = s["state_len"]
	_set_yaw(s["yaw"])
	_vel = s["vel"]
	_driven = s["driven"]
	_move = def.move(s["move"]) if s["move"] != &"" else null
	_move_serial = s["move_serial"]
	_move_connected = s["move_connected"]
	_move_hit = s["move_hit"]
	_spawned = s["spawned"]
	_damage_mult = s["damage_mult"]
	_air_attack_used = s["air_attack_used"]
	_dodge_dir = s["dodge_dir"]
	_counter_frames = s["counter_frames"]
	_invuln_frames = s["invuln_frames"]
	_land_frame = s["land_frame"]
	_since_hit_landed = s["since_hit_landed"]
	_teleports_in_combo = s["teleports"]
	_tp_kind = s["tp_kind"]
	_last_contact_id = s["last_contact"]
	var vb: Dictionary = s["vanish"]
	_vanish_battle = null
	if not vb.is_empty():
		# Both fighters reference one battle: if the opponent holds the same
		# battle (stale or already restored), refresh it in place and share.
		if opponent and opponent._vanish_battle and opponent._vanish_battle.serial == vb["serial"]:
			_vanish_battle = opponent._vanish_battle
			_vanish_battle.apply_dict(vb)
		else:
			_vanish_battle = VanishBattle.from_dict(vb)
	_buffer = (s["buffer"] as PackedInt32Array).duplicate()
	_dodge_buf_dir = s["dodge_buf_dir"]
	_dodge_buf_frames = s["dodge_buf_frames"]
	_input = InputFrame.from_array(s["input"])
	health_changed.emit(health, tuning.max_health)
	ki_changed.emit(ki, ki_max())
	combo_changed.emit(combo_hits)
	state_changed.emit(STATE_NAMES[state])

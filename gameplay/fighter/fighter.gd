class_name Fighter
extends CombatEntity
## A playable fighter: deterministic 60 Hz state machine driven by InputFrames.
##
## PUBLIC CONTRACT (used by MatchDirector, CombatSystem, cameras, HUD) — keep
## these names/signatures stable:
##
##   vars:    slot: int, opponent: Fighter, health: float, ki: float,
##            combo_hits: int, def: CharacterDef, tuning: FighterTuning
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
##            guard_pose() -> MoveData.Height, in_vanish_battle() -> bool,
##            charge_ratio() -> float, is_charging_strike() -> bool,
##            move_opens_string() -> bool, guard_vanish_window() -> int,
##            frames_since_guard_press() -> int, dodge_kind() -> DodgeKind,
##            lying_frames() -> int, is_guard_crashed() -> bool,
##            hitstop_left() -> int (SimEntity; frames frozen by hit impact)
##
## `event` kinds (payload keys; every payload also has "slot" = emitter slot):
##   &"hit"            {attacker_slot, damage, position, heavy, blocked, combo,
##                     guard_result: MoveData.GuardResult or -1 unblocked}
##                     (emitted by the VICTIM)
##   &"perfect_dodge"  {attacker_slot, dodge: StringName, position}
##   &"dodge"          {dodge: StringName, kind: StringName} (dodge started;
##                     kind &"dodge" | &"air_tech" | &"roll")
##   &"guard_break"    {position}                     (guard crash: ki emptied
##                                                     by a ki guard, or a
##                                                     full-charge smash)
##   &"push_off"       {attacker_slot, position, stop: bool} (defender's
##                                                     guard repelled the hit)
##   &"counter_guard"  {attacker_slot, position}      (counter stance caught
##                                                     a hit; counter fires)
##   &"throw"          {target_slot, position}        (grab connected; thrower)
##   &"throw_break"    {attacker_slot, position}      (victim broke the grab)
##   &"taunt"          {}                             (taunt started)
##   &"taunt_done"     {ki}                           (taunt finished, ki paid)
##   &"ground_bounce"  {position}                     (bounced off the floor)
##   &"stagger"        {position}                     (perfect-ducked attacker,
##                                                     or stunned by a charge strike)
##   &"charge_start"   {button}                       (held LIGHT/HEAVY -> charge strike)
##   &"charge_release" {ratio, dir}                   (charge strike fires, 0..1;
##                     dir &"neutral"|&"forward"|&"back"|&"left"|&"right")
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
##   &"wakeup"         {}                             (also on a quick rise)
##   &"ko"             {position}
##
## Strikes: HEAVY reads the stick when it starts (forward = high, neutral =
## mid, back = low; MoveData.height). Holding LIGHT/HEAVY turns the attack
## into its `charge_move`, which can be released early or held to full; a
## LIGHT charge (smash) released with the stick held swaps in a directional
## smash (MoveData.smash_variants: forward = launch, back = ground bounce,
## left/right = knock sideways).
##
## Guard (BT3 style, no guard meter): hold GUARD; the stick picks the pose
## (forward = high, neutral = mid, back = low; a change settles after
## guard_pose_switch_frames). Each move's MoveData.guard_results says what
## each pose does against it: plain block, ki guard (drains ki; empty =
## guard crash, mashed out), push-off / push-stop (attacker recoils) or
## unblockable. Chip can't KO; guard fails from behind. Stick forward +
## LIGHT while guarding = counter stance (catches a string's first hit).
## THROW grabs through any guard; the victim breaks it with a clean GUARD
## press within throw_break_frames while facing the thrower. TAUNT gives ki
## when finished; hits taken while taunting deal more damage.
##
## Budokai Tenkaichi button overloads (the BLAST / SPECIAL / TELEPORT buttons
## still work as optional dedicated shortcuts):
##   - HEAVY outside close_combat_range (from neutral) = ki blast.
##   - CHARGE held + HEAVY = special: neutral = super1, forward = super2,
##     back = ultimate.
##   - GUARD pressed at the right time = teleport / vanish: right after
##     landing a hit (offensive teleport), in hitstun (vanish escape), in a
##     vanish battle's window, or within guard_vanish_window() frames before
##     the first hit of a guardable melee string lands (vanish instead of
##     blocking; a press soon after the previous one never vanishes).
##   Every teleport reappears around the opponent where the left stick points
##   (see FighterTuning.teleport_dir_threshold); neutral = behind them.
##
## Jumping (one air action per jump, same overloads as on the ground):
## LIGHT = jump attack, HEAVY = jump heavy (ki blast out of close range),
## BLAST = ki blast, CHARGE + HEAVY / SPECIAL = special. Moves started in the
## air stall for MoveData.air_hang_frames, lunges dive at the opponent, and
## an air beam aims down at them.
##
## Dodges (right-stick flick) have per-direction timings (duck / sway /
## backflip, see FighterTuning) and chain into each other from their
## chain_from frame, up to dodge_chain_max times (0 = no cap); LIGHT/HEAVY
## pressed during one is queued for its attack_from frame, except HEAVY in a
## duck: the duck kick (CharacterDef.duck_heavy) from duck_heavy_from_frame.
## Knocked down: a flick in the air flips back onto the feet (air tech); on
## the floor a button rises at once and a flick rolls.
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
	THROW, THROWN, TAUNT, COUNTER, RECOIL,
}
enum TeleportKind { OFFENSE, ESCAPE }
## DODGE state flavors: a normal dodge, an air recovery flip, a get-up roll.
enum DodgeKind { DODGE, AIR_TECH, ROLL }

const STATE_NAMES: Array[StringName] = [
	&"idle", &"walk", &"dash", &"jump", &"attack", &"dodge", &"guard",
	&"guard_stun", &"guard_break", &"charge", &"hitstun", &"knockdown",
	&"wakeup", &"teleport", &"vanish_wait", &"ko",
	&"throw", &"thrown", &"taunt", &"counter_guard", &"recoil",
]
const GUARD_POSE_NAMES: Array[StringName] = [&"guard", &"guard_high", &"guard_low"]
const SMASH_DIR_NAMES: Array[StringName] = [&"forward", &"back", &"left", &"right"]
## Face buttons that mash out of a guard crash / stagger.
const MASH_BUTTONS: Array[int] = [InputFrame.Btn.LIGHT, InputFrame.Btn.HEAVY, InputFrame.Btn.GUARD, InputFrame.Btn.JUMP]
const DODGE_NAMES: Array[StringName] = [&"none", &"duck", &"backflip", &"sway_l", &"sway_r"]
const DODGE_KIND_NAMES: Array[StringName] = [&"dodge", &"air_tech", &"roll"]
## Number of InputFrame.Btn bits tracked by the press buffer.
const BUFFER_SIZE := 12
const NEVER := 1 << 20

var slot: int = 0
var opponent: Fighter
var health: float
var ki: float
var combo_hits: int = 0
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
## True when the current state holds the fighter's air motion this tick (no gravity).
var _floating: bool = false
var _move: MoveData
var _move_serial: int = 0
var _move_connected: bool = false
var _move_hit: bool = false
var _spawned: bool = false
var _damage_mult: float = 1.0
var _air_attack_used: bool = false
var _dodge_dir: int = InputFrame.Dodge.NONE
var _dodge_kind: int = DodgeKind.DODGE
## Dodges chained in a row (0 for the first).
var _dodge_chain: int = 0
## LIGHT/HEAVY queued during a dodge (0 = none).
var _dodge_queued_btn: int = 0
var _counter_frames: int = 0
var _invuln_frames: int = 0
## Frame (of the current knockdown/KO state) the fighter landed; -1 airborne.
var _land_frame: int = -1
var _since_hit_landed: int = NEVER
## Frames since GUARD was last pressed, and whether that press was clean
## (the one before it was guard_vanish_rearm_frames earlier) so it may vanish.
var _since_guard_press: int = NEVER
var _guard_press_armed: bool = false
## The current move doesn't continue a string that connected (Hitbox.opens_string).
var _move_opens_string: bool = true
## Victim side of the anti-loop rule, for the current combo segment: melee
## moves that hit, relaunches taken, and the last melee move activation seen.
var _combo_moves_taken: Array[StringName] = []
var _combo_relaunches: int = 0
var _combo_last_melee: int = -1
## Clean hits taken in the current combo from any attacker (drives damage
## scaling, so teammates juggling one victim scale together). Unlike the
## anti-loop segment it isn't reset by a teleport.
var _combo_hits_taken: int = 0
var _teleports_in_combo: int = 0
var _tp_kind: int = TeleportKind.OFFENSE
var _vanish_battle: VanishBattle
var _buffer: PackedInt32Array = PackedInt32Array()
var _dodge_buf_dir: int = InputFrame.Dodge.NONE
var _dodge_buf_frames: int = 0
## Consecutive frames each InputFrame.Btn bit has been held (charge strikes).
var _held: PackedInt32Array = PackedInt32Array()
## Stick height latched when HEAVY was pressed (survives buffering/hitstop).
var _heavy_height: MoveData.Height = MoveData.Height.MID
## Charge strike: holding at MoveData.charge_frame while `_charge_btn` is held.
var _charging: bool = false
var _charge: int = 0
var _charge_btn: int = 0
## Guard pose (MoveData.Height) and a pending stick pose with its hold time.
var _guard_pose: int = MoveData.Height.MID
var _guard_pose_want: int = MoveData.Height.MID
var _guard_pose_frames: int = 0
## The current GUARD_BREAK is a guard crash (refills ki when it ends).
var _guard_crashed: bool = false
## THROWN: the grab came from the front (breakable). THROW: throw behind.
var _throw_breakable: bool = false
var _throw_back: bool = false
## A ground_bounce hit is pending: bounce up on the next grounded tick.
var _bounce_pending: bool = false
## Quantized stick latched for the teleport reappear point.
var _tp_dir: Vector2i = Vector2i.ZERO
var _input: InputFrame = InputFrame.new()
var _control_enabled := false


func _init() -> void:
	_buffer.resize(BUFFER_SIZE)
	_held.resize(BUFFER_SIZE)


func _ready() -> void:
	if def == null:
		def = CharacterRegistry.load_def(&"brawler")
	tuning = def.build_tuning(Tuning.fighter)
	health = tuning.max_health
	ki = tuning.ki_start


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
		_held[i] = _held[i] + 1 if frame.held & (1 << i) else 0
	if frame.just_pressed(InputFrame.Btn.HEAVY):
		_heavy_height = _height_for_stick(frame.move().y)
	if frame.just_pressed(InputFrame.Btn.GUARD):
		_guard_press_armed = _since_guard_press >= tuning.guard_vanish_rearm_frames
		_since_guard_press = 0
	else:
		_since_guard_press = mini(_since_guard_press + 1, NEVER)
	if frame.dodge != InputFrame.Dodge.NONE:
		_dodge_buf_dir = frame.dodge
		_dodge_buf_frames = keep


func sim_tick(_tick: int) -> void:
	_state_frame += 1
	_driven = false
	_floating = false
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
		State.THROW: _tick_throw()
		State.THROWN: _tick_thrown()
		State.TAUNT: _tick_taunt()
		State.COUNTER: _tick_counter()
		State.RECOIL: _tick_recoil()
	_apply_motion()
	_age_buffer()


func reset_for_round(xform: Transform3D) -> void:
	global_position = xform.origin
	var fwd := -xform.basis.z
	_set_yaw(atan2(-fwd.x, -fwd.z))
	health = tuning.max_health
	ki = tuning.ki_start
	combo_hits = 0
	hitstop = 0
	_combo_hits_taken = 0
	_vel = Vector3.ZERO
	_move = null
	_move_serial = 0
	_move_connected = false
	_move_hit = false
	_spawned = false
	_damage_mult = 1.0
	_charging = false
	_charge = 0
	_charge_btn = 0
	_heavy_height = MoveData.Height.MID
	_guard_pose = MoveData.Height.MID
	_guard_pose_want = MoveData.Height.MID
	_guard_pose_frames = 0
	_guard_crashed = false
	_throw_breakable = false
	_throw_back = false
	_bounce_pending = false
	_tp_dir = Vector2i.ZERO
	_air_attack_used = false
	_dodge_dir = InputFrame.Dodge.NONE
	_dodge_kind = DodgeKind.DODGE
	_dodge_chain = 0
	_dodge_queued_btn = 0
	_counter_frames = 0
	_invuln_frames = 0
	_land_frame = -1
	_since_hit_landed = NEVER
	_since_guard_press = NEVER
	_guard_press_armed = false
	_move_opens_string = true
	_clear_combo_segment()
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


## Guard pose (MoveData.Height) while guarding; MID in the counter stance.
func guard_pose() -> MoveData.Height:
	return (MoveData.Height.MID if state == State.COUNTER else _guard_pose) as MoveData.Height


## In a guard crash (ki emptied by guarding): open to anything, mash out.
func is_guard_crashed() -> bool:
	return state == State.GUARD_BREAK and _guard_crashed


func current_state_name() -> StringName:
	return STATE_NAMES[state]


func is_invulnerable() -> bool:
	if _invuln_frames > 0:
		return true
	match state:
		State.TELEPORT, State.KO:
			return true
		State.DODGE:
			if _dodge_kind == DodgeKind.AIR_TECH:
				return true  # until it lands
			return _state_frame >= tuning.dodge_invuln_start and _state_frame < tuning.dodge_invuln_start \
				+ _per_dodge(tuning.duck_invuln_frames, tuning.sway_invuln_frames, tuning.backflip_invuln_frames)
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
		State.GUARD:
			return GUARD_POSE_NAMES[_guard_pose]
		State.KNOCKDOWN, State.KO:
			return &"knockdown" if _land_frame >= 0 else &"launched"
	return STATE_NAMES[state]


func state_frame() -> int:
	return _state_frame


## Charge of the current charge strike, 0..1 (0 when not in one).
func charge_ratio() -> float:
	if state != State.ATTACK or not _move.is_charge_strike():
		return 0.0
	return clampf(_charge / float(_move.charge_max_frames), 0.0, 1.0)


## True while holding a charge strike at its charge frame.
func is_charging_strike() -> bool:
	return state == State.ATTACK and _charging and _state_frame >= _move.charge_frame


## The current move starts a string (its first hit can be guard-vanished).
func move_opens_string() -> bool:
	return state == State.ATTACK and _move_opens_string


## Frames before a melee hit in which a clean GUARD press vanishes; tightens
## as health drops.
func guard_vanish_window() -> int:
	var r := health_ratio()
	if r < tuning.guard_vanish_critical_ratio:
		return tuning.guard_vanish_window_critical
	if r < tuning.guard_vanish_hurt_ratio:
		return tuning.guard_vanish_window_hurt
	return tuning.guard_vanish_window


func frames_since_guard_press() -> int:
	return _since_guard_press


func dodge_kind() -> DodgeKind:
	return _dodge_kind as DodgeKind


## Frames spent lying on the ground in the current knockdown; -1 otherwise.
func lying_frames() -> int:
	if state != State.KNOCKDOWN or _land_frame < 0:
		return -1
	return _state_frame - _land_frame


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
	hb.is_throw = m.is_throw
	hb.is_melee = not m.is_throw
	hb.opens_string = _move_opens_string and sub == 0
	if m.is_charge_strike():
		var t := tuning
		var r := charge_ratio()
		hb.damage_mult *= lerpf(1.0, m.charge_damage_mult, r)
		hb.guard_ki_mult = lerpf(1.0, m.charge_guard_mult, r)
		if r >= t.charge_stun_ratio:
			var k := clampf((r - t.charge_stun_ratio) / maxf(1.0 - t.charge_stun_ratio, 0.0001), 0.0, 1.0)
			hb.stun_frames = roundi(lerpf(t.charge_stun_frames_min, t.charge_stun_frames_max, k))
		hb.breaks_guard = r >= t.charge_break_ratio
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
	elif state == State.ATTACK and _move.low_profile:
		h = tuning.duck_height
	var r := tuning.body_radius
	h = maxf(h, r * 2.0)
	var base := global_position
	return [base + Vector3.UP * r, base + Vector3.UP * (h - r), r]


## Apply a hitbox that overlapped this fighter. Returns the Contact outcome.
func receive_hit(hb: Hitbox) -> Contact:
	if hb.source == hb.attacker and hb.attacker.state == State.THROWN:
		return Contact.NONE  # grabbed this tick, before its own hit resolved
	if state == State.DODGE and _dodge_kind == DodgeKind.DODGE and _state_frame < tuning.perfect_dodge_frames:
		_on_perfect_dodge(hb)
		return Contact.PERFECT_DODGE
	if is_invulnerable() or get_hurtbox().is_empty():
		return Contact.NONE
	if hb.is_throw:
		return Contact.THROW if _try_grabbed(hb) else Contact.NONE
	if state == State.THROW:
		_release_throw()
	if _try_counter_guard(hb):
		return Contact.BLOCKED
	var res := _guard_result_for(hb)
	if res >= 0:
		if _try_guard_vanish(hb):
			return Contact.NONE
		if res != MoveData.GuardResult.UNBLOCKABLE:
			_take_blocked(hb, res)
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
		_charging = false
	if s != State.KNOCKDOWN:
		_bounce_pending = false
	if s != State.GUARD_BREAK:
		_guard_crashed = false
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
	if _consume(InputFrame.Btn.THROW):
		if _start_throw():
			return true
	if allow_guard and _consume(InputFrame.Btn.TAUNT):
		_enter(State.TAUNT)
		event.emit(&"taunt", {"slot": slot})
		return true
	if _consume_special():
		if _try_special():
			return true
	if _consume(InputFrame.Btn.BLAST):
		if _try_ki_blast():
			return true
	if _consume(InputFrame.Btn.HEAVY):
		if not _in_close_range() and _try_ki_blast():
			return true
		return _start_move_id(_heavy_for_stick())
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
		_enter_guard()
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
	if not _air_attack_used and _try_air_action():
		_air_attack_used = true


## Air version of _try_actions' attack overloads. Returns true if a move began.
func _try_air_action() -> bool:
	if _consume_special():
		return _try_special()
	if _consume(InputFrame.Btn.BLAST):
		return _try_ki_blast()
	if _consume(InputFrame.Btn.HEAVY):
		if not _in_close_range() and _try_ki_blast():
			return true
		return _start_move_id(def.jump_heavy if def.jump_heavy != &"" else def.jump_attack)
	if _consume(InputFrame.Btn.LIGHT):
		return _start_move_id(def.jump_attack)
	return false


func _tick_attack() -> void:
	var m := _move
	if _charging and _tick_charge_hold(m):
		return
	var f := _state_frame
	var track := m.startup - tuning.attack_track_lock_frames if m.track_frames < 0 else m.track_frames
	if f <= track:
		_face_opponent(_attack_turn_step())
	var lunging := f >= m.lunge_start and f < m.lunge_start + m.lunge_frames
	if lunging and is_airborne():
		_vel = _dive_velocity(m.lunge_speed)
		_driven = true
		_floating = true
	elif lunging:
		_set_ground_velocity(_fwd() * m.lunge_speed)
	elif is_airborne() and (m.air_hang_frames < 0 or f < m.air_hang_frames):
		_set_ground_velocity(Vector3.ZERO)
		_vel.y = 0.0
		_floating = true
	if _try_charge_strike(m):
		return
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


## Air lunge: along the facing, descending so it touches down at the
## opponent's feet (never rising: fighters don't fly).
func _dive_velocity(speed: float) -> Vector3:
	var reach := 0.0
	if opponent != null:
		var d := opponent.global_position - global_position
		d.y = 0.0
		reach = d.length()
	var dir := _fwd() * reach + Vector3.DOWN * global_position.y
	return dir.normalized() * speed if dir.length_squared() > 0.0001 else _fwd() * speed


## Holding the button that started `m` past charge_hold_frames (outside its
## active frames) turns it into its charge strike.
func _try_charge_strike(m: MoveData) -> bool:
	if m.charge_move == &"" or m.button == 0 or m.is_active_frame(_state_frame):
		return false
	if _held[_bit(m.button)] < tuning.charge_hold_frames:
		return false
	var next := def.move(m.charge_move)
	if next == null:
		return false
	_start_move(next)
	_charging = true
	_charge_btn = m.button
	event.emit(&"charge_start", {"slot": slot, "button": m.button})
	return true


## Charging: pinned at charge_frame while the button is held, until full.
## Returns true while still holding (the tick is consumed).
func _tick_charge_hold(m: MoveData) -> bool:
	if _state_frame < m.charge_frame:
		return false
	_face_opponent(_attack_turn_step())
	_set_ground_velocity(Vector3.ZERO)
	if _try_dodge():
		return true
	if _input.is_held(_charge_btn) and _charge < m.charge_max_frames:
		_charge += 1
		_state_frame = m.charge_frame
		return true
	_charging = false
	var ratio := charge_ratio()
	var dir := _apply_smash_direction(m)
	event.emit(&"charge_release", {"slot": slot, "ratio": ratio, "dir": dir})
	return false


## On release, swap in the smash variant the stick points at (same timing,
## so the frame and charge carry over). Returns the direction name.
func _apply_smash_direction(m: MoveData) -> StringName:
	var v := _input.move()
	if m.smash_variants.is_empty() or v.length() <= tuning.strike_dir_threshold:
		return &"neutral"
	var i := 2 if v.x < 0.0 else 3
	if absf(v.y) >= absf(v.x):
		i = 0 if v.y > 0.0 else 1
	if i >= m.smash_variants.size():
		return &"neutral"
	var variant := def.move(m.smash_variants[i])
	if variant == null:
		return &"neutral"
	_move = variant
	return SMASH_DIR_NAMES[i]


## Stick height for a HEAVY: forward = HIGH, back = LOW, else MID.
func _height_for_stick(y: float) -> MoveData.Height:
	if y > tuning.strike_dir_threshold:
		return MoveData.Height.HIGH
	if y < -tuning.strike_dir_threshold:
		return MoveData.Height.LOW
	return MoveData.Height.MID


func _heavy_for_stick() -> StringName:
	match _heavy_height:
		MoveData.Height.HIGH:
			if def.heavy_high != &"":
				return def.heavy_high
		MoveData.Height.LOW:
			if def.heavy_low != &"":
				return def.heavy_low
	return def.heavy


func _try_cancel_into(m: MoveData) -> bool:
	# Before the loop: CHARGE + HEAVY must not be read as a HEAVY cancel.
	if m.special_cancelable and _move_connected and _consume_special():
		return _try_special()
	for btn: int in [InputFrame.Btn.HEAVY, InputFrame.Btn.LIGHT, InputFrame.Btn.BLAST]:
		if not _buffered(btn):
			continue
		var next_id := _pick_cancel(m, btn)
		if next_id == &"":
			continue
		_consume(btn)
		if btn == InputFrame.Btn.BLAST:
			return _try_ki_blast()
		return _start_move_id(next_id)
	return false


## First `cancel_into` move for `btn`; for HEAVY, prefer the one whose
## height matches the stick.
func _pick_cancel(m: MoveData, btn: int) -> StringName:
	var first := &""
	var want: MoveData.Height = _heavy_height if btn == InputFrame.Btn.HEAVY else MoveData.Height.MID
	for next_id in m.cancel_into:
		var next := def.move(next_id)
		if next == null or next.button != btn:
			continue
		if next.height == want:
			return next_id
		if first == &"":
			first = next_id
	return first


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
	_move_opens_string = not (state == State.ATTACK and _move_connected)
	_move = m
	_move_serial += 1
	_move_connected = false
	_move_hit = false
	_spawned = false
	_charging = false
	_charge = 0
	_enter(State.ATTACK)
	_damage_mult = mult


func _dodge_buffered() -> bool:
	return _dodge_buf_frames > 0 and _dodge_buf_dir != InputFrame.Dodge.NONE


func _try_dodge(kind: DodgeKind = DodgeKind.DODGE) -> bool:
	if not _dodge_buffered():
		return false
	var chained := state == State.DODGE
	_dodge_dir = InputFrame.Dodge.BACK if kind == DodgeKind.AIR_TECH else _dodge_buf_dir
	_dodge_buf_frames = 0
	_dodge_buf_dir = InputFrame.Dodge.NONE
	_enter(State.DODGE)
	_dodge_kind = kind
	_dodge_chain = _dodge_chain + 1 if chained else 0
	_dodge_queued_btn = 0
	_vel.x = 0.0
	_vel.z = 0.0
	if kind == DodgeKind.AIR_TECH:
		_vel.y = tuning.air_tech_lift
	event.emit(&"dodge", {"slot": slot, "dodge": DODGE_NAMES[_dodge_dir], "kind": DODGE_KIND_NAMES[kind]})
	return true


func _tick_dodge() -> void:
	var f := _state_frame
	if _dodge_kind == DodgeKind.AIR_TECH:
		_face_opponent(_turn_step())
		_set_ground_velocity(-_fwd() * tuning.air_tech_back_speed)
		return  # ends on landing (_on_land)
	var chain_from := _per_dodge(tuning.duck_chain_from_frame, tuning.sway_chain_from_frame,
		tuning.backflip_chain_from_frame)
	if _dodge_kind == DodgeKind.DODGE \
			and (tuning.dodge_chain_max <= 0 or _dodge_chain < tuning.dodge_chain_max) \
			and (f >= chain_from or _counter_frames > 0) and _try_dodge():
		return
	match _dodge_dir:
		InputFrame.Dodge.LEFT, InputFrame.Dodge.RIGHT:
			var sway_frames := maxi(tuning.sway_move_frames, 1)
			if f <= sway_frames:
				_sway_step(tuning.sway_distance / sway_frames, _dodge_dir == InputFrame.Dodge.RIGHT)
			_set_ground_velocity(Vector3.ZERO)
		InputFrame.Dodge.BACK:
			var flip_frames := maxi(tuning.backflip_move_frames, 1)
			var speed := tuning.backflip_distance / (flip_frames / float(Tuning.match_rules.tick_rate))
			_set_ground_velocity(-_fwd() * speed if f <= flip_frames else Vector3.ZERO)
		_:
			_set_ground_velocity(Vector3.ZERO)
	if _try_dodge_attack(f):
		return
	if f >= _per_dodge(tuning.duck_total_frames, tuning.sway_total_frames, tuning.backflip_total_frames):
		_enter(State.IDLE)


## Pick the duck / sway / backflip value for the current dodge direction.
func _per_dodge(duck: int, sway: int, backflip: int) -> int:
	match _dodge_dir:
		InputFrame.Dodge.FORWARD:
			return duck
		InputFrame.Dodge.BACK:
			return backflip
	return sway


## Queue LIGHT/HEAVY pressed during a dodge; fire it on the direction's
## attack_from frame (HEAVY in a duck: the duck kick from
## duck_heavy_from_frame), or at once in a perfect-dodge counter window.
func _try_dodge_attack(f: int) -> bool:
	for btn: int in [InputFrame.Btn.HEAVY, InputFrame.Btn.LIGHT]:
		if _consume(btn):
			_dodge_queued_btn = btn
			break
	var duck_kick := _dodge_dir == InputFrame.Dodge.FORWARD and _dodge_queued_btn == InputFrame.Btn.HEAVY \
		and def.duck_heavy != &""
	var attack_from := tuning.duck_heavy_from_frame if duck_kick else _per_dodge(tuning.duck_attack_from_frame,
		tuning.sway_attack_from_frame, tuning.backflip_attack_from_frame)
	if _dodge_queued_btn == 0 or (_counter_frames <= 0 and f < attack_from):
		return false
	var btn := _dodge_queued_btn
	_dodge_queued_btn = 0
	if duck_kick:
		return _start_move_id(def.duck_heavy)
	if btn == InputFrame.Btn.HEAVY:
		return _start_move_id(_heavy_for_stick())
	return _start_move_id(def.light_string[0] if not def.light_string.is_empty() else &"")


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


## Start guarding in the pose the stick holds right now.
func _enter_guard() -> void:
	_enter(State.GUARD)
	_guard_pose = _height_for_stick(_input.move().y)
	_guard_pose_want = _guard_pose
	_guard_pose_frames = 0


## A held guard switches pose once the new stick pose was held long enough.
func _update_guard_pose() -> void:
	var want := _height_for_stick(_input.move().y)
	if want != _guard_pose_want:
		_guard_pose_want = want
		_guard_pose_frames = 0
	if want == _guard_pose:
		_guard_pose_frames = 0
		return
	_guard_pose_frames += 1
	if _guard_pose_frames >= tuning.guard_pose_switch_frames:
		_guard_pose = want
		_guard_pose_frames = 0


func _tick_guard() -> void:
	_face_opponent(_turn_step())
	if not _input.is_held(InputFrame.Btn.GUARD):
		_enter(State.IDLE)
		return
	_update_guard_pose()
	if _input.move().y > tuning.strike_dir_threshold and _consume(InputFrame.Btn.LIGHT):
		_enter(State.COUNTER)
		return
	_try_actions(false)


func _tick_guard_stun() -> void:
	_update_guard_pose()
	if _state_frame >= _state_len:
		if _input.is_held(InputFrame.Btn.GUARD):
			_enter(State.GUARD)  # keeps the pose
		else:
			_enter(State.IDLE)


## Guard crash / stagger: mashing face buttons shortens it.
func _tick_guard_break() -> void:
	for btn in MASH_BUTTONS:
		if _consume(btn):
			_state_len -= tuning.stun_mash_frames
	if _state_frame >= _state_len:
		if _guard_crashed:
			_add_ki(maxf(tuning.guard_crash_ki_refill - ki, 0.0))
		_end_opponent_combo()
		_enter(State.IDLE)


## Counter stance (stick forward + LIGHT from guard); see _try_counter_guard.
func _tick_counter() -> void:
	_face_opponent(_turn_step())
	if _state_frame >= tuning.counter_guard_stance_frames:
		if _input.is_held(InputFrame.Btn.GUARD):
			_enter_guard()
		else:
			_enter(State.IDLE)


## Pushed back after a push-off guard, a counter guard or a throw break.
func _recoil(frames: int, push: Vector3) -> void:
	if state == State.KO:
		return
	_enter(State.RECOIL)
	_state_len = frames
	_vel.x = push.x
	_vel.z = push.z


func _tick_recoil() -> void:
	if _state_frame >= _state_len:
		_enter(State.IDLE)


func _tick_taunt() -> void:
	_face_opponent(_turn_step())
	if _state_frame >= tuning.taunt_frames:
		_add_ki(tuning.taunt_ki_gain)
		event.emit(&"taunt_done", {"slot": slot, "ki": tuning.taunt_ki_gain})
		_enter(State.IDLE)


# --- Throws -----------------------------------------------------------------

func _start_throw() -> bool:
	_throw_back = _input.move().y < -tuning.throw_back_threshold
	return _start_move_id(def.throw)


## Victim side of a grab connecting. Airborne / already reeling fighters
## can't be grabbed (the grab whiffs).
func _try_grabbed(hb: Hitbox) -> bool:
	var thrower := hb.attacker
	if thrower == null or thrower.state != State.ATTACK or is_airborne():
		return false
	match state:
		State.HITSTUN, State.KNOCKDOWN, State.THROW, State.THROWN, State.KO, State.TELEPORT, State.VANISH_WAIT:
			return false
	_end_vanish_battle(thrower.slot)
	_enter(State.THROWN)
	_vel = Vector3.ZERO
	_throw_breakable = _is_facing(hb.origin)
	thrower._on_grab(self)
	# A clean GUARD press just before the grab breaks it at once.
	if _throw_breakable and _guard_press_armed and _since_guard_press < tuning.throw_break_frames:
		_break_throw()
	return true


func _on_grab(victim: Fighter) -> void:
	_enter(State.THROW)
	event.emit(&"throw", {"slot": slot, "target_slot": victim.slot, "position": global_position})


func _tick_thrown() -> void:
	if opponent == null or opponent.state != State.THROW:
		_enter(State.IDLE)
		return
	global_position = opponent.global_position + opponent._fwd() * tuning.throw_hold_distance
	_set_ground_velocity(Vector3.ZERO)
	_face_opponent(PI)
	if _throw_breakable and _state_frame < tuning.throw_break_frames \
			and _guard_press_armed and _since_guard_press < _state_frame:
		_break_throw()


func _break_throw() -> void:
	var thrower := opponent
	_since_guard_press = NEVER  # used up
	event.emit(&"throw_break", {"slot": slot, "attacker_slot": thrower.slot, "position": global_position})
	var away := _fwd() * -tuning.throw_break_push_speed
	_recoil(tuning.throw_break_recoil_frames, away)
	thrower._recoil(tuning.throw_break_recoil_frames, -away)


## The thrower was hit: drop the victim.
func _release_throw() -> void:
	if opponent != null and opponent.state == State.THROWN:
		opponent._enter(State.IDLE)


func _tick_throw() -> void:
	_set_ground_velocity(Vector3.ZERO)
	var f := _state_frame
	if f == tuning.throw_break_frames and opponent != null and opponent.state == State.THROWN:
		_execute_throw()
	if f >= tuning.throw_break_frames + tuning.throw_recovery_frames:
		_enter(State.IDLE)


## The grab held: the throw's damage and knockback land as a clean hit, sent
## forward, or behind the thrower for a back throw.
func _execute_throw() -> void:
	var victim := opponent
	var dir := -_fwd() if _throw_back else _fwd()
	if _throw_back:
		victim.global_position = global_position + dir * tuning.throw_hold_distance
	var hb := Hitbox.new()
	hb.source = self
	hb.attacker = self
	hb.move = _move
	hb.hit_id = _move_serial * 256 + 1
	hb.forward = dir
	hb.right = Vector3(-dir.z, 0.0, dir.x)
	hb.origin = global_position
	hb.a = victim.global_position + Vector3.UP * tuning.body_height * 0.5
	hb.b = hb.a
	hb.is_melee = false
	hb.opens_string = false
	victim._take_hit(hb)
	on_hitbox_contact(hb, victim, Contact.HIT)


func _tick_charge() -> void:
	_face_opponent(_turn_step())
	if not _input.is_held(InputFrame.Btn.CHARGE):
		_enter(State.IDLE)
		return
	if _consume_special() and _try_special():
		return
	_add_ki(tuning.ki_charge_per_frame)


func _tick_hitstun() -> void:
	if _try_vanish_escape():
		return
	if _state_frame >= _state_len and not is_airborne():
		_end_opponent_combo()
		_enter(State.IDLE)


func _tick_knockdown() -> void:
	if _bounce_pending and not is_airborne():
		_bounce_pending = false
		_vel.y = tuning.ground_bounce_velocity
		global_position.y = maxf(global_position.y, 0.001)
		event.emit(&"ground_bounce", {"slot": slot, "position": global_position})
		return
	if _land_frame < 0 and not is_airborne():
		_land_frame = _state_frame
	if state == State.KO:
		return
	if _land_frame < 0:
		if _state_frame >= tuning.air_tech_min_frames and _try_dodge(DodgeKind.AIR_TECH):
			_end_opponent_combo()
		return
	var lying := _state_frame - _land_frame
	if lying >= tuning.knockdown_min_frames:
		if _dodge_buffered() and _dodge_buf_dir != InputFrame.Dodge.FORWARD:
			_end_opponent_combo()
			_try_dodge(DodgeKind.ROLL)
			_invuln_frames = tuning.wakeup_invuln_frames
			return
		if _consume_rise():
			_wake_up()
			return
	if lying >= tuning.knockdown_frames:
		_wake_up()


## Quick rise: any action button, or an up flick (duck), while lying.
func _consume_rise() -> bool:
	if _dodge_buffered():  # only FORWARD reaches here
		_dodge_buf_frames = 0
		_dodge_buf_dir = InputFrame.Dodge.NONE
		return true
	var any := false
	for btn: int in [InputFrame.Btn.LIGHT, InputFrame.Btn.HEAVY, InputFrame.Btn.GUARD, InputFrame.Btn.JUMP]:
		any = _consume(btn) or any
	return any


func _wake_up() -> void:
	_end_opponent_combo()
	_enter(State.WAKEUP)
	_invuln_frames = tuning.wakeup_invuln_frames
	event.emit(&"wakeup", {"slot": slot})


func _tick_wakeup() -> void:
	_face_opponent(_turn_step())
	if _input.is_held(InputFrame.Btn.GUARD):
		_enter_guard()  # get-ups can guard at once
		return
	if _state_frame >= tuning.wakeup_frames:
		_enter(State.IDLE)


# --- Teleport / vanish ------------------------------------------------------

## Offensive vanish: right after landing a hit, reappear behind the victim.
func _try_teleport() -> bool:
	if not _teleport_buffered() or opponent == null:
		return false
	if not opponent._is_teleport_target() or _since_hit_landed > tuning.teleport_hit_window:
		return false
	if _teleports_in_combo >= tuning.teleport_max_per_combo:
		return false
	_consume_teleport()
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
	_clear_combo_segment()  # the follow-up may reuse the string


## Defensive vanish (from hitstun): starts a vanish battle.
func _try_vanish_escape() -> bool:
	if not _teleport_buffered() or opponent == null:
		return false
	_consume_teleport()
	return _start_vanish_battle()


## Guard pressed just before the first hit of a melee string: vanish instead
## of blocking. Mashing GUARD doesn't count (see _guard_press_armed).
func _try_guard_vanish(hb: Hitbox) -> bool:
	if state == State.COUNTER or not hb.is_melee or not hb.opens_string or hb.attacker == null or opponent == null:
		return false
	if not _guard_press_armed or _since_guard_press >= guard_vanish_window():
		return false
	if ki < VanishBattle.cost_from(tuning, tuning.guard_vanish_cost_bars, 0):
		return false  # just block; no not_enough_ki nag on every guard
	_consume_teleport()
	if not _start_vanish_battle(tuning.guard_vanish_cost_bars):
		return false
	_since_guard_press = NEVER  # used up: the next press is clean again
	return true


## Pay the opening cost and vanish behind the opponent, who must respond.
func _start_vanish_battle(opening_bars: float = -1.0) -> bool:
	if opening_bars < 0.0:
		opening_bars = tuning.vanish_escape_cost_bars
	if not _spend_ki(VanishBattle.cost_from(tuning, opening_bars, 0)):
		return false
	var b := VanishBattle.new()
	b.base_bars = opening_bars
	b.serial = (director.tick if director else 0) * 4 + slot
	_vanish_battle = b
	opponent._vanish_battle = b
	_end_opponent_combo()
	_do_vanish_exchange(0)
	return true


## Responder answering a vanish within the window.
func _try_vanish_respond() -> bool:
	if not _consume_teleport():
		return false
	var e := _vanish_battle.exchange + 1
	if not _spend_ki(_vanish_battle.cost(tuning, e)):
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
		if _teleport_buffered() and _try_vanish_respond():
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
	_tp_dir = Vector2i(_input.move_x, _input.move_y)
	_enter(State.TELEPORT)
	_vel = Vector3.ZERO


func _tick_teleport() -> void:
	if _input.move().length() > tuning.teleport_dir_threshold:
		_tp_dir = Vector2i(_input.move_x, _input.move_y)  # steer while vanished
	_set_ground_velocity(Vector3.ZERO)
	_vel.y = 0.0
	if _state_frame >= tuning.teleport_frames:
		_reappear()
		_enter(State.IDLE)


## Reappear around the opponent where the latched stick points (from the
## teleporter's view), or behind their back with a neutral stick; facing them.
func _reappear() -> void:
	if opponent != null:
		var p := opponent.global_position + _reappear_dir() * tuning.teleport_behind_distance
		p.y = 0.0
		global_position = p
		_face_opponent(PI)
	event.emit(&"reappear", {"slot": slot, "position": global_position})


func _reappear_dir() -> Vector3:
	var v := Vector2(_tp_dir) / float(InputFrame.MOVE_SCALE)
	if v.length() <= tuning.teleport_dir_threshold:
		return -opponent._fwd()
	var f := opponent.global_position - global_position
	f.y = 0.0
	f = f.normalized() if f.length_squared() > 0.0001 else _fwd()
	var r := Vector3(-f.z, 0.0, f.x)
	return (r * v.x + f * v.y).normalized()


# --- Specials ---------------------------------------------------------------

func _try_special() -> bool:
	var y := _input.move().y
	var t := tuning
	var move_id := def.super1
	var cost := t.super1_cost_bars
	var kind := &"rush"
	if y > t.special_dir_threshold:
		move_id = def.super2
		cost = t.super2_cost_bars
		kind = &"beam"
	elif y < -t.special_dir_threshold:
		move_id = def.ultimate
		cost = t.ultimate_cost_bars
		kind = &"ultimate"
	if def.move(move_id) == null or not _spend_ki(cost * t.ki_bar_size):
		return false
	_start_move_id(move_id)
	event.emit(&"super_start", {"slot": slot, "kind": kind})
	if kind == &"ultimate":
		event.emit(&"ultimate_start", {"slot": slot, "freeze_frames": t.ultimate_freeze_frames})
		if director:
			director.request_world_freeze(t.ultimate_freeze_frames)
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
			beam.fire(self, m.spawn_move, _move_serial, _beam_aim(m.spawn_move))
			event.emit(&"beam", {"slot": slot, "position": global_position})


## Beam direction: flat along the facing, or from the air down at the
## opponent (beam height above their feet).
func _beam_aim(shot: MoveData) -> Vector3:
	var dir := _fwd()
	if opponent == null or not is_airborne():
		return dir
	var from := global_position + Vector3.UP * shot.hitbox_offset.y
	var to := opponent.global_position + Vector3.UP * shot.hitbox_offset.y
	return (to - from).normalized() if (to - from).length_squared() > 0.0001 else dir


# =============================================================================
# Hit reactions
# =============================================================================

## Within guard_half_angle_deg of facing `from` (ground plane).
func _is_facing(from: Vector3) -> bool:
	var to := from - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return true
	return rad_to_deg(_fwd().angle_to(to.normalized())) <= tuning.guard_half_angle_deg


## The guard's GuardResult against `hb`, or -1 when not guarding at all
## (not in a guard state, or hit from behind).
func _guard_result_for(hb: Hitbox) -> int:
	if not (state == State.GUARD or state == State.GUARD_STUN or state == State.COUNTER):
		return -1
	if not _is_facing(hb.origin):
		return -1
	return hb.move.guard_result(guard_pose())


## Counter stance catching the first hit of a string in its opening frames.
func _try_counter_guard(hb: Hitbox) -> bool:
	if state != State.COUNTER or _state_frame >= tuning.counter_guard_window_frames:
		return false
	if not hb.is_melee or not hb.opens_string or hb.attacker == null or not _is_facing(hb.origin):
		return false
	event.emit(&"counter_guard", {"slot": slot, "attacker_slot": hb.attacker.slot, "position": global_position})
	hb.attacker._recoil(tuning.counter_guard_recoil_frames, Vector3.ZERO)
	if director:
		director.request_world_freeze(tuning.counter_guard_freeze_frames)
	_start_move_id(def.counter)
	return true


func _take_blocked(hb: Hitbox, res: int) -> void:
	var m := hb.move
	var chip := m.damage * hb.damage_mult * tuning.guard_chip_ratio
	_set_health(maxf(health - chip, minf(health, tuning.chip_min_health)))  # chip can't KO
	var push := hb.world_knockback() * tuning.guard_pushback_ratio
	push.y = 0.0
	var crash := hb.breaks_guard
	match res:
		MoveData.GuardResult.KI_GUARD:
			push *= tuning.ki_guard_push_ratio
			_add_ki(-m.guard_ki_cost * hb.guard_ki_mult)
			crash = crash or ki <= 0.0
		MoveData.GuardResult.PUSH_OFF, MoveData.GuardResult.PUSH_STOP:
			push *= tuning.ki_guard_push_ratio
			_add_ki(tuning.ki_gain_on_push_off)
			var stop := res == MoveData.GuardResult.PUSH_STOP
			if hb.is_melee and hb.attacker != null and not crash:
				hb.attacker._recoil(tuning.push_off_recoil_frames, hb.forward * -tuning.push_off_recoil_speed)
			if stop and director:
				director.request_world_freeze(tuning.push_stop_freeze_frames)
			event.emit(&"push_off", {"slot": slot, "attacker_slot": hb.attacker.slot if hb.attacker else -1,
				"position": global_position, "stop": stop})
	if crash:
		_guard_crash()
	else:
		_enter(State.GUARD_STUN)
		_state_len = m.guard_stun
	_vel.x = push.x
	_vel.z = push.z
	_emit_hit(hb, chip, true, res)


## Guard crash (BT3 exhaustion): wide open until it times out or is mashed
## out; ends with a small ki refill.
func _guard_crash() -> void:
	_enter(State.GUARD_BREAK)
	_state_len = tuning.guard_break_stun_frames
	_guard_crashed = true
	event.emit(&"guard_break", {"slot": slot, "position": global_position})


func _take_hit(hb: Hitbox) -> void:
	var m := hb.move
	var attacker := hb.attacker
	var in_combo := state == State.HITSTUN or state == State.KNOCKDOWN or state == State.GUARD_BREAK
	if not in_combo:
		_clear_combo_segment()
		_combo_hits_taken = 0
		if attacker != null:
			attacker._set_combo(0)
			attacker._teleports_in_combo = 0
	var scaled_hits := maxi(_combo_hits_taken - tuning.combo_scaling_start_hit + 1, 0)
	var scale := maxf(1.0 - tuning.combo_scaling_step * scaled_hits, tuning.combo_scaling_min)
	_combo_hits_taken += 1
	var dmg := m.damage * hb.damage_mult * scale
	if state == State.TAUNT:
		dmg *= tuning.taunt_counter_damage_mult
	_set_health(health - dmg)
	_add_ki(tuning.ki_gain_on_hit_taken)
	if _vanish_battle != null:
		_end_vanish_battle(attacker.slot if attacker else -1)
	if attacker != null:
		attacker._on_hit_dealt(m)
	var kb := hb.world_knockback()
	var was_juggle := state == State.KNOCKDOWN
	var loop := _is_loop_hit(hb, was_juggle)
	if health <= 0.0:
		_enter_ko(kb)
	elif loop:
		_push_out(hb)
	elif m.knockdown or was_juggle:
		_enter(State.KNOCKDOWN)
		_land_frame = -1
		_vel = kb
		_bounce_pending = m.ground_bounce
		if _vel.y > 0.0:
			global_position.y = maxf(global_position.y, 0.001)
		event.emit(&"knockdown", {"slot": slot, "position": global_position})
	elif hb.stun_frames > 0:
		_stagger(hb.stun_frames)
		_vel = Vector3(kb.x, 0.0, kb.z)
	else:
		_enter(State.HITSTUN)
		_state_len = m.hitstun
		_vel = Vector3(kb.x, kb.y if is_airborne() else 0.0, kb.z)
	_emit_hit(hb, dmg, false)


## Anti-loop bookkeeping for a clean hit: true if it repeats a melee move of
## the current combo segment or relaunches past juggle_max_relaunches.
func _is_loop_hit(hb: Hitbox, was_juggle: bool) -> bool:
	if was_juggle:
		_combo_relaunches += 1
	var loop := was_juggle and _combo_relaunches > tuning.juggle_max_relaunches
	var activation := hb.hit_id >> 8
	if hb.is_melee and hb.attacker != null and activation != _combo_last_melee:
		_combo_last_melee = activation
		if hb.move.id in _combo_moves_taken:
			loop = true
		else:
			_combo_moves_taken.append(hb.move.id)
	return loop


## Loop breaker: knocked away along the hit with no lift, ending the combo.
func _push_out(hb: Hitbox) -> void:
	_enter(State.KNOCKDOWN)
	_land_frame = -1
	var away := Vector3(hb.forward.x, 0.0, hb.forward.z).normalized() * tuning.loop_pushout_speed
	_vel = Vector3(away.x, minf(_vel.y, 0.0), away.z)
	event.emit(&"knockdown", {"slot": slot, "position": global_position})


func _clear_combo_segment() -> void:
	_combo_moves_taken.clear()
	_combo_relaunches = 0
	_combo_last_melee = -1


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


func _emit_hit(hb: Hitbox, dmg: float, blocked: bool, guard_result: int = -1) -> void:
	var chest := global_position + Vector3.UP * (tuning.body_height * 0.6)
	event.emit(&"hit", {
		"slot": slot,
		"attacker_slot": hb.attacker.slot if hb.attacker else -1,
		"damage": dmg,
		"position": Geometry3D.get_closest_point_to_segment(chest, hb.a, hb.b),
		"heavy": hb.move.is_heavy,
		"blocked": blocked,
		"combo": hb.attacker.combo_hits if hb.attacker else 0,
		"guard_result": guard_result,
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


func _apply_motion() -> void:
	var dt := 1.0 / Tuning.match_rules.tick_rate
	var was_air := is_airborne()
	if was_air and not _floating:
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
			if _move.land_cancel:
				_enter(State.IDLE)
		State.KNOCKDOWN, State.KO:
			_vel.x *= 0.5
			_vel.z *= 0.5
		State.DODGE:
			if _dodge_kind == DodgeKind.AIR_TECH:
				_vel.x = 0.0
				_vel.z = 0.0
				_enter(State.IDLE)


func _set_ground_velocity(v: Vector3) -> void:
	_vel.x = v.x
	_vel.z = v.z
	_driven = true


func _turn_step() -> float:
	return deg_to_rad(tuning.turn_speed_deg) / Tuning.match_rules.tick_rate


func _attack_turn_step() -> float:
	return deg_to_rad(tuning.attack_track_turn_deg) / Tuning.match_rules.tick_rate


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


## SPECIAL, or HEAVY pressed while holding CHARGE.
func _consume_special() -> bool:
	if _consume(InputFrame.Btn.SPECIAL):
		return true
	return _input.is_held(InputFrame.Btn.CHARGE) and _consume(InputFrame.Btn.HEAVY)


## TELEPORT, or GUARD (teleports only where the timing allows it).
func _teleport_buffered() -> bool:
	return _buffered(InputFrame.Btn.TELEPORT) or _buffered(InputFrame.Btn.GUARD)


func _consume_teleport() -> bool:
	var tp := _consume(InputFrame.Btn.TELEPORT)
	var guard := _consume(InputFrame.Btn.GUARD)
	return tp or guard


## Within close_combat_range of the opponent (ground plane): HEAVY strikes
## instead of firing a ki blast.
func _in_close_range() -> bool:
	if opponent == null:
		return true
	var d := opponent.global_position - global_position
	d.y = 0.0
	return d.length() <= tuning.close_combat_range


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
		"state": state, "state_frame": _state_frame,
		"state_len": _state_len, "yaw": _yaw, "vel": _vel, "driven": _driven, "floating": _floating,
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
		"held": _held.duplicate(), "charging": _charging, "charge": _charge,
		"charge_btn": _charge_btn, "heavy_height": _heavy_height,
		"since_guard_press": _since_guard_press, "guard_press_armed": _guard_press_armed,
		"move_opens_string": _move_opens_string, "combo_moves_taken": _combo_moves_taken.duplicate(),
		"combo_relaunches": _combo_relaunches, "combo_last_melee": _combo_last_melee,
		"combo_hits_taken": _combo_hits_taken,
		"dodge_kind": _dodge_kind, "dodge_chain": _dodge_chain, "dodge_queued_btn": _dodge_queued_btn,
		"guard_pose": _guard_pose, "guard_pose_want": _guard_pose_want,
		"guard_pose_frames": _guard_pose_frames, "guard_crashed": _guard_crashed,
		"throw_breakable": _throw_breakable, "throw_back": _throw_back,
		"bounce_pending": _bounce_pending, "tp_dir": _tp_dir,
	})
	return s


func load_state(s: Dictionary) -> void:
	super.load_state(s)
	health = s["health"]
	ki = s["ki"]
	combo_hits = s["combo_hits"]
	_control_enabled = s["control"]
	state = s["state"]
	_state_frame = s["state_frame"]
	_state_len = s["state_len"]
	_set_yaw(s["yaw"])
	_vel = s["vel"]
	_driven = s["driven"]
	_floating = s["floating"]
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
	_held = (s["held"] as PackedInt32Array).duplicate()
	_charging = s["charging"]
	_charge = s["charge"]
	_charge_btn = s["charge_btn"]
	_heavy_height = s["heavy_height"]
	_since_guard_press = s["since_guard_press"]
	_guard_press_armed = s["guard_press_armed"]
	_move_opens_string = s["move_opens_string"]
	_combo_moves_taken = (s["combo_moves_taken"] as Array[StringName]).duplicate()
	_combo_relaunches = s["combo_relaunches"]
	_combo_last_melee = s["combo_last_melee"]
	_combo_hits_taken = s["combo_hits_taken"]
	_dodge_kind = s["dodge_kind"]
	_dodge_chain = s["dodge_chain"]
	_dodge_queued_btn = s["dodge_queued_btn"]
	_guard_pose = s["guard_pose"]
	_guard_pose_want = s["guard_pose_want"]
	_guard_pose_frames = s["guard_pose_frames"]
	_guard_crashed = s["guard_crashed"]
	_throw_breakable = s["throw_breakable"]
	_throw_back = s["throw_back"]
	_bounce_pending = s["bounce_pending"]
	_tp_dir = s["tp_dir"]
	health_changed.emit(health, tuning.max_health)
	ki_changed.emit(ki, ki_max())
	combo_changed.emit(combo_hits)
	state_changed.emit(STATE_NAMES[state])

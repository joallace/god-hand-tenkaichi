extends RefCounted
## Frame data on paper for a character's moves (gameplay_roadmap.md stage 0):
## startup, active, recovery, advantage on hit and on guard, damage as a
## share of health, push, guard results, cancels. Read from MoveData and the
## character's FighterTuning, never from a match; tests/frame_data_test
## checks the advantage formula against the real sim.
##
## Conventions (fighting-game notation, 60 Hz):
## - "hit on" is the first active frame, counted from 1 (MoveData.startup + 1).
## - Advantage assumes contact on the first active frame. After contact the
##   attacker is busy for `active + recovery` more frames and the victim for
##   its stun; hitstop freezes both alike, so it doesn't count:
##   advantage = stun - (active + recovery). Positive = the attacker acts
##   first. Cancels and the dodge cancel (FighterTuning
##   dodge_cancel_recovery_frames) can only improve it.
## - A knockdown has no fixed advantage (it depends on the fall): "KD".
## - Charge strikes get a second row at full charge ("@full").
## - Spawners (ki blasts, beams) show when the shot leaves; the next row is
##   the shot's hit (damage, stun, guard), whose timing depends on distance.
## - Staggers and guard crashes can be shortened by mashing
##   (FighterTuning.stun_mash_frames); the advantage shown is for a victim
##   who doesn't mash.
## - The victim is a reference fighter with the shared tuning (no character
##   overrides): its health, knockback taken, ki bar, push-off recoil it
##   inflicts, hitstop and guard crash length. Attacker-side values (charge
##   stun, guard break ratio) come from the attacker's own tuning.
## - With FighterTuning.charge_breaks_guard, a full charge at or past
##   charge_break_ratio crashes any guard ("crash": guard break stun instead
##   of guard stun).
## - Auto-chained hits (auto_next_on_hit) roll into the next hit on contact:
##   "chain" instead of an advantage.

const HEIGHT_NAMES := ["mid", "high", "low"]
## Guard result letters, by MoveData.GuardResult.
const GUARD_LETTERS := ["P", "K", "O", "S", "U"]

const COLUMNS: Array[String] = [
	"move", "role", "height", "hit on", "active", "recovery", "total",
	"damage", "dmg %", "on hit", "adv hit", "guard stun", "adv guard",
	"adv push-off", "guard m/h/l", "ki guard %bar", "push", "lift", "hitstop hit/guard", "cancel",
]


## One Dictionary per move (and one more per charge strike at full charge),
## keyed by COLUMNS, in the def's move order. `base` is the shared tuning:
## the attacker gets the def's overrides on it, the victim uses it as is.
static func rows(def: CharacterDef, base: FighterTuning) -> Array[Dictionary]:
	var t := def.build_tuning(base)
	var roles := _roles(def)
	var out: Array[Dictionary] = []
	for m: MoveData in def.moves:
		out.append(_row(m, t, base, roles.get(m.id, ""), 0.0))
		if m.is_charge_strike():
			out.append(_row(m, t, base, roles.get(m.id, ""), 1.0))
		if m.spawn_move != null:
			out.append(_payload_row(m, t, base))
	return out


## The hit a spawner's shot carries: its timing depends on the distance it
## travels, so only the hit columns are filled.
static func _payload_row(spawner: MoveData, t: FighterTuning, v: FighterTuning) -> Dictionary:
	var r := _row(spawner.spawn_move, t, v, "shot of " + String(spawner.id), 0.0)
	for c in ["hit on", "active", "recovery", "total", "adv hit", "adv guard", "adv push-off", "cancel"]:
		r[c] = "-"
	return r


## Frames the attacker still owes after contact on the first active frame.
static func busy_after_contact(m: MoveData) -> int:
	return m.active + m.recovery


## Victim stun from a clean hit at charge `ratio` (0 for normal moves):
## [frames, kind] with kind &"stun", &"stagger" or &"knockdown" (frames 0).
static func hit_reaction(m: MoveData, t: FighterTuning, ratio: float) -> Array:
	var knockdown := m.knockdown
	var stagger := m.stagger_frames
	if m.is_charge_strike():
		knockdown = knockdown and ratio >= m.charge_knockdown_ratio
		if ratio >= t.charge_stun_ratio:
			var k := clampf((ratio - t.charge_stun_ratio) / maxf(1.0 - t.charge_stun_ratio, 0.0001), 0.0, 1.0)
			stagger = maxi(stagger, roundi(lerpf(t.charge_stun_frames_min, t.charge_stun_frames_max, k)))
	if knockdown:
		return [0, &"knockdown"]
	if stagger > 0:
		return [stagger, &"stagger"]
	return [m.hitstun, &"stun"]


## Advantage on a clean hit, or null for a knockdown.
static func advantage_on_hit(m: MoveData, t: FighterTuning, ratio: float = 0.0) -> Variant:
	var r := hit_reaction(m, t, ratio)
	if r[1] == &"knockdown":
		return null
	return int(r[0]) - busy_after_contact(m)


## Plain or ki guard.
static func advantage_on_guard(m: MoveData) -> int:
	return m.guard_stun - busy_after_contact(m)


## A pose whose result is push-off / push-stop: the attacker recoils from
## contact for the victim's push_off_recoil_frames instead of finishing the
## move (a push-stop's world freeze stops both alike).
static func advantage_on_push_off(m: MoveData, victim: FighterTuning) -> int:
	return m.guard_stun - victim.push_off_recoil_frames


## A charge strike at `ratio` crashes any guard (attacker's tuning `t`).
static func crashes_guard(m: MoveData, t: FighterTuning, ratio: float) -> bool:
	return t.charge_breaks_guard and m.is_charge_strike() and ratio >= t.charge_break_ratio


## Guard crash: the victim is open for its guard_break_stun_frames.
static func advantage_on_crash(m: MoveData, victim: FighterTuning) -> int:
	return victim.guard_break_stun_frames - busy_after_contact(m)


## `t`: the attacker's tuning, `v`: the victim's.
static func _row(m: MoveData, t: FighterTuning, v: FighterTuning, role: String, ratio: float) -> Dictionary:
	var full := ratio > 0.0
	var dmg := m.damage * (lerpf(1.0, m.charge_damage_mult, ratio) if m.is_charge_strike() else 1.0)
	var guard_ki := m.guard_ki_cost * (lerpf(1.0, m.charge_guard_mult, ratio) if m.is_charge_strike() else 1.0)
	var spawner := m.spawn_kind != &""
	var reaction := hit_reaction(m, t, ratio)
	var on_hit := "KD" if reaction[1] == &"knockdown" else "%s %d" % [reaction[1], reaction[0]]
	var adv_hit: Variant = advantage_on_hit(m, t, ratio)
	var letters := ""
	var ki_guarded := false
	var pushed_off := false
	var blockable := false
	for pose in 3:
		var res := m.guard_result(pose as MoveData.Height)
		letters += GUARD_LETTERS[res]
		ki_guarded = ki_guarded or res == MoveData.GuardResult.KI_GUARD
		pushed_off = pushed_off or res == MoveData.GuardResult.PUSH_OFF or res == MoveData.GuardResult.PUSH_STOP
		blockable = blockable or res != MoveData.GuardResult.UNBLOCKABLE
	var crash := crashes_guard(m, t, ratio)
	var guard_stun := "crash %d" % v.guard_break_stun_frames if crash else str(m.guard_stun)
	var adv_guard := _signed(advantage_on_crash(m, v) if crash else advantage_on_guard(m))
	if m.is_throw:
		letters = "throw"
	if m.is_throw or not blockable:
		guard_stun = "-"
		adv_guard = "-"
	var adv_hit_text := "-" if spawner or adv_hit == null else _signed(adv_hit)
	if m.auto_next_on_hit != &"" and not spawner:
		adv_hit_text = "chain"
	var name := String(m.id) + (" @full" if full else "")
	var hit_on := "%d" % (m.startup + 1)
	if spawner:
		hit_on = "shot %d" % (m.spawn_frame + 1)
	if full:
		hit_on += " +%d held" % m.charge_max_frames
	return {
		"move": name,
		"role": role,
		"height": HEIGHT_NAMES[m.height],
		"hit on": hit_on,
		"active": m.active,
		"recovery": m.recovery,
		"total": m.total(),
		"damage": snappedf(dmg, 0.1),
		"dmg %": snappedf(dmg / v.max_health * 100.0, 0.01),
		"on hit": "-" if spawner else on_hit,
		"adv hit": adv_hit_text,
		"guard stun": "-" if spawner else guard_stun,
		"adv guard": "-" if spawner else adv_guard,
		"adv push-off": _signed(advantage_on_push_off(m, v)) if pushed_off and not spawner and not crash else "-",
		"guard m/h/l": "-" if spawner else letters,
		"ki guard %bar": snappedf(guard_ki / v.ki_bar_size * 100.0, 0.1) if ki_guarded and not spawner and not crash else "-",
		"push": snappedf(m.knockback.z * v.knockback_taken_mult, 0.01),
		"lift": snappedf(m.knockback.y * v.knockback_taken_mult, 0.01),
		"hitstop hit/guard": "%d/%d" % [m.hitstop_frames(v), mini(m.hitstop_frames(v), v.hitstop_light)],
		"cancel": _cancel_text(m),
	}


static func _signed(v: int) -> String:
	return ("+%d" % v) if v > 0 else str(v)


static func _cancel_text(m: MoveData) -> String:
	var parts: Array[String] = []
	if not m.cancel_into.is_empty():
		var ids: Array[String] = []
		for id in m.cancel_into:
			ids.append(String(id))
		parts.append("%d-%d %s%s" % [m.cancel_start + 1, m.cancel_end + 1, " ".join(ids),
			" (on hit)" if m.cancel_requires_hit else ""])
	if m.auto_next_on_hit != &"":
		parts.append("auto %s on hit" % m.auto_next_on_hit)
	if m.special_cancelable:
		parts.append("super")
	return "; ".join(parts)


## move id -> its role(s) in the def ("light 1", "heavy", "finisher"...).
static func _roles(def: CharacterDef) -> Dictionary:
	var roles := {}
	for i in def.light_string.size():
		_add_role(roles, def.light_string[i], "light %d" % (i + 1))
	for prop: String in ["heavy", "heavy_high", "heavy_low", "finisher", "jump_attack", "jump_heavy",
			"duck_heavy", "getup_attack", "dash_attack", "ki_blast", "throw", "counter", "super1",
			"super2", "ultimate"]:
		_add_role(roles, def.get(prop), prop)
	return roles


static func _add_role(roles: Dictionary, id: StringName, role: String) -> void:
	if id == &"":
		return
	roles[id] = (roles[id] + ", " + role) if roles.has(id) else role


static func to_markdown(title: String, rows_in: Array[Dictionary]) -> String:
	var lines: Array[String] = ["### " + title, "",
		"| " + " | ".join(COLUMNS) + " |",
		"|" + "---|".repeat(COLUMNS.size())]
	for r in rows_in:
		var cells: Array[String] = []
		for c in COLUMNS:
			cells.append(str(r[c]).replace("|", "/"))
		lines.append("| " + " | ".join(cells) + " |")
	return "\n".join(lines) + "\n"


static func to_csv(character: String, rows_in: Array[Dictionary], header: bool) -> String:
	var lines: Array[String] = []
	if header:
		lines.append("character," + ",".join(COLUMNS))
	for r in rows_in:
		var cells: Array[String] = [character]
		for c in COLUMNS:
			var s := str(r[c])
			cells.append("\"%s\"" % s.replace("\"", "\"\"") if s.contains(",") or s.contains("\"") else s)
		lines.append(",".join(cells))
	return "\n".join(lines) + "\n"

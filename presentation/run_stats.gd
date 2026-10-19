class_name RunStats
extends Node
## Co-op run statistics for the results screen (SPEC.md §10). Presentation
## side: it only listens to MatchEventHub's CONFIRMED stream (fighter events
## and director flow; SPEC_ONLINE.md §9), so a rolled-back hit or KO is never
## counted, and never touches sim state, so it is not saved with the match.
##
## Per team-0 player slot (config.players):
##   kos             enemies KO'd by this player's hit (the &"hit" a victim
##                   emits right after its &"ko" names the attacker; a KO with
##                   no such hit in its tick goes to the victim's last attacker)
##   damage          damage this player's hits did to enemies (chip included)
##   best_combo      longest combo (the attacker's combo count carried by
##                   each unblocked &"hit")
##   revives         &"revived" events naming this player as reviver
##   perfect_dodges  &"perfect_dodge" events this player emitted
## Team (result()["run"]): cleared, fight frames / seconds (sim ticks between
## the confirmed FIGHT phase and run_ended events), waves cleared
## (CoopRun.waves_cleared(); -1 outside Waves runs).

const KOS := "kos"
const DAMAGE := "damage"
const BEST_COMBO := "best_combo"
const REVIVES := "revives"
const PERFECT_DODGES := "perfect_dodges"
## Display order of the per-player rows (key, label).
const ROWS: Array = [
	[KOS, "KOs"],
	[DAMAGE, "Damage dealt"],
	[BEST_COMBO, "Best combo"],
	[REVIVES, "Revives given"],
	[PERFECT_DODGES, "Perfect dodges"],
]

var director: MatchDirector
var config: MatchConfig
var hub: MatchEventHub
## slot -> {KOS: int, DAMAGE: float, BEST_COMBO: int, REVIVES: int, PERFECT_DODGES: int}
var players: Dictionary = {}
var cleared := false
var ended := false
var fight_frames := 0
var waves_cleared := -1

var _fight_start_tick := -1
var _ko_pending: Dictionary = {}  # victim slot -> tick of its KO (not yet credited)
var _last_attacker: Dictionary = {}  # victim slot -> attacker slot


func _init() -> void:
	name = "RunStats"


## Call before director.setup() so the first FIGHT phase is seen.
func setup(p_director: MatchDirector, p_hub: MatchEventHub, p_config: MatchConfig) -> void:
	director = p_director
	config = p_config
	hub = p_hub
	hub.bind_director(director)
	hub.confirmed_event.connect(_on_confirmed_event)
	reset_players(config)


## One zeroed record per team-0 slot of `cfg`.
func reset_players(cfg: MatchConfig) -> void:
	players.clear()
	for p in cfg.players:
		players[p.slot] = {KOS: 0, DAMAGE: 0.0, BEST_COMBO: 0, REVIVES: 0, PERFECT_DODGES: 0}


func is_waves_run() -> bool:
	return config != null and config.coop != null and config.coop.structure == CoopConfig.Structure.WAVES


## Plain data for Game.last_result: {"stats": {slot: {...}}, "run": {...}}.
func result() -> Dictionary:
	_flush_pending()
	var stats := {}
	for slot: int in players:
		stats[slot] = (players[slot] as Dictionary).duplicate()
	var frames := fight_frames if ended else _frames_so_far()
	return {
		"stats": stats,
		"run": {
			"cleared": cleared,
			"frames": frames,
			"seconds": frames / float(Tuning.match_rules.tick_rate),
			"waves_cleared": _waves_now() if is_waves_run() else -1,
		},
	}


func _frames_so_far() -> int:
	if _fight_start_tick < 0 or director == null:
		return 0
	return director.tick - _fight_start_tick


func _waves_now() -> int:
	if ended:
		return waves_cleared
	if director != null and director.coop != null:
		return director.coop.waves_cleared()
	return 0


func _on_run_ended(tick: int, p_cleared: bool) -> void:
	if ended:
		return
	fight_frames = tick - _fight_start_tick if _fight_start_tick >= 0 else 0
	waves_cleared = _waves_now() if is_waves_run() else -1
	cleared = p_cleared
	ended = true
	_flush_pending()


## KOs whose tick passed without a hit naming the attacker: the victim's last
## attacker gets them (all of them when before_tick < 0).
func _flush_pending(before_tick: int = -1) -> void:
	for slot: int in _ko_pending.keys():
		if before_tick < 0 or int(_ko_pending[slot]) < before_tick:
			_credit_pending(slot)


func _credit_pending(victim_slot: int) -> void:
	if not _ko_pending.has(victim_slot):
		return
	_ko_pending.erase(victim_slot)
	_credit_ko(int(_last_attacker.get(victim_slot, -1)))


func _credit_ko(attacker_slot: int) -> void:
	if players.has(attacker_slot):
		players[attacker_slot][KOS] += 1


## Confirmed events only (fighter payloads carry slot / team).
func _on_confirmed_event(tick: int, kind: StringName, data: Dictionary) -> void:
	_flush_pending(tick)
	var slot: int = int(data.get("slot", -1))
	match kind:
		&"phase_changed":
			if data["phase"] == MatchDirector.Phase.FIGHT and _fight_start_tick < 0:
				_fight_start_tick = tick
		&"run_ended":
			_on_run_ended(tick, bool(data["cleared"]))
		&"hit":
			_on_hit(slot, int(data.get("team", -1)), data)
		&"ko":
			if not players.has(slot):
				_ko_pending[slot] = tick
		&"revived":
			var reviver: int = int(data.get("reviver_slot", -1))
			if players.has(reviver):
				players[reviver][REVIVES] += 1
		&"perfect_dodge":
			if players.has(slot):
				players[slot][PERFECT_DODGES] += 1


## &"hit" is emitted by the victim, after its &"ko" when the hit KO'd.
func _on_hit(victim: int, victim_team: int, data: Dictionary) -> void:
	var attacker: int = int(data.get("attacker_slot", -1))
	if attacker < 0 or attacker == victim:
		return
	if _ko_pending.has(victim):
		_ko_pending.erase(victim)
		_credit_ko(attacker)
	_last_attacker[victim] = attacker
	if not players.has(attacker) or victim_team == CoopRun.HUMAN_TEAM:
		return
	var rec: Dictionary = players[attacker]
	rec[DAMAGE] += float(data.get("damage", 0.0))
	if not bool(data.get("blocked", false)):
		rec[BEST_COMBO] = maxi(int(rec[BEST_COMBO]), int(data.get("combo", 0)))

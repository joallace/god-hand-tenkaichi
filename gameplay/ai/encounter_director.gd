class_name EncounterDirector
extends RefCounted
## Co-op attack coordination (SPEC.md §4.1). Owned by MatchDirector, ticked
## once per non-frozen sim tick after combat, saved with it. Disabled (every
## request granted) outside Mode.COOP.
##
## STUB: the API below is the contract CpuBrain codes against; the real
## per-player melee/ranged token pools and the grab lock replace the bodies.

enum Kind { MELEE, RANGED }

var director: MatchDirector
var enabled := false


func _init(p_director: MatchDirector) -> void:
	director = p_director
	enabled = director.config != null and director.config.mode == MatchConfig.Mode.COOP


## Ask for a `kind` token to attack `victim`. True = granted (or already
## held). Call every tick the attack is wanted; grants are deterministic.
func request_token(_attacker: Fighter, _victim: Fighter, _kind: Kind) -> bool:
	return true


## Whether `attacker` currently holds a `kind` token (on any victim).
func holds_token(_attacker: Fighter, _kind: Kind) -> bool:
	return not enabled


## Give back every token `attacker` holds.
func release(_attacker: Fighter) -> void:
	pass


## Grab lock: true if `attacker` may start a throw on `victim` (no one else
## is grabbing that victim). Claimed until release_grab or the throw ends.
func request_grab(_attacker: Fighter, _victim: Fighter) -> bool:
	return true


func release_grab(_attacker: Fighter) -> void:
	pass


func sim_tick(_tick: int) -> void:
	pass


func save_state() -> Dictionary:
	return {}


func load_state(_s: Dictionary) -> void:
	pass

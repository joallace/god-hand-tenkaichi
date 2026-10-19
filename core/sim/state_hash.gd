class_name StateHash
extends RefCounted
## Checksum of a whole sim state (SPEC_ONLINE.md §6 rule 4): the hash of
## var_to_bytes(director.save_state()). Floats are compared bitwise (so -0.0
## and 0.0 differ, and any drift in the last bit shows), Dictionaries in
## insertion order: save_state must build them in a fixed order (CoopRun
## sorts its keys for that). Used by replays (checkpoints), desync checks and
## rollback tests. 32-bit (Godot's murmur3 over the bytes): enough to spot a
## desync, not a cryptographic digest.


static func of(director: MatchDirector) -> int:
	return of_state(director.save_state())


## Same for an already taken snapshot.
static func of_state(state: Dictionary) -> int:
	return hash(var_to_bytes(state))

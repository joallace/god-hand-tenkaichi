class_name PlayerSlotConfig
extends Resource
## Who controls a fighter and with what. Built by the join screen.

enum InputKind { LOCAL, CPU, NETWORK }

@export var slot: int = 0
@export var character_id: StringName = &"brawler"
@export var input_kind: InputKind = InputKind.LOCAL
## For LOCAL: Bindings.Kind (PAD or KEYBOARD).
@export var device_kind: int = 0
## For LOCAL pads: the joypad device id.
@export var device_id: int = -1
## For CPU: difficulty level, an index into Tuning.cpu.level_names
## (-1 = Tuning.cpu.default_level).
@export var cpu_level: int = -1
## For NETWORK: peer id.
@export var peer_id: int = 0


func create_input_source() -> InputSource:
	match input_kind:
		InputKind.CPU:
			return CpuInput.new(cpu_level)
		InputKind.NETWORK:
			return NetworkInput.new()
	return LocalDeviceInput.new(slot, device_kind, device_id)

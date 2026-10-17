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
## For CPU: difficulty 0..1. For NETWORK: peer id.
@export var cpu_level: float = 0.5
@export var peer_id: int = 0


func create_input_source() -> InputSource:
	match input_kind:
		InputKind.CPU:
			return CpuInput.new()
		InputKind.NETWORK:
			return NetworkInput.new()
	return LocalDeviceInput.new(slot, device_kind, device_id)

class_name MatchScene
extends Node
## Root of scenes/match/match.tscn. Builds the whole match from
## Game.current_config (or a default local versus config when run directly):
##
##   Match (MatchScene)
##   ├─ World (Node3D)            lives in the root viewport's World3D
##   │  ├─ Arena                  floor, ring, wall, scenery, sky, sun
##   │  ├─ MatchDirector          simulation; spawns Fighter1/Fighter2
##   │  └─ Vfx (VfxManager)       visual-only effects
##   ├─ MatchEventHub             deduplicated fighter events for presentation
##   ├─ ViewLayout (Control)      split screen / single view SubViewports,
##   │                            each with a FighterCamera sharing World3D
##   ├─ MatchHud (CanvasLayer 10) global top bar + announcer
##   └─ PauseMenu (CanvasLayer 50)

var config: MatchConfig
var world: Node3D
var arena: Arena
var director: MatchDirector
var hub: MatchEventHub
var views: ViewLayout
var hud: MatchHud
var pause_menu: PauseMenu
var vfx: VfxManager

var _ending := false


func _ready() -> void:
	config = Game.current_config
	if config == null or config.players.size() < 2:
		config = build_default_config()
		Game.current_config = config

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	arena = Arena.new()
	world.add_child(arena)

	hub = MatchEventHub.new()
	add_child(hub)

	director = MatchDirector.new()
	director.name = "MatchDirector"
	world.add_child(director)

	vfx = VfxManager.new()
	world.add_child(vfx)
	vfx.setup(hub)

	views = ViewLayout.new()
	add_child(views)

	hud = MatchHud.new()
	add_child(hud)
	hud.setup(director, hub)

	pause_menu = PauseMenu.new()
	add_child(pause_menu)
	pause_menu.setup(director)

	director.fighters_spawned.connect(_on_fighters_spawned)
	director.round_started.connect(_on_round_started)
	director.match_ended.connect(_on_match_ended)
	director.setup(config)


## P1 = first connected joypad (else keyboard layout A), P2 = second joypad
## (else keyboard layout B).
static func build_default_config() -> MatchConfig:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.LOCAL_VERSUS)
	var pads := Input.get_connected_joypads()
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.LOCAL
		if i < pads.size():
			p.device_kind = Bindings.Kind.PAD
			p.device_id = pads[i]
		else:
			p.device_kind = Bindings.Kind.KEYBOARD
			p.device_id = -1
		cfg.players.append(p)
	return cfg


func _on_fighters_spawned(fighters: Array[Fighter]) -> void:
	hub.watch(fighters)
	views.build(config, fighters, get_viewport().find_world_3d(), hub)


func _on_round_started(_round_number: int) -> void:
	views.snap_cameras()


func _on_match_ended(winner_slot: int) -> void:
	if _ending:
		return
	_ending = true
	get_tree().create_timer(Tuning.hud.match_end_delay, false).timeout.connect(_finish.bind(winner_slot))


func _finish(winner_slot: int) -> void:
	Game.finish_match(winner_slot, director.wins)

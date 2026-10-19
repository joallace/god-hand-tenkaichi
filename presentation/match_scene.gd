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
##   ├─ MatchEventHub             sim events for presentation: immediate
##   │                            (cosmetic) and confirmed (match flow) streams
##   ├─ MatchSfx                  sound effects (via the Sfx autoload)
##   ├─ RunStats                  co-op only: results-screen stats from events
##   ├─ ViewLayout (Control)      split screen / single view SubViewports,
##   │                            each with a FighterCamera sharing World3D
##   │                            (+ a CoopViewHud per view in co-op)
##   ├─ MatchHud (CanvasLayer 10) global top bar + announcer
##   ├─ PauseMenu (CanvasLayer 50)
##   ├─ RollbackDriver            online only: steps the director (§7)
##   └─ NetOverlay (CanvasLayer 60) online only: debug net stats (F3)
##
## Online (Net.room open and the config has owner peers): a RollbackDriver
## drives the director instead of its own physics tick; the slots this
## machine owns read their devices through it (keyboard layouts by local
## player index, so a guest in slot 2 still plays on layout A). A confirmed
## match end tells the room (results phase); a driver abort (desync, host
## gone) leaves the session with a message. The pause menu runs in its
## online form (the sim never pauses), and the HUD shows the other peers'
## pause tags (room `changed`), "Waiting for <name>…" while the driver
## stalls and "<name> disconnected" when a peer leaves the room.

var config: MatchConfig
var world: Node3D
var arena: Arena
var director: MatchDirector
var hub: MatchEventHub
var views: ViewLayout
var hud: MatchHud
var pause_menu: PauseMenu
var vfx: VfxManager
var sfx: MatchSfx
var coop_huds: Dictionary = {}  # view slot -> CoopViewHud (co-op only)
var run_stats: RunStats  # co-op only
var driver: RollbackDriver  # online only
var net_overlay: NetOverlay  # online only
var recorder: ReplayRecorder

var _ending := false


func _ready() -> void:
	config = Game.current_config
	if config == null or (config.players.size() < 2 and config.mode != MatchConfig.Mode.COOP):
		config = build_default_config()
		Game.current_config = config

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	arena = Arena.new()
	arena.radius = MatchDirector.arena_radius_for(config)
	world.add_child(arena)

	hub = MatchEventHub.new()
	add_child(hub)

	director = MatchDirector.new()
	director.name = "MatchDirector"
	world.add_child(director)
	hub.bind_director(director)

	vfx = VfxManager.new()
	world.add_child(vfx)
	vfx.setup(hub)

	sfx = MatchSfx.new()
	add_child(sfx)
	sfx.setup(director, hub)

	views = ViewLayout.new()
	add_child(views)

	hud = MatchHud.new()
	add_child(hud)
	hud.setup(director, hub)

	pause_menu = PauseMenu.new()
	add_child(pause_menu)
	pause_menu.setup(director)

	if config.mode == MatchConfig.Mode.COOP:
		run_stats = RunStats.new()
		add_child(run_stats)

	# Structural: views are built for the spawned fighters (the hub watches
	# fighters joining / leaving by itself).
	director.fighters_spawned.connect(_on_fighters_spawned)
	# Cosmetic: camera snap at round start. Match flow (results) waits for the
	# confirmed match_ended, so a rolled-back KO never ends the match.
	hub.director_event.connect(_on_director_event)
	hub.confirmed_event.connect(_on_confirmed_event)
	if run_stats != null:
		run_stats.setup(director, hub, config)
	if is_online_match():
		_start_online()
	else:
		director.setup(config)
	recorder = ReplayRecorder.new()  # auto-keeps user://replays/last_<n>.ghr
	add_child(recorder)
	recorder.attach(director)


func _exit_tree() -> void:
	if driver != null and Net.driver == driver:
		Net.driver = null
		if Net.room != null:
			Net.room.driver = null


## An online match: a room is open and the config is shared by peers.
func is_online_match() -> bool:
	return Net.room != null and Net.session != null and config.is_online()


func _start_online() -> void:
	driver = RollbackDriver.new()
	driver.name = "RollbackDriver"
	add_child(driver)
	var me := Net.local_peer()
	var local := {}
	for p in config.players:
		if p.input_kind != PlayerSlotConfig.InputKind.CPU and p.owner_peer == me:
			local[p.slot] = LocalDeviceInput.new(local.size(), p.device_kind, p.device_id)
	Net.driver = driver
	Net.room.driver = driver
	driver.aborted.connect(_on_net_aborted)
	driver.start(director, Net.session, config, local, Net.input_delay_for_match(), hub)
	pause_menu.setup_online(driver)
	net_overlay = NetOverlay.new()
	add_child(net_overlay)
	net_overlay.setup(driver)
	Net.room.changed.connect(_on_room_changed)
	Net.room.peer_departed.connect(_on_peer_departed)
	_on_room_changed()


func _process(_delta: float) -> void:
	if driver != null:
		refresh_net_ui()


## Online HUD state that follows the driver every frame (the waiting banner).
func refresh_net_ui() -> void:
	hud.set_waiting(driver.waiting_for() if not driver.is_aborted else "")


## Pause tags: every peer but this one with the overlay open.
func _on_room_changed() -> void:
	if Net.room == null:
		return
	var others: Array[int] = []
	for peer in Net.room.paused_peers:
		if peer != Net.local_peer():
			others.append(peer)
	hud.set_paused_peers(others)


func _on_peer_departed(_peer: int, peer_name: String) -> void:
	if not _ending:
		hud.notice(Tuning.hud.text_disconnected % peer_name)


func _on_net_aborted(reason: StringName) -> void:
	Net.end_with_message(Net.reason_text(Protocol.Reason.DESYNC if reason == &"desync" else Protocol.Reason.LEFT))


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
	if config.mode == MatchConfig.Mode.COOP:
		for slot: int in views.panels:
			var ch := CoopViewHud.new()
			(views.panels[slot] as Control).add_child(ch)
			ch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			ch.setup(director, hub, director.fighter_for_slot(slot), views.cameras[slot])
			coop_huds[slot] = ch


func _on_director_event(kind: StringName, _data: Dictionary) -> void:
	if kind == &"round_started":
		views.snap_cameras()


func _on_confirmed_event(_tick: int, kind: StringName, data: Dictionary) -> void:
	if kind == &"match_ended":
		_on_match_ended(int(data["winner_slot"]))


## True once a confirmed match_ended scheduled the results screen.
func is_ending() -> bool:
	return _ending


func _on_match_ended(winner_slot: int) -> void:
	if _ending:
		return
	_ending = true
	get_tree().create_timer(Tuning.hud.match_end_delay, false).timeout.connect(_finish.bind(winner_slot))


## Human config slots a CPU controls at the end (co-op disconnect / Leave
## Run takeovers), for the results screen's "CPU (<name>)" tags.
static func cpu_takeover_slots(d: MatchDirector) -> PackedInt32Array:
	var out := PackedInt32Array()
	if d == null or d.config == null:
		return out
	for p in d.config.players:
		if p.input_kind != PlayerSlotConfig.InputKind.CPU \
				and d.controller_for_slot(p.slot) == MatchDirector.Controller.CPU:
			out.append(p.slot)
	return out


func _finish(winner_slot: int) -> void:
	if driver != null and Net.room != null:
		Net.room.match_finished()
	var extra: Dictionary = run_stats.result() if run_stats != null else {}
	extra["replay_path"] = recorder.auto_path
	extra["end_reason"] = director.end_reason
	extra["cpu_takeovers"] = cpu_takeover_slots(director)
	Game.finish_match(winner_slot, director.wins, extra)

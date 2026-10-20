class_name AudioPage
extends SettingsPage
## Settings > Audio: volume per bus (Settings.audio), applied and saved on
## every change. Changing the effects volume plays a sample hit so the level
## can be judged; menu sounds already blip on the UI bus.

const MUTED_LABEL := "Muted"
## Sound played on the effects bus when its volume changes.
const SAMPLE_SOUND := &"hit_light"

## bus -> OptionSelector
var sliders: Dictionary[StringName, OptionSelector] = {}


func _init() -> void:
	super()
	title = "AUDIO"


func _ready() -> void:
	var names := {
		AudioSettings.MASTER: ["Master volume", "Overall volume."],
		Tuning.sfx.bus: ["Effects volume", "Hits, ki, movement and other match sounds."],
		Tuning.sfx.ui_bus: ["Menu volume", "Menu navigation and confirmation sounds."],
	}
	for bus in AudioSettings.buses():
		var label: Array = names.get(bus, [String(bus), ""])
		var s := MenuHelpers.selector(label[0], _labels(), _index(Settings.audio.volume(bus)))
		s.wrap_around = false
		s.value_changed.connect(_on_volume.bind(bus))
		sliders[bus] = s
		add_row(s, label[1])
	add_reset_row("Audio", _reset)
	relink()


static func _labels() -> PackedStringArray:
	var out := PackedStringArray()
	var step := maxi(Tuning.sfx.volume_step_percent, 1)
	for p in range(0, AudioSettings.MAX_PERCENT + 1, step):
		out.append(MUTED_LABEL if p == 0 else "%d%%" % p)
	return out


static func _index(percent: int) -> int:
	return roundi(float(percent) / maxi(Tuning.sfx.volume_step_percent, 1))


func _on_volume(i: int, bus: StringName) -> void:
	Settings.audio.set_volume(bus, i * maxi(Tuning.sfx.volume_step_percent, 1))
	Settings.apply_audio()
	if bus == Tuning.sfx.bus:
		Sfx.play(SAMPLE_SOUND)
	if Settings.audio.save() != OK:
		status.emit("Could not save audio settings", true)


func _reset() -> void:
	Settings.audio.reset_defaults()
	Settings.apply_audio()
	Settings.audio.save()
	for bus in sliders:
		sliders[bus].index = _index(Settings.audio.volume(bus))

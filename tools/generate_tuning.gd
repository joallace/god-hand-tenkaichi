extends SceneTree
## Writes data/tuning/<key>.tres for every entry in the Tuning REGISTRY
## that doesn't exist yet (pass --force to overwrite with script defaults).
##   godot --headless --script res://tools/generate_tuning.gd [-- --force]

const TuningDB := preload("res://core/tuning/tuning_db.gd")


func _init() -> void:
	var force := "--force" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(TuningDB.DIR)
	for key in TuningDB.REGISTRY:
		var path: String = TuningDB.DIR + key + ".tres"
		if ResourceLoader.exists(path) and not force:
			print("keep  ", path)
			continue
		var err := ResourceSaver.save(TuningDB.REGISTRY[key].new(), path)
		print("write ", path, " -> ", error_string(err))
	quit()

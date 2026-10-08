extends GutTest

# Guards the web presets' exclude_filter. It drops scripts/tools/*, the test
# scenes and the TTFs from the pck, so anything the shipped game loads must live
# elsewhere.
# A miss does not show up on desktop or in this suite's other tests: the web
# build just fails to load the script. Two ways in are checked: the resource
# dependency graph from main.tscn, and path strings / tool class_names named
# in shipped code (load() by path and global classes are invisible to the graph).

const ROOT_SCENE := "res://scenes/main.tscn"
const EXCLUDED_PREFIXES: Array[String] = ["res://scripts/tools/"]
const EXCLUDED_FILES: Array[String] = [
	"res://scenes/maps/procedural_test.tscn",
	"res://scenes/tools/fire_blob_test.tscn",
	"res://scenes/tools/tileset_test.tscn",
]
# Shipped code = every .gd outside these.
const NOT_SHIPPED_DIRS: Array[String] = ["res://scripts/tools/", "res://tests/", "res://addons/"]


func _is_excluded(path: String) -> bool:
	if path in EXCLUDED_FILES:
		return true
	# assets/fonts/*.ttf: dropped from the pck, and the web engine has no FreeType
	# to draw one anyway. Shipped UI uses the bitmap bakes in assets/fonts/bitmap/.
	if path.begins_with("res://assets/fonts/") and path.ends_with(".ttf"):
		return true
	for prefix in EXCLUDED_PREFIXES:
		if path.begins_with(prefix):
			return true
	return false


# ResourceLoader.get_dependencies entries look like "uid://…::Type::res://path"
# or "res://path::Type"; the res:// part is what the pck stores.
func _dep_path(entry: String) -> String:
	var at := entry.rfind("res://")
	if at < 0:
		return ""
	var path := entry.substr(at)
	var cut := path.find("::")
	return path if cut < 0 else path.substr(0, cut)


func test_main_scene_dependency_graph_avoids_excluded_files() -> void:
	var seen := {}
	var queue: Array[String] = [ROOT_SCENE]
	var offenders: Array[String] = []
	while not queue.is_empty():
		var path: String = queue.pop_back()
		if seen.has(path):
			continue
		seen[path] = true
		if _is_excluded(path):
			offenders.append(path)
		for entry in ResourceLoader.get_dependencies(path):
			var dep := _dep_path(entry)
			if dep != "" and not seen.has(dep):
				queue.append(dep)
	assert_gt(seen.size(), 50, "walked too little of the graph; is the root scene right?")
	assert_eq(offenders, [] as Array[String], "shipped scenes depend on files the web export drops")


func _shipped_scripts(dir: String, out: Array[String]) -> void:
	for skip in NOT_SHIPPED_DIRS:
		if (dir + "/").begins_with(skip):
			return
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			out.append(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_shipped_scripts(dir.path_join(sub), out)


func _code_without_comments(path: String) -> String:
	var lines := FileAccess.get_file_as_string(path).split("\n")
	for i in lines.size():
		var hash_at := lines[i].find("#")
		if hash_at >= 0:
			lines[i] = lines[i].substr(0, hash_at)
	return "\n".join(lines)


func test_shipped_code_names_no_excluded_path_or_tool_class() -> void:
	var tool_classes: Array[String] = []
	for entry in ProjectSettings.get_global_class_list():
		if _is_excluded(entry["path"]):
			tool_classes.append(entry["class"])
	var scripts: Array[String] = []
	_shipped_scripts("res://", scripts)
	assert_gt(scripts.size(), 50, "found too few shipped scripts")

	var offenders: Array[String] = []
	var class_pattern := RegEx.create_from_string("\\b(" + "|".join(tool_classes) + ")\\b")
	for path in scripts:
		var code := _code_without_comments(path)
		for prefix in EXCLUDED_PREFIXES:
			if code.contains(prefix):
				offenders.append("%s names %s" % [path, prefix])
		for excluded in EXCLUDED_FILES:
			if code.contains(excluded):
				offenders.append("%s names %s" % [path, excluded])
		if code.contains(".ttf\""):
			offenders.append("%s loads a TTF" % path)
		if not tool_classes.is_empty():
			var hit := class_pattern.search(code)
			if hit:
				offenders.append("%s uses tool class %s" % [path, hit.get_string()])
	assert_eq(offenders, [] as Array[String], "shipped code reaches into files the web export drops")

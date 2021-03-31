@tool
extends Reference

const aligned_byte_buffer: GDScript = preload("./aligned_byte_buffer.gd")

func to_classname(utype: int) -> String:
	var ret = utype_to_classname.get(utype, "")
	if ret == "":
		return "[UnknownType:" + str(utype) + "]"
	return ret


func to_utype(classname: String) -> int:
	return classname_to_utype.get(classname, 0)


func instantiate_unity_object(meta: Object, fileID: int, utype: int, type: String) -> UnityObject:
	var ret: UnityObject = null
	var actual_type = type
	if utype != 0 and utype_to_classname.has(utype):
		actual_type = utype_to_classname[utype]
		if actual_type != type and (type != "Behaviour" or actual_type != "FlareLayer") and (type != "Prefab" or actual_type != "PrefabInstance"):
			printerr("Mismatched type for " + meta.guid + ":" + str(fileID) + " type:" + type + " vs. utype:" + str(utype) + ":" + actual_type)
	if _type_dictionary.has(actual_type):
		# print("Will instantiate object of type " + str(actual_type) + "/" + str(type) + "/" + str(utype) + "/" + str(classname_to_utype.get(actual_type, utype)))
		ret = _type_dictionary[actual_type].new()
	else:
		printerr("Failed to instantiate object of type " + str(actual_type) + "/" + str(type) + "/" + str(utype) + "/" + str(classname_to_utype.get(actual_type, utype)))
		if type.ends_with("Importer"):
			ret = UnityAssetImporter.new()
		else:
			ret = UnityObject.new()
	ret.meta = meta
	ret.fileID = fileID
	if utype != 0 and utype != classname_to_utype.get(actual_type, utype):
		printerr("Mismatched utype " + str(utype) + " for " + type)
	ret.utype = classname_to_utype.get(actual_type, utype)
	ret.type = actual_type
	return ret


class Skelley extends Reference:
	var id: int = 0
	var bones: Array = [].duplicate()
	
	var root_bones: Array = [].duplicate()
	
	var uniq_key_to_bone: Dictionary = {}.duplicate()
	var godot_skeleton: Skeleton3D = Skeleton3D.new()
	
	# Temporary private storage:
	var intermediate_bones: Array = [].duplicate()
	var intermediates: Dictionary = {}.duplicate()
	var bone0_parent_list: Array = [].duplicate()
	var bone0_parents: Dictionary = {}.duplicate()
	var found_prefab_instance: UnityPrefabInstance = null

	func initialize(bone0: UnityTransform):
		var current_parent: UnityObject = bone0
		var tmp: Array = [].duplicate()
		intermediates[current_parent.uniq_key] = current_parent
		intermediate_bones.push_back(current_parent)
		while current_parent != null:
			tmp.push_back(current_parent)
			bone0_parents[current_parent.uniq_key] = current_parent
			current_parent = current_parent.parent_no_stripped
		# reverse list
		for i in range(len(tmp)):
			bone0_parent_list.push_back(tmp[-1 - i])

	func add_bone(bone: UnityTransform) -> Array:
		bones.push_back(bone)
		var added_bones: Array = [].duplicate()
		var current_parent: UnityObject = bone #### UnityTransform = bone
		while current_parent != null and not bone0_parents.has(current_parent.uniq_key):
			if intermediates.has(current_parent.uniq_key):
				return added_bones
			intermediates[current_parent.uniq_key] = current_parent
			intermediate_bones.push_back(current_parent)
			added_bones.push_back(current_parent)
			current_parent = current_parent.parent_no_stripped
		if current_parent == null:
			printerr("Warning: No common ancestor for skeleton " + bone.uniq_key + ": assume parented at root")
			bone0_parents.clear()
			bone0_parent_list.clear()
			return added_bones
		#if current_parent.parent_no_stripped == null:
		#	bone0_parents.clear()
		#	bone0_parent_list.clear()
		#	printerr("Warning: Skeleton parented at root " + bone.uniq_key + " at " + current_parent.uniq_key)
		#	return added_bones
		if bone0_parent_list.is_empty():
			return added_bones
		while bone0_parent_list[-1] != current_parent:
			bone0_parents.erase(bone0_parent_list[-1].uniq_key)
			bone0_parent_list.pop_back()
			if bone0_parent_list.is_empty():
				printerr("Assertion failure " + bones[0].uniq_key + "/" + current_parent.uniq_key)
				return []
			if not intermediates.has(bone0_parent_list[-1].uniq_key):
				intermediates[bone0_parent_list[-1].uniq_key] = bone0_parent_list[-1]
				intermediate_bones.push_back(bone0_parent_list[-1])
				added_bones.push_back(bone0_parent_list[-1])
		#if current_parent.is_stripped and found_prefab_instance == null:
			# If this is child a prefab instance, we want to make sure the prefab instance itself
			# is used for skeleton merging, so that we avoid having duplicate skeletons.
			# WRONG!!! They might be different skelleys in the source prefab.
		#	found_prefab_instance = current_parent.parent_no_stripped
		#	if found_prefab_instance != null:
		#		added_bones.push_back(found_prefab_instance)
		return added_bones

	# if null, this is not mixed with a prefab's nodes
	var parent_prefab: UnityPrefabInstance:
		get:
			if bone0_parent_list.is_empty():
				return null
			var pref: UnityObject = bone0_parent_list[-1]
			if pref is UnityPrefabInstance:
				return pref
			return null

	# if null, this is a root node.
	var parent_transform: UnityTransform:
		get:
			if bone0_parent_list.is_empty():
				return null
			var pref: UnityObject = bone0_parent_list[-1]
			if pref is UnityTransform:
				return pref
			return null

	func add_nodes_recursively(skel_parents: Dictionary, child_transforms_by_stripped_id: Dictionary, bone_transform: UnityTransform):
		if bone_transform.is_stripped:
			#printerr("Not able to add skeleton nodes from a stripped transform!")
			for child in child_transforms_by_stripped_id.get(bone_transform.fileID, []):
				if not intermediates.has(child.uniq_key):
					print("Adding child bone " + str(child) + " into intermediates during recursive search from " + str(bone_transform))
					intermediates[child.uniq_key] = child
					intermediate_bones.push_back(child)
					# TODO: We might also want to exclude prefab instances here.
					# If something is a prefab, we should not include it in the skeleton!
					if not skel_parents.has(child.uniq_key):
						# We will not recurse: everything underneath this is part of a separate skeleton.
						add_nodes_recursively(skel_parents, child_transforms_by_stripped_id, child)
			return
		for child_ref in bone_transform.children_refs:
			# print("Try child " + str(child_ref))
			var child: UnityTransform = bone_transform.meta.lookup(child_ref)
			# not skel_parents.has(child.uniq_key):
			if not intermediates.has(child.uniq_key):
				print("Adding child bone " + str(child) + " into intermediates during recursive search from " + str(bone_transform))
				intermediates[child.uniq_key] = child
				intermediate_bones.push_back(child)
				# TODO: We might also want to exclude prefab instances here.
				# If something is a prefab, we should not include it in the skeleton!
				if not skel_parents.has(child.uniq_key):
					# We will not recurse: everything underneath this is part of a separate skeleton.
					add_nodes_recursively(skel_parents, child_transforms_by_stripped_id, child)

	func construct_final_bone_list(skel_parents: Dictionary, child_transforms_by_stripped_id: Dictionary):
		var par_transform: UnityObject = bone0_parent_list[-1]
		if par_transform == null:
			printerr("Final bone list transform is null!")
			return
		var par_key: String = par_transform.uniq_key
		var contains_stripped_bones: bool = false
		for bone in intermediate_bones:
			if bone.is_stripped_or_prefab_instance:
				continue
			if bone.parent_no_stripped == null or bone.parent_no_stripped.uniq_key == par_key:
				root_bones.push_back(bone)
		for bone in bones.duplicate():
			print("Skelley " + str(par_transform.uniq_key) + " has root bone " + str(bone.uniq_key))
			self.add_nodes_recursively(skel_parents, child_transforms_by_stripped_id, bone)
		# Keep original bone list in order; migrate intermediates in.
		for bone in bones:
			intermediates.erase(bone.uniq_key)
		for bone in intermediate_bones:
			if bone.is_stripped_or_prefab_instance:
				# We do not explicitly add stripped bones if they are not already present.
				# FIXME: Do cases exist in which we are required to add intermediate stripped bones?
				continue
			if intermediates.has(bone.uniq_key):
				bones.push_back(bone)
		var idx: int = 0
		for bone in bones:
			if bone.is_stripped_or_prefab_instance:
				# We do not know yet the full extent of the skeleton
				uniq_key_to_bone[bone.uniq_key] = -1
				contains_stripped_bones = true
				godot_skeleton = null
				continue
			uniq_key_to_bone[bone.uniq_key] = idx
			bone.skeleton_bone_index = idx
			idx += 1
		if not contains_stripped_bones:
			var dedupe_dict = {}.duplicate()
			for idx in range(godot_skeleton.get_bone_count()):
				dedupe_dict[godot_skeleton.get_bone_name(idx)] = null
			for bone in bones:
				if not dedupe_dict.has(bone.name):
					dedupe_dict[bone.name] = bone
			idx = 0
			for bone in bones:
				var ctr: int = 0
				var orig_bone_name: String = bone.name
				var bone_name: String = orig_bone_name
				while dedupe_dict.get(bone_name) != bone:
					ctr += 1
					bone_name = orig_bone_name + " " + str(ctr)
					if not dedupe_dict.has(bone_name):
						dedupe_dict[bone_name] = bone
				godot_skeleton.add_bone(bone_name)
				print("Adding bone " + bone_name + " idx " + str(idx) + " new size " + str(godot_skeleton.get_bone_count()))
				idx += 1
			idx = 0
			for bone in bones:
				if bone.parent_no_stripped == null:
					godot_skeleton.set_bone_parent(idx, -1)
				else:
					godot_skeleton.set_bone_parent(idx, uniq_key_to_bone.get(bone.parent_no_stripped.uniq_key, -1))
				godot_skeleton.set_bone_rest(idx, bone.godot_transform)
				idx += 1
	# Skelley rules:
	# Root bone will be added as parent to common ancestor of all bones
	# Found parent transforms of each skeleton.
	# Found a list of bones in each skeleton.


static func create_node_state(database: Resource, meta: Resource, root_node: Node3D) -> GodotNodeState:
	var state: GodotNodeState = GodotNodeState.new()
	state.init_node_state(database, meta, root_node)
	return state


class PrefabState extends Reference:
	# Prefab_instance_id -> array[UnityTransform objects]
	var child_transforms_by_stripped_id: Dictionary = {}.duplicate()
	var transforms_by_parented_prefab: Dictionary = {}.duplicate()
	#var transforms_by_parented_prefab_source_obj: Dictionary = {}.duplicate()
	var components_by_stripped_id: Dictionary = {}.duplicate()
	var gameobjects_by_parented_prefab: Dictionary = {}.duplicate()
	#var gameobjects_by_parented_prefab_source_obj: Dictionary = {}.duplicate()
	var skelleys_by_parented_prefab: Dictionary = {}.duplicate()

	# Dictionary from parent_transform uniq_key -> array of UnityPrefabInstance
	var prefab_parents: Dictionary = {}.duplicate()
	var prefab_instance_paths: Array = [].duplicate()

class GodotNodeState extends Reference:
	var owner: Node = null
	var body: CollisionObject3D = null
	var database: Resource = null # asset_database instance
	var meta: Resource = null # asset_database.AssetMeta instance

	# Closest thing Godot 4 has to a "using" statement
	class PrefabStateInner extends PrefabState:
		pass

	# Dictionary from parent_transform uniq_key -> array of convert_scene.Skelley
	var skelley_parents: Dictionary = {}.duplicate()
	# Dictionary from any transform uniq_key -> convert_scene.Skelley
	var uniq_key_to_skelley: Dictionary = {}.duplicate()

	var prefab_state: PrefabState = null
	#var root_nodepath: Nodepath = Nodepath("/")

	func duplicate():
		var state: GodotNodeState = GodotNodeState.new()
		state.owner = owner
		state.body = body
		state.database = database
		state.meta = meta
		state.skelley_parents = skelley_parents
		state.uniq_key_to_skelley = uniq_key_to_skelley
		state.prefab_state = prefab_state
		return state

	func add_child(child: Node, new_parent: Node3D, fileID: int):
		# meta. # FIXME???
		if owner != null:
			assert(new_parent != null)
			new_parent.add_child(child)
			child.owner = owner
		if new_parent == null:
			assert(owner == null)
			# We are the root (of a Prefab). Become the owner.
			self.owner = child
		else:
			assert(owner != null)
		if fileID != 0:
			add_fileID(child, fileID)

	func add_fileID_to_skeleton_bone(bone_name: String, fileID: int):
		meta.fileid_to_skeleton_bone[fileID] = bone_name

	func remove_fileID_to_skeleton_bone(fileID: int):
		meta.fileid_to_skeleton_bone[fileID] = ""

	func add_fileID(child: Node, fileID: int):
		if owner != null:
			print("Add fileID " + str(fileID) + " " + str(owner.name) + " to " + str(child.name))
			meta.fileid_to_nodepath[fileID] = owner.get_path_to(child)
		# FIXME??
		#else:
		#	meta.fileid_to_nodepath[fileID] = root_nodepath
	
	func init_node_state(database: Resource, meta: Resource, root_node: Node3D) -> GodotNodeState:
		self.database = database
		self.meta = meta
		self.owner = root_node
		self.prefab_state = PrefabStateInner.new()
		return self
	
	func state_with_body(new_body: CollisionObject3D) -> GodotNodeState:
		var state: GodotNodeState = duplicate()
		state.body = new_body
		return state

	func state_with_meta(new_meta: Resource) -> GodotNodeState:
		var state: GodotNodeState = duplicate()
		state.meta = new_meta
		return state

	func state_with_owner(new_owner: Node3D) -> GodotNodeState:
		var state: GodotNodeState = duplicate()
		state.owner = new_owner
		return state

	#func state_with_nodepath(additional_nodepath) -> GodotNodeState:
	#	var state: GodotNodeState = duplicate()
	#	state.root_nodepath = NodePath(str(root_nodepath) + str(asdditional_nodepath) + "/")
	#	return state


static func initialize_skelleys(assets: Array, node_state: GodotNodeState) -> Array:
	var skelleys: Dictionary = {}.duplicate()
	var skel_ids: Dictionary = {}.duplicate()
	var num_skels = 0

	var child_transforms_by_stripped_id: Dictionary = node_state.prefab_state.child_transforms_by_stripped_id

	# Start out with one Skeleton per SkinnedMeshRenderer, but merge overlapping skeletons.
	# This includes skeletons where the members are interleaved (S1 -> S2 -> S1 -> S2)
	# which can actually happen in practice, for example clothing with its own bones.
	for asset in assets:
		if asset.type == "SkinnedMeshRenderer":
			if asset.is_stripped:
				# FIXME: We may need to later pull out the "m_Bones" from the modified components??
				continue
			var bones: Array = asset.bones
			if bones.is_empty():
				# Common if MeshRenderer is upgraded to SkinnedMeshRenderer, e.g. by the user.
				# For example, this happens when adding a Cloth component.
				# Also common for meshes which have blend shapes but no skeleton.
				# Skinned mesh renderers without bones act as normal meshes.
				continue
			var bone0_obj: UnityTransform = asset.meta.lookup(bones[0])
			# TODO: what about meshes with bones but without skin? Can this even happen?
			var this_id: int = num_skels
			var this_skelley: Skelley = null
			if skel_ids.has(bone0_obj.uniq_key):
				this_id = skel_ids[bone0_obj.uniq_key]
				this_skelley = skelleys[this_id]
			else:
				this_skelley = Skelley.new()
				this_skelley.initialize(bone0_obj)
				this_skelley.id = this_id
				skelleys[this_id] = this_skelley
				num_skels += 1

			for bone in bones:
				var bone_obj: UnityTransform = asset.meta.lookup(bone)
				var added_bones = this_skelley.add_bone(bone_obj)
				# print("Told skelley " + str(this_id) + " to add bone " + bone_obj.uniq_key + ": " + str(added_bones))
				for added_bone in added_bones:
					var uniq_key: String = added_bone.uniq_key
					if skel_ids.get(uniq_key, this_id) != this_id:
						# We found a match! Let's merge the Skelley objects.
						var new_id: int = skel_ids[uniq_key]
						for inst in skelleys[this_id].bones:
							if skel_ids.get(inst.uniq_key, -1) == this_id: # FIXME: This seems to be missing??
								# print("Telling skelley " + str(new_id) + " to merge bone " + inst.uniq_key)
								skelleys[new_id].add_bone(inst)
						for i in skel_ids:
							if skel_ids.get(str(i)) == this_id:
								skel_ids[str(i)] = new_id
						skelleys.erase(this_id) # We merged two skeletons.
						this_id = new_id
					skel_ids[uniq_key] = this_id

	var skelleys_with_no_parent = [].duplicate()

	# If skelley_parents contains your node, add Skelley.skeleton as a child to it for each item in the list.
	for skel_id in skelleys:
		var skelley: Skelley = skelleys[skel_id]
		var par_transform: UnityObject = skelley.parent_transform ### UnityTransform = skelley.parent_transform
		var i = 0
		for bone in skelley.bones:
			i = i + 1
			if bone == par_transform:
				par_transform = par_transform.parent_no_stripped
				skelley.bone0_parent_list.pop_back()
		if skelley.parent_transform == null:
			if skelley.parent_prefab == null:
				skelleys_with_no_parent.push_back(skelley)
			else:
				var uk: String = skelley.parent_prefab.uniq_key
				if not node_state.prefab_state.skelleys_by_parented_prefab.has(uk):
					node_state.prefab_state.skelleys_by_parented_prefab[uk] = [].duplicate()
				node_state.prefab_state.skelleys_by_parented_prefab[uk].push_back(skelley)
		else:
			var uniq_key = skelley.parent_transform.uniq_key
			if not node_state.skelley_parents.has(uniq_key):
				node_state.skelley_parents[uniq_key] = [].duplicate()
			node_state.skelley_parents[uniq_key].push_back(skelley)

	for skel_id in skelleys:
		var skelley: Skelley = skelleys[skel_id]
		skelley.construct_final_bone_list(node_state.skelley_parents, child_transforms_by_stripped_id)
		for uniq_key in skelley.uniq_key_to_bone:
			node_state.uniq_key_to_skelley[uniq_key] = skelley

	return skelleys_with_no_parent


# Unity types follow:
### ================ BASE OBJECT TYPE ================
class UnityObject extends Reference:
	var meta: Resource = null # AssetMeta instance
	var keys: Dictionary = {}
	var fileID: int = 0 # Not set in .meta files
	var type: String = ""
	var utype: int = 0 # Not set in .meta files
	var _cache_uniq_key: String = ""

	# Some components or game objects within a prefab are "stripped" dummy objects.
	# Setting the stripped flag is not required...
	# and properties of prefabbed objects seem to have no effect anyway.
	var is_stripped: bool = false

	var is_stripped_or_prefab_instance: bool:
		get:
			return is_stripped

	var uniq_key: String:
		get:
			if _cache_uniq_key.is_empty():
				_cache_uniq_key = str(utype)+":"+str(keys.get("m_Name",""))+":"+str(meta.guid) + ":" + str(fileID)
			return _cache_uniq_key

	func _to_string() -> String:
		#return "[" + str(type) + " @" + str(fileID) + ": " + str(len(keys)) + "]" # str(keys) + "]"
		#return "[" + str(type) + " @" + str(fileID) + ": " + JSON.print(keys) + "]"
		return "[" + str(type) + " " + uniq_key + "]"

	var name: String:
		get:
			return keys.get("m_Name","NO_NAME:"+uniq_key)

	var toplevel: bool:
		get:
			return true

	var is_collider: bool:
		get:
			return false

	var transform: Object:
		get:
			return null

	var gameObject: UnityGameObject:
		get:
			return null

	# Belongs in UnityComponent, but we haven't implemented all types yet.
	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		var new_node: Node = Node.new()
		new_node.name = type
		state.add_child(new_node, new_parent, fileID)
		return new_node

	func get_extra_resources() -> Dictionary:
		return {}

	func create_extra_resource(fileID: int) -> Resource:
		return null

	func create_godot_resource() -> Resource:
		return null

	func get_godot_extension() -> String:
		return ".res"

	# Prefab source properties: Component and GameObject sub-types only:
	# UNITY 2018+:
	#  m_CorrespondingSourceObject: {fileID: 100176, guid: ca6da198c98777940835205234d6323d, type: 3}
	#  m_PrefabInstance: {fileID: 2493014228082835901}
	#  m_PrefabAsset: {fileID: 0}
	# (m_PrefabAsset is always(?) 0 no matter what. I guess we can ignore it?

	# UNITY 2017-:
	#  m_PrefabParentObject: {fileID: 4504365477183010, guid: 52b062a91263c0844b7557d84ca92dbd, type: 2}
	#  m_PrefabInternal: {fileID: 15226381}
	var prefab_source_object: Array:
		get:
			# new: m_CorrespondingSourceObject; old: m_PrefabParentObject
			return keys.get("m_CorrespondingSourceObject", keys.get("m_PrefabParentObject", [null, 0, "", 0]))

	var prefab_instance: Array:
		get:
			# new: m_PrefabInstance; old: m_PrefabInternal
			return keys.get("m_PrefabInstance", keys.get("m_PrefabInternal", [null, 0, "", 0]))
	
	var is_prefab_reference: bool:
		get:
			if not is_stripped:
				assert (prefab_source_object[1] == 0 or prefab_instance[1] == 0)
			else:
				# Might have source object=0 if the object is a dummy / broken prefab?
				pass # assert (prefab_source_object[1] != 0 and prefab_instance[1] != 0)
			return (prefab_source_object[1] != 0 and prefab_instance[1] != 0)


### ================ ASSET TYPES ================
# FIXME: All of these are native Godot types. I'm not sure if these types are needed or warranted.
class UnityMesh extends UnityObject:
	const FLIP_X: Transform = Transform.FLIP_X # Transform(-1,0,0,0,1,0,0,0,1,0,0,0)
	
	func get_primitive_format(submesh: Dictionary) -> int:
		match submesh.get("topology", 0):
			0:
				return Mesh.PRIMITIVE_TRIANGLES
			1:
				return Mesh.PRIMITIVE_TRIANGLES # quad meshes handled specially later
			2:
				return Mesh.PRIMITIVE_LINES
			3:
				return Mesh.PRIMITIVE_LINE_STRIP
			4:
				return Mesh.PRIMITIVE_POINTS
			_:
				printerr(str(self) + ": Unknown primitive format " + str(submesh.get("topology", 0)))
		return Mesh.PRIMITIVE_TRIANGLES

	func get_extra_resources() -> Dictionary:
		if binds.is_empty():
			return {}
		return {-meta.main_object_id: ".mesh.skin.tres"}

	func dict_to_matrix(b: Dictionary) -> Transform:
		return FLIP_X.affine_inverse() * Transform(
			Vector3(b.get("e00"), b.get("e10"), b.get("e20")),
			Vector3(b.get("e01"), b.get("e11"), b.get("e21")),
			Vector3(b.get("e02"), b.get("e12"), b.get("e22")),
			Vector3(b.get("e03"), b.get("e13"), b.get("e23")),
		) * FLIP_X

	func create_extra_resource(fileID: int) -> Skin:
		var sk: Skin = Skin.new()
		var idx: int = 0
		for b in binds:
			sk.add_bind(idx, dict_to_matrix(b))
			idx += 1
		return sk

	func create_godot_resource() -> ArrayMesh:
		var vertex_buf: Reference = get_vertex_data()
		var index_buf: Reference = get_index_data()
		var vertex_layout: Dictionary = vertex_layout_info
		var channel_info_array: Array = vertex_layout.get("m_Channels", [])
		# https://docs.unity3d.com/2019.4/Documentation/ScriptReference/Rendering.VertexAttribute.html
		var unity_to_godot_mesh_channels: Array = [ArrayMesh.ARRAY_VERTEX, ArrayMesh.ARRAY_NORMAL, ArrayMesh.ARRAY_TANGENT, ArrayMesh.ARRAY_COLOR, ArrayMesh.ARRAY_TEX_UV, ArrayMesh.ARRAY_TEX_UV2, ArrayMesh.ARRAY_CUSTOM0, ArrayMesh.ARRAY_CUSTOM1, ArrayMesh.ARRAY_CUSTOM2, ArrayMesh.ARRAY_CUSTOM3, -1, -1, ArrayMesh.ARRAY_WEIGHTS, ArrayMesh.ARRAY_BONES]
		# Old vertex layout is probably stable since Unity 5.0
		if vertex_layout.get("serializedVersion", 1) < 2:
			# Old layout seems to have COLOR at the end.
			unity_to_godot_mesh_channels = [ArrayMesh.ARRAY_VERTEX, ArrayMesh.ARRAY_NORMAL, ArrayMesh.ARRAY_TANGENT, ArrayMesh.ARRAY_TEX_UV, ArrayMesh.ARRAY_TEX_UV2, ArrayMesh.ARRAY_CUSTOM0, ArrayMesh.ARRAY_CUSTOM1, ArrayMesh.ARRAY_COLOR]

		var tmp: Array = self.pre2018_skin
		var pre2018_weights_buf: PackedFloat32Array = tmp[0]
		var pre2018_bones_buf: PackedInt32Array = tmp[1]
		var surf_idx: int = 0
		var idx_format: int = keys.get("m_IndexFormat", 0)
		var arr_mesh = ArrayMesh.new()
		var stream_strides: Array = [0, 0, 0, 0]
		var stream_offsets: Array = [0, 0, 0, 0]
		if len(unity_to_godot_mesh_channels) != len(channel_info_array):
			printerr("Unity has the wrong number of vertex channels: " + str(len(unity_to_godot_mesh_channels)) + " vs " + str(len(channel_info_array)))

		for array_idx in range(len(unity_to_godot_mesh_channels)):
			var channel_info: Dictionary = channel_info_array[array_idx]
			stream_strides[channel_info.get("stream", 0)] += channel_info.get("dimension", 4) * aligned_byte_buffer.format_byte_width(channel_info.get("format", 0))
		for s in range(1, 4):
			stream_offsets[s] = stream_offsets[s - 1] + stream_strides[s - 1]

		for submesh in submeshes:
			var surface_arrays: Array = []
			surface_arrays.resize(ArrayMesh.ARRAY_MAX)
			var surface_index_buf: PackedInt32Array
			if idx_format == 0:
				surface_index_buf = index_buf.uint16_subarray(submesh.get("firstByte",0), submesh.get("indexCount",-1))
			else:
				surface_index_buf = index_buf.uint32_subarray(submesh.get("firstByte",0), submesh.get("indexCount",-1))
			if submesh.get("topology", 0) == 1:
				# convert quad mesh to tris
				var new_buf: PackedInt32Array = PackedInt32Array()
				new_buf.resize(len(surface_index_buf) / 4 * 6)
				var quad_idx = [0, 1, 2, 2, 1, 3]
				for i in range(len(surface_index_buf) / 4):
					for el in range(6):
						new_buf[i * 6 + el] = surface_index_buf[i * 4 + quad_idx[el]]
				surface_index_buf = new_buf
			var deltaVertex: int = submesh.get("firstVertex", 0)
			var baseFirstVertex: int = submesh.get("baseVertex", 0) + deltaVertex
			var vertexCount: int = submesh.get("vertexCount", 0)
			print("baseFirstVertex "+ str(baseFirstVertex)+ " baseVertex "+ str(submesh.get("baseVertex", 0)) + " deltaVertex " + str(deltaVertex) + " index0 " + str(surface_index_buf[0]))
			if deltaVertex != 0:
				for i in range(len(surface_index_buf)):
					surface_index_buf[i] -= deltaVertex
			if not pre2018_weights_buf.is_empty():
				surface_arrays[ArrayMesh.ARRAY_WEIGHTS] = pre2018_weights_buf.subarray(baseFirstVertex * 4, (vertexCount + baseFirstVertex) * 4 - 1) # INCLUSIVE!!!
				surface_arrays[ArrayMesh.ARRAY_BONES] = pre2018_bones_buf.subarray(baseFirstVertex * 4, (vertexCount + baseFirstVertex) * 4 - 1) # INCLUSIVE!!!
			var compress_flags: int = 0
			for array_idx in range(len(unity_to_godot_mesh_channels)):
				var godot_array_type = unity_to_godot_mesh_channels[array_idx]
				if godot_array_type == -1:
					continue
				var channel_info: Dictionary = channel_info_array[array_idx]
				var stream: int = channel_info.get("stream", 0)
				var offset: int = channel_info.get("offset", 0) + stream_offsets[stream] + baseFirstVertex * stream_strides[stream]
				var format: int = channel_info.get("format", 0)
				var dimension: int = channel_info.get("dimension", 4)
				if dimension <= 0:
					continue
				match godot_array_type:
					ArrayMesh.ARRAY_BONES:
						if dimension == 8:
							compress_flags |= ArrayMesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
						print("Do bones int")
						surface_arrays[godot_array_type] = vertex_buf.formatted_int_subarray(format, offset, dimension * vertexCount, stream_strides[stream], dimension)
					ArrayMesh.ARRAY_WEIGHTS:
						print("Do weights int")
						surface_arrays[godot_array_type] = vertex_buf.formatted_float_subarray(format, offset, dimension * vertexCount, stream_strides[stream], dimension)
					ArrayMesh.ARRAY_VERTEX, ArrayMesh.ARRAY_NORMAL:
						print("Do vertex or normal vec3 " + str(godot_array_type) + " " + str(format))
						surface_arrays[godot_array_type] = vertex_buf.formatted_vector3_subarray(Vector3(-1,1,1), format, offset, vertexCount, stream_strides[stream], dimension)
					ArrayMesh.ARRAY_TANGENT:
						print("Do tangent float " + str(godot_array_type) + " " + str(format))
						surface_arrays[godot_array_type] = vertex_buf.formatted_tangent_subarray(format, offset, vertexCount, stream_strides[stream], dimension)
					ArrayMesh.ARRAY_COLOR:
						print("Do color " + str(godot_array_type) + " " + str(format))
						surface_arrays[godot_array_type] = vertex_buf.formatted_color_subarray(format, offset, vertexCount, stream_strides[stream], dimension)
					ArrayMesh.ARRAY_TEX_UV, ArrayMesh.ARRAY_TEX_UV2:
						print("Do uv " + str(godot_array_type) + " " + str(format))
						surface_arrays[godot_array_type] = vertex_buf.formatted_vector2_subarray(format, offset, vertexCount, stream_strides[stream], dimension)
					ArrayMesh.ARRAY_CUSTOM0, ArrayMesh.ARRAY_CUSTOM1, ArrayMesh.ARRAY_CUSTOM2, ArrayMesh.ARRAY_CUSTOM3:
						pass # Custom channels are currently broken in Godot master:
					ArrayMesh.ARRAY_MAX: # ARRAY_MAX is a placeholder to disable this
						print("Do custom " + str(godot_array_type) + " " + str(format))
						var custom_shift = (ArrayMesh.ARRAY_FORMAT_CUSTOM1_SHIFT - ArrayMesh.ARRAY_FORMAT_CUSTOM0_SHIFT) * (godot_array_type - ArrayMesh.ARRAY_CUSTOM0) + ArrayMesh.ARRAY_FORMAT_CUSTOM0_SHIFT
						if format == aligned_byte_buffer.FORMAT_UNORM8 or format == aligned_byte_buffer.FORMAT_SNORM8:
							# assert(dimension == 4) # Unity docs says always word aligned, so I think this means it is guaranteed to be 4.
							surface_arrays[godot_array_type] = vertex_buf.formatted_uint8_subarray(format, offset, 4 * vertexCount, stream_strides[stream], 4)
							compress_flags |= (ArrayMesh.ARRAY_CUSTOM_RGBA8_UNORM if format == aligned_byte_buffer.FORMAT_UNORM8 else ArrayMesh.ARRAY_CUSTOM_RGBA8_SNORM) << custom_shift
						elif format == aligned_byte_buffer.FORMAT_FLOAT16:
							assert(dimension == 2 or dimension == 4) # Unity docs says always word aligned, so I think this means it is guaranteed to be 2 or 4.
							surface_arrays[godot_array_type] = vertex_buf.formatted_uint8_subarray(format, offset, dimension * vertexCount * 2, stream_strides[stream], dimension * 2)
							compress_flags |= (ArrayMesh.ARRAY_CUSTOM_RG_HALF if dimension == 2 else ArrayMesh.ARRAY_CUSTOM_RGBA_HALF) << custom_shift
							# We could try to convert SNORM16 and UNORM16 to float16 but that sounds confusing and complicated.
						else:
							assert(dimension <= 4)
							surface_arrays[godot_array_type] = vertex_buf.formatted_float_subarray(format, offset, dimension * vertexCount, stream_strides[stream], dimension)
							compress_flags |= (ArrayMesh.ARRAY_CUSTOM_R_FLOAT + (dimension - 1)) << custom_shift
			#firstVertex: 1302
			#vertexCount: 38371
			surface_arrays[ArrayMesh.ARRAY_INDEX] = surface_index_buf
			var primitive_format: int = get_primitive_format(submesh)
			#var f= File.new()
			#f.open("temp.temp", File.WRITE)
			#f.store_string(str(surface_arrays))
			#f.close()
			for i in range(ArrayMesh.ARRAY_MAX):
				print("Array " + str(i) + ": length=" + (str(len(surface_arrays[i])) if typeof(surface_arrays[i]) != TYPE_NIL else "NULL"))
			print("here are some flags " + str(compress_flags))
			arr_mesh.add_surface_from_arrays(primitive_format, surface_arrays, [], {}, compress_flags)
		# arr_mesh.set_custom_aabb(local_aabb)
		arr_mesh.resource_name = self.name
		return arr_mesh

	var local_aabb: AABB:
		get:
			return AABB(keys.get("m_LocalAABB", {}).get("m_Center") * Vector3(-1,1,1), keys.get("m_LocalAABB", {}).get("m_Extent"))

	var pre2018_skin: Array:
		get:
			var skin_vertices = keys.get("m_Skin", [])
			var ret = [PackedFloat32Array(), PackedInt32Array()]
			# FIXME: Godot bug with F32Array. ret[0].resize(len(skin_vertices) * 4)
			ret[1].resize(len(skin_vertices) * 4)
			var i = 0
			for vert in skin_vertices:
				ret[0].push_back(vert.get("weight[0]"))
				ret[0].push_back(vert.get("weight[1]"))
				ret[0].push_back(vert.get("weight[2]"))
				ret[0].push_back(vert.get("weight[3]"))
				#ret[0][i] = vert.get("weight[0]")
				#ret[0][i + 1] = vert.get("weight[1]")
				#ret[0][i + 2] = vert.get("weight[2]")
				#ret[0][i + 3] = vert.get("weight[3]")
				ret[1][i] = vert.get("boneIndex[0]")
				ret[1][i + 1] = vert.get("boneIndex[1]")
				ret[1][i + 2] = vert.get("boneIndex[2]")
				ret[1][i + 3] = vert.get("boneIndex[3]")
				i += 4
			return ret

	var submeshes: Array:
		get:
			return keys.get("m_SubMeshes", [])

	var binds: Array:
		get:
			return keys.get("m_BindPose", [])

	var vertex_layout_info: Dictionary:
		get:
			return keys.get("m_VertexData", {})

	func get_godot_extension() -> String:
		return ".mesh.res"

	func get_vertex_data() -> Reference:
		return aligned_byte_buffer.new_with_hex(keys.get("m_VertexData", {}).get("_typelessdata", ""))

	func get_index_data() -> Reference:
		return aligned_byte_buffer.new_with_hex(keys.get("m_IndexBuffer", ""))

class UnityMaterial extends UnityObject:

	func get_float_properties() -> Dictionary:
		var flts = keys.get("m_SavedProperties", {}).get("m_Floats", [])
		var ret = {}.duplicate()
		for dic in flts:
			for key in dic:
				ret[key] = dic.get(key)
		return ret

	func get_color_properties() -> Dictionary:
		var cols = keys.get("m_SavedProperties", {}).get("m_Colors", [])
		var ret = {}.duplicate()
		for dic in cols:
			for key in dic:
				ret[key] = dic.get(key)
		return ret

	func get_tex_properties() -> Dictionary:
		var texs = keys.get("m_SavedProperties", {}).get("m_TexEnvs", [])
		var ret = {}.duplicate()
		for dic in texs:
			for key in dic:
				ret[key] = dic.get(key)
		return ret

	func get_texture(texProperties: Dictionary, name: String) -> Texture:
		var env = texProperties.get(name, {})
		var texref: Array = env.get("m_Texture", [])
		if not texref.is_empty():
			return meta.get_godot_resource(texref)
		return null

	func get_texture_scale(texProperties: Dictionary, name: String) -> Vector3:
		var env = texProperties.get(name, {})
		var scale: Vector2 = env.get("m_Scale", Vector2(1,1))
		return Vector3(scale.x, scale.y, 0.0)

	func get_texture_offset(texProperties: Dictionary, name: String) -> Vector3:
		var env = texProperties.get(name, {})
		var offset: Vector2 = env.get("m_Offset", Vector2(0,0))
		return Vector3(offset.x, offset.y, 0.0)

	func get_color(colorProperties: Dictionary, name: String, dfl: Color) -> Color:
		var col: Color = colorProperties.get(name, dfl)
		return col

	func get_float(floatProperties: Dictionary, name: String, dfl: float) -> float:
		var ret: float = floatProperties.get(name, dfl)
		return ret

	func get_vector(colorProperties: Dictionary, name: String, dfl: Color) -> Plane:
		var col: Color = colorProperties.get(name, dfl)
		return Plane(Vector3(col.r, col.g, col.b), col.a)

	func get_keywords() -> Dictionary:
		var ret: Dictionary = {}.duplicate()
		var kwd = keys.get("m_ShaderKeywords", "")
		if typeof(kwd) == TYPE_STRING:
			for x in kwd.split(' '):
				ret[x] = true
		return ret

	func create_godot_resource() -> Material:
		var kws = get_keywords()
		var floatProperties = get_float_properties()
		#print(str(floatProperties))
		var texProperties = get_tex_properties()
		#print(str(texProperties))
		var colorProperties = get_color_properties()
		#print(str(colorProperties))
		var ret = StandardMaterial3D.new()
		ret.resource_name = self.name
		# FIXME: Kinda hacky since transparent stuff doesn't always draw depth in Unity
		# But it seems to workaround a problem with some materials for now.
		ret.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		ret.albedo_tex_force_srgb = true # Nothing works if this isn't set to true explicitly. Stupid default.
		ret.albedo_color = get_color(colorProperties, "_Color", Color.white)
		ret.albedo_texture = get_texture(texProperties, "_MainTex2") ### ONLY USED IN ONE SHADER. This case should be removed.
		if ret.albedo_texture == null:
			ret.albedo_texture = get_texture(texProperties, "_MainTex")
		if ret.albedo_texture == null:
			ret.albedo_texture = get_texture(texProperties, "_Tex")
		if ret.albedo_texture == null:
			ret.albedo_texture = get_texture(texProperties, "_Albedo")
		if ret.albedo_texture == null:
			ret.albedo_texture = get_texture(texProperties, "_Diffuse")
		ret.uv1_scale = get_texture_scale(texProperties, "_MainTex")
		ret.uv1_offset = get_texture_offset(texProperties, "_MainTex")
		# TODO: ORM not yet implemented.
		if kws.get("_NORMALMAP", false):
			ret.normal_enabled = true
			ret.normal_texture = get_texture(texProperties, "_BumpMap")
			ret.normal_scale = get_float(floatProperties, "_BumpScale", 1.0)
		if kws.get("_EMISSION", false):
			ret.emission_enabled = true
			var emis_vec: Plane = get_vector(colorProperties, "_EmissionColor", Color.black)
			var emis_mag = max(emis_vec.x, max(emis_vec.y, emis_vec.z))
			ret.emission = Color.black
			if emis_mag > 0:
				ret.emission = Color(emis_vec.x/emis_mag, emis_vec.y/emis_mag, emis_vec.z/emis_mag)
				ret.emission_energy = emis_mag
			ret.emission_texture = get_texture(texProperties, "_EmissionMap")
		if kws.get("_PARALLAXMAP", false):
			ret.heightmap_enabled = true
			ret.heightmap_texture = get_texture(texProperties, "_ParallaxMap")
			ret.heightmap_scale = get_float(floatProperties, "_Parallax", 1.0)
		if kws.get("__SPECULARHIGHLIGHTS_OFF", false):
			ret.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		if kws.get("_GLOSSYREFLECTIONS_OFF", false):
			pass
		var occlusion = get_texture(texProperties, "_OcclusionMap")
		if occlusion != null:
			ret.ao_enabled = true
			ret.ao_texture = occlusion
			ret.ao_light_affect = get_float(floatProperties, "_OcclusionStrength", 1.0) # why godot defaults to 0???
			ret.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		if kws.get("_METALLICGLOSSMAP"):
			ret.metallic_texture = get_texture(texProperties, "_MetallicGlossMap")
			ret.metallic = get_float(floatProperties, "_Metallic", 0.0)
			ret.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		# TODO: Glossiness: invert color channels??
		ret.roughness = 1.0 - get_float(floatProperties, "_Glossiness", 0.0)
		if kws.get("_ALPHATEST_ON"):
			ret.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		elif kws.get("_ALPHABLEND_ON") or kws.get("_ALPHAPREMULTIPLY_ON"):
			# FIXME: No premultiply
			ret.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Godot's detail map is a bit lacking right now...
		#if kws.get("_DETAIL_MULX2"):
		#	ret.detail_enabled = true
		#	ret.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		return ret

	func get_godot_extension() -> String:
		return ".mat.tres"

class UnityShader extends UnityObject:
	pass

class UnityTexture extends UnityObject:
	pass

class UnityAnimationClip extends UnityObject:

	func get_godot_extension() -> String:
		return ".anim.tres"

class UnityTexture2D extends UnityTexture:
	pass

class UnityTexture2DArray extends UnityTexture:
	pass

class UnityTexture3D extends UnityTexture:
	pass

class UnityCubemap extends UnityTexture:
	pass

class UnityCubemapArray extends UnityTexture:
	pass

class UnityRenderTexture extends UnityTexture:
	pass

class UnityCustomRenderTexture extends UnityRenderTexture:
	pass


class UnityPrefabInstance extends UnityObject:

	# When you see a PrefabInstance, load() the scene.
	# If it is_prefab_reference but not the root, log an error.

	# For all Transform in scene, find transforms whose parent has is_prefab_reference=true. These subtrees must be mapped from PrefabInstance.

	# TODO: Create map from corresponding source object id (stripped id, PrefabInstanceId^target object id) and do so recursively, to target path...

	# For all PrefabInstance in scene, make map from m_TransformParent 
	# Note also: a PrefabInstance with m_TransformParent=0 in a prefab defines a "Prefab Variant". In Godot terms, this is an "inhereted" or instanced scene.
	# COMPLICATED!!!

	# Rules about skeletons: If any skinned mesh has bones, which are part of a prefab instance, mark all bones as belonging to that prefab instance (no consideration is made as to whether they link two separate skeletons together.)
	# Then, repeat one more time and makwe sure no overlap
	# all transforms are marked as parented to the prefab.

	# Generally, all transforms which are sub-objects of a prefab will be marked as such ("Create map from corresponding source object id (stripped id, PrefabInstanceId^target object id) and do so recursively, to target path...")
	func create_godot_node(xstate: GodotNodeState, new_parent: Node3D) -> Node3D:
		meta.prefab_id_to_guid[self.fileID] = self.source_prefab[2] # UnityRef[2] is guid
		var state: Object = xstate
		var target_prefab_meta = meta.lookup_meta(source_prefab)
		if target_prefab_meta == null or target_prefab_meta.guid == self.meta.guid:
			printerr("Unable to load prefab dependency " + str(source_prefab) + " from " + str(self.meta.guid))
			return null
		var packed_scene: PackedScene = target_prefab_meta.get_godot_resource(source_prefab)
		if packed_scene == null:
			printerr("Failed to instantiate prefab with guid " + uniq_key + " from " + str(self.meta.guid))
			return null
		print("Instancing PackedScene at " + str(packed_scene.resource_path) + ": " + str(packed_scene.resource_name))
		var instanced_scene: Node3D = null
		if new_parent == null:
			# FIXME: This may be unstable across Godot versions, if .tscn format ever changes.
			# node->set_scene_inherited_state(sdata->get_state()) is not exposed to GDScript. Let's HACK!!!
			var stub_filename = "res://_temp_scene.tscn"
			var fres = File.new()
			fres.open(stub_filename, File.WRITE)
			print("Writing stub scene to " + stub_filename)
			var to_write: String = ('[gd_scene load_steps=2 format=2]\n\n' +
				'[ext_resource path="' + str(packed_scene.resource_path) + '" type="PackedScene" id=1]\n\n' +
				'[node name="" instance=ExtResource( 1 )]\n')
			fres.store_string(to_write)
			print(to_write)
			fres.close()
			var temp_packed_scene: PackedScene = ResourceLoader.load(stub_filename, "", ResourceLoader.CACHE_MODE_IGNORE)
			instanced_scene = temp_packed_scene.instance(PackedScene.GEN_EDIT_STATE_INSTANCE)
		else:
			instanced_scene = packed_scene.instance(PackedScene.GEN_EDIT_STATE_INSTANCE)
			instanced_scene.filename = packed_scene.resource_path
		state.add_child(instanced_scene, new_parent, fileID)
		print("Prefab " + str(packed_scene.resource_path) + " ------------")
		print(str(target_prefab_meta.fileid_to_nodepath))
		print(str(target_prefab_meta.prefab_fileid_to_nodepath))
		print(str(target_prefab_meta.fileid_to_skeleton_bone))
		print(str(target_prefab_meta.prefab_fileid_to_skeleton_bone))
		print(" ------------")
		var ps: PrefabState = state.prefab_state
		if new_parent != null:
			ps.prefab_instance_paths.push_back(state.owner.get_path_to(instanced_scene))

		var fileid_to_added_bone: Dictionary = {}.duplicate()
		var fileid_to_skeleton_nodepath: Dictionary = {}.duplicate()
		var fileid_to_bone_name: Dictionary = {}.duplicate()

		for skelley in ps.skelleys_by_parented_prefab.get(self.uniq_key, []):
			var godot_skeleton_nodepath = NodePath()
			for bone in skelley.bones: # skelley.root_bones:
				if not bone.is_prefab_reference:
					# We are iterating through bones array because root_bones was not reliable.
					# So we will hit both types of bones. Let's just ignore non-prefab bones for now.
					# FIXME: Should we try to fix the root_bone logic so we can detect bad Skeletons?
					# printerr("Skeleton parented to prefab contains root bone not rooted within prefab.")
					continue
				var source_obj_ref = bone.prefab_source_object
				var target_skelley: NodePath = target_prefab_meta.fileid_to_nodepath.get(source_obj_ref[1],
						target_prefab_meta.prefab_fileid_to_nodepath.get(source_obj_ref[1], NodePath()))
				var target_skel_bone: String = target_prefab_meta.fileid_to_skeleton_bone.get(source_obj_ref[1],
					target_prefab_meta.prefab_fileid_to_skeleton_bone.get(source_obj_ref[1], ""))
				# print("Parented prefab root bone : " + str(bone.uniq_key) + " for " + str(target_skelley) + ":" + str(target_skel_bone))
				if godot_skeleton_nodepath == NodePath() and target_skelley != NodePath():
					godot_skeleton_nodepath = target_skelley
					skelley.godot_skeleton = instanced_scene.get_node(godot_skeleton_nodepath)
				if target_skelley != godot_skeleton_nodepath:
					printerr("Skeleton child of prefab spans multiple Skeleton objects in source prefab.")
				fileid_to_skeleton_nodepath[bone.fileID] = target_skelley
				fileid_to_bone_name[bone.fileID] = target_skel_bone
				bone.skeleton_bone_index = skelley.godot_skeleton.find_bone(target_skel_bone)
				# if fileid_to_skeleton_nodepath.has(source_obj_ref[1]):
				# 	if fileid_to_skeleton_nodepath.get(source_obj_ref[1]) != target_skelley:
				# 		printerr("Skeleton spans multiple ")
				# WE ARE NOT REQUIRED TO create a new skelley object for each Skeleton3D instance in the inflated scene.
				# NO! THIS IS STUPID Then, the skelley objects with parent=scene should be dissolved and replaced with extended versions of the prefab's skelley
				# For every skelley in this prefab, go find the corresponding Skeleton3D object and add the missing nodes. that's it.
				# Then, we should make sure we create the bone attachments for all grand/great children too.
				# FINALLY! We did all this. now let's add the skins and proper bone index arrays into the skins!
			# Add all the bones
			var dedupe_dict = {}.duplicate()
			for idx in range(skelley.godot_skeleton.get_bone_count()):
				dedupe_dict[skelley.godot_skeleton.get_bone_name(idx)] = null
			for bone in skelley.bones:
				if bone.is_prefab_reference:
					continue
				if fileid_to_bone_name.has(bone.fileID):
					continue
				if not dedupe_dict.has(bone.name):
					dedupe_dict[bone.name] = bone
			for bone in skelley.bones:
				if bone.is_prefab_reference:
					continue
				if fileid_to_bone_name.has(bone.fileID):
					continue
				var new_idx: int = skelley.godot_skeleton.get_bone_count()
				var ctr: int = 0
				var orig_bone_name: String = bone.name
				var bone_name: String = orig_bone_name
				while dedupe_dict.get(bone_name) != bone:
					ctr += 1
					bone_name = orig_bone_name + " " + str(ctr)
					if not dedupe_dict.has(bone_name):
						dedupe_dict[bone_name] = bone
				skelley.godot_skeleton.add_bone(bone_name)
				print("Prefab adding bone " + bone.name + " idx " + str(new_idx) + " new size " + str(skelley.godot_skeleton.get_bone_count()))
				fileid_to_bone_name[bone.fileID] = skelley.godot_skeleton.get_bone_name(new_idx)
				bone.skeleton_bone_index = new_idx
			# Now set up the indices and parents.
			for bone in skelley.bones:
				if bone.is_prefab_reference:
					continue
				if fileid_to_skeleton_nodepath.has(bone.fileID):
					continue
				var idx: int = skelley.godot_skeleton.find_bone(fileid_to_bone_name.get(bone.fileID, ""))
				var parent_bone_index: int = skelley.godot_skeleton.find_bone(fileid_to_bone_name.get(bone.parent.fileID, ""))
				skelley.godot_skeleton.set_bone_parent(idx, parent_bone_index)
				skelley.godot_skeleton.set_bone_rest(idx, bone.godot_transform)
				fileid_to_skeleton_nodepath[bone.fileID] = godot_skeleton_nodepath

		var nodepath_bone_to_stripped_gameobject: Dictionary = {}.duplicate()
		var gameobject_fileid_to_attachment: Dictionary = {}.duplicate()
		var gameobject_fileid_to_body: Dictionary = {}.duplicate()
		var orig_state_body: CollisionObject3D = state.body
		for gameobject_asset in ps.gameobjects_by_parented_prefab.get(fileID, {}).values():
			# NOTE: transform_asset may be a GameObject, in case it was referenced by a Component.
			var par: UnityGameObject = gameobject_asset
			var source_obj_ref = par.prefab_source_object
			print("Checking stripped GameObject " + str(par.uniq_key) + ": " + str(source_obj_ref) + " is it " + target_prefab_meta.guid)
			assert(target_prefab_meta.guid == source_obj_ref[2])
			var target_nodepath: NodePath = target_prefab_meta.fileid_to_nodepath.get(source_obj_ref[1],
					target_prefab_meta.prefab_fileid_to_nodepath.get(source_obj_ref[1], NodePath()))
			var target_skel_bone: String = target_prefab_meta.fileid_to_skeleton_bone.get(source_obj_ref[1],
					target_prefab_meta.prefab_fileid_to_skeleton_bone.get(source_obj_ref[1], ""))
			nodepath_bone_to_stripped_gameobject[str(target_nodepath) + "/" + str(target_skel_bone)] = gameobject_asset
			print("Get target node " + str(target_nodepath) + " bone " + str(target_skel_bone) + " from " + str(instanced_scene.filename))
			var target_parent_obj = instanced_scene.get_node(target_nodepath)
			var attachment: Node3D = target_parent_obj
			if (attachment == null):
				printerr("Unable to find node " + str(target_nodepath) + " on scene " + str(packed_scene.resource_path))
				continue
			print("Found gameobject: " + str(target_parent_obj.name))
			if target_skel_bone != "" or target_parent_obj is BoneAttachment3D:
				var godot_skeleton: Node3D = target_parent_obj
				if target_parent_obj is BoneAttachment3D:
					attachment = target_parent_obj
					godot_skeleton = target_parent_obj.get_parent()
				for comp in ps.components_by_stripped_id.get(gameobject_asset.fileID, []):
					if comp.type == "Rigidbody":
						var physattach: PhysicalBone3D = self.rigidbody.create_physical_bone(state, godot_skeleton, target_skel_bone)
						state.body = physattach
						attachment = physattach
						state.add_fileID(attachment, gameobject_asset.fileID)
						gameobject_fileid_to_attachment[gameobject_asset.fileID] = attachment
						#state.fileid_to_nodepath[transform_asset.fileID] = gameobject_asset.fileID
				if attachment == null:
					# Will not include the Transform.
					if len(ps.components_by_stripped_id.get(gameobject_asset.fileID, [])) >= 1:
						attachment = BoneAttachment3D.new()
						attachment.name = target_skel_bone # target_parent_obj.name if not stripped??
						attachment.bone_name = target_skel_bone
						state.add_child(attachment, godot_skeleton, gameobject_asset.fileID)
						gameobject_fileid_to_attachment[gameobject_asset.fileID] = attachment
			for component in ps.components_by_stripped_id.get(gameobject_asset.fileID, []):
				component.create_godot_node(state, attachment)
			gameobject_fileid_to_body[gameobject_asset.fileID] = state.body
			state.body = orig_state_body
					
		for transform_asset in ps.transforms_by_parented_prefab.get(fileID, {}).values():
			# NOTE: transform_asset may be a GameObject, in case it was referenced by a Component.
			var par: UnityTransform = transform_asset
			var source_obj_ref = par.prefab_source_object
			print("Checking stripped Transform " + str(par.uniq_key) + ": " + str(source_obj_ref) + " is it " + target_prefab_meta.guid)
			assert(target_prefab_meta.guid == source_obj_ref[2])
			var target_nodepath: NodePath = target_prefab_meta.fileid_to_nodepath.get(source_obj_ref[1],
					target_prefab_meta.prefab_fileid_to_nodepath.get(source_obj_ref[1], NodePath()))
			var target_skel_bone: String = target_prefab_meta.fileid_to_skeleton_bone.get(source_obj_ref[1],
					target_prefab_meta.prefab_fileid_to_skeleton_bone.get(source_obj_ref[1], ""))
			var gameobject_asset: UnityGameObject = nodepath_bone_to_stripped_gameobject.get(str(target_nodepath) + "/" + str(target_skel_bone), null)
			print("Get target node " + str(target_nodepath) + " bone " + str(target_skel_bone) + " from " + str(instanced_scene.filename))
			var target_parent_obj = instanced_scene.get_node(target_nodepath)
			var attachment: Node3D = target_parent_obj
			var already_has_attachment: bool = false
			if (attachment == null):
				printerr("Unable to find node " + str(target_nodepath) + " on scene " + str(packed_scene.resource_path))
				continue
			print("Found transform: " + str(target_parent_obj.name))
			if gameobject_asset != null:
				state.body = gameobject_fileid_to_body.get(gameobject_asset.fileID, state.body)
			if gameobject_asset != null and gameobject_fileid_to_attachment.has(gameobject_asset.fileID):
				print("We already got one! " + str(gameobject_asset.fileID) + " " + str(target_skel_bone))
				attachment = state.owner.get_node(state.fileid_to_nodepath.get(gameobject_asset.fileID))
				state.add_fileID(attachment, transform_asset.fileID)
				already_has_attachment = true
			elif !already_has_attachment and ((target_skel_bone != "" or target_parent_obj is BoneAttachment3D) and len(state.skelley_parents.get(transform_asset.uniq_key, [])) >= 1):
				var godot_skeleton: Node3D = target_parent_obj
				if target_parent_obj is BoneAttachment3D:
					attachment = target_parent_obj
					godot_skeleton = target_parent_obj.get_parent()
				else:
					attachment = BoneAttachment3D.new()
					attachment.name = target_skel_bone # target_parent_obj.name if not stripped??
					attachment.bone_name = target_skel_bone
					print("Made a new attachment! " + str(target_skel_bone))
					state.add_child(attachment, godot_skeleton, transform_asset.fileID)
			print("It's Peanut Butter Skelley time: " + str(transform_asset.uniq_key))

			var list_of_skelleys: Array = state.skelley_parents.get(transform_asset.uniq_key, [])
			for new_skelley in list_of_skelleys:
				attachment.add_child(new_skelley.godot_skeleton)
				new_skelley.godot_skeleton.owner = state.owner

			for child_transform in ps.child_transforms_by_stripped_id.get(transform_asset.fileID, []):
				if child_transform.is_prefab_reference:
					var prefab_instance: UnityPrefabInstance = meta.lookup(child_transform.prefab_instance)
					prefab_instance.create_godot_node(state, attachment)
				else:
					var child_game_object: UnityObject = child_transform.gameObject
					if child_game_object == null:
						printerr("Failed to lookup gameObject of child_transform " + str(child_transform.name) + " at path " + str(state.owner.get_path_to(attachment)) + " fileId " + str(child_transform.fileID) + "/" + str(child_transform.keys.get("m_GameObject", [])))
						continue
					if child_game_object.is_prefab_reference:
						printerr("child gameObject is a prefab reference! " + child_game_object.meta.guid + "/" + int(child_game_object.fileID))
					var new_skelley: Skelley = state.uniq_key_to_skelley.get(child_transform.uniq_key, null)
					print("Go from " + transform_asset.uniq_key + " to " + str(child_game_object) + " transform " + str(child_transform) + " found skelley " + str(new_skelley))
					if new_skelley != null:
						child_game_object.create_skeleton_bone(state, new_skelley)
					else:
						child_game_object.create_godot_node(state, attachment)
			state.body = orig_state_body

		# TODO: detect skeletons which overlap with existing prefab, and add bones to them.
		# TODO: implement modifications:
		# I think we should separate out the **CREATION OF STRUCTURE** from the **SETTING OF STATE**
		# If we do this, prefab modification properties would work the same way as normal properties:
		# prefab:
		#    instantiate scene
		#    assign property modifications
		# top-level (scene):
		#    build structure with create_godot_nodes
		#    now we have what is basically an instantiated scene.
		#    assign property modifications

		#calculate_prefab_nodepaths(state, instanced_scene, target_fileid, target_prefab_meta)
		#for target_fileid in target_prefab_meta.fileid_to_nodepath:
		#	var stripped_id = int(target_fileid)^fileID
		#	prefab_fileid_to_nodepath = 
		#stripped_id_to_nodepath
		#for mod in self.modifications:
		#	# TODO: Assign godot properties for each modification
		#	pass
		return instanced_scene

	var gameObject: UnityPrefabInstance:
		get:
			return self

	var parent_ref: Array: # UnityRef
		get:
			return keys.get("m_Modification", {}).get("m_TransformParent", [null,0,"",0])

	# Special case: this is used to find a common ancestor for Skeletons. We stop at the prefab instance and do not go further.
	var parent_no_stripped: UnityObject: # Array #UnityRef
		get:
			return null # meta.lookup(parent_ref)

	var parent: Array: # UnityRef
		get:
			return meta.lookup(parent_ref)

	var toplevel: bool:
		get:
			return not is_legacy_parent_prefab and parent_ref[1] == 0

	var modifications: Array:
		get:
			return keys.get("m_Modification", {}).get("m_Modifications", [])

	var removed_components: Array:
		get:
			return keys.get("m_Modification", {}).get("m_RemovedComponents", [])

	var source_prefab: Array: # UnityRef
		get:
			# new: m_SourcePrefab; old: m_ParentPrefab
			return keys.get("m_SourcePrefab", keys.get("m_ParentPrefab", [null, 0, "", 0]))

	var is_legacy_parent_prefab: bool:
		get:
			# Legacy prefabs will stick one of these at the root of the Prefab file. It serves no purpose
			# the legacy "prefab parent" object has a m_RootGameObject reference, but you can determine that
			# the same way modern prefabs do, the only GameObject whose Transform has m_Father == null
			return keys.get("m_IsPrefabParent", false)

	var is_stripped_or_prefab_instance: bool:
		get:
			return true

class UnityPrefabLegacyUnused extends UnityPrefabInstance:
	# I think this will never exist in practice, but it's here anyway:
	# Old Unity's "Prefab" used utype 1001 which is now "PrefabInstance", not 1001480554.
	# so those objects should instantiate UnityPrefabInstance anyway.
	pass

### ================ GAME OBJECT TYPE ================
class UnityGameObject extends UnityObject:

	func create_skeleton_bone(xstate: GodotNodeState, skelley: Skelley):
		var state: Object = xstate
		var godot_skeleton: Skeleton3D = skelley.godot_skeleton
		# Instead of a transform, this sets the skeleton transform position maybe?, etc. etc. etc.
		var transform: UnityTransform = self.transform
		var skeleton_bone_index: int = transform.skeleton_bone_index
		var skeleton_bone_name: String = godot_skeleton.get_bone_name(skeleton_bone_index)
		var ret: Node3D = null
		if self.rigidbody != null:
			ret = self.rigidbody.create_physical_bone(state, godot_skeleton, skeleton_bone_name)
			state.add_fileID(ret, fileID)
			state.add_fileID(ret, transform.fileID)
		elif len(components) > 1 or state.skelley_parents.has(transform.uniq_key):
			ret = BoneAttachment3D.new()
			ret.name = self.name
			state.add_child(ret, godot_skeleton, fileID)
			state.add_fileID(ret, transform.fileID)
			ret.bone_name = skeleton_bone_name
		else:
			state.add_fileID(godot_skeleton, fileID)
			state.add_fileID(godot_skeleton, transform.fileID)
			state.add_fileID_to_skeleton_bone(skeleton_bone_name, fileID)
			state.add_fileID_to_skeleton_bone(skeleton_bone_name, transform.fileID)
		if ret != null:
			var list_of_skelleys: Array = state.skelley_parents.get(transform.uniq_key, [])
			for new_skelley in list_of_skelleys:
				ret.add_child(godot_skeleton)
				godot_skeleton.owner = state.owner

		var skip_first: bool = true

		for component_ref in components:
			if skip_first:
				#Is it a fair assumption that Transform is always the first component???
				skip_first = false
			else:
				assert(ret != null)
				var component = meta.lookup(component_ref.get("component"))
				component.create_godot_node(state, ret)

		for child_ref in transform.children_refs:
			var child_transform: UnityTransform = meta.lookup(child_ref)
			if child_transform.is_prefab_reference:
				var prefab_instance: UnityPrefabInstance = meta.lookup(child_transform.prefab_instance)
				prefab_instance.instance(state, ret)
			else:
				var child_game_object: UnityGameObject = child_transform.gameObject
				if child_game_object.is_prefab_reference:
					printerr("child gameObject is a prefab reference! " + child_game_object.meta.guid + "/" + int(child_game_object.fileID))
				var new_skelley: Skelley = state.uniq_key_to_skelley.get(child_transform.uniq_key, null)
				if new_skelley == null and ret == null:
					printerr("We did not create a node for this child, but it is not a skeleton bone! " + uniq_key + " child " + child_transform.uniq_key + " gameObject " + child_game_object.uniq_key + " name " + child_game_object.name)
					continue
				if new_skelley != null:
					child_game_object.create_skeleton_bone(state, new_skelley)
				else:
					child_game_object.create_godot_node(state, ret)

	func create_godot_node(xstate: GodotNodeState, new_parent: Node3D) -> Node3D:
		var state: Object = xstate
		var ret: Node3D = null
		var components: Array = self.components
		var has_collider: bool = false
		var extra_fileID: Array = [fileID]
		var transform: UnityTransform = self.transform

		for component_ref in components:
			var component = meta.lookup(component_ref.get("component"))
			# Some components take priority and must be created here.
			if component.type == "Rigidbody":
				ret = component.create_physics_body(state, new_parent, name)
				ret.transform = transform.godot_transform
				extra_fileID.push_back(transform.fileID)
				state = state.state_with_body(ret)
			if component.is_collider:
				extra_fileID.push_back(component.fileID)
				print("Has a collider " + self.name)
				has_collider = true
		var is_staticbody: bool = false
		if has_collider and (state.body == null or state.body.get_class().begins_with("StaticBody")):
			ret = StaticBody3D.new()
			print("Created a StaticBody3D " + self.name)
			is_staticbody = true
		else:
			ret = Node3D.new()
		ret.name = name
		state.add_child(ret, new_parent, transform.fileID)
		ret.transform = transform.godot_transform
		if is_staticbody:
			print("Replacing state with body " + str(name))
			state = state.state_with_body(ret)
		for ext in extra_fileID:
			state.add_fileID(ret, ext)
		var skip_first: bool = true

		for component_ref in components:
			if skip_first:
				#Is it a fair assumption that Transform is always the first component???
				skip_first = false
			else:
				var component = meta.lookup(component_ref.get("component"))
				component.create_godot_node(state, ret)

		var list_of_skelleys: Array = state.skelley_parents.get(transform.uniq_key, [])
		for new_skelley in list_of_skelleys:
			ret.add_child(new_skelley.godot_skeleton)
			new_skelley.godot_skeleton.owner = state.owner

		for child_ref in transform.children_refs:
			var child_transform: UnityTransform = meta.lookup(child_ref)
			if child_transform.is_prefab_reference:
				var prefab_instance: UnityPrefabInstance = meta.lookup(child_transform.prefab_instance)
				prefab_instance.instance(state, ret)
			else:
				var child_game_object: UnityGameObject = child_transform.gameObject
				if child_game_object.is_prefab_reference:
					printerr("child gameObject is a prefab reference! " + child_game_object.uniq_key)
				var new_skelley: Skelley = state.uniq_key_to_skelley.get(child_transform.uniq_key, null)
				if new_skelley != null:
					child_game_object.create_skeleton_bone(state, new_skelley)
				else:
					child_game_object.create_godot_node(state, ret)

		return ret

	var components: Variant: # Array:
		get:
			if is_stripped:
				printerr("Attempted to access the component array of a stripped " + type + " " + uniq_key)
				# FIXME: Stripped objects do not know their name.
				return 12345.678 # ???? 
			return keys.get("m_Component")

	var transform: Variant: # UnityTransform:
		get:
			if is_stripped:
				printerr("Attempted to access the transform of a stripped " + type + " " + uniq_key)
				# FIXME: Stripped objects do not know their name.
				return 12345.678 # ???? 
			if typeof(components) != TYPE_ARRAY:
				printerr(uniq_key + " has component array: " + str(components))
			elif len(components) < 1 or typeof(components[0]) != TYPE_DICTIONARY:
				printerr(uniq_key + " has invalid first component: " + str(components))
			elif len(components[0].get("component", [])) < 3:
				printerr(uniq_key + " has invalid component: " + str(components))
			else:
				var component = meta.lookup(components[0].get("component"))
				if component.type != "Transform" and component.type != "RectTransform":
					printerr(str(self) + " does not have Transform as first component! " + str(component.type) + ": components " + str(components))
				return component
			return null

	func GetComponent(typ: String) -> UnityObject:
		for component_ref in components:
			var component = meta.lookup(component_ref.get("component"))
			if component.type == typ:
				return component
		return null

	var meshFilter: UnityMeshFilter:
		get:
			return GetComponent("MeshFilter")

	var rigidbody: UnityRigidbody:
		get:
			return GetComponent("Rigidbody")

	var enabled: bool:
		get:
			return keys.get("m_IsActive")

	var toplevel: Variant: # bool:
		get:
			if is_stripped:
				# Stripped objects are part of a Prefab, so by definition will never be toplevel
				# (The PrefabInstance itself will be the toplevel object)
				return false
			if typeof(transform) == TYPE_NIL:
				printerr(uniq_key + " has no transform in toplevel: " + str(transform))
				return null
			if typeof(transform.parent_ref) != TYPE_ARRAY:
				printerr(uniq_key + " has invalid or missing parent_ref: " + str(transform.parent_ref))
				return null
			return transform.parent_ref[1] == 0

	var gameObject: UnityGameObject:
		get:
			return self


### ================ COMPONENT TYPES ================
class UnityComponent extends UnityObject:

	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		var new_node: Node = Node.new()
		new_node.name = type
		state.add_child(new_node, new_parent, fileID)
		new_node.editor_description = str(self)
		return new_node

	var gameObject: Variant: # UnityGameObject:
		get:
			if is_stripped:
				printerr("Attempted to access the gameObject of a stripped " + type + " " + uniq_key)
				# FIXME: Stripped objects do not know their name.
				return 12345.678 # ???? 
			return meta.lookup(keys.get("m_GameObject", []))

	var name: Variant:
		get:
			if is_stripped:
				printerr("Attempted to access the name of a stripped " + type + " " + uniq_key)
				# FIXME: Stripped objects do not know their name.
				# FIXME: Make the calling function crash, since we don't have stacktraces wwww
				return 12345.678 # ???? 
			return gameObject.name

	var enabled: bool:
		get:
			return true

	var toplevel: bool:
		get:
			return false

class UnityBehaviour extends UnityComponent:
	var enabled: bool:
		get:
			return keys.get("m_Enabled", true)

class UnityTransform extends UnityComponent:

	var skeleton_bone_index: int = -1
	const FLIP_X: Transform = Transform.FLIP_X # Transform(-1,0,0,0,1,0,0,0,1,0,0,0)

	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node3D:
		#var new_node: Node3D = Node3D.new()
		#state.add_child(new_node, new_parent, fileID)
		#new_node.transform = godot_transform
		return null

	var localPosition: Vector3:
		get:
			return keys.get("m_LocalPosition", Vector3(1,2,3))

	var localRotation: Quat:
		get:
			return keys.get("m_LocalRotation", Quat(0.1,0.2,0.3,0.4))

	var localScale: Vector3:
		get:
			var scale = keys.get("m_LocalScale", Vector3(0.4,0.6,0.8))
			if scale.x > -1e-7 && scale.x < 1e-7:
				scale.x = 1e-7
			if scale.y > -1e-7 && scale.y < 1e-7:
				scale.y = 1e-7
			if scale.z > -1e-7 && scale.z < 1e-7:
				scale.z = 1e-7
			return scale

	var godot_transform: Transform:
		get:
			return FLIP_X.affine_inverse() * Transform(Basis(localRotation).scaled(localScale), localPosition) * FLIP_X


	var rootOrder: int:
		get:
			return keys.get("m_RootOrder", 0)

	var parent_ref: Variant: # Array: # UnityRef
		get:
			if is_stripped:
				printerr("Attempted to access the parent of a stripped " + type + " " + uniq_key)
				return 12345.678 # FIXME: Returning bogus value to crash whoever does this
			return keys.get("m_Father", [null,0,"",0])

	var parent_no_stripped: UnityObject: # UnityTransform
		get:
			if is_stripped:
				return meta.lookup(self.prefab_instance) # Not a UnityTransform, but sufficient for determining a common "ancestor" for skeleton bones.
			return meta.lookup(parent_ref)

	var parent: Variant: # UnityTransform:
		get:
			if is_stripped:
				printerr("Attempted to access the parent of a stripped " + type + " " + uniq_key)
				return 12345.678 # FIXME: Returning bogus value to crash whoever does this
			return meta.lookup(parent_ref)

	var children_refs: Array:
		get:
			return keys.get("m_Children")

class UnityRectTransform extends UnityTransform:
	pass

class UnityCollider extends UnityBehaviour:
	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		var new_node: CollisionShape3D = CollisionShape3D.new()
		print("Creating collider at " + self.name + " type " + self.type + " parent name " + str(new_parent.name if new_parent != null else "NULL") + " path " + str(state.owner.get_path_to(new_parent) if new_parent != null else NodePath()) + " body name " + str(state.body.name if state.body != null else "NULL") + " path " + str(state.owner.get_path_to(state.body) if state.body != null else NodePath()))
		if state.body == null:
			state.body = StaticBody3D.new()
			new_parent.add_child(state.body)
			state.body.owner = state.owner
		new_node.name = self.type
		state.add_child(new_node, state.body, fileID)
		var path_to_body = new_parent.get_path_to(state.body)
		var cur_node: Node3D = new_parent
		var xform = Transform(self.basis, self.center)
		for i in range(path_to_body.get_name_count()):
			if path_to_body.get_name(i) == ".":
				continue
			elif path_to_body.get_name(i) == "..":
				xform = cur_node.transform * xform
				cur_node = cur_node.get_parent()
				if cur_node == null:
					break
			else:
				cur_node = cur_node.get_node(str(path_to_body.get_name(i)))
				if cur_node == null:
					break
				xform = cur_node.transform.affine_inverse() * xform
		#while cur_node != state.body and cur_node != null:
		#	xform = cur_node.transform * xform
		#	cur_node = cur_node.get_parent()
		#if cur_node == null:
		#	xform = Transform(self.basis, self.center)
		new_node.transform = xform
		new_node.shape = self.shape
		return new_node

	var center: Vector3:
		get:
			return Vector3(-1.0, 1.0, 1.0) * keys.get("m_Center", Vector3(0.0, 0.0, 0.0))

	var basis: Basis:
		get:
			return Basis(Vector3(0.0, 0.0, 0.0))

	var shape: Shape3D:
		get:
			return null

	var is_collider: bool:
		get:
			return true

class UnityBoxCollider extends UnityCollider:
	var shape: Shape3D:
		get:
			var bs: BoxShape3D = BoxShape3D.new()
			bs.size = size
			return bs

	var size: Vector3:
		get:
			return keys.get("m_Size")

class UnitySphereCollider extends UnityCollider:
	var shape: Shape3D:
		get:
			var bs: SphereShape3D = SphereShape3D.new()
			bs.radius = radius
			return bs

	var radius: float:
		get:
			return keys.get("m_Radius")

class UnityCapsuleCollider extends UnityCollider:
	var shape: Shape3D:
		get:
			var bs: CapsuleShape3D = CapsuleShape3D.new()
			bs.radius = radius
			var adj_height: float = height - 2 * bs.radius
			if adj_height < 0.0:
				adj_height = 0.0
			bs.height = adj_height
			return bs

	var basis: Basis:
		get:
			if direction == 0: # Along the X-Axis
				return Basis(Vector3(0.0, 0.0, PI/2.0))
			if direction == 1: # Along the Y-Axis (Godot default)
				return Basis(Vector3(0.0, 0.0, 0.0))
			if direction == 2: # Along the Z-Axis
				return Basis(Vector3(PI/2.0, 0.0, 0.0))

	var direction: int:
		get:
			return keys.get("m_Direction") # 0, 1 or 2

	var radius: float:
		get:
			return keys.get("m_Radius")

	var height: float:
		get:
			return keys.get("m_Height")

class UnityMeshCollider extends UnityCollider:

	var convex: Shape3D:
		get:
			return keys.get("m_Convex")

	var shape: Shape3D:
		get:
			if convex:
				return meta.get_godot_resource(mesh).create_convex_shape()
			else:
				return meta.get_godot_resource(mesh).create_trimesh_shape()
		
	var mesh: Array: # UnityRef
		get:
			var ret = keys.get("m_Mesh", [null,0,"",null])
			if ret[1] == 0:
				var mf: UnityMeshFilter = gameObject.meshFilter
				if mf != null:
					return gameObject.meshFilter.mesh
			return ret

class UnityRigidbody extends UnityComponent:

	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		return null

	func create_physics_body(state: GodotNodeState, new_parent: Node3D, name: String) -> Node:
		var new_node: Node3D;
		if isKinematic:
			var kinematic: KinematicBody3D = KinematicBody3D.new()
			new_node = kinematic
		else:
			var rigid: RigidBody3D = RigidBody3D.new()
			new_node = rigid

		new_node.name = name # Not type: This replaces the usual transform node.
		state.add_child(new_node, new_parent, fileID)
		return new_node

	func create_physical_bone(state: GodotNodeState, godot_skeleton: Skeleton3D, name: String):
		var new_node: PhysicalBone3D = PhysicalBone3D.new()
		new_node.bone_name = name
		new_node.name = name
		state.add_child(new_node, godot_skeleton, fileID)
		return new_node

	var isKinematic: bool:
		get:
			return keys.get("m_IsKinematic") != 0


class UnityMeshFilter extends UnityComponent:
	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		return null
		
	var mesh: Array: # UnityRef
		get:
			return keys.get("m_Mesh", [null,0,"",null])

class UnityRenderer extends UnityBehaviour:
	pass

class UnityMeshRenderer extends UnityRenderer:
	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		return create_godot_node_orig(state, new_parent, type)

	func create_godot_node_orig(state: GodotNodeState, new_parent: Node3D, component_name: String) -> Node:
		var new_node: MeshInstance3D = MeshInstance3D.new()
		new_node.name = component_name
		state.add_child(new_node, new_parent, fileID)
		new_node.editor_description = str(self)
		new_node.mesh = meta.get_godot_resource(self.mesh)

		var mf: UnityMeshFilter = gameObject.meshFilter
		if mf != null:
			state.add_fileID(new_node, mf.fileID)
		var idx: int = 0
		for m in materials:
			new_node.set_surface_material(idx, meta.get_godot_resource(m))
			idx += 1
		return new_node

	var materials: Array:
		get:
			return keys.get("m_Materials", [])

	var mesh: Array: # UnityRef
		get:
			var mf: UnityMeshFilter = gameObject.meshFilter
			if mf != null:
				return mf.mesh
			return [null,0,"",null]

class UnitySkinnedMeshRenderer extends UnityMeshRenderer:

	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		if len(bones) == 0:
			var cloth: UnityCloth = gameObject.GetComponent("Cloth")
			if cloth != null:
				return create_cloth_godot_node(state, new_parent, type, cloth)
			return create_godot_node_orig(state, new_parent, type)
		else:
			return null

	func create_cloth_godot_node(state: GodotNodeState, new_parent: Node3D, component_name: String, cloth: UnityCloth) -> Node:
		var new_node: MeshInstance3D = cloth.create_cloth_godot_node(state, new_parent, type, self.fileID, self.mesh, null, [])
		var idx: int = 0
		for m in materials:
			new_node.set_surface_material(idx, meta.get_godot_resource(m))
			idx += 1
		return new_node

	func create_skinned_mesh(state: GodotNodeState) -> Node:
		var bones: Array = self.bones
		if len(self.bones) == 0:
			return null
		var first_bone_obj: Reference = meta.lookup(bones[0])
		#if first_bone_obj.is_stripped:
		#	printerr("Cannot create skinned mesh on stripped skeleton!")
		#	return null
		var first_bone_key: String = first_bone_obj.uniq_key
		print("SkinnedMeshRenderer: Looking up " + first_bone_key + " for " + str(self.gameObject))
		var skelley = state.uniq_key_to_skelley.get(first_bone_key, null)
		if skelley == null:
			printerr("Unable to find Skelley to add a mesh " + name + " for " + first_bone_key)
			return null
		var gdskel = skelley.godot_skeleton
		if gdskel == null:
			printerr("Unable to find skeleton to add a mesh " + name + " for " + first_bone_key)
			return null
		var component_name: String = type
		if not self.gameObject.is_stripped:
			component_name = self.gameObject.name
		var cloth: UnityCloth = gameObject.GetComponent("Cloth")
		var ret: MeshInstance3D = null
		if cloth != null:
			ret = create_cloth_godot_node(state, gdskel, component_name, cloth)
		else:
			ret = create_godot_node_orig(state, gdskel, component_name)
		# ret.skeleton = NodePath("..") # default?
		# TODO: skin??
		ret.skin = meta.get_godot_resource(skin)
		if ret.skin == null:
			printerr("Mesh " + component_name + " at " + str(state.owner.get_path_to(ret)) + " mesh " + str(ret.mesh) + " has bones " + str(len(bones)) + " has null skin")
		elif len(bones) != ret.skin.get_bind_count():
			printerr("Mesh " + component_name + " at " + str(state.owner.get_path_to(ret)) + " mesh " + str(ret.mesh) + " has bones " + str(len(bones)) + " mismatched with bind bones " + str(ret.skin.get_bind_count()))
		else:
			var edited: bool = false
			for idx in range(len(bones)):
				var bone_transform: UnityTransform = meta.lookup(bones[idx])
				if ret.skin.get_bind_bone(idx) != bone_transform.skeleton_bone_index:
					edited = true
					break
			if edited:
				ret.skin = ret.skin.duplicate()
				for idx in range(len(bones)):
					var bone_transform: UnityTransform = meta.lookup(bones[idx])
					ret.skin.set_bind_bone(idx, bone_transform.skeleton_bone_index)
					ret.skin.set_bind_name(idx, gdskel.get_bone_name(bone_transform.skeleton_bone_index))
		# TODO: duplicate skin and assign the correct bone names to match self.bones array
		return ret

	var bones: Array:
		get:
			return keys.get("m_Bones", [])

	var skin: Array: # UnityRef
		get:
			var ret: Array = keys.get("m_Mesh", [null,0,"",null])
			return [null, -ret[1], ret[2], ret[3]]

	var mesh: Array: # UnityRef
		get:
			return keys.get("m_Mesh", [null,0,"",null])

class UnityCloth extends UnityBehaviour:
	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		return null

	func get_bone_transform(skel: Skeleton3D, bone_idx: int) -> Transform:
		var transform: Transform = Transform.IDENTITY
		while bone_idx != -1:
			transform = skel.get_bone_rest(bone_idx) * transform
			bone_idx = skel.get_bone_parent(bone_idx)
		return transform

	func get_or_upgrade_bone_attachment(skel: Skeleton3D, state: GodotNodeState, bone_transform: UnityTransform) -> BoneAttachment3D:
		var fileID: int = bone_transform.fileID
		var target_nodepath: NodePath = meta.fileid_to_nodepath.get(fileID,
				meta.prefab_fileid_to_nodepath.get(fileID, NodePath()))
		var ret: Node3D = skel
		if target_nodepath != NodePath():
			ret = state.owner.get_node(target_nodepath)
		if ret is Skeleton3D:
			ret = BoneAttachment3D.new()
			ret.name = skel.get_bone_name(bone_transform.skeleton_bone_index) # target_skel_bone
			state.add_child(ret, skel, bone_transform.fileID)
			state.remove_fileID_to_skeleton_bone(bone_transform.fileID)
			ret.bone_name = ret.name
			return ret
		else:
			return ret

	func create_cloth_godot_node(state: GodotNodeState, new_parent: Node3D, component_name: String, smr_fileID: int, mesh: Array, skel: Skeleton3D, bones: Array) -> SoftBody3D:
		var new_node: SoftBody3D = SoftBody3D.new()
		new_node.name = component_name
		state.add_child(new_node, new_parent, smr_fileID)
		state.add_fileID(new_node, self.fileID)
		new_node.editor_description = str(self)
		new_node.mesh = meta.get_godot_resource(mesh)
		new_node.ray_pickable = false
		new_node.linear_stiffness = self.linear_stiffness
		# new_node.angular_stiffness = self.angular_stiffness # Removed in 4.0 - how to set Bending stiffness??
		# parent_collision_ignore?????? # NodePath to a CollisionObject this SoftBody should avoid clipping. ????
		new_node.damping_coefficient = self.damping_coefficient
		new_node.drag_coefficient = self.drag_coefficient
		# m_CapsuleColliders ??? 
		# m_SphereColliders ???
		# m_Enabled # FIXME: No way to disable?!?!
		# FIXME: no GRAVITY?????
		# world velocity / world acceleration?
		# collision mass?
		# sleep threshold?
		if new_node.mesh == null:
			return new_node
		var max_dist: float = 0.01
		for coef in self.coefficients:
			var dist: float = coef.get("maxDistance", 1.0)
			if dist < 1.0e+10:
				max_dist = max(max_dist, dist)
		# We might not be able to use Unity's "m_Coefficients" because it depends on vertex ordering
		# which might be well defined, but even if so, Unity does some black magic to deduplicate vertices
		# across UV and normal seams. Does Godot also do this? If not, how does it keep the mesh from
		# falling apart at UV seams? If yes, how to map the two engines' algorithms here.
		var mesh_arrays: Array = new_node.mesh.surface_get_arrays(0) # Godot SoftBody ignores other surfaces.
		var mesh_verts: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
		var mesh_bones: PackedInt32Array = mesh_arrays[Mesh.ARRAY_BONES]
		var mesh_weights: Array = Array(mesh_arrays[Mesh.ARRAY_WEIGHTS])
		var bone_per_vert: int = len(mesh_bones) / len(mesh_verts)
		var vertex_info_to_dedupe_index: Dictionary = {}.duplicate()
		var bone_idx_to_bone_transform: Dictionary = {}.duplicate()
		var bone_idx_to_attachment_path: Dictionary = {}.duplicate()
		var dedupe_vertices: PackedInt32Array = PackedInt32Array()
		var vert_idx: int = 0
		# De-duplication of vertices to deal with UV-seams and sharp normals.
		# Seems to match Unity's logic (for meshes with only one surface at least!)
		# For example 1109/1200 or 104/129 verts
		# FIXME: I noticed some differences in vertex ordering in some cases. Hmm....
		for idx in range(len(mesh_verts)):
			var vert: Vector3 = mesh_verts[idx]
			var key = str(vert.x) + "," + str(vert.y) + "," + str(vert.z)
			if not bones.is_empty() and not mesh_bones.is_empty():
				key += str(0.5 * mesh_weights[idx * bone_per_vert] + mesh_bones[idx * bone_per_vert])
			if vertex_info_to_dedupe_index.has(key):
				dedupe_vertices.push_back(vertex_info_to_dedupe_index.get(key))
			else:
				vertex_info_to_dedupe_index[key] = vert_idx
				dedupe_vertices.push_back(vert_idx)
				vert_idx += 1

		print("Verts " + str(len(mesh_verts)) + " " + str(len(mesh_bones)) + " " + str(len(mesh_weights)) + " dedupe_len=" + str(vert_idx) + " unity_len=" + str(len(self.coefficients)))

		var pinned_points: PackedInt32Array = PackedInt32Array()
		var bones_paths: Array = [].duplicate()
		var offsets: Array = [].duplicate()
		var unity_coefficients = self.coefficients
		for vert_idx in range(len(mesh_verts)):
			var dedupe_idx = dedupe_vertices[vert_idx]
			if dedupe_idx >= len(unity_coefficients):
				continue
			var coef = unity_coefficients[dedupe_idx]
			if coef.get("maxDistance", max_dist) / max_dist < 0.01:
				pinned_points.push_back(vert_idx)
				if bones.is_empty():
					bones_paths.push_back(NodePath("."))
					offsets.push_back(mesh_verts[vert_idx])
				else:
					var most_weight: float = 0.0
					var most_bone: int = 0
					for boneidx in range(bone_per_vert):
						var weight: float = mesh_weights[vert_idx * bone_per_vert + boneidx]
						if weight >= most_weight:
							most_weight = weight
							most_bone = mesh_bones[vert_idx * bone_per_vert + boneidx]
					if not bone_idx_to_attachment_path.has(most_bone):
						var attachment: BoneAttachment3D = get_or_upgrade_bone_attachment(skel, state, meta.lookup(bones[most_bone]))
						bone_idx_to_bone_transform[most_bone] = get_bone_transform(skel, skel.find_bone(attachment.bone_name)).affine_inverse()
						bone_idx_to_attachment_path[most_bone] = new_node.get_path_to(attachment)
					bones_paths.push_back(bone_idx_to_attachment_path.get(most_bone))
					offsets.push_back(bone_idx_to_bone_transform[most_bone] * mesh_verts[vert_idx])
		# It may be necessary to add BoneAttachment for each vertex, and
		# then, give a node path and vertex offset for the maximally weighted vertex.
		# This property isn't even documented, so IDK whatever.
		new_node.set("pinned_points", pinned_points)
		for i in range(len(pinned_points)):
			new_node.set("attachments/" + str(i) + "/spatial_attachment_path", bones_paths[i])
			new_node.set("attachments/" + str(i) + "/offset", offsets[i])
		return new_node

	var coefficients:
		get:
			return keys.get("m_Coefficients", [])

	var drag_coefficient:
		get:
			return keys.get("m_Friction", 0)

	var damping_coefficient:
		get:
			return keys.get("m_Damping", 0)

	var linear_stiffness:
		get:
			return keys.get("m_StretchingStiffness", 1)

	var angular_stiffness:
		get:
			return keys.get("m_BendingStiffness", 1)


class UnityLight extends UnityBehaviour:
	func create_godot_node(state: GodotNodeState, new_parent: Node3D) -> Node:
		var light: Light3D
		var unityLightType = lightType
		if unityLightType == 0:
			# Assuming default cookie
			# Assuming Legacy pipeline:
			# Scriptable Rendering Pipeline: shape and innerSpotAngle not supported.
			# Assuming RenderSettings.m_SpotCookie: == {fileID: 10001, guid: 0000000000000000e000000000000000, type: 0}
			var spot_light: SpotLight3D = SpotLight3D.new()
			spot_light.set_param(Light3D.PARAM_SPOT_ANGLE, spotAngle)
			spot_light.set_param(Light3D.PARAM_SPOT_ATTENUATION, 0.25) # Eyeball guess for Unity's default spotlight texture
			spot_light.set_param(Light3D.PARAM_ATTENUATION, 1.0)
			spot_light.set_param(Light3D.PARAM_RANGE, lightRange)
			light = spot_light
		elif unityLightType == 1:
			# depth_range? max_disatance? blend_splits? bias_split_scale?
			#keys.get("m_ShadowNearPlane")
			var dir_light: DirectionalLight3D = DirectionalLight3D.new()
			dir_light.set_param(Light3D.PARAM_SHADOW_NORMAL_BIAS, shadowNormalBias)
			light = dir_light
		elif unityLightType == 2:
			var omni_light: OmniLight3D = OmniLight3D.new()
			light = omni_light
			omni_light.set_param(Light3D.PARAM_ATTENUATION, 1.0)
			omni_light.set_param(Light3D.PARAM_RANGE, lightRange)
		elif unityLightType == 3:
			printerr("Rectangle Area Light not supported!")
			# areaSize?
			return UnityBehaviour.create_godot_node(state, new_parent)
		elif unityLightType == 4:
			printerr("Disc Area Light not supported!")
			return UnityBehaviour.create_godot_node(state, new_parent)

		# TODO: Layers
		if keys.get("useColorTemperature"):
			printerr("Color Temperature not implemented.")
		light.name = type
		state.add_child(light, new_parent, fileID)
		light.transform = Transform(Basis(Vector3(0.0, PI, 0.0)))
		light.light_color = color
		light.set_param(Light3D.PARAM_ENERGY, intensity)
		light.set_param(Light3D.PARAM_INDIRECT_ENERGY, bounceIntensity)
		light.shadow_enabled = shadowType != 0
		light.set_param(Light3D.PARAM_SHADOW_BIAS, shadowBias)
		if lightmapBakeType == 1:
			light.light_bake_mode = Light3D.BAKE_DYNAMIC # INDIRECT??
		elif lightmapBakeType == 2:
			light.light_bake_mode = Light3D.BAKE_DYNAMIC # BAKE_ALL???
			light.editor_only = true
		else:
			light.light_bake_mode = Light3D.BAKE_DISABLED
		return light
	
	var color: Color:
		get:
			return keys.get("m_Color")
	
	var lightType: float:
		get:
			return keys.get("m_Type")
	
	var lightRange: float:
		get:
			return keys.get("m_Range")

	var intensity: float:
		get:
			return keys.get("m_Intensity")
	
	var bounceIntensity: float:
		get:
			return keys.get("m_BounceIntensity")
	
	var spotAngle: float:
		get:
			return keys.get("m_SpotAngle")

	var lightmapBakeType: int:
		get:
			return keys.get("m_Lightmapping")

	var shadowType: int:
		get:
			return keys.get("m_Shadows").get("m_Type")

	var shadowBias: float:
		get:
			return keys.get("m_Shadows").get("m_Bias")

	var shadowNormalBias: float:
		get:
			return keys.get("m_Shadows").get("m_NormalBias")


### ================ IMPORTER TYPES ================
class UnityAssetImporter extends UnityObject:
	var main_object_id: int:
		get:
			return 0 # Unknown

	func get_external_objects() -> Dictionary:
		var eo: Dictionary = {}.duplicate()
		for srcAssetIdent in keys.get("externalObjects", []):
			var type_str: String = srcAssetIdent.get("first", {}).get("type","")
			var type_key: String = type_str.split(":")[-1]
			var key: String = srcAssetIdent.get("first", {}).get("name","")
			var val: Array = srcAssetIdent.get("second", {}) # UnityRef
			if key != "" and type_str.begins_with("UnityEngine"):
				if not eo.has(type_key):
					eo[type_key] = {}.duplicate()
				eo[type_key][key] = val
		return eo


class UnityModelImporter extends UnityAssetImporter:

	var addCollider: bool:
		get:
			return keys.get("meshes").get("addCollider") == 1

	func get_animation_clips() -> Array:
		var unityClips = keys.get("animations").get("clipAnimations", [])
		var outClips = [].duplicate()
		for unityClip in unityClips:
			var clip = {}.duplicate()
			outClips.push_back(clip)
			clip["name"] = unityClip.get("name", "")
			clip["start_frame"] = unityClip.get("firstFrame", 0.0)
			clip["end_frame"] = unityClip.get("lastFrame", 0.0)
			# "loop" also exists but appears to be unused at least
			clip["loops"] = unityClip.get("loopTime", 0) != 0
			# TODO: Root motion?
			#cycleOffset: -0
			#loop: 0
			#hasAdditiveReferencePose: 0
			#loopTime: 1
			#loopBlend: 1
			#loopBlendOrientation: 0
			#loopBlendPositionY: 1
			#loopBlendPositionXZ: 0
			#keepOriginalOrientation: 0
			#keepOriginalPositionY: 0
			#keepOriginalPositionXZ: 0
			# TODO: Humanoid retargeting?
			# humanDescription:
			#   serializedVersion: 2
			#   human:
			#   - boneName: RightUpLeg
			#     humanName: RightUpperLeg
		return outClips

	var meshes_light_baking: int:
		get:
			# Godot uses: Disabled,Enabled,GenLightmaps
			return keys.get("meshes").get("generateSecondaryUV") * 2

	var meshes_root_scale: float:
		get:
			return keys.get("meshes").get("globalScale") == 1

	var animation_import: bool:
		# legacyGenerateAnimations = 4 ??
		# animationType = 3 ??
		get:
			return (keys.get("importAnimation") and
				keys.get("animationType") != 0)

	var fileIDToRecycleName: Dictionary:
		get:
			return keys.get("fileIDToRecycleName", {})

	# 0: No compression; 1: keyframe reduction; 2: keyframe reduction and compress
	# 3: all of the above and choose best curve for runtime memory.
	func animation_optimizer_settings() -> Dictionary:
		var rotError: float = keys.get("animations").get("animationRotationError", 0.5) # Degrees
		var rotErrorHalfRevs: float = rotError / 180 # p_alowed_angular_err is defined this way (divides by PI)
		return {
			"enabled": keys.get("animations").get("animationCompression") != 0,
			"max_linear_error": keys.get("animations").get("animationPositionError", 0.5),
			"max_angular_error": rotErrorHalfRevs, # Godot defaults this value to 
		}

	var main_object_id: int:
		get:
			return 100100000 # a model is a type of Prefab

class UnityShaderImporter extends UnityAssetImporter:
	var main_object_id: int:
		get:
			return 4800000 # Shader

class UnityTextureImporter extends UnityAssetImporter:
	var textureShape: int:
		get:
			# 1: Texture2D
			# 2: Cubemap
			# 3: Texture2DArray (Unity 2020)
			# 4: Texture3D (Unity 2020)
			return keys.get("textureShape", 0) # Some old files do not have this

	# TODO: implement textureType. Currently unused
	var textureType: int:
		get:
			# -1: Unknown
			# 0: Default
			# 1: NormalMap
			# 2: GUI
			# 3: Sprite
			# ...
			# bumpmap.convertToNormalMap?
			return keys.get("textureType", 0)

	var main_object_id: int:
		# Note: some textureType will add a Sprite or other asset as well.
		get:
			match textureShape:
				0, 1:
					return 2800000 # "Texture2D",
				2:
					return 8900000 # "Cubemap",
				3:
					return 18700000 # "Texture2DArray",
				4:
					return 11700000 # "Texture3D",
				_:
					return 0

class UnityTrueTypeFontImporter extends UnityAssetImporter:
	var main_object_id: int:
		get:
			return 12800000 # Font

class UnityNativeFormatImporter extends UnityAssetImporter:
	var main_object_id: int:
		get:
			return keys.get("mainObjectFileID", 0)

class UnityPrefabImporter extends UnityAssetImporter:
	var main_object_id: int:
		get:
			# PrefabInstance is 1001. Multiply by 100000 to create default ID.
			return 100100000 # Always should be this ID.

class UnityTextScriptImporter extends UnityAssetImporter:
	var main_object_id: int:
		get:
			return 4900000 # TextAsset

class UnityAudioImporter extends UnityAssetImporter:
	var main_object_id: int:
		get:
			return 8300000 # AudioClip

class UnityDefaultImporter extends UnityAssetImporter:
	# Will depend on filetype or file extension?
	# Check file extension from `meta.path`???
	var main_object_id: int:
		get:
			match meta.path.get_extension():
				"unity":
					# Scene file.
					# 1: OcclusionCullingSettings (29),
					# 2: RenderSettings (104),
					# 3: LightmapSettings (157),
					# 4: NavMeshSettings (196),
					# We choose 1 to represent the default id, but there is no actual root node.
					return 1
				"txt", "html", "htm", "xml", "bytes", "json", "csv", "yaml", "fnt":
					# Supported file extensions for text (.bytes is special)
					return 4900000 # TextAsset
				_:
					# Folder, or unsupported type.
					return 102900000 # DefaultAsset

var _type_dictionary: Dictionary = {
	# "AimConstraint": UnityAimConstraint,
	# "AnchoredJoint2D": UnityAnchoredJoint2D,
	# "Animation": UnityAnimation,
	"AnimationClip": UnityAnimationClip,
	# "Animator": UnityAnimator,
	# "AnimatorController": UnityAnimatorController,
	# "AnimatorOverrideController": UnityAnimatorOverrideController,
	# "AnimatorState": UnityAnimatorState,
	# "AnimatorStateMachine": UnityAnimatorStateMachine,
	# "AnimatorStateTransition": UnityAnimatorStateTransition,
	# "AnimatorTransition": UnityAnimatorTransition,
	# "AnimatorTransitionBase": UnityAnimatorTransitionBase,
	# "AnnotationManager": UnityAnnotationManager,
	# "AreaEffector2D": UnityAreaEffector2D,
	# "AssemblyDefinitionAsset": UnityAssemblyDefinitionAsset,
	# "AssemblyDefinitionImporter": UnityAssemblyDefinitionImporter,
	# "AssemblyDefinitionReferenceAsset": UnityAssemblyDefinitionReferenceAsset,
	# "AssemblyDefinitionReferenceImporter": UnityAssemblyDefinitionReferenceImporter,
	# "AssetBundle": UnityAssetBundle,
	# "AssetBundleManifest": UnityAssetBundleManifest,
	# "AssetDatabaseV1": UnityAssetDatabaseV1,
	"AssetImporter": UnityAssetImporter,
	# "AssetImporterLog": UnityAssetImporterLog,
	# "AssetImportInProgressProxy": UnityAssetImportInProgressProxy,
	# "AssetMetaData": UnityAssetMetaData,
	# "AudioBehaviour": UnityAudioBehaviour,
	# "AudioBuildInfo": UnityAudioBuildInfo,
	# "AudioChorusFilter": UnityAudioChorusFilter,
	# "AudioClip": UnityAudioClip,
	# "AudioDistortionFilter": UnityAudioDistortionFilter,
	# "AudioEchoFilter": UnityAudioEchoFilter,
	# "AudioFilter": UnityAudioFilter,
	# "AudioHighPassFilter": UnityAudioHighPassFilter,
	# "AudioImporter": UnityAudioImporter,
	# "AudioListener": UnityAudioListener,
	# "AudioLowPassFilter": UnityAudioLowPassFilter,
	# "AudioManager": UnityAudioManager,
	# "AudioMixer": UnityAudioMixer,
	# "AudioMixerController": UnityAudioMixerController,
	# "AudioMixerEffectController": UnityAudioMixerEffectController,
	# "AudioMixerGroup": UnityAudioMixerGroup,
	# "AudioMixerGroupController": UnityAudioMixerGroupController,
	# "AudioMixerLiveUpdateBool": UnityAudioMixerLiveUpdateBool,
	# "AudioMixerLiveUpdateFloat": UnityAudioMixerLiveUpdateFloat,
	# "AudioMixerSnapshot": UnityAudioMixerSnapshot,
	# "AudioMixerSnapshotController": UnityAudioMixerSnapshotController,
	# "AudioReverbFilter": UnityAudioReverbFilter,
	# "AudioReverbZone": UnityAudioReverbZone,
	# "AudioSource": UnityAudioSource,
	# "Avatar": UnityAvatar,
	# "AvatarMask": UnityAvatarMask,
	# "BaseAnimationTrack": UnityBaseAnimationTrack,
	# "BaseVideoTexture": UnityBaseVideoTexture,
	"Behaviour": UnityBehaviour,
	# "BillboardAsset": UnityBillboardAsset,
	# "BillboardRenderer": UnityBillboardRenderer,
	# "BlendTree": UnityBlendTree,
	"BoxCollider": UnityBoxCollider,
	# "BoxCollider2D": UnityBoxCollider2D,
	# "BuildReport": UnityBuildReport,
	# "BuildSettings": UnityBuildSettings,
	# "BuiltAssetBundleInfoSet": UnityBuiltAssetBundleInfoSet,
	# "BuoyancyEffector2D": UnityBuoyancyEffector2D,
	# "CachedSpriteAtlas": UnityCachedSpriteAtlas,
	# "CachedSpriteAtlasRuntimeData": UnityCachedSpriteAtlasRuntimeData,
	# "Camera": UnityCamera,
	# "Canvas": UnityCanvas,
	# "CanvasGroup": UnityCanvasGroup,
	# "CanvasRenderer": UnityCanvasRenderer,
	"CapsuleCollider": UnityCapsuleCollider,
	# "CapsuleCollider2D": UnityCapsuleCollider2D,
	# "CGProgram": UnityCGProgram,
	# "CharacterController": UnityCharacterController,
	# "CharacterJoint": UnityCharacterJoint,
	# "CircleCollider2D": UnityCircleCollider2D,
	"Cloth": UnityCloth,
	# "ClusterInputManager": UnityClusterInputManager,
	"Collider": UnityCollider,
	# "Collider2D": UnityCollider2D,
	# "Collision": UnityCollision,
	# "Collision2D": UnityCollision2D,
	"Component": UnityComponent,
	# "CompositeCollider2D": UnityCompositeCollider2D,
	# "ComputeShader": UnityComputeShader,
	# "ComputeShaderImporter": UnityComputeShaderImporter,
	# "ConfigurableJoint": UnityConfigurableJoint,
	# "ConstantForce": UnityConstantForce,
	# "ConstantForce2D": UnityConstantForce2D,
	"Cubemap": UnityCubemap,
	"CubemapArray": UnityCubemapArray,
	"CustomRenderTexture": UnityCustomRenderTexture,
	# "DefaultAsset": UnityDefaultAsset,
	"DefaultImporter": UnityDefaultImporter,
	# "DelayedCallManager": UnityDelayedCallManager,
	# "Derived": UnityDerived,
	# "DistanceJoint2D": UnityDistanceJoint2D,
	# "EdgeCollider2D": UnityEdgeCollider2D,
	# "EditorBuildSettings": UnityEditorBuildSettings,
	# "EditorExtension": UnityEditorExtension,
	# "EditorExtensionImpl": UnityEditorExtensionImpl,
	# "EditorProjectAccess": UnityEditorProjectAccess,
	# "EditorSettings": UnityEditorSettings,
	# "EditorUserBuildSettings": UnityEditorUserBuildSettings,
	# "EditorUserSettings": UnityEditorUserSettings,
	# "Effector2D": UnityEffector2D,
	# "EmptyObject": UnityEmptyObject,
	# "FakeComponent": UnityFakeComponent,
	# "FBXImporter": UnityFBXImporter,
	# "FixedJoint": UnityFixedJoint,
	# "FixedJoint2D": UnityFixedJoint2D,
	# "Flare": UnityFlare,
	# "FlareLayer": UnityFlareLayer,
	# "float": Unityfloat,
	# "Font": UnityFont,
	# "FrictionJoint2D": UnityFrictionJoint2D,
	# "GameManager": UnityGameManager,
	"GameObject": UnityGameObject,
	# "GameObjectRecorder": UnityGameObjectRecorder,
	# "GlobalGameManager": UnityGlobalGameManager,
	# "GraphicsSettings": UnityGraphicsSettings,
	# "Grid": UnityGrid,
	# "GridLayout": UnityGridLayout,
	# "Halo": UnityHalo,
	# "HaloLayer": UnityHaloLayer,
	# "HierarchyState": UnityHierarchyState,
	# "HingeJoint": UnityHingeJoint,
	# "HingeJoint2D": UnityHingeJoint2D,
	# "HumanTemplate": UnityHumanTemplate,
	# "IConstraint": UnityIConstraint,
	# "IHVImageFormatImporter": UnityIHVImageFormatImporter,
	# "InputManager": UnityInputManager,
	# "InspectorExpandedState": UnityInspectorExpandedState,
	# "Joint": UnityJoint,
	# "Joint2D": UnityJoint2D,
	# "LensFlare": UnityLensFlare,
	# "LevelGameManager": UnityLevelGameManager,
	# "LibraryAssetImporter": UnityLibraryAssetImporter,
	"Light": UnityLight,
	# "LightingDataAsset": UnityLightingDataAsset,
	# "LightingDataAssetParent": UnityLightingDataAssetParent,
	# "LightmapParameters": UnityLightmapParameters,
	# "LightmapSettings": UnityLightmapSettings,
	# "LightProbeGroup": UnityLightProbeGroup,
	# "LightProbeProxyVolume": UnityLightProbeProxyVolume,
	# "LightProbes": UnityLightProbes,
	# "LineRenderer": UnityLineRenderer,
	# "LocalizationAsset": UnityLocalizationAsset,
	# "LocalizationImporter": UnityLocalizationImporter,
	# "LODGroup": UnityLODGroup,
	# "LookAtConstraint": UnityLookAtConstraint,
	# "LowerResBlitTexture": UnityLowerResBlitTexture,
	"Material": UnityMaterial,
	"Mesh": UnityMesh,
	# "Mesh3DSImporter": UnityMesh3DSImporter,
	"MeshCollider": UnityMeshCollider,
	"MeshFilter": UnityMeshFilter,
	"MeshRenderer": UnityMeshRenderer,
	"ModelImporter": UnityModelImporter,
	# "MonoBehaviour": UnityMonoBehaviour,
	# "MonoImporter": UnityMonoImporter,
	# "MonoManager": UnityMonoManager,
	# "MonoObject": UnityMonoObject,
	# "MonoScript": UnityMonoScript,
	# "Motion": UnityMotion,
	# "NamedObject": UnityNamedObject,
	"NativeFormatImporter": UnityNativeFormatImporter,
	# "NativeObjectType": UnityNativeObjectType,
	# "NavMeshAgent": UnityNavMeshAgent,
	# "NavMeshData": UnityNavMeshData,
	# "NavMeshObstacle": UnityNavMeshObstacle,
	# "NavMeshProjectSettings": UnityNavMeshProjectSettings,
	# "NavMeshSettings": UnityNavMeshSettings,
	# "NewAnimationTrack": UnityNewAnimationTrack,
	"Object": UnityObject,
	# "OcclusionArea": UnityOcclusionArea,
	# "OcclusionCullingData": UnityOcclusionCullingData,
	# "OcclusionCullingSettings": UnityOcclusionCullingSettings,
	# "OcclusionPortal": UnityOcclusionPortal,
	# "OffMeshLink": UnityOffMeshLink,
	# "PackageManifest": UnityPackageManifest,
	# "PackageManifestImporter": UnityPackageManifestImporter,
	# "PackedAssets": UnityPackedAssets,
	# "ParentConstraint": UnityParentConstraint,
	# "ParticleSystem": UnityParticleSystem,
	# "ParticleSystemForceField": UnityParticleSystemForceField,
	# "ParticleSystemRenderer": UnityParticleSystemRenderer,
	# "PhysicMaterial": UnityPhysicMaterial,
	# "Physics2DSettings": UnityPhysics2DSettings,
	# "PhysicsManager": UnityPhysicsManager,
	# "PhysicsMaterial2D": UnityPhysicsMaterial2D,
	# "PhysicsUpdateBehaviour2D": UnityPhysicsUpdateBehaviour2D,
	# "PlatformEffector2D": UnityPlatformEffector2D,
	# "PlatformModuleSetup": UnityPlatformModuleSetup,
	# "PlayableDirector": UnityPlayableDirector,
	# "PlayerSettings": UnityPlayerSettings,
	# "PluginBuildInfo": UnityPluginBuildInfo,
	# "PluginImporter": UnityPluginImporter,
	# "PointEffector2D": UnityPointEffector2D,
	# "Polygon2D": UnityPolygon2D,
	# "PolygonCollider2D": UnityPolygonCollider2D,
	# "PositionConstraint": UnityPositionConstraint,
	"Prefab": UnityPrefabLegacyUnused,
	"PrefabImporter": UnityPrefabImporter,
	"PrefabInstance": UnityPrefabInstance,
	# "PreloadData": UnityPreloadData,
	# "Preset": UnityPreset,
	# "PresetManager": UnityPresetManager,
	# "Projector": UnityProjector,
	# "QualitySettings": UnityQualitySettings,
	# "RayTracingShader": UnityRayTracingShader,
	# "RayTracingShaderImporter": UnityRayTracingShaderImporter,
	"RectTransform": UnityRectTransform,
	# "ReferencesArtifactGenerator": UnityReferencesArtifactGenerator,
	# "ReflectionProbe": UnityReflectionProbe,
	# "RelativeJoint2D": UnityRelativeJoint2D,
	"Renderer": UnityRenderer,
	# "RendererFake": UnityRendererFake,
	# "RenderSettings": UnityRenderSettings,
	"RenderTexture": UnityRenderTexture,
	# "ResourceManager": UnityResourceManager,
	"Rigidbody": UnityRigidbody,
	# "Rigidbody2D": UnityRigidbody2D,
	# "RootMotionData": UnityRootMotionData,
	# "RotationConstraint": UnityRotationConstraint,
	# "RuntimeAnimatorController": UnityRuntimeAnimatorController,
	# "RuntimeInitializeOnLoadManager": UnityRuntimeInitializeOnLoadManager,
	# "SampleClip": UnitySampleClip,
	# "ScaleConstraint": UnityScaleConstraint,
	# "SceneAsset": UnitySceneAsset,
	# "SceneVisibilityState": UnitySceneVisibilityState,
	# "ScriptedImporter": UnityScriptedImporter,
	# "ScriptMapper": UnityScriptMapper,
	# "SerializableManagedHost": UnitySerializableManagedHost,
	# "Shader": UnityShader,
	"ShaderImporter": UnityShaderImporter,
	# "ShaderVariantCollection": UnityShaderVariantCollection,
	# "SiblingDerived": UnitySiblingDerived,
	# "SketchUpImporter": UnitySketchUpImporter,
	"SkinnedMeshRenderer": UnitySkinnedMeshRenderer,
	# "Skybox": UnitySkybox,
	# "SliderJoint2D": UnitySliderJoint2D,
	# "SortingGroup": UnitySortingGroup,
	# "SparseTexture": UnitySparseTexture,
	# "SpeedTreeImporter": UnitySpeedTreeImporter,
	# "SpeedTreeWindAsset": UnitySpeedTreeWindAsset,
	"SphereCollider": UnitySphereCollider,
	# "SpringJoint": UnitySpringJoint,
	# "SpringJoint2D": UnitySpringJoint2D,
	# "Sprite": UnitySprite,
	# "SpriteAtlas": UnitySpriteAtlas,
	# "SpriteAtlasDatabase": UnitySpriteAtlasDatabase,
	# "SpriteMask": UnitySpriteMask,
	# "SpriteRenderer": UnitySpriteRenderer,
	# "SpriteShapeRenderer": UnitySpriteShapeRenderer,
	# "StreamingController": UnityStreamingController,
	# "StreamingManager": UnityStreamingManager,
	# "SubDerived": UnitySubDerived,
	# "SubstanceArchive": UnitySubstanceArchive,
	# "SubstanceImporter": UnitySubstanceImporter,
	# "SurfaceEffector2D": UnitySurfaceEffector2D,
	# "TagManager": UnityTagManager,
	# "TargetJoint2D": UnityTargetJoint2D,
	# "Terrain": UnityTerrain,
	# "TerrainCollider": UnityTerrainCollider,
	# "TerrainData": UnityTerrainData,
	# "TerrainLayer": UnityTerrainLayer,
	# "TextAsset": UnityTextAsset,
	# "TextMesh": UnityTextMesh,
	"TextScriptImporter": UnityTextScriptImporter,
	"Texture": UnityTexture,
	"Texture2D": UnityTexture2D,
	"Texture2DArray": UnityTexture2DArray,
	"Texture3D": UnityTexture3D,
	"TextureImporter": UnityTextureImporter,
	# "Tilemap": UnityTilemap,
	# "TilemapCollider2D": UnityTilemapCollider2D,
	# "TilemapRenderer": UnityTilemapRenderer,
	# "TimeManager": UnityTimeManager,
	# "TrailRenderer": UnityTrailRenderer,
	"Transform": UnityTransform,
	# "Tree": UnityTree,
	"TrueTypeFontImporter": UnityTrueTypeFontImporter,
	# "UnityConnectSettings": UnityUnityConnectSettings,
	# "Vector3f": UnityVector3f,
	# "VFXManager": UnityVFXManager,
	# "VFXRenderer": UnityVFXRenderer,
	# "VideoClip": UnityVideoClip,
	# "VideoClipImporter": UnityVideoClipImporter,
	# "VideoPlayer": UnityVideoPlayer,
	# "VisualEffect": UnityVisualEffect,
	# "VisualEffectAsset": UnityVisualEffectAsset,
	# "VisualEffectImporter": UnityVisualEffectImporter,
	# "VisualEffectObject": UnityVisualEffectObject,
	# "VisualEffectResource": UnityVisualEffectResource,
	# "VisualEffectSubgraph": UnityVisualEffectSubgraph,
	# "VisualEffectSubgraphBlock": UnityVisualEffectSubgraphBlock,
	# "VisualEffectSubgraphOperator": UnityVisualEffectSubgraphOperator,
	# "WebCamTexture": UnityWebCamTexture,
	# "WheelCollider": UnityWheelCollider,
	# "WheelJoint2D": UnityWheelJoint2D,
	# "WindZone": UnityWindZone,
	# "WorldAnchor": UnityWorldAnchor,
}

var utype_to_classname = {
	0: "Object",
	1: "GameObject",
	2: "Component",
	3: "LevelGameManager",
	4: "Transform",
	5: "TimeManager",
	6: "GlobalGameManager",
	8: "Behaviour",
	9: "GameManager",
	11: "AudioManager",
	13: "InputManager",
	18: "EditorExtension",
	19: "Physics2DSettings",
	20: "Camera",
	21: "Material",
	23: "MeshRenderer",
	25: "Renderer",
	27: "Texture",
	28: "Texture2D",
	29: "OcclusionCullingSettings",
	30: "GraphicsSettings",
	33: "MeshFilter",
	41: "OcclusionPortal",
	43: "Mesh",
	45: "Skybox",
	47: "QualitySettings",
	48: "Shader",
	49: "TextAsset",
	50: "Rigidbody2D",
	53: "Collider2D",
	54: "Rigidbody",
	55: "PhysicsManager",
	56: "Collider",
	57: "Joint",
	58: "CircleCollider2D",
	59: "HingeJoint",
	60: "PolygonCollider2D",
	61: "BoxCollider2D",
	62: "PhysicsMaterial2D",
	64: "MeshCollider",
	65: "BoxCollider",
	66: "CompositeCollider2D",
	68: "EdgeCollider2D",
	70: "CapsuleCollider2D",
	72: "ComputeShader",
	74: "AnimationClip",
	75: "ConstantForce",
	78: "TagManager",
	81: "AudioListener",
	82: "AudioSource",
	83: "AudioClip",
	84: "RenderTexture",
	86: "CustomRenderTexture",
	89: "Cubemap",
	90: "Avatar",
	91: "AnimatorController",
	93: "RuntimeAnimatorController",
	94: "ScriptMapper",
	95: "Animator",
	96: "TrailRenderer",
	98: "DelayedCallManager",
	102: "TextMesh",
	104: "RenderSettings",
	108: "Light",
	109: "CGProgram",
	110: "BaseAnimationTrack",
	111: "Animation",
	114: "MonoBehaviour",
	115: "MonoScript",
	116: "MonoManager",
	117: "Texture3D",
	118: "NewAnimationTrack",
	119: "Projector",
	120: "LineRenderer",
	121: "Flare",
	122: "Halo",
	123: "LensFlare",
	124: "FlareLayer",
	125: "HaloLayer",
	126: "NavMeshProjectSettings",
	128: "Font",
	129: "PlayerSettings",
	130: "NamedObject",
	134: "PhysicMaterial",
	135: "SphereCollider",
	136: "CapsuleCollider",
	137: "SkinnedMeshRenderer",
	138: "FixedJoint",
	141: "BuildSettings",
	142: "AssetBundle",
	143: "CharacterController",
	144: "CharacterJoint",
	145: "SpringJoint",
	146: "WheelCollider",
	147: "ResourceManager",
	150: "PreloadData",
	153: "ConfigurableJoint",
	154: "TerrainCollider",
	156: "TerrainData",
	157: "LightmapSettings",
	158: "WebCamTexture",
	159: "EditorSettings",
	162: "EditorUserSettings",
	164: "AudioReverbFilter",
	165: "AudioHighPassFilter",
	166: "AudioChorusFilter",
	167: "AudioReverbZone",
	168: "AudioEchoFilter",
	169: "AudioLowPassFilter",
	170: "AudioDistortionFilter",
	171: "SparseTexture",
	180: "AudioBehaviour",
	181: "AudioFilter",
	182: "WindZone",
	183: "Cloth",
	184: "SubstanceArchive",
	185: "ProceduralMaterial",
	186: "ProceduralTexture",
	187: "Texture2DArray",
	188: "CubemapArray",
	191: "OffMeshLink",
	192: "OcclusionArea",
	193: "Tree",
	195: "NavMeshAgent",
	196: "NavMeshSettings",
	198: "ParticleSystem",
	199: "ParticleSystemRenderer",
	200: "ShaderVariantCollection",
	205: "LODGroup",
	206: "BlendTree",
	207: "Motion",
	208: "NavMeshObstacle",
	210: "SortingGroup",
	212: "SpriteRenderer",
	213: "Sprite",
	214: "CachedSpriteAtlas",
	215: "ReflectionProbe",
	218: "Terrain",
	220: "LightProbeGroup",
	221: "AnimatorOverrideController",
	222: "CanvasRenderer",
	223: "Canvas",
	224: "RectTransform",
	225: "CanvasGroup",
	226: "BillboardAsset",
	227: "BillboardRenderer",
	228: "SpeedTreeWindAsset",
	229: "AnchoredJoint2D",
	230: "Joint2D",
	231: "SpringJoint2D",
	232: "DistanceJoint2D",
	233: "HingeJoint2D",
	234: "SliderJoint2D",
	235: "WheelJoint2D",
	236: "ClusterInputManager",
	237: "BaseVideoTexture",
	238: "NavMeshData",
	240: "AudioMixer",
	241: "AudioMixerController",
	243: "AudioMixerGroupController",
	244: "AudioMixerEffectController",
	245: "AudioMixerSnapshotController",
	246: "PhysicsUpdateBehaviour2D",
	247: "ConstantForce2D",
	248: "Effector2D",
	249: "AreaEffector2D",
	250: "PointEffector2D",
	251: "PlatformEffector2D",
	252: "SurfaceEffector2D",
	253: "BuoyancyEffector2D",
	254: "RelativeJoint2D",
	255: "FixedJoint2D",
	256: "FrictionJoint2D",
	257: "TargetJoint2D",
	258: "LightProbes",
	259: "LightProbeProxyVolume",
	271: "SampleClip",
	272: "AudioMixerSnapshot",
	273: "AudioMixerGroup",
	290: "AssetBundleManifest",
	300: "RuntimeInitializeOnLoadManager",
	310: "UnityConnectSettings",
	319: "AvatarMask",
	320: "PlayableDirector",
	328: "VideoPlayer",
	329: "VideoClip",
	330: "ParticleSystemForceField",
	331: "SpriteMask",
	362: "WorldAnchor",
	363: "OcclusionCullingData",
	1001: "PrefabInstance",
	1002: "EditorExtensionImpl",
	1003: "AssetImporter",
	1004: "AssetDatabaseV1",
	1005: "Mesh3DSImporter",
	1006: "TextureImporter",
	1007: "ShaderImporter",
	1008: "ComputeShaderImporter",
	1020: "AudioImporter",
	1026: "HierarchyState",
	1028: "AssetMetaData",
	1029: "DefaultAsset",
	1030: "DefaultImporter",
	1031: "TextScriptImporter",
	1032: "SceneAsset",
	1034: "NativeFormatImporter",
	1035: "MonoImporter",
	1038: "LibraryAssetImporter",
	1040: "ModelImporter",
	1041: "FBXImporter",
	1042: "TrueTypeFontImporter",
	1045: "EditorBuildSettings",
	1048: "InspectorExpandedState",
	1049: "AnnotationManager",
	1050: "PluginImporter",
	1051: "EditorUserBuildSettings",
	1055: "IHVImageFormatImporter",
	1101: "AnimatorStateTransition",
	1102: "AnimatorState",
	1105: "HumanTemplate",
	1107: "AnimatorStateMachine",
	1108: "PreviewAnimationClip",
	1109: "AnimatorTransition",
	1110: "SpeedTreeImporter",
	1111: "AnimatorTransitionBase",
	1112: "SubstanceImporter",
	1113: "LightmapParameters",
	1120: "LightingDataAsset",
	1124: "SketchUpImporter",
	1125: "BuildReport",
	1126: "PackedAssets",
	1127: "VideoClipImporter",
	100000: "int",
	100001: "bool",
	100002: "float",
	100003: "MonoObject",
	100004: "Collision",
	100005: "Vector3f",
	100006: "RootMotionData",
	100007: "Collision2D",
	100008: "AudioMixerLiveUpdateFloat",
	100009: "AudioMixerLiveUpdateBool",
	100010: "Polygon2D",
	100011: "void",
	19719996: "TilemapCollider2D",
	41386430: "AssetImporterLog",
	73398921: "VFXRenderer",
	156049354: "Grid",
	181963792: "Preset",
	277625683: "EmptyObject",
	285090594: "IConstraint",
	294290339: "AssemblyDefinitionReferenceImporter",
	334799969: "SiblingDerived",
	367388927: "SubDerived",
	369655926: "AssetImportInProgressProxy",
	382020655: "PluginBuildInfo",
	426301858: "EditorProjectAccess",
	468431735: "PrefabImporter",
	483693784: "TilemapRenderer",
	638013454: "SpriteAtlasDatabase",
	641289076: "AudioBuildInfo",
	644342135: "CachedSpriteAtlasRuntimeData",
	646504946: "RendererFake",
	662584278: "AssemblyDefinitionReferenceAsset",
	668709126: "BuiltAssetBundleInfoSet",
	687078895: "SpriteAtlas",
	747330370: "RayTracingShaderImporter",
	825902497: "RayTracingShader",
	877146078: "PlatformModuleSetup",
	895512359: "AimConstraint",
	937362698: "VFXManager",
	994735392: "VisualEffectSubgraph",
	994735403: "VisualEffectSubgraphOperator",
	994735404: "VisualEffectSubgraphBlock",
	1001480554: "Prefab",
	1027052791: "LocalizationImporter",
	1091556383: "Derived",
	1114811875: "ReferencesArtifactGenerator",
	1152215463: "AssemblyDefinitionAsset",
	1154873562: "SceneVisibilityState",
	1183024399: "LookAtConstraint",
	1268269756: "GameObjectRecorder",
	1325145578: "LightingDataAssetParent",
	1386491679: "PresetManager",
	1403656975: "StreamingManager",
	1480428607: "LowerResBlitTexture",
	1542919678: "StreamingController",
	1742807556: "GridLayout",
	1766753193: "AssemblyDefinitionImporter",
	1773428102: "ParentConstraint",
	1803986026: "FakeComponent",
	1818360608: "PositionConstraint",
	1818360609: "RotationConstraint",
	1818360610: "ScaleConstraint",
	1839735485: "Tilemap",
	1896753125: "PackageManifest",
	1896753126: "PackageManifestImporter",
	1953259897: "TerrainLayer",
	1971053207: "SpriteShapeRenderer",
	1977754360: "NativeObjectType",
	1995898324: "SerializableManagedHost",
	2058629509: "VisualEffectAsset",
	2058629510: "VisualEffectImporter",
	2058629511: "VisualEffectResource",
	2059678085: "VisualEffectObject",
	2083052967: "VisualEffect",
	2083778819: "LocalizationAsset",
	208985858483: "ScriptedImporter",
}

func invert_hashtable(ht: Dictionary) -> Dictionary:
	var outd: Dictionary = Dictionary()
	for key in ht:
		outd[ht[key]] = key
	return outd

var classname_to_utype: Dictionary = invert_hashtable(utype_to_classname)

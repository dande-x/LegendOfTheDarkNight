import argparse
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

argv = sys.argv
if "--" in argv:
    argv = argv[argv.index("--") + 1:]
else:
    argv = []

parser = argparse.ArgumentParser()
parser.add_argument("--input", required=True)
parser.add_argument("--out", required=True)
args = parser.parse_args(argv)

in_path = Path(args.input)
out_path = Path(args.out)
out_path.parent.mkdir(parents=True, exist_ok=True)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()

bpy.ops.import_scene.gltf(filepath=str(in_path))
mesh_objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not mesh_objs:
    raise RuntimeError("no mesh imported")

# Merge imported mesh objects to keep export simple.
bpy.ops.object.select_all(action="DESELECT")
for obj in mesh_objs:
    obj.select_set(True)
bpy.context.view_layer.objects.active = mesh_objs[0]
if len(mesh_objs) > 1:
    bpy.ops.object.join()
mesh = bpy.context.view_layer.objects.active
mesh.name = "DeerRiggedMesh"
mesh.data.name = "DeerRiggedMeshData"

# Normalize transform, keep model around 1.8m high. Imported deer bbox is centered around origin.
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

bbox = [mesh.matrix_world @ Vector(corner) for corner in mesh.bound_box]
min_x, max_x = min(v.x for v in bbox), max(v.x for v in bbox)
min_y, max_y = min(v.y for v in bbox), max(v.y for v in bbox)
min_z, max_z = min(v.z for v in bbox), max(v.z for v in bbox)
center = Vector(((min_x + max_x) * 0.5, (min_y + max_y) * 0.5, (min_z + max_z) * 0.5))
mesh.location -= center
bpy.context.view_layer.update()

# Recompute local bbox after recenter.
bbox = [mesh.matrix_world @ Vector(corner) for corner in mesh.bound_box]
min_x, max_x = min(v.x for v in bbox), max(v.x for v in bbox)
min_y, max_y = min(v.y for v in bbox), max(v.y for v in bbox)
min_z, max_z = min(v.z for v in bbox), max(v.z for v in bbox)
size_x, size_y, size_z = max_x - min_x, max_y - min_y, max_z - min_z

# In Blender import, deer visual length is mostly X, height is Z. Build a quadruped skeleton.
def p(x, y, z):
    return Vector((x, y, z))

z_ground = min_z
z_body = min_z + size_z * 0.52
z_head = min_z + size_z * 0.70
front_x = max_x - size_x * 0.22
back_x = min_x + size_x * 0.22
neck_x = max_x - size_x * 0.12
head_x = max_x - size_x * 0.02
leg_y = size_y * 0.23

bpy.ops.object.armature_add(enter_editmode=True, align="WORLD", location=(0, 0, 0))
arm = bpy.context.object
arm.name = "DeerArmature"
arm.data.name = "DeerArmatureData"
arm.show_in_front = False
edit_bones = arm.data.edit_bones
root = edit_bones[0]
root.name = "Root"
root.head = p(0, 0, z_ground)
root.tail = p(0, 0, z_body)

body = edit_bones.new("Body")
body.parent = root
body.head = p(back_x, 0, z_body)
body.tail = p(front_x, 0, z_body)

neck = edit_bones.new("Neck")
neck.parent = body
neck.head = p(front_x, 0, z_body + size_z * 0.05)
neck.tail = p(neck_x, 0, z_head)

head = edit_bones.new("Head")
head.parent = neck
head.head = p(neck_x, 0, z_head)
head.tail = p(head_x + size_x * 0.08, 0, z_head + size_z * 0.02)

tail = edit_bones.new("Tail")
tail.parent = body
tail.head = p(back_x, 0, z_body)
tail.tail = p(min_x - size_x * 0.10, 0, z_body + size_z * 0.02)

leg_specs = [
    ("L_Front", front_x, leg_y),
    ("R_Front", front_x, -leg_y),
    ("L_Back", back_x, leg_y),
    ("R_Back", back_x, -leg_y),
]
for prefix, x, y in leg_specs:
    upper = edit_bones.new(prefix + "_Upper")
    upper.parent = body
    upper.head = p(x, y, z_body - size_z * 0.08)
    upper.tail = p(x, y, z_ground + size_z * 0.22)
    lower = edit_bones.new(prefix + "_Lower")
    lower.parent = upper
    lower.head = upper.tail
    lower.tail = p(x + (0.04 if "Front" in prefix else -0.04), y, z_ground + size_z * 0.03)

bpy.ops.object.mode_set(mode="OBJECT")

# Parent with automatic weights. This is imperfect but enough to create a real skinned quadruped asset.
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.parent_set(type="ARMATURE_AUTO")

# Create walk and idle actions.
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = 40
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")

def set_rot(frame, bone_name, rx=0, ry=0, rz=0):
    pb = arm.pose.bones.get(bone_name)
    if not pb:
        return
    pb.rotation_mode = "XYZ"
    pb.rotation_euler = (math.radians(rx), math.radians(ry), math.radians(rz))
    pb.keyframe_insert(data_path="rotation_euler", frame=frame)

walk = bpy.data.actions.new("deer_walk")
arm.animation_data_create()
arm.animation_data.action = walk
for frame, phase in [(1, 1), (10, -1), (20, 1), (30, -1), (40, 1)]:
    swing = 22 * phase
    counter = -22 * phase
    set_rot(frame, "L_Front_Upper", 0, swing, 0)
    set_rot(frame, "R_Back_Upper", 0, swing, 0)
    set_rot(frame, "R_Front_Upper", 0, counter, 0)
    set_rot(frame, "L_Back_Upper", 0, counter, 0)
    set_rot(frame, "L_Front_Lower", 0, -14 * phase, 0)
    set_rot(frame, "R_Back_Lower", 0, -14 * phase, 0)
    set_rot(frame, "R_Front_Lower", 0, 14 * phase, 0)
    set_rot(frame, "L_Back_Lower", 0, 14 * phase, 0)
    set_rot(frame, "Body", 0, 0, 2 * phase)
    set_rot(frame, "Neck", 0, 4 * phase, 0)

idle = bpy.data.actions.new("deer_idle")
arm.animation_data.action = idle
for frame, phase in [(1, 1), (30, -1), (60, 1)]:
    set_rot(frame, "Neck", 0, 2 * phase, 0)
    set_rot(frame, "Head", 0, 2 * phase, 0)
    set_rot(frame, "Tail", 0, 0, 5 * phase)

bpy.ops.object.mode_set(mode="OBJECT")

# Save blend for inspection, then export FBX with mesh, armature and actions.
bpy.ops.wm.save_as_mainfile(filepath=str(out_path.with_suffix(".blend")))
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.fbx(
    filepath=str(out_path),
    use_selection=True,
    add_leaf_bones=False,
    bake_anim=True,
    bake_anim_use_all_actions=True,
    bake_anim_use_nla_strips=False,
    bake_anim_simplify_factor=0.0,
    object_types={"ARMATURE", "MESH"},
)
print(f"[deer-rig] wrote {out_path}")

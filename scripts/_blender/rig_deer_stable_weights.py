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

bpy.ops.object.select_all(action="DESELECT")
for obj in mesh_objs:
    obj.select_set(True)
bpy.context.view_layer.objects.active = mesh_objs[0]
if len(mesh_objs) > 1:
    bpy.ops.object.join()
mesh = bpy.context.view_layer.objects.active
mesh.name = "DeerStableRigMesh"
mesh.data.name = "DeerStableRigMeshData"
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

bbox = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
center = Vector(((min(v.x for v in bbox) + max(v.x for v in bbox)) * 0.5,
                 (min(v.y for v in bbox) + max(v.y for v in bbox)) * 0.5,
                 (min(v.z for v in bbox) + max(v.z for v in bbox)) * 0.5))
mesh.location -= center
bpy.context.view_layer.update()
bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)

bbox = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
min_x, max_x = min(v.x for v in bbox), max(v.x for v in bbox)
min_y, max_y = min(v.y for v in bbox), max(v.y for v in bbox)
min_z, max_z = min(v.z for v in bbox), max(v.z for v in bbox)
size_x, size_y, size_z = max_x - min_x, max_y - min_y, max_z - min_z

# Blender axes for this imported deer: X length, Y width, Z height.
def p(x, y, z):
    return Vector((x, y, z))

z_ground = min_z
z_body = min_z + size_z * 0.52
z_shoulder = min_z + size_z * 0.48
z_knee = min_z + size_z * 0.23
z_hoof = min_z + size_z * 0.03
front_x = max_x - size_x * 0.25
back_x = min_x + size_x * 0.25
mid_x = (min_x + max_x) * 0.5
neck_x = max_x - size_x * 0.13
head_x = max_x - size_x * 0.02
z_head = min_z + size_z * 0.70
leg_y = size_y * 0.24

# Create armature.
bpy.ops.object.armature_add(enter_editmode=True, align="WORLD", location=(0, 0, 0))
arm = bpy.context.object
arm.name = "DeerStableArmature"
arm.data.name = "DeerStableArmatureData"
edit_bones = arm.data.edit_bones
root = edit_bones[0]
root.name = "Root"
root.head = p(mid_x, 0, z_ground)
root.tail = p(mid_x, 0, z_body)

body = edit_bones.new("Body")
body.parent = root
body.head = p(back_x, 0, z_body)
body.tail = p(front_x, 0, z_body)

neck = edit_bones.new("Neck")
neck.parent = body
neck.head = p(front_x, 0, z_body + size_z * 0.04)
neck.tail = p(neck_x, 0, z_head)

head = edit_bones.new("Head")
head.parent = neck
head.head = neck.tail
head.tail = p(max_x + size_x * 0.08, 0, z_head + size_z * 0.02)

tail = edit_bones.new("Tail")
tail.parent = body
tail.head = p(back_x, 0, z_body)
tail.tail = p(min_x - size_x * 0.10, 0, z_body)

leg_defs = [
    ("L_Front", front_x, leg_y),
    ("R_Front", front_x, -leg_y),
    ("L_Back", back_x, leg_y),
    ("R_Back", back_x, -leg_y),
]
for name, x, y in leg_defs:
    upper = edit_bones.new(name + "_Upper")
    upper.parent = body
    upper.head = p(x, y, z_shoulder)
    upper.tail = p(x, y, z_knee)
    lower = edit_bones.new(name + "_Lower")
    lower.parent = upper
    lower.head = upper.tail
    lower.tail = p(x, y, z_hoof)

bpy.ops.object.mode_set(mode="OBJECT")

# Add armature modifier and deterministic vertex groups.
for mod in list(mesh.modifiers):
    mesh.modifiers.remove(mod)
arm_mod = mesh.modifiers.new("DeerStableArmature", "ARMATURE")
arm_mod.object = arm

bone_names = ["Root", "Body", "Neck", "Head", "Tail",
              "L_Front_Upper", "L_Front_Lower", "R_Front_Upper", "R_Front_Lower",
              "L_Back_Upper", "L_Back_Lower", "R_Back_Upper", "R_Back_Lower"]
for name in bone_names:
    if mesh.vertex_groups.get(name) is None:
        mesh.vertex_groups.new(name=name)

# Clear existing groups.
for v in mesh.data.vertices:
    for g in list(v.groups):
        pass
for group in mesh.vertex_groups:
    try:
        group.remove(range(len(mesh.data.vertices)))
    except Exception:
        pass

def add_weight(v_index, group_name, weight):
    mesh.vertex_groups[group_name].add([v_index], max(0.0, min(1.0, weight)), "ADD")

def smoothstep(edge0, edge1, x):
    if edge0 == edge1:
        return 0.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)

# Rule weights by local-space regions. Use normalized x/y/z in mesh local coordinates.
for v in mesh.data.vertices:
    co = v.co
    nx = (co.x - min_x) / size_x if size_x > 0 else 0.5
    ny = (co.y - min_y) / size_y if size_y > 0 else 0.5
    nz = (co.z - min_z) / size_z if size_z > 0 else 0.5

    # Head / neck / tail priority.
    if nx > 0.78 and nz > 0.42:
        add_weight(v.index, "Head", 1.0)
        continue
    if nx > 0.64 and nz > 0.36:
        head_blend = smoothstep(0.72, 0.82, nx)
        add_weight(v.index, "Neck", 1.0 - head_blend)
        add_weight(v.index, "Head", head_blend)
        continue
    if nx < 0.16 and nz > 0.38:
        tail_blend = 1.0 - smoothstep(0.08, 0.18, nx)
        add_weight(v.index, "Tail", tail_blend)
        add_weight(v.index, "Body", 1.0 - tail_blend)
        continue

    # Leg regions: lower half, four corners. Upper/lower split by height.
    is_left = co.y >= 0
    front_score = smoothstep(0.52, 0.75, nx)
    back_score = 1.0 - smoothstep(0.25, 0.48, nx)
    side_score = smoothstep(0.54, 0.78, abs((co.y) / (size_y * 0.5 if size_y > 0 else 1)))
    leg_score = max(front_score, back_score) * side_score * (1.0 - smoothstep(0.46, 0.62, nz))

    if leg_score > 0.25:
        if front_score >= back_score:
            prefix = "L_Front" if is_left else "R_Front"
        else:
            prefix = "L_Back" if is_left else "R_Back"
        lower_blend = 1.0 - smoothstep(0.16, 0.34, nz)
        add_weight(v.index, prefix + "_Lower", lower_blend)
        add_weight(v.index, prefix + "_Upper", 1.0 - lower_blend)
        continue

    # Main torso.
    neck_blend = smoothstep(0.58, 0.72, nx) * smoothstep(0.35, 0.55, nz)
    tail_blend = (1.0 - smoothstep(0.12, 0.25, nx)) * smoothstep(0.35, 0.55, nz)
    body_w = max(0.0, 1.0 - neck_blend - tail_blend)
    add_weight(v.index, "Body", body_w)
    if neck_blend > 0:
        add_weight(v.index, "Neck", neck_blend)
    if tail_blend > 0:
        add_weight(v.index, "Tail", tail_blend)

# Parent mesh to armature object without changing weights.
mesh.parent = arm
mesh.matrix_parent_inverse = arm.matrix_world.inverted()

# Animations for future import/debug, even if game currently drives bones in Lua.
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
arm.animation_data_create()
walk = bpy.data.actions.new("deer_walk")
arm.animation_data.action = walk

def set_rot(frame, bone_name, rx=0, ry=0, rz=0):
    pb = arm.pose.bones.get(bone_name)
    if not pb:
        return
    pb.rotation_mode = "XYZ"
    pb.rotation_euler = (math.radians(rx), math.radians(ry), math.radians(rz))
    pb.keyframe_insert(data_path="rotation_euler", frame=frame)

for frame, phase in [(1, 1), (10, -1), (20, 1), (30, -1), (40, 1)]:
    set_rot(frame, "L_Front_Upper", 0, 22 * phase, 0)
    set_rot(frame, "R_Back_Upper", 0, 22 * phase, 0)
    set_rot(frame, "R_Front_Upper", 0, -22 * phase, 0)
    set_rot(frame, "L_Back_Upper", 0, -22 * phase, 0)
    set_rot(frame, "L_Front_Lower", 0, -12 * phase, 0)
    set_rot(frame, "R_Back_Lower", 0, -12 * phase, 0)
    set_rot(frame, "R_Front_Lower", 0, 12 * phase, 0)
    set_rot(frame, "L_Back_Lower", 0, 12 * phase, 0)
    set_rot(frame, "Body", 0, 0, 1.5 * phase)
    set_rot(frame, "Neck", 0, -3 * phase, 0)

idle = bpy.data.actions.new("deer_idle")
arm.animation_data.action = idle
for frame, phase in [(1, 1), (30, -1), (60, 1)]:
    set_rot(frame, "Body", 0, 0, 0.8 * phase)
    set_rot(frame, "Neck", 0, 1.5 * phase, 0)
    set_rot(frame, "Tail", 0, 0, 3 * phase)

bpy.ops.object.mode_set(mode="OBJECT")

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
    path_mode="COPY",
    embed_textures=True,
)
print(f"[deer-stable-rig] wrote {out_path}")

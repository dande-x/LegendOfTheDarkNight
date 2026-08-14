#!/usr/bin/env python3
"""Create one fully skinned UrhoX character model with authored profession clothing.

This is an offline project tool. It preserves the complete source new-model UMD2
skeleton/tail and adds a second skinned geometry whose vertices are weighted to the
same body bones. It does not call Maker or any generative service.
"""
from __future__ import annotations

import argparse
import math
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

# UMD2 vertex declarations used by the existing rigged character assets.
TYPE_VECTOR2 = 2
TYPE_VECTOR3 = 3
TYPE_VECTOR4 = 4
TYPE_UBYTE4 = 5
TYPE_UBYTE4_NORM = 6
SEM_POSITION = 0
SEM_NORMAL = 1
SEM_TANGENT = 3
SEM_TEXCOORD = 4
SEM_COLOR = 5
SEM_BLENDWEIGHTS = 6
SEM_BLENDINDICES = 7

ELEMENT_SIZE = {0: 4, 1: 4, 2: 8, 3: 12, 4: 16, 5: 4, 6: 4}


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def read(self, size: int) -> bytes:
        if self.offset + size > len(self.data):
            raise ValueError("unexpected end of UMD2")
        value = self.data[self.offset : self.offset + size]
        self.offset += size
        return value

    def u8(self) -> int:
        return self.read(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.read(4))[0]

    def f32(self) -> float:
        return struct.unpack("<f", self.read(4))[0]

    def string(self) -> str:
        end = self.data.find(b"\0", self.offset)
        if end < 0:
            raise ValueError("unterminated string in UMD2")
        value = self.data[self.offset:end].decode("utf-8")
        self.offset = end + 1
        return value


@dataclass
class VertexBufferRecord:
    blob: bytes
    vertex_count: int


@dataclass
class IndexBufferRecord:
    blob: bytes
    index_count: int


@dataclass
class Lod:
    distance: float
    primitive_type: int
    vb_ref: int
    ib_ref: int
    index_start: int
    index_count: int


@dataclass
class Geometry:
    bone_mapping: list[int]
    lods: list[Lod]


@dataclass
class Bone:
    name: str
    parent: int
    position: tuple[float, float, float]
    rotation: tuple[float, float, float, float]
    scale: tuple[float, float, float]


@dataclass
class SourceModel:
    magic: bytes
    vertex_buffers: list[VertexBufferRecord]
    index_buffers: list[IndexBufferRecord]
    geometries: list[Geometry]
    tail: bytes
    bones: list[Bone]
    bone_index: dict[str, int]


@dataclass
class V:
    p: tuple[float, float, float]
    n: tuple[float, float, float]
    uv: tuple[float, float]
    bone: int


class Mesh:
    def __init__(self):
        self.vertices: list[V] = []
        self.indices: list[int] = []

    def quad(self, points: Iterable[tuple[float, float, float]], normal, bone: int):
        p = list(points)
        base = len(self.vertices)
        for point, uv in zip(p, ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0))):
            self.vertices.append(V(point, normal, uv, bone))
        self.indices.extend((base, base + 1, base + 2, base, base + 2, base + 3))

    def box(self, center, half, bone: int):
        cx, cy, cz = center
        hx, hy, hz = half
        x0, x1 = cx - hx, cx + hx
        y0, y1 = cy - hy, cy + hy
        z0, z1 = cz - hz, cz + hz
        self.quad(((x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)), (0,0,1), bone)
        self.quad(((x1,y0,z0),(x0,y0,z0),(x0,y1,z0),(x1,y1,z0)), (0,0,-1), bone)
        self.quad(((x0,y0,z0),(x0,y0,z1),(x0,y1,z1),(x0,y1,z0)), (-1,0,0), bone)
        self.quad(((x1,y0,z1),(x1,y0,z0),(x1,y1,z0),(x1,y1,z1)), (1,0,0), bone)
        self.quad(((x0,y1,z1),(x1,y1,z1),(x1,y1,z0),(x0,y1,z0)), (0,1,0), bone)
        self.quad(((x0,y0,z0),(x1,y0,z0),(x1,y0,z1),(x0,y0,z1)), (0,-1,0), bone)

    def cylinder(self, center, radius: float, height: float, bone: int, segments: int = 12):
        cx, cy, cz = center
        hh = height * 0.5
        for i in range(segments):
            a0 = i * math.tau / segments
            a1 = (i + 1) * math.tau / segments
            c0, s0, c1, s1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
            n = norm((c0 + c1, 0.0, s0 + s1))
            self.quad(((cx+c0*radius,cy-hh,cz+s0*radius),
                       (cx+c1*radius,cy-hh,cz+s1*radius),
                       (cx+c1*radius,cy+hh,cz+s1*radius),
                       (cx+c0*radius,cy+hh,cz+s0*radius)), n, bone)


def norm(v):
    length = math.sqrt(sum(c * c for c in v)) or 1.0
    return tuple(c / length for c in v)


def parse_source(path: Path) -> SourceModel:
    data = path.read_bytes()
    r = Reader(data)
    magic = r.read(4)
    if magic != b"UMD2":
        raise ValueError(f"{path} is not UMD2")

    vertex_buffers = []
    for _ in range(r.u32()):
        start = r.offset
        vertex_count = r.u32()
        element_count = r.u32()
        stride = 0
        for _ in range(element_count):
            desc = r.u32()
            stride += ELEMENT_SIZE[desc & 0xff]
        r.read(8)
        r.read(vertex_count * stride)
        vertex_buffers.append(VertexBufferRecord(data[start:r.offset], vertex_count))

    index_buffers = []
    for _ in range(r.u32()):
        start = r.offset
        count = r.u32()
        size = r.u32()
        r.read(count * size)
        index_buffers.append(IndexBufferRecord(data[start:r.offset], count))

    geometries = []
    for _ in range(r.u32()):
        mapping = [r.u32() for _ in range(r.u32())]
        lods = []
        for _ in range(r.u32()):
            lods.append(Lod(r.f32(), r.u32(), r.u32(), r.u32(), r.u32(), r.u32()))
        geometries.append(Geometry(mapping, lods))

    tail_start = r.offset
    # Skip morph records to locate skeleton. Character models currently have zero morphs,
    # but fail loudly instead of corrupting an asset if that changes.
    morph_count = r.u32()
    if morph_count != 0:
        raise ValueError(f"source contains {morph_count} morphs; unsupported by this offline authoring tool")
    bone_count = r.u32()
    bones: list[Bone] = []
    for _ in range(bone_count):
        name = r.string()
        parent = r.u32()
        position = struct.unpack("<3f", r.read(12))
        rotation = struct.unpack("<4f", r.read(16))
        scale = struct.unpack("<3f", r.read(12))
        r.read(48)  # Matrix3x4 offset matrix
        collision_mask = r.u8()
        if collision_mask & 1:
            r.read(4)
        if collision_mask & 2:
            r.read(24)
        bones.append(Bone(name, parent, position, rotation, scale))

    return SourceModel(magic, vertex_buffers, index_buffers, geometries, data[tail_start:], bones,
                       {bone.name: i for i, bone in enumerate(bones)})


def add_piece(mesh: Mesh, source: SourceModel, kind: str, bone: str, center, size):
    index = source.bone_index.get(bone)
    if index is None:
        raise ValueError(f"required bone not found: {bone}")
    if kind == "box":
        mesh.box(center, size, index)
    elif kind == "cylinder":
        mesh.cylinder(center, size[0], size[1], index)
    else:
        raise ValueError(kind)


def build_outfit(source: SourceModel, profession: str) -> Mesh:
    mesh = Mesh()
    # Dimensions are authored in each bone's bind-local space. These three source rigs use
    # the same standard humanoid hierarchy and approximately 1-metre source height.
    if profession == "warrior":
        add_piece(mesh, source, "box", "Spine02", (0, 0.01, 0.018), (0.145, 0.105, 0.070))
        add_piece(mesh, source, "box", "Spine02", (0, -0.055, 0.089), (0.110, 0.018, 0.010))
        add_piece(mesh, source, "box", "Spine01", (0, -0.035, 0.012), (0.135, 0.070, 0.065))
        add_piece(mesh, source, "box", "Pelvis", (0, 0.060, 0.078), (0.150, 0.015, 0.012))
        for side in ("L", "R"):
            add_piece(mesh, source, "box", f"{side}_Clavicle", (0, 0, 0), (0.070, 0.045, 0.075))
            add_piece(mesh, source, "cylinder", f"{side}_Forearm", (0, 0, 0), (0.040, 0.150))
            add_piece(mesh, source, "box", f"{side}_Thigh", (0, -0.025, 0.018), (0.052, 0.135, 0.050))
            add_piece(mesh, source, "box", f"{side}_Calf", (0, -0.030, 0.010), (0.048, 0.125, 0.052))
    elif profession == "mage":
        add_piece(mesh, source, "box", "Spine02", (0, 0.005, 0.015), (0.135, 0.125, 0.062))
        add_piece(mesh, source, "box", "Spine01", (0, -0.050, 0.005), (0.145, 0.095, 0.066))
        add_piece(mesh, source, "box", "Pelvis", (0, -0.075, 0.000), (0.165, 0.145, 0.078))
        for side in ("L", "R"):
            add_piece(mesh, source, "box", f"{side}_Upperarm", (0, 0, 0), (0.060, 0.130, 0.060))
            add_piece(mesh, source, "cylinder", f"{side}_Forearm", (0, 0, 0), (0.043, 0.145))
            add_piece(mesh, source, "box", f"{side}_Thigh", (0, -0.045, 0), (0.060, 0.145, 0.060))
    elif profession == "taoist":
        add_piece(mesh, source, "box", "Spine02", (0, 0.005, 0.014), (0.132, 0.125, 0.061))
        add_piece(mesh, source, "box", "Spine01", (0, -0.050, 0.006), (0.145, 0.095, 0.066))
        add_piece(mesh, source, "box", "Pelvis", (0, -0.075, 0), (0.162, 0.145, 0.076))
        for side in ("L", "R"):
            add_piece(mesh, source, "box", f"{side}_Upperarm", (0, 0, 0), (0.058, 0.135, 0.058))
            add_piece(mesh, source, "cylinder", f"{side}_Forearm", (0, 0, 0), (0.040, 0.145))
            add_piece(mesh, source, "box", f"{side}_Thigh", (0, -0.045, 0), (0.060, 0.145, 0.060))
    else:
        raise ValueError(f"unknown profession: {profession}")
    return mesh


def pack_vertex(v: V) -> bytes:
    tangent = (1.0, 0.0, 0.0, 1.0)
    weights = (1.0, 0.0, 0.0, 0.0)
    indices = (v.bone, 0, 0, 0)
    if v.bone > 255:
        raise ValueError("bone index exceeds UBYTE4")
    return b"".join((
        struct.pack("<3f", *v.p),
        struct.pack("<3f", *v.n),
        struct.pack("<4B", 255, 255, 255, 255),
        struct.pack("<2f", *v.uv),
        struct.pack("<4f", *tangent),
        struct.pack("<4f", *weights),
        struct.pack("<4B", *indices),
    ))


def build_vertex_buffer(mesh: Mesh) -> bytes:
    elements = (
        (TYPE_VECTOR3, SEM_POSITION, 0),
        (TYPE_VECTOR3, SEM_NORMAL, 0),
        (TYPE_UBYTE4_NORM, SEM_COLOR, 0),
        (TYPE_VECTOR2, SEM_TEXCOORD, 0),
        (TYPE_VECTOR4, SEM_TANGENT, 0),
        (TYPE_VECTOR4, SEM_BLENDWEIGHTS, 0),
        (TYPE_UBYTE4, SEM_BLENDINDICES, 0),
    )
    out = bytearray(struct.pack("<II", len(mesh.vertices), len(elements)))
    for element_type, semantic, index in elements:
        out.extend(struct.pack("<I", element_type | (semantic << 8) | (index << 16)))
    out.extend(struct.pack("<II", 0, 0))
    for vertex in mesh.vertices:
        out.extend(pack_vertex(vertex))
    return bytes(out)


def build_index_buffer(mesh: Mesh) -> bytes:
    if len(mesh.vertices) >= 65536:
        raise ValueError("outfit has too many vertices")
    return struct.pack("<II", len(mesh.indices), 2) + struct.pack("<" + "H" * len(mesh.indices), *mesh.indices)


def write_model(source: SourceModel, mesh: Mesh, output: Path):
    out = bytearray(source.magic)
    out.extend(struct.pack("<I", len(source.vertex_buffers) + 1))
    for vb in source.vertex_buffers:
        out.extend(vb.blob)
    out.extend(build_vertex_buffer(mesh))

    out.extend(struct.pack("<I", len(source.index_buffers) + 1))
    for ib in source.index_buffers:
        out.extend(ib.blob)
    out.extend(build_index_buffer(mesh))

    out.extend(struct.pack("<I", len(source.geometries) + 1))
    for geometry in source.geometries:
        out.extend(struct.pack("<I", len(geometry.bone_mapping)))
        for index in geometry.bone_mapping:
            out.extend(struct.pack("<I", index))
        out.extend(struct.pack("<I", len(geometry.lods)))
        for lod in geometry.lods:
            out.extend(struct.pack("<fIIIII", lod.distance, lod.primitive_type, lod.vb_ref, lod.ib_ref,
                                   lod.index_start, lod.index_count))

    # Outfit geometry. Empty mapping means blend indices address the global skeleton directly,
    # matching the source character geometry convention.
    new_vb = len(source.vertex_buffers)
    new_ib = len(source.index_buffers)
    out.extend(struct.pack("<II", 0, 1))
    out.extend(struct.pack("<fIIIII", 0.0, 0, new_vb, new_ib, 0, len(mesh.indices)))

    # The preserved source tail contains one geometry center. Append a second center for the
    # authored outfit immediately after the source center so following optional model fields
    # stay aligned. All current source models have one geometry and no convex-collision buffers.
    if len(source.geometries) != 1:
        raise ValueError("offline authoring currently expects one source geometry")
    if len(source.tail) < 13:
        raise ValueError("source UMD2 tail is too short")
    # Locate skeleton + bounding box + source geometry center by parsing the preserved tail.
    tail_reader = Reader(source.tail)
    if tail_reader.u32() != 0:
        raise ValueError("source morph layout changed")
    bone_count = tail_reader.u32()
    for _ in range(bone_count):
        tail_reader.string()
        tail_reader.read(4 + 12 + 16 + 12 + 48)
        collision_mask = tail_reader.u8()
        if collision_mask & 1:
            tail_reader.read(4)
        if collision_mask & 2:
            tail_reader.read(24)
    tail_reader.read(24)  # bounding box
    source_center_end = tail_reader.offset + 12
    if source_center_end > len(source.tail):
        raise ValueError("source geometry center is missing")
    out.extend(source.tail[:source_center_end])
    out.extend(struct.pack("<3f", 0.0, 0.0, 0.0))
    out.extend(source.tail[source_center_end:])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--profession", choices=("warrior", "mage", "taoist"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    source = parse_source(args.source)
    mesh = build_outfit(source, args.profession)
    write_model(source, mesh, args.output)
    print(f"wrote {args.output}: {len(mesh.vertices)} vertices, {len(mesh.indices) // 3} triangles, "
          f"{len(source.bones)} preserved bones")


if __name__ == "__main__":
    main()

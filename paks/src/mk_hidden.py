# python mk_hidden.py [out.fbx]  -> art\SM2_BPUnitHidden00.fbx
# Blender is not installed on this box, so this writes a minimal ASCII FBX 7.4 directly (no deps).
# 6 tiny (1x1 cm) triangles, one per material slot Hid0..Hid5. cm units, Z up, no collision shapes.
import os, sys
NAME = "SM2_BPUnitHidden00"
assert len(NAME) == len("SM2_LargeContainer") == 18  # same-length byte patch in the cloned actor
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "art", NAME + ".fbx")
N = 6
V = []
for i in range(N): V += [0, 0, 0, 1, 0, 0, 0, 1, 0]
idx = []
for i in range(N): idx += [3 * i, 3 * i + 1, -(3 * i + 2) - 1]
uv = [0, 0, 1, 0, 0, 1] * N
uvi = list(range(3 * N))
nrm = [0, 0, 1] * (3 * N)
f = lambda l: ",".join(str(x) for x in l)
G, M, T = 1000001, 2000001, 3000001
mats = "".join('\tMaterial: %d, "Material::Hid%d", "" {\n\t\tVersion: 102\n\t\tShadingModel: "phong"\n\t\tMultiLayer: 0\n\t\tProperties70:  {\n\t\t\tP: "DiffuseColor", "Color", "", "A",0.8,0.8,0.8\n\t\t}\n\t}\n' % (T + i, i) for i in range(N))
conn = "".join("\tC: \"OO\",%d,%d\n" % (T + i, M) for i in range(N))
txt = f'''; FBX 7.4.0 project file
FBXHeaderExtension:  {{
	FBXHeaderVersion: 1003
	FBXVersion: 7400
	Creator: "mk_hidden.py"
}}
GlobalSettings:  {{
	Version: 1000
	Properties70:  {{
		P: "UpAxis", "int", "Integer", "",2
		P: "UpAxisSign", "int", "Integer", "",1
		P: "FrontAxis", "int", "Integer", "",1
		P: "FrontAxisSign", "int", "Integer", "",-1
		P: "CoordAxis", "int", "Integer", "",0
		P: "CoordAxisSign", "int", "Integer", "",1
		P: "UnitScaleFactor", "double", "Number", "",1
	}}
}}
Definitions:  {{
	Version: 100
	Count: {3 + N}
	ObjectType: "Model" {{
		Count: 1
	}}
	ObjectType: "Geometry" {{
		Count: 1
	}}
	ObjectType: "Material" {{
		Count: {N}
	}}
}}
Objects:  {{
	Geometry: {G}, "Geometry::{NAME}", "Mesh" {{
		Vertices: *{len(V)} {{
			a: {f(V)}
		}}
		PolygonVertexIndex: *{len(idx)} {{
			a: {f(idx)}
		}}
		GeometryVersion: 124
		LayerElementNormal: 0 {{
			Version: 101
			Name: ""
			MappingInformationType: "ByPolygonVertex"
			ReferenceInformationType: "Direct"
			Normals: *{len(nrm)} {{
				a: {f(nrm)}
			}}
		}}
		LayerElementUV: 0 {{
			Version: 101
			Name: "UVMap"
			MappingInformationType: "ByPolygonVertex"
			ReferenceInformationType: "IndexToDirect"
			UV: *{len(uv)} {{
				a: {f(uv)}
			}}
			UVIndex: *{len(uvi)} {{
				a: {f(uvi)}
			}}
		}}
		LayerElementMaterial: 0 {{
			Version: 101
			Name: ""
			MappingInformationType: "ByPolygon"
			ReferenceInformationType: "IndexToDirect"
			Materials: *{N} {{
				a: {f(range(N))}
			}}
		}}
		Layer: 0 {{
			Version: 100
			LayerElement:  {{
				Type: "LayerElementNormal"
				TypedIndex: 0
			}}
			LayerElement:  {{
				Type: "LayerElementMaterial"
				TypedIndex: 0
			}}
			LayerElement:  {{
				Type: "LayerElementUV"
				TypedIndex: 0
			}}
		}}
	}}
	Model: {M}, "Model::{NAME}", "Mesh" {{
		Version: 232
		Properties70:  {{
			P: "Lcl Translation", "Lcl Translation", "", "A",0,0,0
		}}
		Shading: T
		Culling: "CullingOff"
	}}
{mats}}}
Connections:  {{
	C: "OO",{M},0
	C: "OO",{G},{M}
{conn}}}
'''
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "w", newline="\n").write(txt)
print("EXPORTED", out)

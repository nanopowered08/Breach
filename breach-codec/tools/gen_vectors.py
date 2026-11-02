#!/usr/bin/env python3
"""Independent reference ENCODER (written from the spec, section 4) used to generate test vectors
for BreachCodec.luau.  Usage: gen_vectors.py <plugin-src-dir> > tests/vectors.luau
Values in test missions are given in the DECODED shape the Luau decoder returns."""
import re, sys, math, json, base64, struct
SRC = sys.argv[1]
def rd(n): return open(f"{SRC}/SerializationTools__{n}.lua", encoding="utf-8").read()

def parse_rows(body):
    """Parse `{ "Name", "Type", default }` rows. Tolerates missing spaces before `}` and ASSERTS that
    no row was skipped (an earlier version silently dropped rows like `Vector3.new()},`)."""
    rows = re.findall(r'\{\s*"([A-Za-z0-9]+)"\s*,\s*"([A-Za-z0-9]+)"\s*,\s*(.*?)\s*\}\s*,?\s*$', body, re.M)
    expect = len(re.findall(r'^\s*\{\s*"', body, re.M))
    assert len(rows) == expect, f"row parse mismatch: parsed {len(rows)} of {expect}"
    return rows

CS = "bcdfghjkmpqrtvwxy346789!\"#$%&'()*+,-./:;<=>?@BCDFGHJKMPQRTVWXY[\\]^_`{|}~"
N = 72
def mx(c): return N**c - 1
def rnd(x): return math.floor(x + 0.5)
def n2s(n, c):
    n = int(n); s = ""
    for _ in range(c): s = CS[n % N] + s; n //= N
    return s
SI = mx(3)//2
# ---- tables from the plugin
ids = {k: int(v) for k, v in re.findall(r'\t([A-Za-z]+) = (\d+),', rd("Types__InstanceTypes"))}
props_src = rd("Types__InstanceProperties"); PROPS = {}; DEFN = {}
for m in re.finditer(r'^\t([A-Za-z]+) = \{\n(.*?)^\t\},', props_src, re.M|re.S):
    rows = parse_rows(m.group(2))
    PROPS[m.group(1)] = [(n, t) for n, t, d in rows]
    nm = [d for n, t, d in rows if n == "Name"]; DEFN[m.group(1)] = json.loads(nm[0]) if nm else None
PROPS["PartNoAttributes"] = PROPS["Part"]; DEFN["PartNoAttributes"] = "Part"
ATT = {k: int(v) for k, v in re.findall(r'\t([A-Za-z0-9]+) = (\d+),', rd("Types__AttributeTypes"))}
HAS_ATTR = {"Model", "Folder", "Part", "BoolValue", "MeshPart", "UnionOperation"}
EF = {"Material":"Types__Enums__Materials","NormalId":"Types__Enums__NormalId","PartType":"Types__Enums__PartTypes","MeshType":"Types__Enums__MeshType","RenderFidelity":"Types__Enums__RenderFidelity","CollisionFidelity":"Types__Enums__CollisionFidelity","TextureMode":"Types__Enums__TextureMode","ParticleEmitterShape":"Types__Enums__Particles__ParticleEmitterShape","ParticleEmitterShapeInOut":"Types__Enums__Particles__ParticleEmitterShapeInOut","ParticleEmitterShapeStyle":"Types__Enums__Particles__ParticleEmitterShapeStyle","ParticleOrientation":"Types__Enums__Particles__ParticleOrientation","ResamplerMode":"Types__Enums__GUI__ResamplerMode","SurfaceGuiSizingMode":"Types__Enums__GUI__SurfaceGuiSizingMode"}
ENUM = {e: {k: int(v) for k, v in re.findall(r'([A-Za-z0-9]+) = (\d+)', rd(f))} for e, f in EF.items()}

# ---- primitive writers
def w_signed(n): return n2s(n + SI, 3)
def w_float(x): f = math.floor(x); return w_signed(f) + n2s(rnd((x - f) * mx(2)), 2)
def w_sbf(x): return n2s(rnd(min(max(x, 0), 1) * mx(2)), 2)
def w_bf(x): return n2s(rnd(min(max(x, 0), 1) * mx(3)), 3)
def w_bool(b): return "b" if b else "c"
def esc(s, v): return s.replace("&","&&").replace("\n","&n").replace("\r","&r").replace("\t","&t") if v >= 1 else s
class Enc:
    def __init__(self, version): self.v = version; self.strs = {}; self.cols = {}
    def si(self, s):
        if s not in self.strs: self.strs[s] = len(self.strs) + 1
        return n2s(self.strs[s], 2)
    def ci(self, c):
        k = tuple(c)
        if k not in self.cols: self.cols[k] = len(self.cols) + 1
        return n2s(self.cols[k], 2)
    def wstring(self, s):
        b = esc(s, self.v).encode("utf-8"); return n2s(len(b), 4), b
    def value(self, t, v, node_paths):
        if t == "Bool": return w_bool(v)
        if t == "Float": return w_float(v)
        if t == "Int": return n2s(v, 4)
        if t == "ShortBoundedFloat": return w_sbf(v)
        if t == "Vector2": return w_float(v["X"]) + w_float(v["Y"])
        if t == "Vector3": return w_float(v["X"]) + w_float(v["Y"]) + w_float(v["Z"])
        if t == "UDim2": return "".join(w_float(v[a][b]) for a in "XY" for b in ("Scale","Offset"))
        if t == "FloatRange": return w_float(v["Min"]) + w_float(v["Max"])
        if t == "FloatSequence": return n2s(len(v), 2) + "".join(w_sbf(k["Time"]) + w_float(k["Value"]) + w_float(k["Envelope"]) for k in v)
        if t == "ColorSequence": return n2s(len(v), 2) + "".join(w_sbf(k["Time"]) + w_sbf(k["Color"]["R"]) + w_sbf(k["Color"]["G"]) + w_sbf(k["Color"]["B"]) for k in v)
        if t == "CFrame":
            p, e = v["Position"], v["EulerXYZ"]
            return w_float(p["X"]) + w_float(p["Y"]) + w_float(p["Z"]) + "".join(w_bf((e[a] + math.pi) / (2*math.pi)) for a in "XYZ")
        if t == "InstanceReference": ln, b = self.wstring(v["Ref"]); return ("RAW", ln, b)
        if t in ENUM: return n2s(ENUM[t][v], 1)
        raise Exception("encoder: no writer for " + t)

def node(cls, name=None, props=None, attrs=None, children=None):
    return {"cls": cls, "name": name, "props": props or {}, "attrs": attrs or {}, "children": children or []}
NIL = {"cls": "Nil"}

def encode_stream(root, version):
    e = Enc(version)
    out = []  # list of str or bytes
    def emit(x): out.append(x)
    def inst(n):
        if n["cls"] == "Nil": emit("c"); return
        cls = n["cls"]
        wire = "PartNoAttributes" if (cls == "Part" and not n["attrs"]) else cls
        emit(n2s(ids[wire], 1))
        nm = n["name"] if n["name"] is not None else DEFN[wire]
        for pid, (pname, ptype) in enumerate(PROPS[wire], 1):
            if pname == "Name":
                if nm != DEFN[wire]: emit(n2s(pid, 1) + e.si(nm))
                continue
            if pname not in n["props"]: continue
            v = n["props"][pname]; emit(n2s(pid, 1))
            if ptype == "String": emit("bb" if v is None else e.si(v))   # map index 0 = nil (real exports contain this)
            elif ptype == "Color3": emit(e.ci((v["R"], v["G"], v["B"])))
            else:
                w = e.value(ptype, v, None)
                if isinstance(w, tuple): emit(w[1]); emit(w[2])
                else: emit(w)
        emit(n2s(0, 1))
        if wire in HAS_ATTR:
            for k, v in n["attrs"].items():
                if isinstance(v, bool): emit(n2s(ATT["Bool"], 1) + e.si(k) + w_bool(v))
                elif isinstance(v, str): emit(n2s(ATT["String"], 1) + e.si(k) + e.si(v))
                elif isinstance(v, (int, float)):
                    if v != round(v) or v < 0: emit(n2s(ATT["Float"], 1) + e.si(k) + w_float(v))
                    else: emit(n2s(ATT["LongInt"], 1) + e.si(k) + n2s(v, 6))
                elif "R" in v: emit(n2s(ATT["Color3"], 1) + e.si(k) + e.ci((v["R"], v["G"], v["B"])))
                elif "Z" in v: emit(n2s(ATT["Vector3"], 1) + e.si(k) + w_float(v["X"]) + w_float(v["Y"]) + w_float(v["Z"]))
                else: raise Exception("attr type")
            emit(n2s(0, 1))
        for c in n["children"]: inst(c)
        emit(n2s(0, 1))
    inst(root)
    body = b""
    for x in out: body += x if isinstance(x, bytes) else x.encode("utf-8")
    hdr = n2s(len(e.cols), 2) + "".join(w_sbf(c) for col in sorted(e.cols, key=e.cols.get) for c in col)
    hdr += n2s(len(e.strs), 2)
    hb = hdr.encode("utf-8")
    for s in sorted(e.strs, key=e.strs.get):
        ln, b = e.wstring(s); hb += ln.encode() + b
    return hb + body

# ---- zstd frame using only RAW blocks (valid per RFC 8878), so the test host can be tiny
def zstd_stored(data: bytes) -> bytes:
    f = b"\x28\xb5\x2f\xfd" + bytes([0xA0]) + struct.pack("<I", len(data))   # single segment, 4-byte content size
    if not data: return f + struct.pack("<I", 1)[:3]
    for i in range(0, len(data), 131072):
        blk = data[i:i+131072]; last = 1 if i + 131072 >= len(data) else 0
        f += struct.pack("<I", last | (0 << 1) | (len(blk) << 3))[:3] + blk
    return f

def header(version, map_id, cur, total): return n2s(version, 1) + n2s(map_id, 2) + n2s(cur, 2) + n2s(total, 2)

# ---- test mission
def v3(x, y, z): return {"X": x, "Y": y, "Z": z}
def col(r, g, b): return {"R": r, "G": g, "B": b}
def cf(px, py, pz, rx, ry, rz): return {"Position": v3(px, py, pz), "EulerXYZ": v3(rx, ry, rz)}

def build_mission():
    rig_children = [node("Attachment", "A0", {"CFrame": cf(0, 1, 0, 0, 0, 0)}), node("Attachment", "A1", {"CFrame": cf(4, 1, 0, 0, 0, 0)})]
    rig = node("Part", "Rig", {"Size": v3(1, 1, 1), "CFrame": cf(0, 5, 0, 0, 0, 0)}, {"Tag": "rig"}, rig_children + [None])
    root = node("Folder", "DebugMission", children=[
        node("Part", "Floor", {"CFrame": cf(1.25, 0.5, -3, 0.1, 0.2, -0.3), "Color": col(0.25, 0.5, 0.75),
             "Size": v3(10, 1, 10.5), "Material": "Concrete", "Transparency": 0.25, "Shape": "Cylinder", "CastShadow": True},
             {"Tag": "x", "Count": 12, "Ratio": 1.5, "Neg": -4, "Flag": True, "Off": v3(1, 2, 3), "Tint": col(1, 0, 0.5)}),
        node("Part", None, {"Size": v3(2, 2, 2)}),                               # default name, no attributes -> PartNoAttributes
        NIL,                                                                      # unsupported class: must not shift indices
        node("UnionOperation", "Cut", {"Size": v3(3, 3, 3), "MeshId": None}, {"Tag": "u"}),
        node("Model", "Props", children=[
            node("BoolValue", "Door1", {"Value": True}, {"Type": "DoorMetal", "LockFront": True, "Access": "Key1 Key2"}),
            node("WedgePart", None, {"Size": v3(1, 2, 3), "Material": "Brick"}),
            node("PointLight", None, {"Brightness": 2.5, "Color": col(1, 0.5, 0), "Range": 12}),
        ]),
        rig,
        node("ParticleEmitter", "Emit", {"Color": [{"Time": 0, "Color": col(1, 0, 0)}, {"Time": 1, "Color": col(0, 0, 1)}],
             "Size": [{"Time": 0, "Value": 1, "Envelope": 0}, {"Time": 1, "Value": 3.5, "Envelope": 0.5}],
             "Rotation": {"Min": -1, "Max": 2.5}, "Shape": "Sphere", "ShapeInOut": "InAndOut", "Orientation": "VelocityParallel",
             "EmissionDirection": "Front", "Rate": 33, "Acceleration": v3(0, -9.5, 0), "SpreadAngle": {"X": 10, "Y": 20}}),
        node("SurfaceGui", "Screen", {"Face": "Back", "SizingMode": "FixedSize"}, children=[
            node("ImageLabel", "Img", {"Position": {"X": {"Scale": 0.5, "Offset": 10}, "Y": {"Scale": 0, "Offset": -4}},
                  "Size": {"X": {"Scale": 1, "Offset": 0}, "Y": {"Scale": 1, "Offset": 0}}, "Image": "rbxassetid://123", "ResampleMode": "Pixelated"})]),
        node("StringValue", "TableMissionSetup", {"Value": json.dumps({"Colors": {"Sky": [1, 0.5, 0]}, "Objectives": [{"Text": "caf\u00e9 \U0001F600", "Active": "1"}], "SoundTravelDistance": 1.5}, ensure_ascii=True)}),
        node("StringValue", "StringMissionSetup", {"Value": "local M = {}\n\treturn M -- a & b &&\r\n"}, children=[
            node("StringValue", "Helpers", {"Value": "return 1"})]),
        node("BoolValue", "CustomMissionSettings", children=[
            node("BoolValue", "EnforceCellLinks", {"Value": True}), node("StringValue", "MissionName", {"Value": "Test Mission"}),
            node("StringValue", "ExportVersion", {"Value": "7"})]),
    ])
    # wire up Beam refs (paths count only serialisable siblings; Nil is not one)
    def path_of(target):
        def find(n, p):
            if n is target: return p
            idx = 0
            for c in n["children"]:
                if c is None or c["cls"] == "Nil": continue
                idx += 1
                r = find(c, p + [idx])
                if r is not None: return r
            return None
        return ".".join(map(str, find(root, [])))
    rig["children"].remove(None)
    beam = node("Beam", "Laser", {"Attachment0": {"Ref": path_of(rig_children[0])}, "Attachment1": {"Ref": path_of(rig_children[1])},
                                   "Width0": 0.5, "Transparency": [{"Time": 0, "Value": 0, "Envelope": 0}]})
    rig["children"].append(beam)
    return root

def expected(n):
    """decoded shape the Luau decoder must produce (without Parent)."""
    cls = n["cls"]
    props = {k: v for k, v in n["props"].items() if v is not None}
    if cls == "BoolValue": props.setdefault("Value", False)
    if cls == "StringValue": props.setdefault("Value", "")
    nm = n["name"] if n["name"] is not None else DEFN[cls]
    return {"ClassName": cls, "Name": nm, "Props": props, "Attrs": dict(n["attrs"]),
            "Children": [expected(c) for c in n["children"] if c["cls"] != "Nil"]}

def lua(v, ind=0):
    t = "\t" * (ind + 1)
    if v is True: return "true"
    if v is False: return "false"
    if v is None: return "nil"
    if isinstance(v, (int, float)):
        return repr(float(v)) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        o = ""
        for b in v.encode("utf-8"):
            c = chr(b)
            if c == "\\": o += "\\\\"
            elif c == '"': o += '\\"'
            elif c == "\n": o += "\\n"
            elif c == "\r": o += "\\r"
            elif c == "\t": o += "\\t"
            elif 32 <= b < 127: o += c
            else: o += "\\x%02X" % b
        return '"' + o + '"'
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(lua(x, ind + 1) for x in v) + "}"
    if isinstance(v, dict):
        if not v: return "{}"
        return "{\n" + "".join(f"{t}[{lua(k)}] = {lua(x, ind + 1)},\n" for k, x in v.items()) + "\t" * ind + "}"
    raise Exception(type(v))

root = build_mission()
exp = expected(root)
cases = []
for ver in (0, 1, 2):
    raw = encode_stream(root, ver)
    if ver == 2:
        payload = base64.b64encode(zstd_stored(raw)).decode()
    else:
        payload = raw.decode("utf-8", errors="strict")
    code = header(ver, 1234, 1, 1) + payload
    cases.append({"name": f"v{ver} single piece", "code": code, "version": ver})
    if ver == 0:
        # v0 strings are unescaped; our test strings contain newlines/tabs so the v0 payload is simply raw bytes
        pass
# gist-wrapped (v1) and multi-piece (v1)
raw1 = encode_stream(root, 1).decode()
gist = "!!!\nHow to play custom missions:\n\nMission Name: Test Mission\nCreator: me\n\n!!!" + header(1, 4321, 1, 1) + raw1
third = len(raw1) // 3 + 1
pieces = [header(1, 777, i + 1, 3) + raw1[i*third:(i+1)*third] for i in range(3)]
# a v2 multi-piece too, to cover base64 across piece boundaries
b64 = base64.b64encode(zstd_stored(encode_stream(root, 2))).decode(); h = len(b64) // 2 + 1
pieces2 = [header(2, 55, 1, 2) + b64[:h], header(2, 55, 2, 2) + b64[h:]]
# the tiny mission from the documentation (section 4.11)
doc_body = "bc.b.b.bbjbbbtDebugMissionbbbhFloorbbbmTrigger1bbbgTypebbbrTriggerZonebbbmIsGlobalfcbcbbhcbdd-~~bb-~~.b-~~bb.bb.bb.bbfbcg.bpbb.bbbb.bpbbbbjcbfbfbgbhgbjbbbb"
print("-- GENERATED by tools/gen_vectors.py -- do not edit")
print("return {")
print("expected = " + lua(exp, 0) + ",")
print("single = " + lua(cases, 0) + ",")
print("gist = " + lua(gist) + ",")
print("pieces = " + lua(pieces) + ",")
print("pieces_v2 = " + lua(pieces2) + ",")
print("doc_body = " + lua(doc_body) + ",")
print("}")
# self-check zstd framing with a real library when available
try:
    import zstandard
    d = encode_stream(root, 2)
    assert zstandard.ZstdDecompressor().decompress(zstd_stored(d)) == d
    sys.stderr.write("stored-zstd frame verified by python-zstandard\n")
except ImportError:
    sys.stderr.write("(python-zstandard not installed; frame not cross-checked)\n")

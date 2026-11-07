const fs = require('fs'), path = require('path');
const L = (process.env.MS_MODS_ROOT || 'F:\\MSDemoMods') + '\\legacy\\MainSequence\\Content\\Blueprints\\BuildingBlocks';
const OUT = path.join(__dirname, 'stage', 'MainSequence', 'Content', 'Blueprints', 'BuildingBlocks');
fs.mkdirSync(OUT, { recursive: true });
const LOC_IN = (process.env.MS_MODS_ROOT || 'F:\\MSDemoMods') + '\\legacy\\MainSequence\\Content\\Data\\Localization';
const LOC_OUT = path.join(__dirname, 'stage', 'MainSequence', 'Content', 'Data', 'Localization');
fs.mkdirSync(LOC_OUT, { recursive: true });
// hologram template transform (BP uexp doubles). Vanilla: loc (0,0,141.0058747886738), scale 0.0325. designer sets HOLO_*.
const HOLO_SCALE = 1.0, HOLO_Z = 150;
const HOLO_VAN_Z = 141.0058747886738, HOLO_VAN_SCALE = 0.0325;
const HOLO_OFF = { locX: 8281, locY: 8289, locZ: 8297, scX: 8305, scY: 8313, scZ: 8321 };
const BPO_OLD = 'BPO_CommandModule', BPO_NEW = 'BPO_BlueprintUnit';
const BP_OLD = 'BP_CommandModule', BP_NEW = 'BP_BlueprintUnit';
const MESH_OLD = 'SM2_Holotable', MESH_NEW = 'SM2_BPUnitTbl';
const DESC_OLD = 'A central command location for stations. Can be used to construct new station modules.';
const DESC_NEW = ('Imports a factory blueprint from the clipboard and builds it on your station.').padEnd(86, ' ');
if (BPO_OLD.length !== BPO_NEW.length || BP_OLD.length !== BP_NEW.length || MESH_OLD.length !== MESH_NEW.length || DESC_OLD.length !== DESC_NEW.length || DESC_OLD.length !== 86) throw new Error('length mismatch');
function replaceAll(buf, from, to) {
  if (from.length !== to.length) throw new Error('length mismatch: ' + from + ' vs ' + to);
  const a = Buffer.from(from, 'latin1'), b = Buffer.from(to, 'latin1');
  let n = 0, i = buf.indexOf(a, 0, 'latin1');
  while (i !== -1) { b.copy(buf, i); n++; i = buf.indexOf(a, i + a.length, 'latin1'); }
  return n;
}
const u16 = (s) => Buffer.from(s, 'utf16le').toString('latin1');
const both = (buf, f, t) => replaceAll(buf, f, t) + replaceAll(buf, u16(f), u16(t));
let bad = false;
function need(label, n) { console.log(label + ': ' + n); if (!(n > 0)) { console.log('ERROR zero: ' + label); bad = true; } }
function job(src, dst, fn) {
  const buf = fs.readFileSync(path.join(L, src)); const len = buf.length;
  const c = fn(buf);
  if (buf.length !== len) throw new Error('length changed ' + src);
  fs.writeFileSync(path.join(OUT, dst), buf);
  return c;
}
const bpoUa = job(BPO_OLD + '.uasset', BPO_NEW + '.uasset', (b) => ({ bpo: both(b, BPO_OLD, BPO_NEW), bp: both(b, BP_OLD, BP_NEW) }));
need('BPO uasset self', bpoUa.bpo); need('BPO uasset actor import', bpoUa.bp);
const bpoUe = job(BPO_OLD + '.uexp', BPO_NEW + '.uexp', (b) => ({
  text: replaceAll(b, '\x0F\x00\x00\x00Command Module\x00', '\x0F\x00\x00\x00Blueprint Unit\x00'),
  desc: replaceAll(b, DESC_OLD, DESC_NEW),
  k1: replaceAll(b, 'C2E293D24543B80DB3F9B5B6F44BEA8F', '12E293D24543B80DB3F9B5B6F44BEA8F'),
  k2: replaceAll(b, '90569B1B4FE3B21DA14BBBBFB2C29545', '10569B1B4FE3B21DA14BBBBFB2C29545'),
}));
need('BPO uexp text', bpoUe.text); need('BPO uexp desc', bpoUe.desc);
need('BPO uexp key1', bpoUe.k1); need('BPO uexp key2', bpoUe.k2);
const bpUa = job(BP_OLD + '.uasset', BP_NEW + '.uasset', (b) => ({
  bpo: both(b, BPO_OLD, BPO_NEW), bp: both(b, BP_OLD, BP_NEW), mesh: replaceAll(b, MESH_OLD, MESH_NEW),
}));
console.log('BP uasset BPO cast import (0 ok): ' + bpUa.bpo);
need('BP uasset self', bpUa.bp); need('BP uasset mesh', bpUa.mesh);
const bpUe = job(BP_OLD + '.uexp', BP_NEW + '.uexp', (b) => ({
  bpo: both(b, BPO_OLD, BPO_NEW), bp: both(b, BP_OLD, BP_NEW), mesh: replaceAll(b, MESH_OLD, MESH_NEW),
}));
console.log('BP uexp (0 ok): bpo=' + bpUe.bpo + ' bp=' + bpUe.bp + ' mesh=' + bpUe.mesh);

// ---- Job A: prompt string table (copy of STB_Interaction, "to Use Blueprint"; same length) ----
const PROMPT = 'STB_BPUnitPromp', STB_OLD = 'STB_Interaction';
const PROMPT_OLD_TXT = 'to Open Designer\x00', PROMPT_NEW_TXT = 'to Use Blueprint\x00';
if (PROMPT_OLD_TXT.length !== PROMPT_NEW_TXT.length || STB_OLD.length !== PROMPT.length) throw new Error('length mismatch: prompt');
function jobAt(inDir, outDir, name, fn) {
  const buf = fs.readFileSync(path.join(inDir, name)); const len = buf.length;
  const c = fn(buf);
  if (buf.length !== len) throw new Error('length changed ' + name);
  fs.writeFileSync(path.join(outDir, name.replace(STB_OLD, PROMPT)), buf);
  console.log('prompt', name, '->', PROMPT, JSON.stringify(c));
  return c;
}
const pUa = jobAt(LOC_IN, LOC_OUT, STB_OLD + '.uasset', (b) => ({ stb: replaceAll(b, STB_OLD, PROMPT), stbU16: replaceAll(b, u16(STB_OLD), u16(PROMPT)) }));
need('prompt uasset table rename (ascii+utf16)', pUa.stb + pUa.stbU16);
const pUe = jobAt(LOC_IN, LOC_OUT, STB_OLD + '.uexp', (b) => ({ stb: replaceAll(b, STB_OLD, PROMPT), text: replaceAll(b, PROMPT_OLD_TXT, PROMPT_NEW_TXT) }));
need('prompt uexp table rename', pUe.stb); need('prompt uexp text', pUe.text);

// ---- post-patches on existing BP_BlueprintUnit outputs (same length) ----
function patchOut(name, fn) {
  const p = path.join(OUT, name); const buf = fs.readFileSync(p); const len = buf.length;
  const c = fn(buf);
  if (buf.length !== len) throw new Error('length changed ' + name);
  fs.writeFileSync(p, buf);
  return c;
}
const bpP = patchOut(BP_NEW + '.uasset', (b) => ({ stb: replaceAll(b, STB_OLD, PROMPT), stbU16: replaceAll(b, u16(STB_OLD), u16(PROMPT)) }));
console.log('BP uasset prompt table ref: ascii=' + bpP.stb + ' utf16=' + bpP.stbU16);
need('BP uasset prompt table ref', bpP.stb + bpP.stbU16);

// ---- Job B: hologram mesh same-length rename (25 chars both sides; path dir unchanged) ----
const SM_OLD = 'SM_StarterStationHologram', SM_NEW = 'SM_BPUnitBlueprintHolo_01';
if (SM_OLD.length !== 25 || SM_NEW.length !== SM_OLD.length) throw new Error('length mismatch: SM holo');
const bpH = patchOut(BP_NEW + '.uasset', (b) => ({ sm: replaceAll(b, SM_OLD, SM_NEW), smU16: replaceAll(b, u16(SM_OLD), u16(SM_NEW)) }));
console.log('BP uasset hologram mesh rename: ascii=' + bpH.sm + ' utf16=' + bpH.smU16);
need('BP uasset hologram mesh rename', bpH.sm + bpH.smU16);

// ---- Job E: suppress vanilla station window (BP_CommandModule opens WBP_StationInventory). Same-length dummy name, like Mining Unit WBP_Workbench -> WBP_MiningUnt ----
const WIN_OLD = 'WBP_StationInventory', WIN_NEW = 'WBP_BPUnitNoWindow00';
if (WIN_OLD.length !== 20 || WIN_NEW.length !== WIN_OLD.length) throw new Error('length mismatch: station window');
const bpW = patchOut(BP_NEW + '.uasset', (b) => ({ win: replaceAll(b, WIN_OLD, WIN_NEW), winU16: replaceAll(b, u16(WIN_OLD), u16(WIN_NEW)) }));
console.log('BP uasset vanilla station window rename: ascii=' + bpW.win + ' utf16=' + bpW.winU16);
need('BP uasset station window rename (ascii: package path, WBP_StationInventory_C, Default__)', bpW.win);
{
  const b = fs.readFileSync(path.join(OUT, BP_NEW + '.uasset'));
  if (b.indexOf(WIN_OLD, 0, 'latin1') !== -1 || b.indexOf(u16(WIN_OLD), 0, 'latin1') !== -1) { console.log('LEFTOVER ' + WIN_OLD + ' in ' + BP_NEW + '.uasset'); bad = true; }
}

// ---- Job C: hologram template transform (BP uexp float64 LE). Asserts vanilla layout before writing. ----
const bpT = patchOut(BP_NEW + '.uexp', (b) => {
  const chk = (label, off, want, tol) => {
    const got = b.readDoubleLE(off);
    if (Math.abs(got - want) > tol) throw new Error('hologram layout shift: ' + label + ' @' + off + ' = ' + got + ', want ' + want);
  };
  chk('locX', HOLO_OFF.locX, 0, 1e-6); chk('locY', HOLO_OFF.locY, 0, 1e-6); chk('locZ', HOLO_OFF.locZ, HOLO_VAN_Z, 1e-6);
  chk('scX', HOLO_OFF.scX, HOLO_VAN_SCALE, 1e-6); chk('scY', HOLO_OFF.scY, HOLO_VAN_SCALE, 1e-6); chk('scZ', HOLO_OFF.scZ, HOLO_VAN_SCALE, 1e-6);
  b.writeDoubleLE(HOLO_Z, HOLO_OFF.locZ);
  b.writeDoubleLE(HOLO_SCALE, HOLO_OFF.scX); b.writeDoubleLE(HOLO_SCALE, HOLO_OFF.scY); b.writeDoubleLE(HOLO_SCALE, HOLO_OFF.scZ);
  return { locZ: HOLO_Z, scale: HOLO_SCALE };
});
console.log('hologram transform patched: ' + JSON.stringify(bpT));

// assert the BPO still has the hull/frame items and the new display name
const outBpoA = fs.readFileSync(path.join(OUT, BPO_NEW + '.uasset')), outBpoE = fs.readFileSync(path.join(OUT, BPO_NEW + '.uexp'));
for (const s of ['ITEM_HullPlates', 'ITEM_LightweightFrame']) {
  if (outBpoA.indexOf(s, 0, 'latin1') === -1) throw new Error('BPO uasset missing ' + s);
}
if (outBpoE.indexOf('Blueprint Unit', 0, 'latin1') === -1) throw new Error('BPO uexp missing Blueprint Unit');

// leftover scan: old BP/BPO/mesh names must be gone (bare CommandModule stays on purpose)
for (const f of [BPO_NEW + '.uasset', BPO_NEW + '.uexp', BP_NEW + '.uasset', BP_NEW + '.uexp']) {
  const b = fs.readFileSync(path.join(OUT, f));
  for (const s of [BP_OLD, BPO_OLD, MESH_OLD]) {
    const n = b.indexOf(s, 0, 'latin1') + b.indexOf(u16(s), 0, 'latin1');
    if (n > -2) { console.log('LEFTOVER ' + s + ' in ' + f); bad = true; }
  }
}
// new leftover scans: hologram mesh + STB_Interaction gone from BP and prompt table
for (const f of [BP_NEW + '.uasset', BP_NEW + '.uexp', PROMPT + '.uasset', PROMPT + '.uexp']) {
  const dir = f.startsWith(PROMPT) ? LOC_OUT : OUT;
  const b = fs.readFileSync(path.join(dir, f));
  for (const s of [STB_OLD, SM_OLD]) {
    if (f.startsWith(PROMPT) && s === SM_OLD) continue;
    const n = b.indexOf(s, 0, 'latin1') + b.indexOf(u16(s), 0, 'latin1');
    if (n > -2) { console.log('LEFTOVER ' + s + ' in ' + f); bad = true; }
  }
}
// ---- Job D: hidden default container machine = clone of vanilla large container SIM (BP_ContainerObject_2 -> BP_BPUnitStoreObj_01)
// + clone of its actor BP_Container_2 -> BP_BPUnitSto_2 (mesh -> SM2_BPUnitHidden00, pak97). Parent BP_ContainerObject stays.
// The sim's actor import is package name base "BP_Container" with FName number 3 (= suffix _2). Base rename to BP_BPUnitSto (same length) keeps number 3 -> BP_BPUnitSto_2.
// Off unless BPU_CONTAINER=1 (build_pak.ps1 -Container clone).
if (process.env.BPU_CONTAINER === '1') {
const MACH_IN = (process.env.MS_MODS_ROOT || 'F:\\MSDemoMods') + '\\legacy\\MainSequence\\Content\\Blueprints\\Machines';
const MACH_OUT = path.join(__dirname, 'stage', 'MainSequence', 'Content', 'Blueprints', 'Machines');
fs.mkdirSync(MACH_OUT, { recursive: true });
const SIM_OLD = 'BP_ContainerObject_2', SIM_NEW = 'BP_BPUnitStoreObj_01';
if (SIM_OLD.length !== SIM_NEW.length) throw new Error('length mismatch: machine');
// sim uexp int32 (BP_ContainerObject_2.uexp, from diff_container.py): InventorySize @120, StackSizeBonusMultiplier @124
const INV_OFF = 120, INV_OLD = 32, INV_NEW = 120;
const BONUS_OFF = 124, BONUS_OLD = 10, BONUS_NEW = 200;
function machJob(src, dst, fn) {
  const buf = fs.readFileSync(path.join(MACH_IN, src)); const len = buf.length;
  const c = fn(buf);
  if (buf.length !== len) throw new Error('length changed ' + src);
  fs.writeFileSync(path.join(MACH_OUT, dst), buf);
  return c;
}
const simUa = machJob(SIM_OLD + '.uasset', SIM_NEW + '.uasset', (b) => ({
  sim: both(b, SIM_OLD, SIM_NEW),
  actPkg: both(b, '/Game/Blueprints/Machines/BP_Container\0', '/Game/Blueprints/Machines/BP_BPUnitSto\0'),  // actor package (FName base, number 3)
  actCls: both(b, 'BP_Container_2_C', 'BP_BPUnitSto_2_C'),
}));
need('machine sim uasset self', simUa.sim); need('machine sim actor package', simUa.actPkg); need('machine sim actor class', simUa.actCls);
const simUe = machJob(SIM_OLD + '.uexp', SIM_NEW + '.uexp', (b) => {
  const inv = b.readInt32LE(INV_OFF), bon = b.readInt32LE(BONUS_OFF);
  if (inv !== INV_OLD || bon !== BONUS_OLD) throw new Error('machine layout shift: InventorySize ' + inv + ' bonus ' + bon);
  b.writeInt32LE(INV_NEW, INV_OFF); b.writeInt32LE(BONUS_NEW, BONUS_OFF);
  return { sim: both(b, SIM_OLD, SIM_NEW) };
});
console.log('machine sim uexp: inventory ' + INV_OLD + '->' + INV_NEW + ' @' + INV_OFF + ', bonus ' + BONUS_OLD + '->' + BONUS_NEW + ' @' + BONUS_OFF + ', refs ' + JSON.stringify(simUe));
// ---- actor clone: BP_Container_2 -> BP_BPUnitSto_2. Base rename skips WBP_Container (W before) and BP_ContainerObject (Object after).
const ACT_BASE_OLD = 'BP_Container', ACT_BASE_NEW = 'BP_BPUnitSto';
const ACT_MESH_OLD = 'SM2_LargeContainer', ACT_MESH_NEW = 'SM2_BPUnitHidden00';
if (ACT_BASE_OLD.length !== ACT_BASE_NEW.length || ACT_MESH_OLD.length !== 18 || ACT_MESH_NEW.length !== 18) throw new Error('length mismatch: actor');
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const wEsc = (s) => s.split('').map((c) => esc(c) + '\\x00').join('');
function baseRename(buf, from, to) {
  let n = 0, t = buf.toString('latin1');
  const go = (f, r, pre, post) => { t = t.replace(new RegExp('(?<!' + pre + ')' + f + '(?!' + post + ')', 'g'), () => { n++; return r; }); };
  go(esc(from), to, 'W', 'Object');
  go(wEsc(from), Buffer.from(to, 'utf16le').toString('latin1'), wEsc('W'), wEsc('Object'));
  const o = Buffer.from(t, 'latin1'); if (o.length !== buf.length) throw new Error('length changed (baseRename)');
  o.copy(buf); return n;
}
function actJob(src, dst, fn) {
  const buf = fs.readFileSync(path.join(MACH_IN, src)); const len = buf.length;
  const c = fn(buf);
  if (buf.length !== len) throw new Error('length changed ' + src);
  fs.writeFileSync(path.join(MACH_OUT, dst), buf);
  return c;
}
const actUa = actJob('BP_Container_2.uasset', 'BP_BPUnitSto_2.uasset', (b) => ({
  base: baseRename(b, ACT_BASE_OLD, ACT_BASE_NEW), mesh: both(b, ACT_MESH_OLD, ACT_MESH_NEW),
}));
need('actor uasset base rename', actUa.base); need('actor uasset mesh', actUa.mesh);
const actUe = actJob('BP_Container_2.uexp', 'BP_BPUnitSto_2.uexp', (b) => ({
  base: baseRename(b, ACT_BASE_OLD, ACT_BASE_NEW), mesh: both(b, ACT_MESH_OLD, ACT_MESH_NEW),
}));
console.log('actor uasset ' + JSON.stringify(actUa) + ' uexp ' + JSON.stringify(actUe));
// actor leftovers: no vanilla mesh, no non-W/non-Object BP_Container base
for (const f of ['BP_BPUnitSto_2.uasset', 'BP_BPUnitSto_2.uexp']) {
  const t = fs.readFileSync(path.join(MACH_OUT, f)).toString('latin1');
  if (/(?<!W)BP_Container(?!Object)/.test(t) || /SM2_LargeContainer/.test(t)) { console.log('LEFTOVER vanilla actor name in ' + f); bad = true; }
}
{
  const t = fs.readFileSync(path.join(MACH_OUT, 'BP_BPUnitSto_2.uasset')).toString('latin1');
  if (t.indexOf('/Game/Blueprints/Machines/BP_BPUnitSto_2\0', 0, 'latin1') === -1 && t.indexOf('/Game/Blueprints/Machines/BP_BPUnitSto_2', 0, 'latin1') === -1) { console.log('ERROR actor header FString BP_BPUnitSto_2 missing'); bad = true; }
}
// sim: parent import must survive; actor refs renamed; no vanilla actor ref left
const simOut = fs.readFileSync(path.join(MACH_OUT, SIM_NEW + '.uasset')).toString('latin1');
if (simOut.indexOf('/Game/Blueprints/Machines/BP_ContainerObject', 0, 'latin1') === -1) { console.log('ERROR parent import BP_ContainerObject missing'); bad = true; }
if (simOut.indexOf('/Game/Blueprints/Machines/BP_BPUnitSto\0', 0, 'latin1') === -1) { console.log('ERROR sim actor package BP_BPUnitSto missing'); bad = true; }
if (simOut.indexOf('BP_BPUnitSto_2_C', 0, 'latin1') === -1) { console.log('ERROR sim actor class BP_BPUnitSto_2_C missing'); bad = true; }
for (const f of [SIM_NEW + '.uasset', SIM_NEW + '.uexp']) {
  const t = fs.readFileSync(path.join(MACH_OUT, f)).toString('latin1');
  for (const s of [SIM_OLD, 'BP_Container\0', 'BP_Container_2']) {
    if (t.indexOf(s) !== -1) { console.log('LEFTOVER ' + JSON.stringify(s) + ' in ' + f); bad = true; }
  }
}
console.log('machine leftover scan done');
}

console.log('leftover scan done');
if (bad) process.exit(2);
console.log('OK');

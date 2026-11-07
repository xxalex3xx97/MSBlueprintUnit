"""Author /Game/BlueprintUnitUI/WBP_BlueprintUnit headlessly (own pak pakchunk102-BPUnitUI_P; was /Game/MiningUnitUI) (Station-Console look, Mining Unit palette).
Run: UnrealEditor-Cmd.exe <uproject> -ExecutePythonScript=<this> -unattended -nullrhi   (expects SAVED)
Names are the Lua contract (see mods\\BlueprintUnitUI). Every widget is a variable. Not run by the build."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from uew import *

FONTS = {}
BPU_DIR = '/Game/BlueprintUnitUI'   # output folder of the window (own pak); donors below stay in ASSETS (/Game/MiningUnitUI)
TRANSIENT = U.find_object(None, '/Engine/Transient')
assert TRANSIENT, 'no transient package'
GOLD = U.LinearColor(1.0, 0.443, 0.0, 1.0)   # game gold, linear (as gen_paste GOLD_RAW)
BODY = lin('3A3A3A', 0.97); INSET = lin('2B2B2B'); OUTLINE = lin('1C1C1C'); BTN = lin('4A4A4A')
DARK = lin('1A1A1A'); WHITE = lin('FFFFFF'); DIM = lin('B0B0B0'); GREEN = lin('5BD35B')


def copy_art():
    # own copies of the header textures: the window must not reference /Game/MiningUnitUI (pak98) at runtime
    for n in ('Header_Bar', 'Header_L', 'Header_R'):
        dst = '%s/Art/T_UI_%s' % (BPU_DIR, n)
        if U.EditorAssetLibrary.does_asset_exist(dst):
            U.EditorAssetLibrary.delete_asset(dst)
        U.EditorAssetLibrary.duplicate_asset('%s/Art/T_UI_%s' % (ASSETS, n), dst)
        U.EditorAssetLibrary.save_asset(dst, only_if_is_dirty=False)


copy_art()


def tex_brush(n, m):
    b = U.SlateBrush()
    b.set_editor_property('draw_as', U.SlateBrushDrawType.BOX)
    v = U.DeprecateSlateVector2D(); v.set_editor_property('x', 40.0); v.set_editor_property('y', 40.0)
    b.set_editor_property('image_size', v)
    b.set_editor_property('margin', U.Margin(*m))
    b.set_editor_property('tint_color', slate_color(U.LinearColor(1, 1, 1, 1)))
    b.set_editor_property('resource_object', U.load_asset('%s/Art/T_UI_%s.T_UI_%s' % (BPU_DIR, n, n)))
    return b


# ---- Is Variable: python cannot set UWidget::bIsVariable (not a reflected-visible property; class default is false for
# TextBlock/Border/panels/ScrollBox) and `Set` console is blocked in the editor. Workaround: take already-variable widgets of the
# same class out of throw-away duplicates of WBP_MiningUnit (rename into our WidgetTree; the rename hook registers the GUID). Variable-by-default classes (Button, Image) need no trick.
POOL_CLS = ('Border', 'HorizontalBox', 'VerticalBox', 'TextBlock', 'ScrollBox')
pool = {c: [] for c in POOL_CLS}
srcs = []


def fill_pool():
    path = '%s/WBP_ZSrc%d' % (ASSETS, len(srcs))
    if U.EditorAssetLibrary.does_asset_exist(path):
        U.EditorAssetLibrary.delete_asset(path)
    U.EditorAssetLibrary.duplicate_asset(ASSETS + '/WBP_MiningUnit', path)
    s = U.load_asset(path)
    srcs.append(path)
    U.BlueprintEditorLibrary.compile_blueprint(s)
    cdo = U.get_default_object(s.generated_class())

    def walk(x):
        c = x.get_class().get_name()
        if c in pool:
            try:
                cdo.get_editor_property(x.get_name())
                pool[c].append(x)
            except Exception:
                pass
        if isinstance(x, U.PanelWidget):
            for i in range(x.get_children_count()):
                walk(x.get_child_at(i))
    walk(ELib.find_source_widget_by_name(s, 'Panel'))


def mk(cls, name, parent=''):
    c = cls.static_class().get_name()
    if c not in pool:
        return add(wbp, cls, name, parent)
    if not pool[c]:
        fill_pool()
    par = ELib.find_source_widget_by_name(wbp, parent)
    w = add(wbp, cls, name, parent)   # registers the GUID for `name`; then park the placeholder (same name, other outer: GUID stays)
    par.remove_child(w)
    if w.get_parent():
        par.remove_child_at(par.get_child_index(w))
    w.rename(None, TRANSIENT)
    p = pool[c].pop()
    p.remove_from_parent()
    if isinstance(p, U.PanelWidget):
        p.clear_children()
    p.rename(name, tree)   # GUID already registered by the placeholder
    par.add_child(p)
    p.set_visibility(U.SlateVisibility.VISIBLE if c in ('ScrollBox', 'Border') else U.SlateVisibility.SELF_HIT_TEST_INVISIBLE)
    return p


def border(name, parent, color, ipad=None, brush=None, **sl):
    b = mk(U.Border, name, parent)
    b.set_editor_property('brush_color', color)
    b.set_editor_property('background', brush if brush is not None else U.SlateBrush())
    b.set_editor_property('padding', U.Margin(*(ipad or (0, 0, 0, 0))))
    b.set_editor_property('content_color_and_opacity', U.LinearColor(1, 1, 1, 1))
    if sl:
        slot(b, **sl)
    return b


def box(cls, name, parent, **sl):
    b = mk(cls, name, parent)
    if sl:
        slot(b, **sl)
    return b


def txt(name, parent, s, size=15, color=WHITE, wrap=False, **sl):
    t = mk(U.TextBlock, name, parent)
    t.set_editor_property('text', U.Text(s))
    f = t.get_editor_property('font'); f.set_editor_property('size', size)
    try:
        f.set_editor_property('typeface_font_name', 'Regular')   # regular weight, not bold
    except Exception as e:
        print('TYPEFACE-NOTSET', e)
    t.set_editor_property('font', f)
    t.set_editor_property('color_and_opacity', slate_color(color))
    t.set_editor_property('auto_wrap_text', wrap)
    FONTS[name] = size
    t.set_editor_property('justification', U.TextJustify.LEFT)
    t.set_editor_property('text_overflow_policy', U.TextOverflowPolicy.CLIP)
    if sl:
        slot(t, **sl)
    return t


def header(key, parent, title_name, title, size=20):
    """game header, fixed 40 px tall: gold Header_L tab (auto width, text inset 20/20, centred) + gold Header_Bar line"""
    sizebox('Row_HeadSize' + key, parent, None, 40, h='Fill')
    box(U.HorizontalBox, 'Row_Header' + key, 'Row_HeadSize' + key, h='Fill', v='Fill')
    border('Row_Tab' + key, 'Row_Header' + key, GOLD, (20, 0, 20, 0), tex_brush('Header_L', (0.40, 0.50, 0.40, 0.25)), v='Fill')
    txt(title_name, 'Row_Tab' + key, title, size, DARK, v='Center')
    border('Row_Line' + key, 'Row_Header' + key, GOLD, None, tex_brush('Header_Bar', (0.49, 0.175, 0.49, 0.35)),
           fill=1.0, h='Fill', v='Fill')


def cap(key, btn, tname, label, size=20, pad=(14, 6, 14, 6)):
    """gold Header_R cap at the right end of Row_Header<key> holding a transparent button with dark label"""
    border('Row_%sCap' % btn, 'Row_Header' + key, GOLD, None, tex_brush('Header_R', (0.40, 0.20, 0.20, 0.25)), v='Fill')
    b = add(wbp, U.Button, btn, 'Row_%sCap' % btn)
    slot(b, h='Fill', v='Fill')
    nb = U.SlateBrush(); nb.set_editor_property('draw_as', U.SlateBrushDrawType.NO_DRAW_TYPE)
    b.set_editor_property('widget_style', button_style(nb, round_brush(lin('FFFFFF', 0.2), 4.0), round_brush(lin('000000', 0.25), 4.0)))
    txt(tname, btn, label, size, DARK, h='Center', v='Center', pad=pad)


def big_btn(name, tname, label, parent, pad):
    b = add(wbp, U.Button, name, parent)
    slot(b, fill=1.0, h='Fill', pad=pad)
    b.set_editor_property('widget_style', button_style(round_brush(BTN), round_brush(lin('5C5C5C')), round_brush(lin('333333'))))
    t = txt(tname, name, label, 18, WHITE, h='Center', v='Center', pad=(0, 16, 0, 16))
    t.set_editor_property('justification', U.TextJustify.CENTER)


wbp = new_wbp('WBP_BlueprintUnit', BPU_DIR)
root = add(wbp, U.Overlay, 'Root', '', var=False)   # Overlay default non-variable; Panel below is the contract root
tree = root.get_outer()
# frame: outline > body (Mining Unit window convention)
def sizebox(name, parent, wd, ht, **sl):
    z = add(wbp, U.SizeBox, name, parent, var=False)
    for k, v in (('bOverride_WidthOverride', wd is not None), ('bOverride_HeightOverride', True)):   # flags: UMG SizeBox needs them True
        try:
            z.set_editor_property(k, v)
        except Exception as e:
            print('SIZEBOX-FLAG-NOTSET', k, e)
    if wd is not None:
        z.set_editor_property('width_override', float(wd))
    z.set_editor_property("height_override", float(ht))
    if sl:
        slot(z, **sl)
    return z


# fixed centred 1280x960 frame, independent of the viewport slot; modal stays outside (full-screen backdrop)
sizebox('Frame_Size', 'Root', 1280, 960, h='Center', v='Center')
border('Panel', 'Frame_Size', OUTLINE, (2, 2, 2, 2), h='Fill', v='Fill')
border('Row_Body', 'Panel', BODY, (10, 10, 10, 10), h='Fill', v='Fill')
box(U.HorizontalBox, 'Row_Cols', 'Row_Body', h='Fill', v='Fill')

# LEFT ~28%: Modification Cost (rows = game WBP_ItemAmount_C added by Lua into Scr_Cost)
box(U.VerticalBox, 'Row_CostCol', 'Row_Cols', fill=0.28, h='Fill', v='Fill', pad=(0, 0, 12, 0))
header('Cost', 'Row_CostCol', 'Txt_CostHdr', u'\u25bc Modification Cost', 16)
cap('Cost', 'Btn_CostPin', 'Txt_CostPin', 'Pin', 14, (12, 6, 12, 6))   # visual only
border('Row_CostInset', 'Row_CostCol', INSET, (16, 12, 16, 12), fill=1.0, h='Fill', v='Fill', pad=(0, 8, 0, 0))
box(U.VerticalBox, 'Row_CostStack', 'Row_CostInset', h='Fill', v='Fill')
txt('Txt_CostEmpty', 'Row_CostStack', 'No import yet', 14, DIM, h='Fill', pad=(0, 0, 0, 8))   # outside the ScrollBox: ClearChildren keeps it
box(U.ScrollBox, 'Scr_Cost', 'Row_CostStack', fill=1.0, h='Fill', v='Fill')

# RIGHT: title bar + close X, status, Import/Build, unit grid, player grid
box(U.VerticalBox, 'Row_Right', 'Row_Cols', fill=0.72, h='Fill', v='Fill')
header('Main', 'Row_Right', 'Txt_Title', 'Blueprint Unit', 20)
cap('Main', 'Btn_Close', 'Txt_Close', 'X')

border('Row_Inset', 'Row_Right', INSET, (16, 12, 16, 12), fill=1.0, h='Fill', v='Fill', pad=(0, 8, 0, 0))
box(U.VerticalBox, 'Row_Stack', 'Row_Inset', h='Fill', v='Fill')
txt('Txt_Status', 'Row_Stack', '', 16, WHITE, wrap=True, h='Fill', pad=(0, 0, 0, 8))
txt('Txt_Summary', 'Row_Stack', '', 14, WHITE, wrap=True, h='Fill', pad=(0, 0, 0, 8))
txt('Txt_Removes', 'Row_Stack', '', 12, DIM, wrap=True, h='Fill', pad=(0, 0, 0, 10)).set_visibility(U.SlateVisibility.COLLAPSED)
box(U.HorizontalBox, 'Row_Buttons', 'Row_Stack', h='Fill', pad=(0, 4, 0, 12))
big_btn('Btn_Import', 'Txt_Import', 'Import', 'Row_Buttons', (0, 0, 6, 0))
big_btn('Btn_Build', 'Txt_Build', 'Build', 'Row_Buttons', (6, 0, 0, 0))
txt('Txt_UnitInvTitle', 'Row_Stack', 'Block inventory', 16, GOLD, pad=(0, 0, 0, 8))
# inventory hosts: auto-size (Fill=0) Left/Top wrappers so WBP_Inventory_C's UniformGridPanel gets its natural width (no cell stretch);
# vertical Fill weights (unit 0.5 / player 0.35) wrap them. ScrollBox desired width = content width, so Scr_UnitInv hugs the 8 columns.
box(U.HorizontalBox, 'Row_UnitInvWrap', 'Row_Stack', fill=0.5, h='Fill', v='Fill', pad=(0, 0, 0, 12))
border('Row_UnitInvFrame', 'Row_UnitInvWrap', OUTLINE, (2, 2, 14, 2), h='Left', v='Fill')
box(U.ScrollBox, 'Scr_UnitInv', 'Row_UnitInvFrame')
txt('Txt_PlayerInvTitle', 'Row_Stack', 'Player Inventory', 16, GOLD, pad=(0, 0, 0, 8))
box(U.HorizontalBox, 'Row_PlayerWrap', 'Row_Stack', fill=0.35, h='Fill', v='Fill')
border('Host_PlayerInv', 'Row_PlayerWrap', lin('242424'), (4, 4, 4, 4), h='Left', v='Top')
for n in ('Row_UnitInvFrame', 'Host_PlayerInv'):
    w = ELib.find_source_widget_by_name(wbp, n)
    w.set_editor_property('horizontal_alignment', U.HorizontalAlignment.H_ALIGN_LEFT)
    w.set_editor_property('vertical_alignment', U.VerticalAlignment.V_ALIGN_TOP)

# ---- Import modal: last child of Root overlay => on top. Pnl_ImportModal (Border, variable) = dim backdrop (blocks clicks) + centred 640x420 box.
border('Pnl_ImportModal', 'Root', lin('000000', 0.6), None, h='Fill', v='Fill')
pm = ELib.find_source_widget_by_name(wbp, 'Pnl_ImportModal')
pm.set_editor_property('horizontal_alignment', U.HorizontalAlignment.H_ALIGN_CENTER)
pm.set_editor_property('vertical_alignment', U.VerticalAlignment.V_ALIGN_CENTER)
sizebox('Row_ImportSize', 'Pnl_ImportModal', 640, 420)
border('Row_ImportOutline', 'Row_ImportSize', OUTLINE, (2, 2, 2, 2), h='Fill', v='Fill')
border('Row_ImportBody', 'Row_ImportOutline', BODY, (14, 12, 14, 12), h='Fill', v='Fill')
box(U.VerticalBox, 'Row_ImportStack', 'Row_ImportBody', h='Fill', v='Fill')
header('Imp', 'Row_ImportStack', 'Txt_ImportTitle', 'Import blueprint', 20)
cap('Imp', 'Btn_ImportClose', 'Txt_ImportClose', 'X')
ed = add(wbp, U.MultiLineEditableTextBox, 'Edt_ImportJson', 'Row_ImportStack')
slot(ed, fill=1.0, h='Fill', v='Fill', pad=(0, 10, 0, 6))
ed.set_editor_property('hint_text', U.Text('Paste the blueprint JSON here'))
ws = ed.get_editor_property('widget_style')
blk = slate_color(lin('000000'))
tsty = ws.get_editor_property('text_style')
f = tsty.get_editor_property('font'); f.set_editor_property('size', 14); tsty.set_editor_property('font', f)
tsty.set_editor_property('color_and_opacity', blk)
ws.set_editor_property('text_style', tsty)
for k in ('foreground_color', 'focused_foreground_color', 'read_only_foreground_color'):
    ws.set_editor_property(k, blk)
ed.set_editor_property('widget_style', ws)
txt('Txt_ImportHint', 'Row_ImportStack', 'Ctrl+V to paste, then press Import', 12, DIM, h='Fill', pad=(0, 0, 0, 8))
box(U.HorizontalBox, 'Row_ImportBtns', 'Row_ImportStack', h='Right')
for bn, tn, lb, pd in (('Btn_ImportOk', 'Txt_ImportOk', 'Import', (0, 0, 8, 0)), ('Btn_ImportCancel', 'Txt_ImportCancel', 'Cancel', (0, 0, 0, 0))):
    b = add(wbp, U.Button, bn, 'Row_ImportBtns')
    slot(b, pad=pd)
    b.set_editor_property('widget_style', button_style(round_brush(BTN), round_brush(lin('5C5C5C')), round_brush(lin('333333'))))
    txt(tn, bn, lb, 18, WHITE, h='Center', v='Center', pad=(24, 8, 24, 8)).set_editor_property('justification', U.TextJustify.CENTER)
pm.set_visibility(U.SlateVisibility.COLLAPSED)

save(wbp)
for p in srcs:
    U.EditorAssetLibrary.delete_asset(p)
print('FONTS', FONTS)
print('SAVED')

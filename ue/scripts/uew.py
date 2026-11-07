"""Headless UMG authoring helpers (UnrealEditor-Cmd -ExecutePythonScript). Colors/sizes mirror gen_paste.py."""
import unreal

ASSETS = '/Game/MiningUnitUI'
U = unreal
ELib = unreal.EditorUtilityLibrary


def _srgb(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lin(hex_rgb, a=1.0):
    return U.LinearColor(*(_srgb(int(hex_rgb[i:i + 2], 16)) for i in (0, 2, 4)), a)


def slate_color(c):
    return U.SlateColor(specified_color=c)


def round_brush(c, r=6.0):
    b = U.SlateBrush()
    b.set_editor_property('draw_as', U.SlateBrushDrawType.ROUNDED_BOX)
    o = U.SlateBrushOutlineSettings()
    o.set_editor_property('corner_radii', U.Vector4(r, r, r, r))
    o.set_editor_property('rounding_type', U.SlateBrushRoundingType.FIXED_RADIUS)
    b.set_editor_property('outline_settings', o)
    b.set_editor_property('tint_color', slate_color(c))
    return b


def image_brush(path, tint, size):
    b = U.SlateBrush()
    b.set_editor_property('draw_as', U.SlateBrushDrawType.IMAGE)
    v = U.DeprecateSlateVector2D(); v.set_editor_property('x', size); v.set_editor_property('y', size)
    b.set_editor_property('image_size', v)
    b.set_editor_property('tint_color', slate_color(tint))
    b.set_editor_property('resource_object', U.load_asset(path))
    return b


def button_style(normal, hover, pressed):
    s = U.ButtonStyle()
    s.set_editor_property('normal', normal)
    s.set_editor_property('hovered', hover)
    s.set_editor_property('pressed', pressed)
    return s


def new_wbp(name, folder=ASSETS):
    path = '%s/%s' % (folder, name)
    if U.EditorAssetLibrary.does_asset_exist(path):
        U.EditorAssetLibrary.delete_asset(path)
    f = U.WidgetBlueprintFactory()
    f.set_editor_property('parent_class', U.UserWidget)
    return U.AssetToolsHelpers.get_asset_tools().create_asset(name, folder, U.WidgetBlueprint, f)


def add(wbp, cls, name, parent='', var=True):
    w = ELib.add_source_widget(wbp, cls, name, parent)
    try:
        w.set_editor_property('is_variable', var)
    except Exception:
        pass
    return w


def slot(w, pad=None, fill=None, h=None, v=None):
    s = w.slot
    if pad is not None:
        l, t, r, b = pad
        s.set_editor_property('padding', U.Margin(l, t, r, b))
    if fill is not None:
        s.set_editor_property('size', U.SlateChildSize(value=fill, size_rule=U.SlateSizeRule.FILL))
    if h:
        s.set_editor_property('horizontal_alignment', getattr(U.HorizontalAlignment, 'H_ALIGN_' + h.upper()))
    if v:
        s.set_editor_property('vertical_alignment', getattr(U.VerticalAlignment, 'V_ALIGN_' + v.upper()))


def save(wbp):
    U.BlueprintEditorLibrary.compile_blueprint(wbp)
    U.EditorAssetLibrary.save_loaded_asset(wbp, False)


def text(wbp, name, parent, size=14, color=None, wrap=False, var=False, slot_kw=None):
    t = add(wbp, U.TextBlock, name, parent, var)
    t.set_editor_property('text', U.Text(''))
    f = t.get_editor_property('font'); f.set_editor_property('size', size); t.set_editor_property('font', f)
    if color is not None:
        t.set_editor_property('color_and_opacity', slate_color(color))
    if wrap:
        t.set_editor_property('auto_wrap_text', True)
    if slot_kw:
        slot(t, **slot_kw)
    return t


def icon_button(wbp, name, parent, icon, size_px, tint, box=None):
    """transparent icon button (NoDrawType) with an Image child; box=(w,h) wraps it in a SizeBox"""
    if box:
        sz = add(wbp, U.SizeBox, 'Sz_' + name, parent)
        sz.set_editor_property('width_override', float(box[0])); sz.set_editor_property('height_override', float(box[1]))
        parent = 'Sz_' + name
    b = add(wbp, U.Button, name, parent)
    nb = U.SlateBrush(); nb.set_editor_property('draw_as', U.SlateBrushDrawType.NO_DRAW_TYPE)
    b.set_editor_property('widget_style', button_style(nb, nb, nb))
    im = add(wbp, U.Image, 'Img_' + name, name)
    im.set_editor_property('brush', image_brush('/Game/MiningUnitUI/%s.%s' % (icon, icon), tint, size_px))
    slot(im, h='Center', v='Center')
    return b


def remove(wbp, name):
    """detach a widget from its parent panel; verified (ScrollBox ignores remove_child, so fall back to remove_child_at)"""
    w = ELib.find_source_widget_by_name(wbp, name)
    par = w.get_parent() if w else None
    if not par:
        return False
    par.remove_child(w)
    if w.get_parent():
        par.remove_child_at(par.get_child_index(w))
    if w.get_parent():
        w.set_editor_property('visibility', U.SlateVisibility.COLLAPSED)
        print('REMOVE-FALLBACK collapsed', name)
        return False
    return True


def dyn_box(wbp, name, parent, entry_wbp, spacing=6.0):
    d = ELib.find_source_widget_by_name(wbp, name) or add(wbp, U.DynamicEntryBox, name, parent)
    d.set_editor_property('entry_widget_class', U.load_class(None, '%s/%s.%s_C' % (ASSETS, entry_wbp, entry_wbp)))
    d.set_editor_property('entry_box_type', U.DynamicBoxType.VERTICAL)
    d.set_editor_property('entry_spacing', U.Vector2D(0.0, spacing))
    d.set_editor_property('entry_horizontal_alignment', U.HorizontalAlignment.H_ALIGN_FILL)
    return d


def move_last(panel_name, wbp, child_name):
    """move an existing child to the end of its panel (VerticalBox / ScrollBox)"""
    p = ELib.find_source_widget_by_name(wbp, panel_name)
    c = ELib.find_source_widget_by_name(wbp, child_name)
    p.remove_child(c)
    (p.add_child if isinstance(p, U.ScrollBox) else p.add_child_to_vertical_box)(c)
    return c


def dyn_list(wbp, name, parent, row_wbp, add_btn=None, spacing=6.0, **slot_kw):
    """The one way to make a list: DynamicEntryBox `name` (vertical, full width) of `row_wbp` under panel `parent`;
    add_btn = optional size-box name of an Add button that must sit after the list."""
    d = dyn_box(wbp, name, parent, row_wbp, spacing)
    slot(d, h='Fill', **slot_kw)
    if add_btn:
        p = ELib.find_source_widget_by_name(wbp, parent)
        a = ELib.find_source_widget_by_name(wbp, add_btn)
        if p.get_child_index(a) < p.get_child_index(d):
            move_last(parent, wbp, add_btn)
            slot(a, pad=(0, 4, 0, 0), h='Fill')
    return d

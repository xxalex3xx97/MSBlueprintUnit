"""Check every WBP_BlueprintUnit contract name exists and is a variable. Prints MISSING/NOTVAR lines, then CHECK-DONE."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from uew import *
wbp = U.load_asset(ASSETS + '/WBP_BlueprintUnit')
U.BlueprintEditorLibrary.compile_blueprint(wbp)
cdo = U.get_default_object(wbp.generated_class())  # a widget is a variable iff the generated class has a property of its name
names = ['Panel', 'Txt_Title', 'Btn_Close', 'Txt_Close', 'Txt_Status', 'Btn_Import', 'Txt_Import', 'Btn_Build', 'Txt_Build',
         'Txt_CostHdr', 'Btn_CostPin', 'Txt_CostPin', 'Scr_Cost', 'Txt_CostEmpty', 'Txt_UnitInvTitle', 'Scr_UnitInv', 'Txt_PlayerInvTitle', 'Host_PlayerInv',
         'Txt_Summary', 'Txt_Removes', 'Pnl_ImportModal', 'Txt_ImportTitle', 'Btn_ImportClose', 'Txt_ImportClose', 'Edt_ImportJson',
         'Btn_ImportOk', 'Txt_ImportOk', 'Btn_ImportCancel', 'Txt_ImportCancel', 'Txt_ImportHint']
gone = [n for n in ('Row_Cost_1', 'Img_Cost_1', 'Txt_CostHave_1', 'Txt_CostName_1', 'Txt_CostRefund_1', 'Row_Cost_40') if ELib.find_source_widget_by_name(wbp, n)]
print('LEFTOVER-ROWS', gone)
for n in ('Txt_Title', 'Txt_CostHdr', 'Txt_Status', 'Txt_Summary', 'Txt_Removes', 'Txt_Import', 'Txt_Build', 'Txt_UnitInvTitle', 'Txt_PlayerInvTitle', 'Txt_CostEmpty', 'Txt_CostPin'):
    t = ELib.find_source_widget_by_name(wbp, n)
    print('FONT', n, t.get_editor_property('font').get_editor_property('size'), 'wrap', t.get_editor_property('auto_wrap_text'))
miss = nonvar = 0
for n in names:
    w = ELib.find_source_widget_by_name(wbp, n)
    if not w:
        print('MISSING', n); miss += 1
    else:
        try:
            cdo.get_editor_property(n)
        except Exception:
            print('NOTVAR', n); nonvar += 1
def chain(w):
    o = []
    while w:
        o.append(w.get_name()); w = w.get_parent()
    return ' < '.join(o)
for n in ('Frame_Size', 'Row_ImportSize'):
    z = ELib.find_source_widget_by_name(wbp, n)
    print('SIZEBOX', n, z.get_class().get_name(), 'W', z.get_editor_property('width_override'), 'H', z.get_editor_property('height_override'),
          'bW', z.get_editor_property('bOverride_WidthOverride'), 'bH', z.get_editor_property('bOverride_HeightOverride'))
fz = ELib.find_source_widget_by_name(wbp, 'Frame_Size')
print('SLOT', type(fz.slot).__name__, 'h', fz.slot.get_editor_property('horizontal_alignment'), 'v', fz.slot.get_editor_property('vertical_alignment'))
pn = ELib.find_source_widget_by_name(wbp, 'Panel')
print('PANEL-SLOT', type(pn.slot).__name__, 'h', pn.slot.get_editor_property('horizontal_alignment'), 'v', pn.slot.get_editor_property('vertical_alignment'))
print('PATH Panel', chain(pn))
print('PATH Pnl_ImportModal', chain(ELib.find_source_widget_by_name(wbp, 'Pnl_ImportModal')))
root = ELib.find_source_widget_by_name(wbp, 'Root')
print('ROOT', root.get_class().get_name(), [root.get_child_at(i).get_name() for i in range(root.get_children_count())])
print('EDT_CLASS', ELib.find_source_widget_by_name(wbp, 'Edt_ImportJson').get_class().get_name())
print('CHECK-DONE n_missing=%d n_notvar=%d total=%d' % (miss, nonvar, len(names)))

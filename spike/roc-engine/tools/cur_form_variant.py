"""cur_form_variant.py SRC_DIR OUT_DIR N MID -- copy of the original
form-builder whose initial schema has N generated fields (same generator as
the p4 bench: kinds cycle text, number, email, select), plus host-bench specs
for mount and the measured events on field MID."""
import sys, os, shutil
src, out, n, mid = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(src, out)
p = os.path.join(out, 'Form.roc')
s = open(p).read()
a = s.index('\tinitial_schema : Form.Schema')
b = s.index('\tinitial_answers : List(Form.Answer)')
s = s[:a] + f'''\tinitial_schema : Form.Schema
\tinitial_schema = Form.schema_of({n})

\tschema_of : U64 -> Form.Schema
\tschema_of = |n| {{
\t\tvar $s = {{ seq: 0, fields: [] }}
\t\tvar $i = 0.U64
\t\twhile $i < n {{
\t\t\tkind = match $i % 4 {{
\t\t\t\t0 => Form.text_kind
\t\t\t\t1 => Form.number_kind
\t\t\t\t2 => Form.email_kind
\t\t\t\t_ => Form.select_kind
\t\t\t}}
\t\t\t$s = Form.add_field($s, kind)
\t\t\t$i = $i + 1
\t\t}}
\t\t$s
\t}}

''' + s[b:]
open(p, 'w').write(s)
sd = os.path.join(out, 'specs')
shutil.rmtree(sd)
os.makedirs(sd)
specs = {
    'mount': '(expect-visible (test-id "designer-status"))',
    'edit-label': f'(fill (label "Label {mid}") "Renamed")',
    'answer': f'(fill (label "Answer {mid}") "Ada")',
    'toggle-required': f'(check (label "Required {mid}"))',
}
for name, step in specs.items():
    open(os.path.join(sd, name + '.scm'), 'w').write(f'(test "{name}"\n  (steps\n    (mark-metrics)\n    {step}))\n')

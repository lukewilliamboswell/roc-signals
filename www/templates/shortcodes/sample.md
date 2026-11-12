{#- A Roc code sample from www/samples/, which `blueprint run check` compiles.
    `file` names the sample; `region` (optional) selects the lines between
    `# region NAME` and `# endregion NAME`. Each marker is the whole end of
    its line (the end marker may also end the file), so a region `row` does
    not end at `# endregion row-state`. Region marker lines never render. -#}
{%- set text = load_data(path="samples/" ~ file, format="plain") -%}
{%- if region -%}
{%- set text = text ~ "\n" -%}
{%- set text = text | split(pat="# region " ~ region ~ "\n") | nth(n=1) | split(pat="# endregion " ~ region ~ "\n") | first -%}
{%- endif -%}
```{{ syntax | default(value="roc") }}
{% for line in text | trim_end | split(pat="\n") -%}
{%- if line is not containing("# region ") and line is not containing("# endregion ") -%}
{{ line }}
{% endif -%}
{%- endfor -%}
```

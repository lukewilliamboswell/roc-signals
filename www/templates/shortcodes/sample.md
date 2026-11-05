{#- A Roc code sample from www/samples/, which `blueprint run check` compiles.
    `file` names the sample; `region` (optional) selects the lines between
    `# region NAME` and `# endregion NAME`. Region marker lines never render. -#}
{%- set text = load_data(path="samples/" ~ file, format="plain") -%}
{%- if region -%}
{%- set text = text | split(pat="# region " ~ region ~ "\n") | nth(n=1) | split(pat="# endregion " ~ region) | first -%}
{%- endif -%}
```{{ syntax | default(value="roc") }}
{% for line in text | trim_end | split(pat="\n") -%}
{%- if line is not containing("# region ") and line is not containing("# endregion ") -%}
{{ line }}
{% endif -%}
{%- endfor -%}
```

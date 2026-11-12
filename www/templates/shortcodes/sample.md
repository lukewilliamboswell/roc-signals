{# Escaped parser-backed HTML is generated from the checked sample files by site.roc. #}
{%- set name = "highlighted/" ~ file ~ "/full.html" -%}
{%- if region -%}
{%- set name = "highlighted/" ~ file ~ "/regions/" ~ region ~ ".html" -%}
{%- endif -%}
<pre class="sample-code" data-sample-file="{{ file }}" data-sample-region="{{ region | default(value='') }}"><code class="language-{{ syntax | default(value="roc") }}">{{ load_data(path=name, format="plain") | safe }}</code></pre>

{{ define "personality" }}
{{- /*
  Default empty personality block.

  Cities can override this fragment in their own template-fragments/
  directory to inject city-specific identity into the mayor (or any
  other agent that references {{ template "personality" . }}).

  Example override:

    {{ define "personality" }}
    You are Mayor Euler, the mathematically-inclined coordinator
    of this Math City.
    {{ end }}
*/ -}}
{{ end }}

{{/*
Labels every object carries. Pod templates and selectors deliberately do NOT use these:
the controller's Service, the NetworkPolicies and the worker pods select on fixed labels
(`app.kubernetes.io/name`, `app.kubernetes.io/component`) the controller itself writes.
*/}}
{{- define "arbiter-node.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: arbiter
{{- end -}}

{{/* True ("true") when this release renders the cluster-admin guardrails. */}}
{{- define "arbiter-node.bootstrap" -}}
{{- if has .Values.mode (list "all" "bootstrap") -}}true{{- end -}}
{{- end -}}

{{/* True ("true") when this release renders the controller and its RBAC. */}}
{{- define "arbiter-node.node" -}}
{{- if has .Values.mode (list "all" "node") -}}true{{- end -}}
{{- end -}}

{{/* The node name the primary knows this controller by. The release name unless set. */}}
{{- define "arbiter-node.nodeName" -}}
{{- default .Release.Name .Values.node.name -}}
{{- end -}}

{{/* The controller image: a digest wins over a tag; the tag defaults to the chart's appVersion. */}}
{{- define "arbiter-node.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ default .Chart.AppVersion .Values.image.tag }}
{{- end -}}
{{- end -}}

{{/* The tailscale sidecar image, pinned by tag and digest. */}}
{{- define "arbiter-node.tailscaleImage" -}}
{{- $i := .Values.reach.tailscale.image -}}
{{ $i.repository }}:{{ $i.tag }}{{ if $i.digest }}@{{ $i.digest }}{{ end }}
{{- end -}}

{{/* The port of a URL: the explicit one, else the scheme's default. */}}
{{- define "arbiter-node.urlPort" -}}
{{- $u := urlParse . -}}
{{- $port := regexFind ":[0-9]+$" $u.host | trimPrefix ":" -}}
{{- if $port -}}{{ $port }}{{- else if eq $u.scheme "http" -}}80{{- else -}}443{{- end -}}
{{- end -}}

{{/*
A map of Kubernetes quantities as YAML, every value a string: `--set cpu=2` makes an
integer, and a quantity in a manifest or in controller.yaml is a string.
Usage: include "arbiter-node.quantities" $map
*/}}
{{- define "arbiter-node.quantities" -}}
{{- range $k, $v := . }}
{{ $k }}: {{ toString $v | quote }}
{{- end }}
{{- end -}}

{{/* The imagePullSecrets list of the controller pod. */}}
{{- define "arbiter-node.pullSecrets" -}}
{{- range .Values.imagePullSecrets }}
- name: {{ . | quote }}
{{- end }}
{{- end -}}

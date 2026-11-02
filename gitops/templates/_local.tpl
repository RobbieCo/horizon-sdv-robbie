{{/*
Copyright (c) 2026 Accenture, All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

{{/*
horizon.local.ingress renders a single ingress-nginx Ingress that replaces the
GKE Gateway HTTPRoute for one in-scope service when config.local.enabled is true.
It is a no-op in production (callers guard with {{- if .Values.config.local.enabled }}).

Expected dict keys:
  root         - the root context ($), used for config.* access.
  name         - Ingress metadata.name.
  namespace    - service namespace (namespacePrefix is prepended).
  serviceName  - backend Service name.
  servicePort  - backend Service port number.
  pathPrefix   - HTTP path prefix (e.g. /horizon-api, /auth).
  stripPrefix  - true => rewrite the prefix away (backend sees /); false => pass path through.
  appRoot      - optional; redirect host root "/" to this path (portal only).
  proxyTimeout - optional; nginx proxy read/send timeout seconds (default 3600).
  syncWave     - optional; Argo CD sync-wave annotation (default "7").
*/}}
{{- define "horizon.local.ingress" -}}
{{- $root := .root -}}
{{- $cfg := $root.Values.config -}}
{{- $local := $cfg.local -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .name }}
  namespace: {{ $cfg.namespacePrefix }}{{ .namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ .syncWave | default "7" | quote }}
    {{- if .stripPrefix }}
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    {{- end }}
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: {{ .proxyTimeout | default "3600" | quote }}
    nginx.ingress.kubernetes.io/proxy-send-timeout: {{ .proxyTimeout | default "3600" | quote }}
    {{- if .appRoot }}
    nginx.ingress.kubernetes.io/app-root: {{ .appRoot | quote }}
    {{- end }}
spec:
  ingressClassName: {{ $local.ingressClassName }}
  {{- if $local.tlsSecretName }}
  tls:
    - hosts:
        - {{ $cfg.domain }}
      secretName: {{ $local.tlsSecretName }}
  {{- end }}
  rules:
    - host: {{ $cfg.domain }}
      http:
        paths:
          - path: {{ if .stripPrefix }}{{ .pathPrefix }}(/|$)(.*){{ else }}{{ .pathPrefix }}{{ end }}
            pathType: {{ if .stripPrefix }}ImplementationSpecific{{ else }}Prefix{{ end }}
            backend:
              service:
                name: {{ .serviceName }}
                port:
                  number: {{ .servicePort }}
{{- end -}}

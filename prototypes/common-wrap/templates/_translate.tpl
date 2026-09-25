{{/*
  nilchela -> bjw-s common: the only place the two vocabularies meet.

  Emits the values shape that `bjw-s.common.loader.all` renders from. The output is
  written as YAML text and re-parsed by the caller (`| fromYaml`) rather than built
  with nested `dict` calls: the target shape is app-template's, so the most
  reviewable form for it is YAML.

  NOT YET RENDERED — no helm binary was available where this was written. Stated
  plainly because it is unverified code, not production code. See README.md.
*/}}
{{- define "nilchela.translate" -}}
{{- $v := .Values -}}
{{- $image := $v.image | default dict -}}
{{- $gw := $v.gateway | default dict -}}
{{- $svc := $gw.service | default dict -}}
{{- $svcEnabled := $svc.enabled | default true -}}
{{- $userEnv := $v.env | default dict -}}
{{- $storage := $v.storage | default dict -}}
{{- $tools := $v.tools | default dict -}}
{{- $sched := $v.scheduling | default dict -}}
{{- $res := $v.resources | default dict -}}
{{- $repo := $image.repository | default "ghcr.io/infiniteprimates/nilchela" -}}
{{- $tag := $image.tag | default .Chart.AppVersion -}}
{{- $pull := $image.pullPolicy | default "IfNotPresent" -}}
{{- $toolsSize := ($storage.tools | default dict).size | default "10Gi" -}}
{{- $cacheSize := ($storage.cache | default dict).size | default "5Gi" -}}
{{- $dataSize := ($storage.data | default dict).size | default "10Gi" -}}
{{- $svcType := $svc.type | default "ClusterIP" -}}
{{- $svcPort := $svc.port | default 42617 -}}
{{- with $sched }}
defaultPodOptions:
  {{- toYaml . | nindent 2 }}
{{- end }}
controllers:
  main:
    type: statefulset
    containers:
      main:
        image:
          repository: {{ $repo }}
          tag: {{ $tag | quote }}
          pullPolicy: {{ $pull }}
        {{- if or $svcEnabled (gt (len $userEnv) 0) }}
        env:
          {{- if $svcEnabled }}
          ZEROCLAW_gateway__host: "0.0.0.0"
          ZEROCLAW_gateway__allow_public_bind: "true"
          {{- end }}
          {{- range $k, $val := $userEnv }}
          {{ $k }}: {{ $val | quote }}
          {{- end }}
        {{- end }}
        securityContext:
          runAsUser: 65534
          runAsGroup: 65534
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        {{- with $res }}
        resources:
          {{- toYaml . | nindent 10 }}
        {{- end }}
    initContainers:
      fix-ownership:
        image:
          repository: {{ $repo }}
          tag: {{ $tag | quote }}
          pullPolicy: {{ $pull }}
        command: ["chown"]
        args: ["65534:65534", "/cache", "/zeroclaw-data"]
        securityContext:
          runAsUser: 0
          runAsGroup: 0
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
      install-tools:
        dependsOn: fix-ownership
        image:
          repository: {{ $repo }}
          tag: {{ $tag | quote }}
          pullPolicy: {{ $pull }}
        command: ["mise"]
        args: ["install"]
        securityContext:
          runAsUser: 0
          runAsGroup: 0
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
{{- if $svcEnabled }}
service:
  main:
    controller: main
    type: {{ $svcType }}
    ports:
      http:
        port: {{ $svcPort }}
        protocol: HTTP
        primary: true
{{- end }}
persistence:
  tools:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: {{ $toolsSize }}
    retain: true
    # The tools volume is mounted by identity in two places: writable for the root
    # installer, read-only for the non-root agent. That split is what lets the agent
    # execute toolchains it cannot overwrite.
    advancedMounts:
      main:
        install-tools:
          - path: /tools
        main:
          - path: /tools
            readOnly: true
  cache:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: {{ $cacheSize }}
    retain: true
    globalMounts:
      - path: /cache
  data:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: {{ $dataSize }}
    retain: true
    globalMounts:
      - path: /zeroclaw-data
  config:
    type: configMap
    identifier: config
    globalMounts:
      - path: /config
        readOnly: true
configMaps:
  config:
    data:
      mise.toml: |
        # Rendered from .Values.tools — pin exactly, no ranges.
        [tools]
        {{- range $k, $val := $tools }}
        {{- if not (kindIs "map" $val) }}
        {{ $k }} = {{ $val | quote }}
        {{- end }}
        {{- end }}
        {{- range $k, $val := $tools }}
        {{- if kindIs "map" $val }}
        [tools.{{ $k }}]
        {{- range $ik, $iv := $val }}
        {{ $ik }} = {{ if kindIs "string" $iv }}{{ $iv | quote }}{{ else }}{{ $iv }}{{ end }}
        {{- end }}
        {{- end }}
        {{- end }}

        # Toolchain cache redirection is policy, not boilerplate: each tool has its
        # own variable, so mise cannot infer them. Keeps disposable registries off
        # the durable /zeroclaw-data volume.
        [env]
        CARGO_HOME       = "/cache/cargo"
        GOMODCACHE       = "/cache/go/pkg/mod"
        GOCACHE          = "/cache/go-build"
        NPM_CONFIG_CACHE = "/cache/npm"
        UV_CACHE_DIR     = "/cache/uv"
{{- end -}}

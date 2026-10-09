{{/*
  The translation seam: nilchela's value keys -> the shape that
  `bjw-s.common.loader.all` renders from.

  Emits the values shape that `bjw-s.common.loader.all` renders from. The output
  is written as YAML text and re-parsed by the caller (`| fromYaml`) rather than
  built with nested `dict` calls: the target shape is the library's, so the most
  reviewable form for it is YAML.

  Everything user-facing is decided below. Nothing here reads a key that is not
  described in values.yaml + values.schema.json, and no key of the library's own
  values interface is reachable from the user's side.

  Guarded by tests/chart_contract.py, which asserts the *rendered* pod model.
*/}}
{{- define "nilchela.translate" -}}
{{- $v := .Values -}}
{{- $image := $v.image | default dict -}}
{{- $gw := $v.gateway | default dict -}}
{{- $svc := $gw.service | default dict -}}
{{- $svcEnabled := ternary $svc.enabled true (hasKey $svc "enabled") -}}
{{- $userEnv := $v.env | default dict -}}
{{- $storage := $v.storage | default dict -}}
{{- $tools := ($v.mise | default dict).tools | default dict -}}
{{- $miseEnv := ($v.mise | default dict).env | default dict -}}
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
{{- $probesCfg := $v.probes | default dict -}}
{{- $probeLive := $probesCfg.liveness | default dict -}}
{{- $probeReady := $probesCfg.readiness | default dict -}}
{{- $probeStart := $probesCfg.startup | default dict -}}
{{- $probeLiveOn := $probeLive.enabled | default false -}}
{{- $probeReadyOn := $probeReady.enabled | default false -}}
{{- $probeStartOn := $probeStart.enabled | default false -}}
{{- $probesOn := or $probeLiveOn (or $probeReadyOn $probeStartOn) -}}
{{- $probePort := $probesCfg.port | default $svcPort -}}
{{- /* The daemon must leave loopback for anything outside the container that has
       to reach it: the Service, and the kubelet's probes. Both probe the pod IP,
       so a probe against a loopback-bound daemon fails — and a liveness probe
       would then restart a pod that was working perfectly. */ -}}
{{- $reachable := or $svcEnabled $probesOn -}}
{{- $toolsSpec := $storage.tools | default dict -}}
{{- $cacheSpec := $storage.cache | default dict -}}
{{- $dataSpec := $storage.data | default dict -}}
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
        {{- if or $reachable (gt (len $userEnv) 0) }}
        env:
          {{- if $reachable }}
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
        {{- if $probesOn }}
        probes:
          {{- if $probeLiveOn }}
          liveness:
            {{- toYaml (mergeOverwrite (dict "enabled" true "type" "HTTP" "path" "/health" "port" $probePort) $probeLive) | nindent 12 }}
          {{- end }}
          {{- if $probeReadyOn }}
          readiness:
            {{- toYaml (mergeOverwrite (dict "enabled" true "type" "HTTP" "path" "/health" "port" $probePort) $probeReady) | nindent 12 }}
          {{- end }}
          {{- if $probeStartOn }}
          startup:
            {{- toYaml (mergeOverwrite (dict "enabled" true "type" "HTTP" "path" "/health" "port" $probePort) $probeStart) | nindent 12 }}
          {{- end }}
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
    {{- if $toolsSpec.existingClaim }}
    existingClaim: {{ $toolsSpec.existingClaim | quote }}
    {{- else }}
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: {{ $toolsSize }}
    retain: true
    {{- with $toolsSpec.storageClass }}
    storageClass: {{ . | quote }}
    {{- end }}
    {{- end }}
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
    {{- if $cacheSpec.existingClaim }}
    existingClaim: {{ $cacheSpec.existingClaim | quote }}
    {{- else }}
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: {{ $cacheSize }}
    retain: true
    {{- with $cacheSpec.storageClass }}
    storageClass: {{ . | quote }}
    {{- end }}
    {{- end }}
    globalMounts:
      - path: /cache
  data:
    {{- if $dataSpec.existingClaim }}
    existingClaim: {{ $dataSpec.existingClaim | quote }}
    {{- else }}
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: {{ $dataSize }}
    retain: true
    {{- with $dataSpec.storageClass }}
    storageClass: {{ . | quote }}
    {{- end }}
    {{- end }}
    globalMounts:
      - path: /zeroclaw-data
  config:
    type: configMap
    identifier: config
    globalMounts:
      - path: /config
        readOnly: true
  {{- /* One projected volume for every agent's credentials. See values.yaml for
         why a mount rather than env, and why the mode cannot isolate agents. The
         <agent>/<app>/ prefix is generated here rather than accepted from the
         user: it is the interface the per-agent path allowlist keys on, so it is
         the chart's to guarantee.

         advancedMounts, not globalMounts: only the agent container gets the
         tree. The init containers run as root and have no use for a credential,
         so mounting it into them would widen the surface for nothing — the same
         per-container reasoning /tools gets.

         Whitespace note: this comment may not move below the range chain. The
         chain ends with a left-trim-only `{{- end }}`, which is the only reason
         a newline survives before `advancedMounts:`; an action with a right trim
         there glues the key onto the last `items` line and the document stops
         parsing — silently, because the loader then renders almost nothing. */ -}}
  {{- $secrets := $v.agentSecrets | default dict -}}
  {{- $secretAgents := $secrets.agents | default dict -}}
  {{- $secretMount := $secrets.mountPath | default "/var/run/agent-secrets" -}}
  {{- $secretMode := $secrets.defaultMode | default "0444" -}}
  {{- $secretApps := 0 -}}
  {{- range $agent, $agentSpec := $secretAgents -}}
    {{- $secretApps = add $secretApps (len ($agentSpec.apps | default dict)) -}}
  {{- end -}}
  {{- /* A named agent with no apps would mount nothing while reading as
         configured. Fail loudly instead: silence is the failure mode. */ -}}
  {{- if and (gt (len $secretAgents) 0) (eq $secretApps 0) -}}
    {{- fail "agentSecrets.agents is set but declares no apps, so nothing would be mounted. Add an app, or remove agentSecrets.agents." -}}
  {{- end -}}
  {{- if $secretApps }}
  agent-secrets:
    type: projected
    defaultMode: {{ $secretMode }}
    sources:
      {{- range $agent, $agentSpec := $secretAgents }}
        {{- range $app, $appSpec := ($agentSpec.apps | default dict) }}
      - secret:
          name: {{ $appSpec.secretName | quote }}
          {{- if $appSpec.optional }}
          optional: true
          {{- end }}
          items:
            {{- range $appSpec.items }}
            - key: {{ .key | quote }}
              path: {{ printf "%s/%s/%s" $agent $app (.path | default .key) | quote }}
            {{- end }}
        {{- end }}
      {{- end }}
    advancedMounts:
      main:
        main:
          - path: {{ $secretMount | quote }}
            readOnly: true
  {{- end }}
configMaps:
  config:
    data:
      mise.toml: |
        # Rendered from .Values.mise.tools — pin exactly, no ranges.
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

        {{- with $miseEnv }}

        # Toolchain runtime env, rendered from .Values.mise.env. Each tool uses its
        # own cache-dir variable, so mise cannot infer them; they are declared per
        # deployment rather than pinned here, because the toolchain set is.
        [env]
        {{- range $k, $val := . }}
        {{ $k }} = {{ $val | quote }}
        {{- end }}
        {{- end }}
{{- end -}}

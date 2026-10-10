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
{{- $extraVolumes := $v.extraVolumes | default list -}}
{{- $extraMounts := $v.extraVolumeMounts | default list -}}

{{- /* The extra-volume surface. Guards first, so a contradiction fails here at
       `helm template` rather than at sync or at pod admission:

         * a name the chart already uses (the pod cannot carry two volumes under
           one name, and the chart's own four are mounted at fixed paths),
         * a mount naming anything but an extraVolumes entry — the chart places
           its own four volumes itself, at paths it derives rather than takes,
         * a mountPath the chart already occupies (k8s rejects a duplicate
           mountPath inside one container),
         * a volume nothing mounts (it would render and consume nothing — a
           silent no-op, which is the failure mode this chart refuses).

       A name collision is a contradiction, not an override: the chart's volumes
       are mounted where they are for reasons stated in values.yaml, and the
       escape hatch is not a way to disagree with them silently. */ -}}
{{- $chartVolumes := list "data" "tools" "cache" "config" -}}
{{- $chartMountPaths := list "/zeroclaw-data" "/tools" "/cache" "/config" -}}
{{- $extraVolumeNames := list -}}
{{- range $extraVolumes -}}
  {{- if has .name $chartVolumes -}}
    {{- fail (printf "extraVolumes: %q is a name the chart owns (%s). It is mounted at a fixed path; rename yours." .name (join ", " $chartVolumes)) -}}
  {{- end -}}
  {{- $extraVolumeNames = append $extraVolumeNames .name -}}
{{- end -}}
{{- $mountedNames := list -}}
{{- $mountsByName := dict -}}
{{- range $extraMounts -}}
  {{- if not (has .name $extraVolumeNames) -}}
    {{- fail (printf "extraVolumeMounts: %q is not an extraVolumes entry. The chart places its own volumes (data, tools, cache, config) itself; this key is for volumes the chart does not know about." .name) -}}
  {{- end -}}
  {{- if has .mountPath $chartMountPaths -}}
    {{- fail (printf "extraVolumeMounts: mountPath %q is already occupied by the chart's own volume. Pick another path." .mountPath) -}}
  {{- end -}}
  {{- $mountedNames = append $mountedNames .name -}}
  {{- /* The library names the mount field `path`, not `mountPath`, and takes the
         volume name from the persistence identifier rather than the mount. So the
         user's k8s VolumeMount is re-keyed on the way in; every other field is
         passed through as written. */ -}}
  {{- $mount := omit . "name" "mountPath" -}}
  {{- $_ := set $mount "path" .mountPath -}}
  {{- $_ := set $mountsByName .name (append (get $mountsByName .name | default list) $mount) -}}
{{- end -}}
{{- range $extraVolumes -}}
  {{- if not (has .name $mountedNames) -}}
    {{- fail (printf "extraVolumes: %q is declared but never mounted, so nothing would consume it. Add a matching extraVolumeMounts entry, or drop the volume." .name) -}}
  {{- end -}}
{{- end -}}
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
  {{- range $vol := $extraVolumes }}
  {{ $vol.name }}:
    # type: custom is the library's raw-volume escape: volumeSpec is a k8s Volume
    # body, verbatim, and the volume's name is the identifier above. Nothing is
    # created — custom renders no PVC and no object of its own.
    type: custom
    volumeSpec:
      {{- omit $vol "name" | toYaml | nindent 6 }}
    # advancedMounts, not globalMounts: the agent container only. The two root
    # init containers need no credential, and scoping the mount here is what keeps
    # that true without naming a container in the values surface.
    advancedMounts:
      main:
        main:
          {{- toYaml (get $mountsByName $vol.name) | nindent 10 }}
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

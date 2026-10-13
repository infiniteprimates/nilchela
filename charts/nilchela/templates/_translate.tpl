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
{{- $volumes := $v.volumes | default dict -}}
{{- $required := $volumes.required | default dict -}}
{{- $extra := $volumes.extra | default dict -}}
{{- $tools := ($v.mise | default dict).tools | default dict -}}
{{- $miseEnv := ($v.mise | default dict).env | default dict -}}
{{- $sched := $v.scheduling | default dict -}}
{{- $res := $v.resources | default dict -}}
{{- $repo := $image.repository | default "ghcr.io/infiniteprimates/nilchela" -}}
{{- $tag := $image.tag | default .Chart.AppVersion -}}
{{- $pull := $image.pullPolicy | default "IfNotPresent" -}}
{{- $toolsSize := ($required.tools | default dict).size | default "10Gi" -}}
{{- $cacheSize := ($required.cache | default dict).size | default "5Gi" -}}
{{- $dataSize := ($required.data | default dict).size | default "10Gi" -}}
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
{{- $toolsSpec := $required.tools | default dict -}}
{{- $cacheSpec := $required.cache | default dict -}}
{{- $dataSpec := $required.data | default dict -}}
{{- /* What backs each of the three paths. The chart owns the path; this is the one
       thing about a required volume the deployer decides. Any value but these two
       is refused by the schema's enum, before this template runs. */ -}}
{{- $toolsType := $toolsSpec.type | default "persistentVolumeClaim" -}}
{{- $cacheType := $cacheSpec.type | default "persistentVolumeClaim" -}}
{{- $dataType := $dataSpec.type | default "persistentVolumeClaim" -}}
{{- /* The paths the chart occupies. A deployer's extra volume may not land on one
       of them: k8s would reject the duplicate mountPath, but only after the
       release is half-applied, and the message would not say which key did it.
       These are also the keys the chart's own persistence entries use, so an
       extra volume may not be named one of them either. */ -}}
{{- $chartPaths := list "/tools" "/cache" "/zeroclaw-data" "/config" -}}
{{- $chartKeys := list "tools" "cache" "data" "config" -}}
{{- /* Nested extra mounts: what the kubelet creates, and what it does not.

       Every mount point the kubelet creates, it creates as root:root, and it
       creates one per *container* — so the directories under an extra mount path
       appear while the agent container is being set up, which is after every init
       container has exited. `fix-ownership` is therefore already past, and its
       chown is non-recursive by design: the durable volume is unbounded, and a
       recursive walk on every start is a cost with no ceiling.

       On a volume where the path already exists — the long-lived install — the
       kubelet creates only the shadowed leaf, the mount covers it, and nothing
       breaks. On a *fresh* volume it creates the whole chain, and the agent (uid
       65534) cannot write into it: the daemon dies at boot creating its own data
       directory, before the agent ever runs.

       Collect what has to exist, and be the agent's, before `main` starts: every
       ancestor of an extra mount path that lies inside one of the chart's own
       writable volumes — excluding the mount point itself (its mount covers it)
       and excluding anything at or below another extra's mount point (those
       directories belong to the deployer's volume, not to the chart). */ -}}
{{- $extraPaths := dict -}}
{{- range $key, $spec := $extra -}}
{{- $_ := set $extraPaths ($spec.path | default (printf "/%s" $key)) true -}}
{{- end -}}
{{- $prepare := dict -}}
{{- range $key, $spec := $extra -}}
{{- $mountPath := $spec.path | default (printf "/%s" $key) -}}
{{- range $root := (list "/tools" "/cache" "/zeroclaw-data") -}}
{{- if hasPrefix (printf "%s/" $root) $mountPath -}}
{{- $parts := splitList "/" (trimPrefix (printf "%s/" $root) $mountPath) -}}
{{- $acc := $root -}}
{{- range $i, $part := $parts -}}
{{- $acc = printf "%s/%s" $acc $part -}}
{{- if lt $i (sub (len $parts) 1) -}}
{{- if hasKey $extraPaths $acc -}}
{{- break -}}
{{- end -}}
{{- $_ := set $prepare $acc true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
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
      {{- if $prepare }}
      prepare-mounts:
        dependsOn: fix-ownership
        image:
          repository: {{ $repo }}
          tag: {{ $tag | quote }}
          pullPolicy: {{ $pull }}
        command: ["sh", "-c"]
        args:
          - |-
            set -eu
            for dir in{{ range $dir, $_ := $prepare }} {{ $dir | quote }}{{ end }}; do
              mkdir -p "$dir"
              chown 65534:65534 "$dir"
            done
        securityContext:
          runAsUser: 0
          runAsGroup: 0
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
      {{- end }}
      install-tools:
        dependsOn: {{ if $prepare }}prepare-mounts{{ else }}fix-ownership{{ end }}
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
{{- /* A required volume is a claim or an emptyDir, never both. An emptyDir creates
       no claim, so a claim field named beside it would render a value nothing
       reads — and the emptyDir fields beside a claim are the same mistake in the
       other direction. Both fail here, naming the key and the field, in the same
       shape as the extra-volume guards below: a value that renders nothing is
       worse than a value that refuses. */ -}}
{{- range $key, $spec := (dict "tools" $toolsSpec "cache" $cacheSpec "data" $dataSpec) }}
{{- $kind := $spec.type | default "persistentVolumeClaim" }}
{{- if eq $kind "emptyDir" }}
{{- range $field := (list "size" "storageClass" "existingClaim") }}
{{- if hasKey $spec $field }}
{{- fail (printf "volumes.required.%s: type emptyDir creates no claim, so %s cannot be set; drop one of the two" $key $field) }}
{{- end }}
{{- end }}
{{- else }}
{{- range $field := (list "medium" "sizeLimit") }}
{{- if hasKey $spec $field }}
{{- fail (printf "volumes.required.%s: %s is an emptyDir field and this volume is a %s; set type: emptyDir or drop it" $key $field $kind) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- /* Every claim the chart creates carries a pinned `suffix`, so its name is
       <fullname>-<key> in every combination. The library appends the identifier
       only when a chart renders more than one claim (common:
       lib/common/_determineResourceNameFromValues.tpl, `itemCount > 1`), which
       makes the name depend on how many of the other volumes happen to be
       ephemeral: flipping two of the three required volumes to emptyDir would
       rename the survivor to the bare release name — a NEW, empty claim created
       beside the retained one it orphaned. That is the failure the `keep`
       annotation exists to prevent, so the name is pinned instead of inherited. */}}
persistence:
  tools:
    {{- if eq $toolsType "emptyDir" }}
    type: emptyDir
    {{- with $toolsSpec.medium }}
    medium: {{ . | quote }}
    {{- end }}
    {{- with $toolsSpec.sizeLimit }}
    sizeLimit: {{ . | quote }}
    {{- end }}
    {{- else if $toolsSpec.existingClaim }}
    existingClaim: {{ $toolsSpec.existingClaim | quote }}
    {{- else }}
    type: persistentVolumeClaim
    suffix: tools
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
    {{- if eq $cacheType "emptyDir" }}
    type: emptyDir
    {{- with $cacheSpec.medium }}
    medium: {{ . | quote }}
    {{- end }}
    {{- with $cacheSpec.sizeLimit }}
    sizeLimit: {{ . | quote }}
    {{- end }}
    {{- else if $cacheSpec.existingClaim }}
    existingClaim: {{ $cacheSpec.existingClaim | quote }}
    {{- else }}
    type: persistentVolumeClaim
    suffix: cache
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
    {{- if eq $dataType "emptyDir" }}
    type: emptyDir
    {{- with $dataSpec.medium }}
    medium: {{ . | quote }}
    {{- end }}
    {{- with $dataSpec.sizeLimit }}
    sizeLimit: {{ . | quote }}
    {{- end }}
    {{- else if $dataSpec.existingClaim }}
    existingClaim: {{ $dataSpec.existingClaim | quote }}
    {{- else }}
    type: persistentVolumeClaim
    suffix: data
    accessMode: ReadWriteOnce
    size: {{ $dataSize }}
    retain: true
    {{- with $dataSpec.storageClass }}
    storageClass: {{ . | quote }}
    {{- end }}
    {{- end }}
    globalMounts:
      - path: /zeroclaw-data
{{- /* Extra volumes: one persistence entry per key, mounted into the agent
       container and nothing else — the two root init containers must never carry
       a deployer's credential. Hence advancedMounts.main.main rather than
       globalMounts, which would reach every container in the pod. */ -}}
{{- $mounted := dict -}}
{{- range $key, $spec := $extra }}
  {{- if has $key $chartKeys }}
  {{- fail (printf "volumes.extra.%s: the chart already owns a volume under this name; choose another key" $key) }}
  {{- end }}
  {{- $type := $spec.type | default "persistentVolumeClaim" }}
  {{- $mountPath := $spec.path | default (printf "/%s" $key) }}
  {{- if eq $type "image" }}
  {{- /* The library only handles type image from k8s 1.33 (the ImageVolume
         feature). Below that it falls through to "Not a valid persistence.type",
         which names neither the key nor the real requirement. */ -}}
  {{- $minor := regexReplaceAll "[^0-9]" $.Capabilities.KubeVersion.Minor "" | int }}
  {{- if lt $minor 33 }}
  {{- fail (printf "volumes.extra.%s: type image needs Kubernetes 1.33 or newer (ImageVolume); this render targets %s" $key $.Capabilities.KubeVersion.Version) }}
  {{- end }}
  {{- end }}
  {{- /* A claim entry with neither a size nor an adopted claim renders `size:`
         empty: the schema accepts it (there is no chart default to fall back on,
         the way there is for the three required volumes) and k8s rejects it at
         sync, naming neither the key nor the field that is missing. */ -}}
  {{- if and (eq $type "persistentVolumeClaim") (not $spec.existingClaim) (not $spec.size) }}
  {{- fail (printf "volumes.extra.%s: type persistentVolumeClaim needs size or existingClaim" $key) }}
  {{- end }}
  {{- if has $mountPath $chartPaths }}
  {{- fail (printf "volumes.extra.%s: %s is mounted by the chart; choose another path" $key $mountPath) }}
  {{- end }}
  {{- if hasKey $mounted $mountPath }}
  {{- fail (printf "volumes.extra.%s: %s is already mounted by volumes.extra.%s" $key $mountPath (get $mounted $mountPath)) }}
  {{- end }}
  {{- $_ := set $mounted $mountPath $key }}
  {{ $key }}:
    type: {{ $type }}
    {{- if eq $type "persistentVolumeClaim" }}
    {{- if $spec.existingClaim }}
    existingClaim: {{ $spec.existingClaim | quote }}
    {{- else }}
    suffix: {{ $key }}
    accessMode: {{ $spec.accessMode | default "ReadWriteOnce" }}
    size: {{ $spec.size }}
    retain: true
    {{- with $spec.storageClass }}
    storageClass: {{ . | quote }}
    {{- end }}
    {{- end }}
    {{- else if or (eq $type "secret") (eq $type "configMap") }}
    {{- with $spec.name }}
    name: {{ . | quote }}
    {{- end }}
    {{- with $spec.identifier }}
    identifier: {{ . | quote }}
    {{- end }}
    {{- with $spec.defaultMode }}
    defaultMode: {{ . }}
    {{- end }}
    {{- with $spec.items }}
    items:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- else if eq $type "projected" }}
    {{- with $spec.defaultMode }}
    defaultMode: {{ . }}
    {{- end }}
    sources:
      {{- toYaml $spec.sources | nindent 6 }}
    {{- else if eq $type "emptyDir" }}
    {{- with $spec.medium }}
    medium: {{ . | quote }}
    {{- end }}
    {{- with $spec.sizeLimit }}
    sizeLimit: {{ . | quote }}
    {{- end }}
    {{- else if eq $type "ephemeral" }}
    accessMode: {{ $spec.accessMode | default "ReadWriteOnce" }}
    size: {{ $spec.size | quote }}
    {{- with $spec.storageClass }}
    storageClass: {{ . | quote }}
    {{- end }}
    {{- else if eq $type "hostPath" }}
    hostPath: {{ $spec.hostPath | quote }}
    {{- with $spec.hostPathType }}
    hostPathType: {{ . | quote }}
    {{- end }}
    {{- else if eq $type "image" }}
    {{- if kindIs "string" $spec.image }}
    image: {{ $spec.image | quote }}
    {{- else }}
    image:
      {{- toYaml $spec.image | nindent 6 }}
    {{- end }}
    {{- with $spec.pullPolicy }}
    pullPolicy: {{ . }}
    {{- end }}
    {{- end }}
    advancedMounts:
      main:
        main:
          - path: {{ $mountPath }}
            {{- if $spec.readOnly }}
            readOnly: true
            {{- end }}
{{- end }}
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
        # Rendered from .Values.mise.tools — pin exactly, no ranges.
        #
        # Keys are quoted only where TOML requires it. A mise backend-qualified
        # tool name (`pipx:trash-cli`, `cargo:resvg`) carries a colon, which is
        # not legal in a TOML bare key: rendered unquoted, the document does not
        # parse, and `mise install` — the install container's entire job — fails
        # before the pod ever starts. Quoting only when the key cannot stand bare
        # keeps the common case (`gh = "..."`, `[tools.rust]`) in the shape a
        # reader expects.
        [tools]
        {{- range $k, $val := $tools }}
        {{- if not (kindIs "map" $val) }}
        {{ if regexMatch "^[A-Za-z0-9_-]+$" $k }}{{ $k }}{{ else }}{{ $k | quote }}{{ end }} = {{ $val | quote }}
        {{- end }}
        {{- end }}
        {{- range $k, $val := $tools }}
        {{- if kindIs "map" $val }}
        [tools.{{ if regexMatch "^[A-Za-z0-9_-]+$" $k }}{{ $k }}{{ else }}{{ $k | quote }}{{ end }}]
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

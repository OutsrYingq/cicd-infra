# 03 通用 Helm Chart 设计（generic-service）

对应实现：`cicd-infra/charts/generic-service/`

## 1. 定位

一份参数化 chart 覆盖**所有无状态服务**的标准形态：Deployment + Service + Ingress + HPA + 探针 + 资源限制 + 配置注入 + 密文。服务不写任何 K8s YAML，只填 values 差异。

设计原则：

- **约定优于配置**：默认值面向 k3s（traefik ingress、小资源规格），开箱即用
- **有状态/特殊服务不走此 chart**（数据库、中间件等用独立 chart 或 Bitnami），generic-service 保持简单
- **dev/prod 同集群 namespace 隔离**（ADR-6）：`<svc>-dev` / `<svc>-prod`，靠 resources 限额控制互相影响；后续可加 ResourceQuota/LimitRange
- 扩展按需：前 3 个服务接入期会暴露新参数需求（挂载、initContainer、cronJob…），增量迭代，不预先设计

## 2. 渲染拓扑

```
charts/generic-service
├── Chart.yaml
├── values.yaml                  # chart 层默认值（第 1 层）
└── templates/
    ├── _helpers.tpl             # 名称/标签
    ├── deployment.yaml          # 核心：容器、探针、资源、envFrom
    ├── service.yaml
    ├── ingress.yaml             # traefik
    ├── hpa.yaml                 # 可选
    ├── configmap.yaml           # .Values.config → ConfigMap → envFrom
    ├── sealedsecret.yaml        # .Values.sealedSecrets → SealedSecret（密文直通）
    ├── secret-dockerconfig.yaml # .Values.imageCredentials → GHCR 拉取凭证（可选）
    ├── serviceaccount.yaml      # 可选
    └── NOTES.txt                # 部署完输出访问地址
```

## 3. values 完整定义

```yaml
# ── 元数据（ApplicationSet 使用，chart 本体忽略这两个字段）──
service: user-api     # 服务名（files generator 参数）
env: dev              # 环境名（files generator 参数）

# ── 镜像 ──
image:
  repository: ghcr.io/outsryingq/user-api
  tag: abc1234          # 必填：CI 自动 bump；手动改 = 定点发布/回滚。缺失时渲染直接报错（不回退 appVersion，杜绝静默部署旧版本）
  pullPolicy: IfNotPresent

imagePullSecrets: []    # 例: [{name: ghcr-pull}]（GHCR 私有包拉取，见 05 文档）

replicaCount: 1

serviceAccount:
  create: false         # 需要 RBAC 的服务才开
  name: ""

# 注意：网络配置用顶层 port/serviceType，不能叫 service——
# 顶层 service 是元数据字符串（见第 5 节），同名键会把整个配置块覆盖掉
port: 8080             # 服务端口（容器 / Service / 探针共用）
serviceType: ClusterIP

ingress:
  enabled: true
  className: traefik    # k3s 默认
  host: user-api.dev.example.com
  tls:                  # HTTP 起步（ADR-7）；接入 cert-manager 后置 enabled: true 即自动 https
    enabled: false
    secretName: ""

config:                 # 非敏感应用配置 → ConfigMap → 全部注入为环境变量
  LOG_LEVEL: debug
  REDIS_ADDR: redis:6379

secretEnv: ""           # envFrom 的 Secret 名（来自 sealedSecrets 解密产物），如 "user-api-secret"

extraEnv: []            # 原生 env 片段（valueFrom 场景），例:
# - name: DB_PASSWORD
#   valueFrom: { secretKeyRef: { name: user-api-secret, key: db-password } }

probes:
  enabled: true
  path: /healthz          # 服务必须实现；没有健康接口的服务设 enabled: false
  initialDelaySeconds: 5  # readiness/liveness 起始延迟
  startupSeconds: 60      # startupProbe 预算：启动窗口内不被 liveness 误杀（慢启动服务调大）

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 256Mi }

hpa:
  enabled: false        # 开启后 Deployment 不再固定 replicas
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 80

podAnnotations: {}      # 如接入监控注入
nodeSelector: {}
tolerations: []
affinity: {}

# ── 密文（kubeseal 生成，见 05 文档）──
sealedSecrets: {}
# user-api-secret:
#   encryptedData:
#     db-password: AgBm...

# ── GHCR 拉取凭证（明文 PAT 会进 Git，仅限 dev 快速验证；生产用 sealedSecrets 模板方式）──
imageCredentials:
  enabled: false
  registry: ghcr.io
  username: ""
  password: ""
```

## 4. 关键模板设计

### 4.1 deployment.yaml

- `replicas` 仅在 `hpa.enabled == false` 时渲染（HPA 与固定副本互斥）
- 显式 `strategy.rollingUpdate: {maxUnavailable: 0, maxSurge: 1}`：**任意副本数（含 1）发布不断流**
- `startupProbe`（periodSeconds 5 × failureThreshold 按预算换算 ≈ `probes.startupSeconds`）：启动期由它接管，通过后 liveness/readiness 才生效，慢启动服务不被误杀
- 显式 `terminationGracePeriodSeconds: 30`：优雅停机窗口（SIGTERM 后强杀兜底）
- `image.tag` 用 `required` 校验必填，缺失渲染即报错
- 容器端口 = 顶层 `port`（容器/Service/探针三处共用），name `http`（探针、ingress 引用统一）
- 环境注入三通道：
  1. `envFrom.configMapRef` ← `config` 生成的 ConfigMap（**改配置自动生效的关键链路**）
  2. `envFrom.secretRef` ← `secretEnv` 指向的 Secret
  3. `extraEnv` 原生片段（valueFrom 细粒度引用）
- Pod template 注入 `checksum/config` 注解 = ConfigMap 内容 hash：**ConfigMap 变更 → Pod 滚动重启**（否则 envFrom 更新但旧 Pod 环境变量不变，配置"改了但没生效"）
- 探针：liveness 与 readiness 同 `probes.path`（httpGet :http），默认够用，后续按需拆分参数
- `imagePullSecrets` 透传 values

### 4.2 configmap.yaml + checksum 联动

```yaml
{{- with .Values.config }}
data: {{- toYaml . | nindent 2 }}
{{- end }}
```

deployment 的 pod annotation：

```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

### 4.3 sealedsecret.yaml（模板直通设计）

支持任意 SealedSecret，含类型覆盖（dockerconfigjson 场景）：

```yaml
{{- range $name, $ss := .Values.sealedSecrets }}
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ $name }}
  {{- with $ss.annotations }}
  # scope 注解必须透传：cluster-wide 密文丢了它，控制器按 strict 解密必然失败
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with $ss.template }}
  template:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  encryptedData:
    {{- toYaml $ss.encryptedData | nindent 4 }}
---
{{- end }}
```

`template` 字段直通意味着可以渲染出 `type: kubernetes.io/dockerconfigjson` 的拉取凭证 Secret（GHCR PAT 的 sealed 方案，见 05 文档 4.2 节）。

> 注意时序：SealedSecret 与 Deployment 同批同步时，解密需要几秒，期间 Pod 可能 ImagePullBackOff，控制器解密后 kubelet 重试自愈——属预期抖动，非故障。

### 4.4 ingress.yaml

- `networking.k8s.io/v1`，`ingressClassName: traefik`（k3s 默认装 traefik）
- host 单域名起步，tls 可选
> k3s 版本差异注意：新版 k3s 的 traefik 可能由 HelmManifest 部署，ingressClass 名称一致即可；若集群禁用了 traefik，改 `className` 指向实际控制器。

### 4.5 hpa.yaml

`autoscaling/v2`，仅 CPU 指标起步；开启时 Deployment 省略 replicas（否则 HPA 与声明副本互相打架）。
前提：集群 metrics-server 可用——k3s 默认内置，但 `--disable=metrics-server` 安装的集群需自查（`kubectl top nodes`）。

### 4.6 _helpers.tpl

- `generic-service.name`：`nameOverride` 优先，否则取 `{{ .Values.service }}`，回退 `Chart.Name`
- `generic-service.labels` / `selectorLabels`：标准 `app.kubernetes.io/*` 五件套 + `env` 标签（按环境筛选方便）

## 5. 与 ApplicationSet 的字段约定

每个 `envs/<env>/<svc>.yaml` 顶部必须有 `service` 与 `env` 两个元字段（ApplicationSet files generator 据此生成应用名与 namespace `<service>-<env>`）。chart 渲染时这两个字段仅作名称/标签来源，其余 values 正常合并。

## 6. 环境差异示例

dev（自动部署、单副本、调试配置、宽松资源）：

```yaml
service: user-api
env: dev
image: { repository: ghcr.io/outsryingq/user-api, tag: abc1234 }
replicaCount: 1
ingress: { enabled: true, className: traefik, host: user-api.dev.example.com }
config:
  LOG_LEVEL: debug
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 256Mi }
```

prod（PR 审批、多副本、正式配置、收紧资源、HPA）：

```yaml
service: user-api
env: prod
image: { repository: ghcr.io/outsryingq/user-api, tag: abc1234 }
replicaCount: 3
ingress: { enabled: true, className: traefik, host: user-api.example.com }
config:
  LOG_LEVEL: info
hpa: { enabled: true, minReplicas: 3, maxReplicas: 8, targetCPUUtilizationPercentage: 70 }
resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   { cpu: 1, memory: 512Mi }
```

晋升 = 从 dev 文件复制改差异项，PR 评审即为晋升审批。

## 7. 扩展路线（按需触发，不预先实现）

| 需求场景 | 扩展方式 |
|---|---|
| 定时任务 | 新增 `cronjobs:` values + template（或独立 chart） |
| 挂载配置文件/持久卷 | `volumes`/`extraVolumes` values |
| gRPC/自定义端口协议 | `service.annotations` + ingress annotations |
| 金丝雀/蓝绿 | 引入 Argo Rollouts，替换 Deployment 模板 |
| 监控接入 | `podAnnotations` 注入 + `ServiceMonitor` 可选模板 |

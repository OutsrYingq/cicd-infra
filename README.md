# cicd-infra — 组织级 CI/CD 基础设施

业务仓库**一个 workflow 文件**接入，即获得：构建 → 推 GHCR → 配置管理 → GitOps 一键部署。

```
 业务仓库 × N                本仓库（cicd-infra）              deploy 仓库（独立）
┌────────────────┐          ┌────────────────────┐          ┌────────────────────┐
│ 源码 + ci.yml   │ uses@v1  │ pipeline.yml        │ git push │ envs/<env>/<svc>.yaml │
│ Dockerfile      │────────▶ │ charts/generic-svc  │────────▶ │ argocd/applicationset │
└────────────────┘          │ docker/ 语言模板     │ 改tag     └─────────┬──────────┘
        │                    └────────────────────┘                    │ watch ≤3min
        │ buildx + GITHUB_TOKEN                                        ▼
        ▼                                                          Argo CD (k3s)
   ghcr.io/<org>/<svc>:<sha> ───────────────────────────────────▶ Pod / Ingress
```

核心机制：**CI 只改 deploy 仓库的 `image.tag`，实际部署由集群内 Argo CD 完成**——CI 不持集群凭证；改配置即生效；回滚 = git revert。

> 本地目录中的 `deploy/` 是 **deploy 仓库的骨架**，需推成独立 Git 仓库（`OutsrYingq/deploy`），已被本仓库 `.gitignore` 屏蔽。

## 文档导航

| 文档 | 内容 |
|---|---|
| [docs/design/01-总体架构](docs/design/01-总体架构.md) | 目标、架构、选型、ADR 决策记录 |
| [docs/design/02~07](docs/design/) | 流水线 / chart / Argo CD / 配置管理 / 虚机 / 安全分册 |
| [docs/实现步骤.md](docs/实现步骤.md) | **分阶段落地手册（含验收标准与排障表）** ← 建设从这开始 |

---

## 一、首次建设（管理员，一次性）

完整步骤见 [docs/实现步骤.md](docs/实现步骤.md) 阶段 0-3，概要：

1. **推两个仓库**：本仓库 → `OutsrYingq/cicd-infra`；`deploy/` 目录 → `OutsrYingq/deploy`（各自独立 git init）
2. **组织级 secrets**（GitHub org → Settings → Secrets → Actions）：

   | Secret | 用途 | 权限 |
   |---|---|---|
   | `GITOPS_PAT` | CI 向 deploy 仓库 push | fine-grained，仅 deploy 仓库 Contents:RW |
   | `GHCR_PULL_USER` / `GHCR_PULL_TOKEN` | k3s/虚机拉 GHCR 私有包 | classic PAT，仅 read:packages |
   | `VM_SSH_KEY` | 虚机部署通道（按需） | 虚机部署用户私钥 |

3. **Environments**：`prod` 配 required reviewers（≥2 人）；`dev` 无需配置
4. **集群 bootstrap**（一次性）：按 [deploy/bootstrap/README.md](deploy/bootstrap/README.md) 装 Argo CD + sealed-secrets（锁版本）、配 Git 凭证（私有仓库必须）、生成 GHCR 拉取密文、`kubectl apply` applicationset
5. **分支保护**：两个仓库 main 均要求 PR

## 二、新服务接入（服务负责人，约 10 分钟）

**① 业务仓库加 Dockerfile**（已有则跳过）

模板在 [docker/go.Dockerfile](docker/go.Dockerfile) / [docker/node.Dockerfile](docker/node.Dockerfile)。要点：test stage 内跑测试（不过构建不过）、监听端口与 values 的 `port` 一致、实现 `/healthz`。

**② 业务仓库加 `.github/workflows/ci.yml`**（接入的全部）

```yaml
name: CI/CD
permissions:
  contents: read
  packages: write   # GHCR 推送；被调用方不可越权，必须在业务仓库声明

on:
  push:
    branches: [main]                  # 合并即自动发 dev
    paths-ignore: ["**.md", "docs/**"]
  pull_request:                       # PR 只验证：测试+构建，不推镜像不部署
  workflow_dispatch:                  # 一键部署入口
    inputs:
      env:
        type: choice
        options: [dev, prod]
jobs:
  pipeline:
    uses: OutsrYingq/cicd-infra/.github/workflows/pipeline.yml@main   # 稳定后改 @v1
    with:
      service: my-service             # 全小写，=镜像名=应用名=values文件名
      deploy-env: ${{ (github.event_name == 'push' && 'dev') || inputs.env || '' }}
    secrets: inherit
```

**③ deploy 仓库加 `envs/dev/my-service.yaml`**（示例与字段说明见 [deploy/envs/README.md](deploy/envs/README.md)）

```yaml
service: my-service          # 必须与文件名、ci.yml 的 service 一致
env: dev

image:
  repository: ghcr.io/outsryingq/my-service
  tag: init000               # 首次随意，CI 马上覆盖

port: 8080
ingress:
  host: my-service.dev.example.com

config:
  LOG_LEVEL: debug

imagePullSecrets:
  - name: ghcr-pull
sealedSecrets:               # 拉取密文各文件同一份，生成命令见 bootstrap/README 第 4 节
  ghcr-pull:
    template:
      type: kubernetes.io/dockerconfigjson
    encryptedData:
      .dockerconfigjson: AgB...
```

**④ 触发首次发布**：业务仓库 push 一个 commit 到 main，然后确认：

- [ ] Actions：build、deploy 两个 job 绿
- [ ] deploy 仓库出现 `deploy(dev): my-service -> <sha>` commit
- [ ] Argo CD：`my-service-dev` 应用 Healthy（≤3min）
- [ ] `kubectl -n my-service-dev get pods` Running

首次常见问题：推送镜像 403 → org 的 Packages/Actions 包策略；Pod ImagePullBackOff → 包可见性或 ghcr-pull 密文。更多见实现步骤排障表。

## 三、日常操作

| 场景 | 操作 |
|---|---|
| 发布 dev | 业务仓库 PR merge 到 main，全自动 |
| 发布 prod（一键部署） | Actions → CI/CD → Run workflow → 选 `prod` → 审批人批准 |
| 回滚 | deploy 仓库 `git revert` 对应的 bump commit（秒~分钟级生效） |
| 改配置（env/副本/资源/域名） | 提 PR 改 `envs/<env>/<svc>.yaml`，merge 后 ≤3min 生效 |
| 定点发某版本 | PR 把 `image.tag` 改为目标 sha |
| 看线上状态 | Argo CD UI（应用健康、同步历史、资源树） |
| 下线服务 | 见 [docs/design/04](docs/design/04-ArgoCD-GitOps部署设计.md) 第 7 节（先删应用再删文件） |
| 虚机服务部署 | ci.yml 引用 `deploy-vm.yml`，虚机初始化见 [docs/design/06](docs/design/06-虚机部署通道.md) |

## 四、本仓库（基础设施）维护

```
cicd-infra/
├── .github/workflows/   # 可复用流水线（业务仓库引用的入口）
├── charts/generic-service/  # 通用 Helm chart
├── docker/              # Dockerfile / compose 模板
└── docs/                # 设计文档 + 实现步骤
```

- **变更流程**：PR + review → 合并 main；按阶段发布 tag 并移动 `v1` 指针，业务仓库 `uses` 逐步切 `@v1`（建设期可直接 `@main`）
- **chart 改动必须本地验证**：

  ```bash
  helm template charts/generic-service \
    --set service=demo --set env=dev \
    --set image.repository=ghcr.io/org/demo --set image.tag=t1 \
    --set ingress.host=demo.dev.example.com
  ```

- **注意**：envs values 顶层 `service`/`env` 是元数据字符串，chart 网络配置因此用顶层 `port`/`serviceType`——不要改回 `service.port`（键冲突，渲染必炸）

## 五、更多

- 安全模型与凭证轮换周期：[docs/design/07](docs/design/07-安全与权限设计.md)
- 新增环境（staging 等）：`deploy/envs/` 下建目录即可，ApplicationSet 自动纳管
- 后续加固路线（cosign 签名、通知、Vault 等）：各设计文档末节

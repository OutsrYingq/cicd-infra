# 04 Argo CD GitOps 部署设计

对应实现：`deploy/argocd/applicationset.yaml`、`deploy/bootstrap/`（安装手册）。

## 1. 为什么直接上 Argo CD（而跳过 push 模式 MVP）

当前已有的实际痛点：**改配置必须重新走一遍流水线**。push 模式（CI 直跑 helm upgrade）下 deploy 仓库的 values 是"死"的，没有东西 watch 它；要生效就得再造一个触发机制，等于手搓简陋版 CD。

直接上 Argo CD（pull 模式）一次解决：

| 能力 | 效果 |
|---|---|
| 改配置即生效 | values merge → ≤3min 自动同步，无需跑任何流水线 |
| 单一事实源 | 集群状态 = deploy 仓库；`kubectl get` 与 git log 永远对得上 |
| drift 自愈 | 手工 kubectl 改动被 selfHeal 纠正（或在 UI 标黄暴露） |
| 回滚 | `git revert` 或 UI 点 History → Rollback |
| CI 零集群凭证 | CI 只有 Git 写权限，kubeconfig 不出集群 |
| 灾难恢复 | deploy 仓库指向新集群即整体重建 |

代价：k3s 多跑一个 Argo CD（约几百 MB 内存）+ 一个要升级的组件。可接受。

## 2. 安装与访问（bootstrap 摘要）

```bash
# 1. 安装 Argo CD：锁定具体版本号（≥2.8，建议 v3.x 最新 stable），勿用 stable 别名
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/vX.Y.Z/manifests/install.yaml

# 2. sealed-secrets 控制器（同样锁版本）
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/controller.yaml

# 3. 私有仓库必须：为 Argo CD 配只读 Git 凭证（deploy 与 cicd-infra 各一个 Secret）
kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-deploy
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  url: https://github.com/OutsrYingq/deploy
  username: git
  password: <ARGO_GIT_READONLY_PAT>   # fine-grained，仅这两个仓库 Contents:Read
EOF
# 对 cicd-infra 重复一次（name: repo-cicd-infra，url 换掉）

# 4. 本地访问 UI（或经 ingress 暴露，见 bootstrap/README）
kubectl -n argocd port-forward svc/argocd-server 8080:443

# 5. 初始 admin 密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

完整步骤与 ingress 暴露方案见 `deploy/bootstrap/README.md`。

## 3. 应用编排：ApplicationSet（files generator）

### 3.1 设计

一条 ApplicationSet 管**所有服务 × 所有环境**：

- **generator**：git files generator 扫 `deploy` 仓库 `envs/*/*.yaml`，每个文件生成一个 Application 参数
- 文件顶部的 `service` / `env` 元字段 → 应用名 `{{ .service }}-{{ .env }}`、namespace `{{ .service }}-{{ .env }}`
- **multi-source**：chart 来自 cicd-infra 仓库，values 来自 deploy 仓库——两个仓库解耦（chart 随基础设施 tag 发版，配置随业务高频变更）
- **集群拓扑**（ADR-6）：单集群，destination 固定 `https://kubernetes.default.svc`；将来双集群演进 = 换 clusters generator 按 env 路由 + 注册新集群，values 与业务仓库零改动

### 3.2 完整清单

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: https://github.com/OutsrYingq/deploy.git
        revision: main
        files:
          - path: "envs/*/*.yaml"
  template:
    metadata:
      name: "{{ .service }}-{{ .env }}"
    spec:
      project: default
      sources:
        # 源 1：通用 chart（cicd-infra 仓库）
        - repoURL: https://github.com/OutsrYingq/cicd-infra.git
          targetRevision: main        # 稳定后固定为 v1 tag
          path: charts/generic-service
          helm:
            valueFiles:
              - "$values/envs/{{ .env }}/{{ .service }}.yaml"
        # 源 2：仅提供 $values 引用（deploy 仓库）
        - repoURL: https://github.com/OutsrYingq/deploy.git
          targetRevision: main
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ .service }}-{{ .env }}"
      syncPolicy:
        automated:
          selfHeal: true     # 纠正手工漂移
          prune: false       # 误删 values 文件不直接删集群资源，人工确认后再清理
        syncOptions:
          - CreateNamespace=true
```

### 3.3 语义推论（这套设计的红利）

| 动作 | 结果 |
|---|---|
| deploy 仓库新增 `envs/prod/order-svc.yaml` | Argo CD 自动创建 `order-svc-prod` 应用与 namespace，**零注册** |
| CI bump `image.tag` | 对应应用自动同步新版本 |
| 手工改 PR 调 `replicaCount` | 自动生效 |
| 删除 values 文件 | 应用变 orphaned（prune=false 时不删资源），删除服务需按第 7 节流程 |
| 手工 kubectl scale | 被 selfHeal 打回（如需临时扩容：改 values 或临时关 selfHeal） |

## 4. 版本与依赖要求

| 组件 | 要求 | 说明 |
|---|---|---|
| Argo CD | ≥ 2.8（建议 v3.x stable） | multi-source Application + ApplicationSet goTemplate 需要 |
| chart targetRevision | 初期 `main`，稳定后 `v1` tag | 与业务仓库 uses 引用同策略；tag 指针更新由 Argo 刷新自动跟进 |
| 刷新延迟 | 默认 ≤3min | 发布后 UI 未变先等一个周期；可选配 GitHub webhook 即时触发（bootstrap/README） |

## 5. 环境门禁模型

```
dev:   merge → CI → bump dev tag → Argo 自动同步        （全自动）
prod:  workflow_dispatch 选 prod → GitHub Environment 审批 → bump prod tag → Argo 自动同步
```

- **审批发生在 tag bump 之前**（GitHub Environment required reviewers），Argo CD 侧保持统一自动同步——只有一套自动逻辑，不存在"审批了但没同步/同步了但没审批"的歧义
- deploy 仓库 main 分支保护（要求 PR + review）作为**配置变更**（含手动改 tag 回滚）的第二道闸
- Argo CD 本身 admin 权限收敛给平台维护者，服务负责人给只读 UI 权限

## 6. 回滚设计

| 场景 | 操作 | 效果 |
|---|---|---|
| 发布了坏版本 | deploy 仓库 `git revert` 那个 bump commit | tag 回旧 sha，自动同步回滚（秒级~分钟级） |
| 配置改坏 | revert 配置 PR | 同上 |
| 想快速点一下 | Argo CD UI → Application → History → Rollback | 注意：selfHeal 会把 Git 再同步回来——**回滚必须落 Git**，UI 回滚仅用于应急观察 |

## 7. 删除服务的正确姿势

1. 确认下线 → 先在 Argo CD UI 手动删 Application（或临时把 ApplicationSet 的 prune 置 true）
2. 删除 `envs/<env>/<svc>.yaml`
3. 清理残留 namespace 与 GHCR 包（可选）

顺序不能反：直接删文件在 `prune: false` 下不会删资源，只会留一个孤儿应用。

## 8. 已知风险与对策

| 风险 | 对策 |
|---|---|
| multi-source + files generator 兼容性 | 锁定 Argo CD ≥2.8；升级 Argo CD 前在测试 namespace 验证 ApplicationSet 渲染 |
| values 文件缺 `service`/`env` 元字段 | files generator 静默跳过 → 接入 checklist 强制校验；实现步骤文档含自检命令 |
| chart 模板报错卡住同步 | UI 看 sync error 定位；chart 变更先在本地 `helm template` 验证（实现步骤含命令） |
| secret 解密时序 | ImagePullBackOff 几秒后自愈，属预期（03 文档 4.3） |
| 单点：Argo CD 挂了 | 不影响已运行负载，仅暂停同步；恢复后自动追上 Git |

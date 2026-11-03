# DERP-docker

自动把 [Tailscale](https://github.com/tailscale/tailscale) 的 DERP 中继服务器 `cmd/derper`
从上游源码编译成多架构 Docker 镜像并发布。GitHub Actions 定时检查上游，**Tailscale 发布新版本，
或 Go 发布新版本时，自动重新拉取、构建并推送镜像**。

- 镜像：`ghcr.io/<owner>/derper`（可选同步发布到 Docker Hub）
- 架构：`linux/amd64`、`linux/arm64`、`linux/arm/v7`
- 运行时：Alpine，自带 CA 证书，可 `docker exec` 进入排查

## 镜像标签

每次构建由 **Tailscale 版本 + Go 版本** 这一对唯一确定，并推送以下标签：

| 标签 | 含义 |
|---|---|
| `v1.104.5-go1.27.3` | 精确到 Tailscale 与 Go 版本，不可变 |
| `v1.104.5` | 该 Tailscale 版本的最新构建（Go 更新后会被覆盖） |
| `v1.104` | 该次要版本线的最新构建 |
| `latest` | 最新 Tailscale 稳定版 + 最新 Go |

镜像带有 OCI 标签：`io.tailscale.derper.version`、`io.tailscale.derper.commit`、`io.tailscale.derper.go-version`。

## 工作流原理

`.github/workflows/build.yml` 分两个 job：

1. **resolve** —— 由 `scripts/resolve-versions.sh` 解析上游版本：
   - Tailscale：GitHub API `releases/latest` 的 tag（即最新稳定版），并通过 `git ls-remote` 取得 tag 对应的 commit；
   - Go：读取该 tag 的 `go.mod`（`go` / `toolchain` 指令）得到最低要求，再从 `go.dev/dl` 取最新稳定版，取两者中较高者；
   - 目标标签 `vX.Y.Z-goA.B.C` 已在 GHCR 存在 → 跳过（除非强制）；
   - 对应的官方 `golang:A.B.C` 镜像尚未发布（Go 新版本发布后通常会滞后几小时）→ 本次跳过，下次定时再试。
2. **build** —— 先在 runner 原生平台构建并做冒烟测试（`derper --version` 必须输出上游风格的
   `1.104.5-t73a48057a`，entrypoint 必须把环境变量正确传给 derper），再交叉编译三个架构并推送，
   推送后逐平台拉回运行 `--version` 验证，最后把本次版本写入 `versions.json` 提交到 `main`。

触发方式：

| 触发 | 行为 |
|---|---|
| 定时（每 6 小时） | 版本无变化则什么都不做 |
| 推送到 `main` 且改动了 `Dockerfile` / `docker-entrypoint.sh` / 工作流 | 强制重建当前版本 |
| 手动 `workflow_dispatch` | 可指定 `tailscale_version`、`go_version`，或勾选 `force` 强制重建 |

构建阶段用 `--platform=$BUILDPLATFORM` 在原生平台交叉编译，不在 QEMU 下跑 Go 编译器；版本号用与上游
`build_dist.sh` 相同的 `-ldflags -X tailscale.com/version.*Stamp` 方式写入。

## 启用

1. 把本仓库推到 GitHub，默认分支为 `main`（定时任务只在默认分支运行）。
2. 在 Actions 页面手动运行一次 **Build derper image**，或等待定时触发。
3. 首次推送后 GHCR 包默认是 **私有** 的：到仓库的 Packages → `derper` → Package settings 把可见性改为 Public。
4. （可选）同步发布到 Docker Hub：在仓库 Secrets 里添加 `DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN`，
   工作流会自动额外推送到 `docker.io/<用户名>/derper`。

工作流需要的权限（已在文件中声明）：`packages: write` 推送镜像，`contents: write` 提交 `versions.json`。
如果 `main` 开了分支保护不允许 bot 推送，“Record published versions” 这一步会失败但不影响镜像发布，
也可以直接删掉这一步并把权限降为 `contents: read`。

> 注意：GitHub 会在公开仓库 60 天没有任何提交后自动停用定时工作流。本工作流每发布一个新版本就会
> 提交一次 `versions.json`，Tailscale / Go 的更新频率足以保持仓库活跃；若仍被停用，到 Actions 页面
> 点一下 Enable workflow 即可。

## 使用

```bash
docker run -d --name derper --restart unless-stopped \
  -p 80:80 -p 443:443 -p 3478:3478/udp \
  -v derper-data:/var/lib/derper \
  -v derper-certs:/app/certs \
  -e DERP_HOSTNAME=derp.example.com \
  ghcr.io/<owner>/derper:latest
```

或使用仓库里的 `docker-compose.yml`。

### 环境变量

| 变量 | 默认值 | 对应 derper 参数 |
|---|---|---|
| `DERP_HOSTNAME`（别名 `DERP_DOMAIN`） | （无，必填） | `--hostname` |
| `DERP_ADDR` | `:443` | `-a` |
| `DERP_HTTP_PORT` | `80` | `--http-port`（`-1` 关闭） |
| `DERP_STUN` | `true` | `--stun` |
| `DERP_STUN_PORT` | `3478` | `--stun-port` |
| `DERP_CERT_MODE` | `letsencrypt` | `--certmode`（`letsencrypt` / `manual`） |
| `DERP_CERT_DIR` | `/app/certs` | `--certdir` |
| `DERP_CONFIG` | `/var/lib/derper/derper.key` | `-c` |
| `DERP_VERIFY_CLIENTS` | `false` | `--verify-clients` |
| `DERP_VERIFY_CLIENT_URL` | （无） | `--verify-client-url` |
| `DERP_MESH_WITH` | （无） | `--mesh-with` |
| `DERP_MESH_PSK_FILE` | （无） | `--mesh-psk-file` |
| `DERP_ACME_EMAIL` | （无） | `--acme-email` |
| `DERP_HOME` | （无） | `--home` |
| `DERP_EXTRA_ARGS` | （无） | 按空白拆分后原样追加 |

任何 derper 参数都可以直接作为容器命令传入，会追加在环境变量生成的参数之后（后者优先）：

```bash
docker run --rm ghcr.io/<owner>/derper:latest --version
docker run ... ghcr.io/<owner>/derper:latest --hostname derp.example.com --certmode manual
```

- `DERP_CERT_MODE=manual` 时，把 `derp.example.com.crt` 和 `derp.example.com.key` 放进 `/app/certs`。
- `DERP_VERIFY_CLIENTS=true` 需要把宿主机的 `/var/run/tailscale/tailscaled.sock` 挂进容器同一路径。
- 容器以 root 运行（derper 默认把私钥放在 `/var/lib/derper/derper.key`，并需要绑定 80/443）。

## 本地构建

```bash
docker build --build-arg TS_VERSION=v1.104.5 --build-arg GO_VERSION=1.27.3 -t derper:local .
```

`scripts/resolve-versions.sh` 可以在本地直接运行查看当前会解析出什么版本；`scripts/test-resolve-versions.sh`
是它的离线测试（用本地文件和临时 git 仓库替代上游接口）：

```bash
./scripts/resolve-versions.sh
./scripts/test-resolve-versions.sh
```

## 文件

| 文件 | 作用 |
|---|---|
| `.github/workflows/build.yml` | 定时检查、构建、推送、验证、记录 |
| `scripts/resolve-versions.sh` | 解析 Tailscale / Go 版本（可离线测试） |
| `scripts/test-resolve-versions.sh` | 上述脚本的测试 |
| `Dockerfile` | 两阶段构建：Debian golang 镜像交叉编译 → Alpine 运行时 |
| `docker-entrypoint.sh` | 把 `DERP_*` 环境变量翻译成 derper 参数 |
| `docker-compose.yml` | 部署示例 |
| `versions.json` | 工作流自动维护的最近一次发布记录 |

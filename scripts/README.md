# 部署脚本说明

本目录存放 OBARA 知识库系统（WeKnora）在 Ubuntu 22.04.5 LTS 上的环境准备脚本，对应主文档《README》阶段一。

| 脚本 | 适用场景 | 执行命令 |
| --- | --- | --- |
| `install-docker.sh` | 全新虚机首次安装 Docker | `sudo bash scripts/install-docker.sh` |
| `fix-docker-env.sh` | Docker 已安装，但配置未生效、APT 源或镜像加速器异常 | `sudo bash scripts/fix-docker-env.sh` |

## 通用前提

- 系统：Ubuntu 20.04 / 22.04 / 24.04，架构 `amd64` 或 `arm64`
- 权限：root（通过 `sudo` 执行）
- 网络：可访问清华镜像站或 Docker 官方源；受限时先按主文档 1.4 节配置代理
- 可重复执行；脚本会先备份将被覆盖的配置（`*.bak.<时间戳>`）

## install-docker.sh

用途：安装 Docker 引擎与 Compose 插件，并完成基础调优，替代手工执行 `get.docker.com` 脚本。

```bash
sudo bash scripts/install-docker.sh
```

主要步骤：

1. 安装依赖（`ca-certificates`、`curl`、`gnupg` 等）并创建 `/etc/apt/keyrings`
2. 导入 Docker GPG 公钥：清华源优先，失败时重试并回退 `download.docker.com`
3. 写入 Docker APT 源：代号支持 `focal` / `jammy` / `noble`，其他代号回退 `jammy`；清华源不可用时自动回退官方源
4. 安装 `docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin`、`docker-compose-plugin`
5. 生成 `/etc/docker/daemon.json`：镜像加速器、systemd cgroup、`overlay2`、日志轮转（100m × 3）、`live-restore`、DNS
6. 将执行用户加入 `docker` 组，输出版本/服务状态，并用 `hello-world` 验证镜像拉取

执行后：

- 当前终端运行 `newgrp docker` 或重新登录，才能免 `sudo` 使用 `docker`
- 若 `hello-world` 拉取失败，见下方"常见问题"，或执行 `fix-docker-env.sh`

## fix-docker-env.sh

用途：修复首次安装后常见的环境问题。出现以下任一情况时执行。

```bash
sudo bash scripts/fix-docker-env.sh
```

适用场景：

- `apt update` 提示 `cn.mirrors.tuna.tsinghua.edu.cn` 无法解析
- `docker info` 中看不到 `registry-mirrors`，或修改 `daemon.json` 后未生效（安装 Docker 包时守护进程已先启动）
- Docker Hub 直连不通，需要重新探测可用的镜像加速器

主要步骤：

1. 将 `/etc/apt/sources.list` 及 `/etc/apt/sources.list.d/*.list` 中的 `cn.mirrors.tuna.tsinghua.edu.cn` 替换为 `mirrors.tuna.tsinghua.edu.cn`（原文件先备份）
2. 逐一探测候选加速器（daocloud / imgdb / 1panel / rat.dev），仅保留可用项
3. 重写 `/etc/docker/daemon.json` 并做 JSON 校验，随后 `systemctl restart docker`
4. 验证 Docker 状态、加速器生效情况、APT 源可达性、`hello-world` 拉取

> 注意：第 3 步会整体覆盖现有 `daemon.json`（已自动备份）。若此前手工配置了 `proxies` 等自定义项，需在执行后重新补回。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 访问 `docker.sock` 报 `Permission denied` | 重新登录或执行 `newgrp docker`；用 `id -nG` 确认已包含 `docker` 组 |
| `hello-world` 拉取失败 | 确认代理可用后执行 `fix-docker-env.sh` 重新探测加速器；必要时在 `daemon.json` 中补充 `proxies` |
| 修改 `daemon.json` 后不生效 | 执行 `sudo systemctl restart docker`，或直接运行 `fix-docker-env.sh` |
| APT 源报 404 / 无法解析 | 执行 `fix-docker-env.sh` 第 1 步逻辑，或按主文档 1.1 节重新配置镜像源 |
| 脚本中途失败 | 可直接重跑；已有配置均有备份 |

## 相关文档

- 主文档：[../README.md](../README.md)（阶段一：虚机与系统准备）

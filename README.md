# Debian 换源一键脚本

> 一条命令把 Debian 的 APT 源切换成国内镜像，自动适配你当前的系统版本，写错了还能一键回滚。

作者：末晨 · <https://blog.mochen.one> · 脚本版本：v2.0.0

仓库：<https://github.com/mocchen/Debian-sources-shell>

---

## 简介

`source.sh` 是一个运行在 Debian 上的 APT 换源工具。它会读取当前系统版本，按版本生成**格式正确、内容完整**的源配置，然后帮你更新软件包索引。

和早期版本最大的区别是：**不再写死在 Debian 10~13 上**。无论你用的是已停止支持的 Debian 11，还是当前的 Debian 13、测试版 14，甚至以后发布的新版本，脚本都会自动选对套件名、组件和安全源路径，不需要改代码。

---

## 适配范围

| Debian 版本 | 代号 | 状态 | 脚本行为 |
| --- | --- | --- | --- |
| 9 | stretch | 已归档 | 使用 `archive.debian.org` 归档源 |
| 10 | buster | 已归档 | 使用归档源，安全源为 `buster/updates` |
| 11 | bullseye | 已归档 | 使用归档源，安全源为 `bullseye-security` |
| 12 | bookworm | 旧稳定版（LTS） | 正常镜像源，含 `non-free-firmware` |
| 13 | trixie | 当前稳定版 | 正常镜像源，默认写 deb822 格式 |
| 14 | forky | 测试版 | 按稳定版规则生成，套件名自动推导 |
| 15+ / sid | — | 未来版本 / 滚动版 | 自动适配；sid 不写安全源 |

判断顺序：先看 `/etc/os-release` 的 `VERSION_CODENAME`，缺失时按 `VERSION_ID` 推断，再缺失则读 `/etc/debian_version`。

> 仅支持 Debian 本体。Ubuntu、Kali 等衍生版会先警告并默认中止，避免把系统写坏。

---

## 特性

- **版本自适应**：9~14 及未来版本无需改脚本；已 EOL 的版本自动切换归档源。
- **双格式支持**：自动识别当前系统使用 `deb822`（`/etc/apt/sources.list.d/debian.sources`）还是传统 `/etc/apt/sources.list`，并沿用同一种格式写入，避免"写了不生效"。
- **重复源清理**：写入前会把另一种格式里残留的 Debian 条目停用/注释，同时**保留你原有的第三方源**（Docker、Proxmox 等）。
- **写入前快照**：整个源配置备份到 `/var/backups/apt-dsh/<时间戳>/`，一条 `--restore` 回到从前。
- **云厂商内网加速**：在腾讯云/阿里云机器上自动探测内网元数据，走 HTTP 内网镜像。
- **镜像可用性预检**：探测目标镜像上是否真有当前版本的索引，不可用就提示换源，避免写出一份跑不通的配置。
- **非交互模式**：`-y` 一键执行，适合批量部署、初始化脚本、自动化运维。

---

## 快速开始

### 方式一：在线一键运行

不落地文件，直接执行仓库里的最新版：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mocchen/Debian-sources-shell/refs/heads/mochen/source.sh)"
```

这条命令把脚本内容整体交给 `bash` 执行，标准输入仍然是你的终端，所以交互菜单、写入确认、`--restore` 的询问都能正常响应。

需要带参数时（`-s --` 之后的参数会原样传给脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/mocchen/Debian-sources-shell/refs/heads/mochen/source.sh | sudo bash -s -- -m tuna -y
```

管道形式同样能弹菜单——脚本在标准输入不是终端时会自动改从 `/dev/tty` 读取，因此 `curl | bash` 这种常见写法不会失效。

### 方式二：下载后运行（推荐）

```bash
curl -fsSLO https://raw.githubusercontent.com/mocchen/Debian-sources-shell/refs/heads/mochen/source.sh
less source.sh          # 先看一眼再执行
sudo bash source.sh
```

本地运行的好处是方便用 `-h` 看帮助、用 `--print` 预览，出问题时也能直接 `--restore` 回滚。

> 上面的链接指向 `mochen` 分支的最新提交，内容会随仓库更新而变化。对稳定性要求高的场景，建议把分支名换成固定的 commit SHA 或 tag。仓库若改为私有，raw 链接需要携带 token 才能访问。

### 常用一行命令

```bash
sudo bash source.sh -m tuna -y            # 切换清华源并更新索引
sudo bash source.sh -m aliyun --no-src    # 阿里云源，不写 deb-src
sudo bash source.sh -m ustc -y --upgrade  # 换源后顺便升级已安装软件包
bash source.sh --print                    # 只看会写成什么样，不动任何文件
```

---

## 交互菜单

```
  请选择要使用的镜像源：

    0) 退出
    1) 官方 Debian 源 (deb.debian.org)
    2) 清华 TUNA
    3) 中科大 USTC
    4) 阿里云
    5) 腾讯云
    6) 华为云
    7) 南京大学 (NJU)
    8) 恢复备份的源配置
    9) 查看当前源配置
```

---

## 命令行参数

| 参数 | 说明 |
| --- | --- |
| `-m, --mirror NAME` | 指定镜像源：`official` `tuna` `ustc` `aliyun` `tencent` `huawei` `nju` |
| `-y, --yes` | 非交互，所有确认自动通过 |
| `-f, --format FMT` | 配置格式：`auto`（默认，跟随系统）`list` `deb822` |
| `-s, --with-src` | 写入 `deb-src` 源 |
| `--no-src` | 不写 `deb-src` 源 |
| `--no-backports` | 不写 `-backports` 源 |
| `-p, --print` | 只打印生成的配置，不修改任何文件 |
| `--no-update` | 写入后不执行 `apt-get update` |
| `--upgrade` | 更新索引后执行 `apt-get upgrade` |
| `--restore [快照]` | 恢复备份，不带参数则恢复最近一次 |
| `--list-backups` | 列出所有备份 |
| `--show` | 显示当前生效的源配置 |
| `--codename NAME` | 强制指定发行代号（如 `trixie`、`forky`、`sid`） |
| `--root DIR` | 操作指定根目录，用于离线预览/测试 |
| `--force` | 跳过镜像可用性检测 |
| `-h, --help` | 显示帮助 |

镜像名支持别名，例如 `tsinghua`/`thu` → `tuna`，`ali` → `aliyun`，`txy`/`qcloud` → `tencent`，`debian`/`default` → `official`。

---

## 生成结果示例

### Debian 13 trixie（deb822）

`/etc/apt/sources.list.d/debian.sources`

```ini
Types: deb deb-src
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian/
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security/
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

### Debian 12 bookworm（传统 sources.list）

```bash
deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb-src https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware

deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware

deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb-src https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware

deb https://mirrors.ustc.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware
deb-src https://mirrors.ustc.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware
```

### Debian 11 bullseye（已 EOL → 归档源）

```bash
deb [check-valid-until=no] https://archive.debian.org/debian/ bullseye main contrib non-free
deb [check-valid-until=no] https://archive.debian.org/debian/ bullseye-updates main contrib non-free
deb [check-valid-until=no] https://archive.debian.org/debian-security/ bullseye-security main contrib non-free
```

---

## 备份与回滚

每次写入前都会做一次完整快照：

```
/var/backups/apt-dsh/
├── latest                  # 纯文本指针，内容是最近一次快照路径
├── 20261126-034607/
│   ├── sources.list
│   ├── sources.list.d/
│   └── manifest            # 时间、脚本版本、系统版本、代号、镜像、格式
└── 20261125-120102/
```

```bash
sudo bash source.sh --list-backups          # 看有哪些备份
sudo bash source.sh --restore               # 回到最近一次
sudo bash source.sh --restore 20261125-120102   # 回到指定快照
```

恢复会同时还原 `sources.list` 与整个 `sources.list.d/` 目录里的 `.list` / `.sources` 文件（其余文件不动）。

---

## 工作原理

1. 检查 root 权限，读取 `/etc/os-release` 判断是否为 Debian。
2. 解析发行代号与版本号，得出：套件列表、组件、安全源套件名、是否为归档版本。
3. 探测镜像上 `dists/<代号>/Release` 是否存在，确认镜像同步了当前版本。
4. 判断当前系统在用 deb822 还是传统格式，生成对应内容（`deb-src` 默认跟随现有配置）。
5. 快照备份 → 清理另一种格式里的重复 Debian 条目 → 原子写入（临时文件 + rename，权限 644）。
6. 执行 `apt-get update` 并汇报结果；失败时提示可用 `--restore` 回滚。

---

## 常见问题

**Q：会不会把我自己加的第三方源弄丢？**
不会。传统格式写入时会把非 Debian 条目原样追加到新文件末尾；deb822 文件里若混有第三方 stanza，只删 Debian 的那段。

**Q：为什么 Debian 12 及以上有 `non-free-firmware`，11 及以下没有？**
Debian 12 起把非自由固件从 `non-free` 拆成了独立组件，套件内容不同，写错会 404。

**Q：为什么旧版本要用 `archive.debian.org`？会不会很慢？**
Debian 11 及更早已进入归档，官方镜像站不再同步，指向 `deb.debian.org` 只会得到 404。归档站没有国内镜像，速度取决于出口带宽；如果只是临时装几个包，可考虑用 `snapshot.debian.org` 指定历史时间点。

**Q：`apt update` 报 `Target ... is configured multiple times`？**
说明系统里还残留着另一份 Debian 源。新版脚本会自动停用，也可手动检查 `/etc/apt/sources.list` 和 `/etc/apt/sources.list.d/`。

**Q：`--no-src` 有什么用？**
`deb-src` 会额外下载源码索引，`apt update` 明显变慢。只装二进制包的话可以关掉，需要时再跑一次 `-s`。

**Q：`curl ... | bash` 运行还能弹菜单吗？**
可以。脚本检测到标准输入不是终端时会自动从 `/dev/tty` 读取输入；纯自动化场景请直接传 `-m` 和 `-y`。

**Q：出了事怎么救？**
`sudo bash source.sh --restore`。备份在 `/var/backups/apt-dsh/`，即使脚本本身丢了也能手动 `cp` 回去。

---

## 注意事项

- 请以 root 运行（`sudo bash source.sh`），否则无法写 `/etc/apt`。
- 换源只改 APT 源列表，不会安装/卸载软件，也不动 GPG 密钥。
- 归档版本不再有安全更新，生产环境请尽快升级到 Debian 12/13。
- 脚本只处理 Debian 官方仓库相关的条目，第三方源（Docker、NodeSource、Proxmox 等）保持原样。
- 建议在首次执行后确认 `/etc/apt/sources.list.d/` 中没有多余的 `.sources` 文件。

---

## 许可

脚本可自由使用、修改和分发，请保留作者信息。

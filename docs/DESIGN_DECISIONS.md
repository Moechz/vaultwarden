# Design decisions

> 编号只增不改；推翻旧决策用新条目并标注 Superseded。

## 部署形态

### D-001: 直开端口模式（0.0.0.0:8222，不走 /vaultwarden/ 反代）【Superseded by D-010】
**Decision:** 应用以 WebUI External Open（新标签页）直开 `http://${ip}:8222`，服务监听 0.0.0.0:8222，各端客户端直连同址；不使用"回环 + TOS nginx 子路径反代"模式。
**Consequences:**
- 根因：Vaultwarden 的 API 固定挂载在 URL 根（/api /identity /notifications /icons /alive…），web vault 前端也存在根相对请求，**不支持子路径**；反代剥离前缀后浏览器会把根相对请求打到 8181 根命名空间（属 TOS 自身，不可占用）。
- hermes-agent-webui 已真机验证 `${ip}:端口` 的 path 写法可用；桌面图标/客户端/附件下载全部自洽。
- 代价：8222 对局域网开放（这正是 vaultwarden 社区的常规部署形态）；真机验证清单的"仅回环"项对本模式**按设计不适用**。
- TOS 8181 侧仅保留 302 兜底跳转（见 D-007）。
- 排除方案：① 子路径反代（会断）；② TOS 根级 /api /location 反代（与平台 API 冲突，禁止）。

### D-002: 二进制取自官方 alpine 镜像（static-pie musl），Registry API 直拉【Superseded by D-011】
**Decision:** 不从源码编译，二进制与 web-vault 均提取自 `vaultwarden/server:<版本>-alpine` 官方镜像，经 Docker Registry HTTP API 用纯 Python 拉取，层 digest 作为 sha256 校验与内容固定依据（build/downloads/image-lock.json）。
**Consequences:**
- 背景：上游 GitHub Release 自 1.37.x 起不附二进制；官方默认镜像 tag 的二进制是 Debian trixie glibc 动态链接，需要 GLIBC_2.39（TOS7=Ubuntu22.04/glibc2.35 必挂）——2026-09 真机实测实锤；alpine 变体为 static-pie musl 全静态，TOS 直接可跑。
- verify 阶段断言"静态链接 + 架构匹配"双条件（坑 28 防呆）。
- 版本升级 = 改 config.env 的 VAULTWARDEN_VERSION 重跑（同 tag 镜像内容被 digest 固定，可复现）。
- 排除方案：cargo 交叉编译（构建链重、周期长）；第三方预编译（信任不足）。

### D-003: web-vault 随包且与二进制同源【来源修订 by D-011：改取 bw_web_builds 官方发布，配套关系不变】
**Decision:** web vault 静态文件（约 280 文件）打包进 /usr/local/vaultwarden/web-vault/，取自与二进制相同的镜像层。
**Consequences:**
- 版本天然配套，杜绝二进制/web-vault 版本错配（上游 wiki 明示需匹配）。
- 不裁剪 .map 等开发产物：保持与官方镜像内容一致，简化完整性叙事；代价约 +50MB 磁盘（xz 后影响小）。
- 排除方案：单独从 dani-garcia/bw_web_builds 拉 web vault（多一个来源、需人工核对配套关系）。

## 安全与配置

### D-004: ADMIN_TOKEN 首装随机生成，绝不打印
**Decision:** postinst 首装时生成 96 位十六进制随机令牌追加到 vaultwarden.env；不向安装输出/维护日志打印令牌本体，只在安装提示中给出查看命令。
**Consequences:**
- App Center 安装日志（用户可见）不会泄露令牌。
- 令牌为明文（vaultwarden 支持但会在日志提示 NOTICE）；env 模板与 README 说明可用 `vaultwarden hash` 换 argon2 PHC 串。
- 生成失败（罕见）时明确告警并指路手工设置，不静默。

### D-005: unit 内置 Environment= 默认值 + env 文件可覆盖
**Decision:** vaultwarden 无命令行参数，无法复制 navidrome 的"ExecStart flags 写死"模式；等价实现为 unit 里 `Environment=ROCKET_ADDRESS/ROCKET_PORT/DATA_FOLDER/WEB_VAULT_FOLDER` 默认值，`EnvironmentFile=-...` 声明其后，用户 env 可覆盖一切。
**Consequences:**
- env 误删时服务仍以安全默认值工作（端口/数据目录不漂移）。
- 用户改端口/目录只需编辑 env + restart；unit 无需动。
- verify 断言四个默认值存在（防回退）。

### D-006: .lang 采用 23 语超集
**Decision:** 语言文件包含真机实测 14 语 + 官方英文口径 9 语的超集（23 节）；en/zh-cn/zh-hk 全译，主要语种翻译 descript/important，其余填英文。
**Consequences:**
- 同时满足两个官方口径（坑：官方文档与真机校验的 14 语清单不一致）。
- hermesagent 先例，随包真机验证无副作用。

### D-007: nginx conf 为 302 兜底跳转，不做反代【Superseded by D-010】
**Decision:** 随包 nginx/vaultwarden.conf 仅含 `location /vaultwarden/ { return 302 http://$host:8222/; }`（含无尾斜杠精确匹配变体），满足 External Open 应用必带 nginx/ 的规范；postinst 写入 /etc/nginx/conf.d 时照例 nginx -t 校验失败即回滚。
**Consequences:**
- 用户手输 8181/vaultwarden/ 也能到达应用；绝无"半能用的反代页"。
- TOS 平台侧无论是否加载该 conf 都不影响功能。

### D-008: HTTPS 限制必须显著文档化（不可代码修复）
**Decision:** 在 .lang 的 important、control Description、postinst 输出、README 四处显著说明：浏览器网页保管库解锁需要 HTTPS（WebCrypto secure context），局域网 http 请用各端客户端或启用 HTTPS/反代。
**Consequences:**
- 这是 Bitwarden 全系网页版固有行为（http 非 localhost 即无 crypto.subtle），包内无解；文档化是唯一正确处置，也预防商店审核误判。
- 各端客户端（浏览器插件/桌面）在 http 下可用；移动端视系统策略可能要求 https（文案措辞留有余地）。
- DOMAIN：【2026-09 整改后】unit 内置默认 `http://127.0.0.1:8181/vaultwarden`（D-010：路径部分是路由挂载前缀，必须设；origin 部分为占位）；用户应在 env 按实际入口地址覆盖（路径部分不可改）。

## 构建与分发

### D-009: 产物双命名 + sha256（沿用项目族约定）
**Decision:** out/ 同时产出 `vaultwarden_<版本>_<arch>.deb`（本地测试，文件名不用 amd64/arm64 字样以外的 TOS 平台名——实际为 `vaultwarden_1.37.3-1_amd64.deb` 风格，供 ssh 手动 apt 安装）与 `vaultwarden_{x86_64,aarch64}.deb(.sha256)`（Release 资产，版本由 tag 表达）。
**Consequences:**
- 与 metube/beszel/navidrome 三项目同构，发布流程零新知识。
- 上架 Release tag 必须 = `v<完整版本>`；每次提交严格递增（坑 19）。

---

# 2026-09 商店合规整改批（指南 9/19 更新，坑 37–49 驳回实录驱动）

## 部署形态（整改）

### D-010: 路由 /vaultwarden/ + 回环监听 + 保留前缀反代（取代 D-001/D-007）
**Decision:** config.ini `path="/vaultwarden/"`（纯路由，禁 `${ip}`/协议/端口）；服务仅监听 `127.0.0.1:8222`；nginx 网关为唯一入口：`location /vaultwarden/ { proxy_pass http://127.0.0.1:8222/vaultwarden/; }`（**保留前缀**转发）+ WebSocket 升级头 + 无尾斜杠 302 + 隐私政策精确路由。
**Consequences:**
- D-001 的"不支持子路径"前提**不成立**：源码考古发现上游 main.rs 会把全部路由挂载在 `DOMAIN` 的路径部分之下（`mount([basepath, "/api"]…)`），且官方 web vault 补丁（bw_web_builds，web-environment.service.ts）以"当前地址含路径"为 base URL——子路径是 vaultwarden 官方支持的部署方式，`.env.template` 的 DOMAIN 示例本就带路径。
- 后端必须设 `DOMAIN` 且路径部分锁死 `/vaultwarden`（unit 内置默认 `http://127.0.0.1:8181/vaultwarden`；协议/主机/端口由用户在 env 按实际入口覆盖，改路径会脱离 nginx 路由 = 404，文档锁死）。
- `/api/config` 的 environment URL（api/identity/notifications/vault）全部带前缀，各端客户端与服务闭环；FIDO2/app-id.json 亦随 DOMAIN 生成。
- 真机全路径验证：索引/静态资源/prelogin/api/config/admin 登录/WS 握手/隐私政策全部 200，8222 仅回环、外网拒连。
- 驱动：C21（path 必须路由，直连 URL 逐机端口漂移必驳）+ 安全审核（0.0.0.0 无平台鉴权一票否决）。
- 排除方案：剥前缀反代（后端根挂载也能工作，但后端重定向/env URL 均为根路径，需 proxy_redirect 兑底，运行时 URL 拼接链脆弱；保留前缀无任何 rewrite 魔法）。

## 构建与分发（整改）

### D-011: 二进制改为本仓库 CI 从上游源码自建（取代 D-002；V6 合规链）
**Decision:** BINARY_SOURCE=source（默认，上架必用）：`.github/workflows/release.yml` 从上游 tag 源码构建静态二进制（blackdex/rust-musl 容器，与上游 Dockerfile.alpine 同配方，VW_VERSION 同 Docker ARG 注入），产物发布到本仓库 Release；web vault 取 bw_web_builds 官方发布原样再分发（前端预构建产物，workflow 记录 tag，坑 43 alist 先例）。fetch 阶段（scripts/fetch_release.py）双重校验：Release SHA256SUMS + config.env 钉死值；verify 断言二进制 sha256 == 钉死值 + 静态 + 无 UPX 段表摘除。
**Consequences:**
- 驱动：V6（坑 30a/31/32/43）——包内预编译 ELF 无源码可溯 = 一票拒；Docker 镜像提取的二进制审计链更弱。
- compat 模式（原镜像提取）保留为本地调试逃生门（`VW_COMPAT=1 ./build.sh`），构建时显式警告"产物禁止上架"并跳过 sha256 钉死校验。
- 溯源三件套：VERIFICATION.md + repro-build.sh + Dockerfile.repro（公开仓库）；PROVENANCE.md 随包落盘 /usr/share/doc/vaultwarden/。
- 鸡生蛋流程：先推 workflow → 打 tag v<VERSION_FULL> 触 CI → Release 出产物 → sha256 回填 config.env → source 模式重出 deb。升级上游版本需重跑此循环。
- 排除方案：本地 cargo 交叉编译（构建机无审计链，与 V6 初裁同样被动）；改用上游官方 Release 二进制（1.37.x 起不存在）。

### D-012: 隐私政策三处可达（C3 必备资产）
**Decision:** 双语（EN+ZH）privacy-policy.html 随包落盘 /usr/local/vaultwarden/privacy/，nginx 精确路由 `location = /vaultwarden/privacy-policy.html` alias 之；.lang descript、control Description、postinst 输出、webui 入口页四处提及。
**Consequences:**
- vaultwarden 涉账号/用户数据/可选外联（SMTP、favicon 下载），隐私政策为商店硬性要求（坑 45/alist 实录）。
- 内容如实披露：零遥测、数据本地 SQLite、favicon 默认会向条目站点发起出站请求（及关闭方法）、SMTP/FIDO2 可选。
- 精确匹配 location 优先于前缀反代，无冲突（sftpgo 同模式）。

### D-013: 署名与字段定夺（2026-09-19 用户定夺，替代早前"publisher=上游"方案）
**Decision:** 四字段分工如下——
- `.lang` 各语 `auth` = "Daniel García"（上游原始作者；体现作者归上游）
- `config.ini` 的 `publisher` = "Moechz"（本包发布者/打包者）
- `config.ini` 的 `help` = https://forum.terra-master.com/en/viewtopic.php?t=10596（TOS 论坛帖）
- `config.ini` 的 `official` = https://github.com/dani-garcia/vaultwarden/wiki（上游 wiki）
- `.lang` 各语 `name` 统一 "Vaultwarden"（短名）；control Maintainer 仍为打包者，Description 尾注保留 "Upstream author … packaged for TOS by …" 分工说明。
**Consequences:**
- "作者（auth）归上游、发布者（publisher）归打包者"的语义分工；与 hermes（publisher=Moechz）一致。
- official 指向上游 wiki：用户点它查的是产品官方资料；打包仓库（CI/溯源）仍可经 deb 内 PROVENANCE.md 与 Release 链条发现，V6 材料不依赖 official 字段。
- check_assets 断言 23 语 auth 统一等于 config.env AUTHOR，防逐语漂移。

### D-014: webui.bz2 用 python tarfile 规范重打（S11）
**Decision:** stage 阶段不再用 macOS bsdtar 打 webui.bz2，改为 Python tarfile（GNU_FORMAT，全部成员 uid/gid=0、uname/gname=root、mtime=0、mode 0644）；verify 断言归档内每个成员的 uid/gid/mtime 均 = 0。
**Consequences:**
- 嵌套归档里的 macOS uid 501 污染会触发商店 S11 校验失败（坑 46）；同模式适用于未来任何嵌套归档资产。

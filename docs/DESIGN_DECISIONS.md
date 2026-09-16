# Design decisions

> 编号只增不改；推翻旧决策用新条目并标注 Superseded。

## 部署形态

### D-001: 直开端口模式（0.0.0.0:8222，不走 /vaultwarden/ 反代）
**Decision:** 应用以 WebUI External Open（新标签页）直开 `http://${ip}:8222`，服务监听 0.0.0.0:8222，各端客户端直连同址；不使用"回环 + TOS nginx 子路径反代"模式。
**Consequences:**
- 根因：Vaultwarden 的 API 固定挂载在 URL 根（/api /identity /notifications /icons /alive…），web vault 前端也存在根相对请求，**不支持子路径**；反代剥离前缀后浏览器会把根相对请求打到 8181 根命名空间（属 TOS 自身，不可占用）。
- hermes-agent-webui 已真机验证 `${ip}:端口` 的 path 写法可用；桌面图标/客户端/附件下载全部自洽。
- 代价：8222 对局域网开放（这正是 vaultwarden 社区的常规部署形态）；真机验证清单的"仅回环"项对本模式**按设计不适用**。
- TOS 8181 侧仅保留 302 兜底跳转（见 D-007）。
- 排除方案：① 子路径反代（会断）；② TOS 根级 /api /location 反代（与平台 API 冲突，禁止）。

### D-002: 二进制取自官方 alpine 镜像（static-pie musl），Registry API 直拉
**Decision:** 不从源码编译，二进制与 web-vault 均提取自 `vaultwarden/server:<版本>-alpine` 官方镜像，经 Docker Registry HTTP API 用纯 Python 拉取，层 digest 作为 sha256 校验与内容固定依据（build/downloads/image-lock.json）。
**Consequences:**
- 背景：上游 GitHub Release 自 1.37.x 起不附二进制；官方默认镜像 tag 的二进制是 Debian trixie glibc 动态链接，需要 GLIBC_2.39（TOS7=Ubuntu22.04/glibc2.35 必挂）——2026-09 真机实测实锤；alpine 变体为 static-pie musl 全静态，TOS 直接可跑。
- verify 阶段断言"静态链接 + 架构匹配"双条件（坑 28 防呆）。
- 版本升级 = 改 config.env 的 VAULTWARDEN_VERSION 重跑（同 tag 镜像内容被 digest 固定，可复现）。
- 排除方案：cargo 交叉编译（构建链重、周期长）；第三方预编译（信任不足）。

### D-003: web-vault 随包且与二进制同源
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

### D-007: nginx conf 为 302 兜底跳转，不做反代
**Decision:** 随包 nginx/vaultwarden.conf 仅含 `location /vaultwarden/ { return 302 http://$host:8222/; }`（含无尾斜杠精确匹配变体），满足 External Open 应用必带 nginx/ 的规范；postinst 写入 /etc/nginx/conf.d 时照例 nginx -t 校验失败即回滚。
**Consequences:**
- 用户手输 8181/vaultwarden/ 也能到达应用；绝无"半能用的反代页"。
- TOS 平台侧无论是否加载该 conf 都不影响功能。

### D-008: HTTPS 限制必须显著文档化（不可代码修复）
**Decision:** 在 .lang 的 important、control Description、postinst 输出、README 四处显著说明：浏览器网页保管库解锁需要 HTTPS（WebCrypto secure context），局域网 http 请用各端客户端或启用 HTTPS/反代。
**Consequences:**
- 这是 Bitwarden 全系网页版固有行为（http 非 localhost 即无 crypto.subtle），包内无解；文档化是唯一正确处置，也预防商店审核误判。
- 各端客户端（浏览器插件/桌面）在 http 下可用；移动端视系统策略可能要求 https（文案措辞留有余地）。
- DOMAIN 默认不设（安装期无法得知最终访问地址）；env 模板置顶说明其影响（邮件链接/FIDO2/部分客户端功能），用户自行填写。

## 构建与分发

### D-009: 产物双命名 + sha256（沿用项目族约定）
**Decision:** out/ 同时产出 `vaultwarden_<版本>_<arch>.deb`（本地测试，文件名不用 amd64/arm64 字样以外的 TOS 平台名——实际为 `vaultwarden_1.37.3-1_amd64.deb` 风格，供 ssh 手动 apt 安装）与 `vaultwarden_{x86_64,aarch64}.deb(.sha256)`（Release 资产，版本由 tag 表达）。
**Consequences:**
- 与 metube/beszel/navidrome 三项目同构，发布流程零新知识。
- 上架 Release tag 必须 = `v<完整版本>`；每次提交严格递增（坑 19）。

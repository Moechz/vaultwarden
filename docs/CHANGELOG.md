# Changelog

## 1.37.3-2 — 2026-09-19

维护版：包内容与 1.37.3-1 一致（同一上游源码 tag 构建、同一 web vault），
为真机全项复验与文档勘误后的重发。**无需用户手工操作，升级即生效。**

### Added
- 真机（TOS 7 x86_64）外部入口全项复验通过：网关路由 `/vaultwarden/`、管理后台
  `/vaultwarden/admin`、隐私政策页、无尾斜杠 302（Location 为相对路径，入口端口
  不丢）、外部直连 8222 拒连（仅回环）。
- 记录升级前基线（数据库 / RSA 密钥 / 配置 / 桌面图标数），供后续版本升级回归对比。

### Fixed
- 文档勘误：应用注册完整性的判据修正为**桌面图标数量**（`.oexe`）。此前依据
  `/etc/sc.d/<appid>` 是否为空判断，真机实测该文件在本构建上对所有应用（含系统
  服务）恒为空，不具判别力。

### Notes
- 「应用中心 → 手动安装」路径真机确认完成：23 个桌面图标 + 完整 dpkg 时间线，
  无卡进度（对应打包指南坑 11 的卡死判定）。
- WebSocket 端点 `/vaultwarden/notifications/hub` 探测需带完整 Upgrade 握手头
  （返回 401 即端点存活）；裸 GET 返回 404 属 websocket 路由的正常行为。

## 1.37.3-1 — 2026-09-19（首版；2026-09-17 初版封装 + 商店审核合规整改后重出）

### Added
- 首个 TOS 7 封装：Vaultwarden 1.37.3 + 配套 web vault 2026.7.0，双架构
  （x86_64 / aarch64）。
- 二进制为本仓库 CI 从上游源码 tag 自建的静态 musl 产物（V6 合规链：
  公开 workflow + Release 资产 + 双重 sha256 钉死）；web vault 取
  bw_web_builds 官方发布，版本与上游 1.37.3 官方镜像钉定一致。
- TOS 网关路由 /vaultwarden/：服务仅监听 127.0.0.1（回环封闭），nginx
  保留前缀反代 + WebSocket 升级；web 入口、各端客户端、附件与实时推送
  全部经同一路由。
- 双语隐私政策，/vaultwarden/privacy-policy.html 可达（C3 必备）。
- 溯源材料：VERIFICATION.md / repro-build.sh / Dockerfile.repro（公开仓库）
  + PROVENANCE.md（随包 /usr/local/vaultwarden/；坑 50：/usr/share/doc 会被 TOS dpkg 剥离）。
- 安装时自动生成随机 ADMIN_TOKEN（管理后台 /vaultwarden/admin；查看方式
  见 README），不出现在安装日志中。
- 23 语言应用中心文案（en/zh-cn/zh-hk 全文，主要语种翻译，其余英文）。
- 数据目录 /var/lib/vaultwarden：apt remove 保留、apt purge 彻底清除。
- systemd 沙箱加固（专用非特权用户、ProtectSystem=strict 等）；
  DOMAIN 默认路径前缀 /vaultwarden 与网关路由联动（origin 可改）。
- 署名（D-013）：.lang auth = 上游作者 Daniel García；publisher = Moechz（发布者）；
  help = TOS 论坛帖；official = 上游 wiki；应用名统一 "Vaultwarden"；
  Maintainer = 打包者，Description 尾注明示分工。

### Notes
- 网页保管库在浏览器中解锁需要 HTTPS（Bitwarden 网页版固有的 WebCrypto
  secure-context 限制）；局域网 http 请使用各端客户端，或在 NAS 启用
  HTTPS / 自行加 https 反代。
- 建议安装后：立即注册首个账号，随后关闭开放注册（SIGNUPS_ALLOWED）
  或改用后台邀请；按访问方式在 vaultwarden.env 设置 DOMAIN。

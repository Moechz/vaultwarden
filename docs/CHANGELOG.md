# Changelog

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
  + PROVENANCE.md（随包 /usr/share/doc/vaultwarden/）。
- 安装时自动生成随机 ADMIN_TOKEN（管理后台 /vaultwarden/admin；查看方式
  见 README），不出现在安装日志中。
- 23 语言应用中心文案（en/zh-cn/zh-hk 全文，主要语种翻译，其余英文）。
- 数据目录 /var/lib/vaultwarden：apt remove 保留、apt purge 彻底清除。
- systemd 沙箱加固（专用非特权用户、ProtectSystem=strict 等）；
  DOMAIN 默认路径前缀 /vaultwarden 与网关路由联动（origin 可改）。
- 署名：publisher/.lang auth = 上游作者 Daniel García；Maintainer =
  打包者，Description 尾注明示分工。

### Notes
- 网页保管库在浏览器中解锁需要 HTTPS（Bitwarden 网页版固有的 WebCrypto
  secure-context 限制）；局域网 http 请使用各端客户端，或在 NAS 启用
  HTTPS / 自行加 https 反代。
- 建议安装后：立即注册首个账号，随后关闭开放注册（SIGNUPS_ALLOWED）
  或改用后台邀请；按访问方式在 vaultwarden.env 设置 DOMAIN。

### Added
- 首个 TOS 7 封装：Vaultwarden 1.37.3（官方 alpine 镜像 static-pie musl 二进制）
  + 配套 web vault 2026.7.0，双架构（x86_64 / aarch64）。
- WebUI External Open（新标签页直开 http://<NAS-IP>:8222/）；TOS 8181 侧附
  /vaultwarden/ → :8222 的 302 兜底跳转。
- 安装时自动生成随机 ADMIN_TOKEN（管理后台 /admin；查看方式见 README），
  不出现在安装日志中。
- 23 语言应用中心文案（en/zh-cn/zh-hk 全文，主要语种翻译，其余英文）。
- 数据目录 /var/lib/vaultwarden：apt remove 保留、apt purge 彻底清除。
- systemd 沙箱加固（专用非特权用户、ProtectSystem=strict 等）。

### Notes
- 网页保管库在浏览器中解锁需要 HTTPS（Bitwarden 网页版固有的 WebCrypto
  secure-context 限制）；局域网 http 请使用各端客户端，或在 NAS 启用
  HTTPS / 自行加 https 反代。
- 建议安装后：立即注册首个账号，随后关闭开放注册（SIGNUPS_ALLOWED）
  或改用后台邀请；按访问方式在 vaultwarden.env 设置 DOMAIN。

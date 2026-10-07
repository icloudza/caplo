# 发布与在线更新

推送 `vX.Y.Z` 标签后，[`.github/workflows/release.yml`](../../.github/workflows/release.yml) 依次完成：

1. 按标签换算版本号与构建号（`version.sh`）
2. 归档、以 Developer ID 导出、重签 Sparkle 组件（`build.sh`）
3. 公证并装订应用，打包 DMG，再公证并装订 DMG
4. 创建 GitHub Release，附上 DMG 与更新说明（`notes.sh`）
5. 签名安装包，生成并签名 `appcast.xml` 与 `latest.json`，上传到 Cloudflare R2（`publish.sh`）

应用内更新使用 [Sparkle](https://sparkle-project.org)：每天检查一次 `appcast.xml`，在录制或导出期间不弹窗。安装包和 appcast 都经过 EdDSA 签名校验。

## 一次性配置

在仓库根目录运行配置向导，按提示填写（每项可以回车跳过，之后再补）：

```bash
Scripts/release/configure-github.sh
```

| 名称 | 类型 | 内容 |
| --- | --- | --- |
| `MACOS_CERTIFICATE_P12` | Secret | Developer ID Application 证书（.p12，base64） |
| `MACOS_CERTIFICATE_PASSWORD` | Secret | .p12 的导出密码 |
| `APPLE_TEAM_ID` | Secret | 团队 ID |
| `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` | Secret | App Store Connect API 密钥，用于公证 |
| `SPARKLE_PRIVATE_KEY` | Secret | 更新签名私钥 |
| `SPARKLE_PUBLIC_KEY` | Variable | 更新签名公钥，写入应用 |
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Secret | R2 API 令牌 |
| `R2_BUCKET` | Variable | 存储桶名称 |
| `DOWNLOAD_BASE_URL` | Variable | 存储桶绑定的下载域名，例如 `https://download.caplo.app` |
| `SITE_URL` | Variable | 官网地址（可选） |
| `MACOS_RUNNER` / `XCODE_PATH` | Variable | 可选：指定运行器与 Xcode，默认 `macos-26` 和其中最新的正式版 Xcode |

配置完成后，在 Actions → Release Check → Run workflow 跑一次发布前检查。它会逐项验证证书、公证密钥、更新签名密钥、R2 写入和下载域名，不构建、不发版。

**Sparkle 私钥必须备份。** 私钥会存进本机钥匙串（账户名 `caplo`），可以用下面的命令导出到安全位置：

```bash
"$(Scripts/release/sparkle-tools.sh)/generate_keys" --account caplo -x ~/caplo-sparkle-private-key
```

私钥一旦丢失，已安装的用户就收不到后续更新，只能手动重新下载。

## 发布

更新说明写在 `ReleaseNotes/<版本>.md`，应用内更新窗口和 GitHub Release 共用这份说明，格式支持 `##` 标题、`-` 列表和行内 Markdown。写好后提交，再推送标签：

```bash
git tag v0.2.0
```

```bash
git push origin v0.2.0
```

预发布使用 `v0.2.0-beta.1` 或 `v0.2.0-rc.1` 这类标签：只生成 GitHub 预发布版本并上传安装包，不更新 `appcast.xml` 和官网下载。重新发布已有标签：Actions → Release → Run workflow，填入标签。

## 下载服务器

| 路径 | 用途 | 缓存 |
| --- | --- | --- |
| `appcast.xml` | 应用内更新 | 60 秒 |
| `latest.json` | 官网读取版本号、大小与说明 | 60 秒 |
| `Caplo.dmg` | 官网"下载"按钮，始终是最新正式版 | 5 分钟 |
| `releases/<版本>/Caplo-<版本>.dmg` | 各版本存档，appcast 指向这里 | 永久 |

## 本地试跑

不公证、不上传，只验证构建与签名链路：

```bash
APPLE_TEAM_ID=XXXXXXXXXX UPDATE_FEED_URL=https://download.caplo.app/appcast.xml SPARKLE_PUBLIC_KEY=… Scripts/release/build.sh v0.2.0
```

```bash
SPARKLE_PRIVATE_KEY="$(cat ~/caplo-sparkle-private-key)" SPARKLE_PUBLIC_KEY=… DOWNLOAD_BASE_URL=https://download.caplo.app Scripts/release/publish.sh v0.2.0 --dry-run
```

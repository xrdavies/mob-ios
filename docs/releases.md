# 发布 Runbook（iOS / iPadOS）

本文是 mob-ios 的发布操作手册：一次性准备 → 每次发布 → 发布后验证 → 回滚与热修复。
标注说明：

- **【现有】**：仓库中已有并核对过的设置（`mob-ios.xcodeproj`、`Info.plist`）。
- **【待建】**：尚未配置。仓库有 `make release`、`make archive`、`ExportOptions.plist` 和隐私清单
  （`PrivacyInfo.xcprivacy`），但**没有**发布工作流、`DEVELOPMENT_TEAM` 或 entitlements 文件；
  也无法从仓库确认 App Store Connect 上是否已有应用记录。

发布目标是 **App Store**。路径（手动）：`make release` → `make archive` 上传 App Store Connect →
TestFlight 内部验证 → 提交 App Store 审核 → 发布。CI 自动化见第六节（提议）。

## 项目现状【现有】

| 项 | 值 | 位置 |
| --- | --- | --- |
| Bundle ID | `com.xrdavies.mob-ios` | `PRODUCT_BUNDLE_IDENTIFIER` |
| 显示名称 | `Mob` | `CFBundleDisplayName` |
| 最低系统 | iOS / iPadOS 17.0 | `IPHONEOS_DEPLOYMENT_TARGET` |
| 设备 | iPhone + iPad | `TARGETED_DEVICE_FAMILY = "1,2"` |
| 签名 | Automatic，**未设置 Team** | `CODE_SIGN_STYLE`，无 `DEVELOPMENT_TEAM` |
| 版本 | `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`，由 `make release` 写入并提交（0.1.0 → 构建号 `1000`） | target build settings |
| Archive 配置 | Release | `mob-ios.xcscheme` |
| 依赖 | `stasel/WebRTC` 155.0.0（SPM 二进制） | `Package.resolved` |
| 后台 | `UIBackgroundModes = fetch`，任务 ID `com.xrdavies.mob-ios.refresh` | `Info.plist`、`App/MobApp.swift` |
| 通知 | 仅本地通知（`UNUserNotificationCenter`），无 APNs 推送，无 entitlements | `State/Notifier.swift` |
| 相机 | `NSCameraUsageDescription`：扫描 `mobd link` 二维码 | `Info.plist` |
| 本地网络 | `NSLocalNetworkUsageDescription` | `Info.plist` |
| ATS | `NSAllowsArbitraryLoads = true`（mobd 可在局域网用 HTTP） | `Info.plist` |
| 方向 | iPhone：竖屏、左横屏、右横屏；iPad：四个方向 | `UISupportedInterfaceOrientations`、`~ipad` |
| 隐私清单 | UserDefaults（`CA92.1`），无跟踪、不收集数据 | `PrivacyInfo.xcprivacy` |
| 出口合规 | `ITSAppUsesNonExemptEncryption = NO` | `Info.plist` |

官网（`../mob-site`，https://mob.0xd.app ）：仓库变量 `IOS_APP_URL`（只接受 `apps.apple.com` 或
`testflight.apple.com`）设置后，下载页 iPhone 卡片显示 “Get it on the App Store”（TestFlight 链接显示
“Join on TestFlight”）；未设置时显示 “Coming to the App Store”。设置后重新运行官网的 Pages 工作流。

## 一、一次性准备【待建】

### 1. Apple Developer 账号与 Team

1. 加入 Apple Developer Program（个人或组织；组织需 D-U-N-S）。记下 10 位 Team ID
   `<TEAM_ID>`（developer.apple.com → Membership）。
2. 决定 Team ID 的放置方式：
   - 写入工程（`DEVELOPMENT_TEAM = <TEAM_ID>`，Xcode → target → Signing & Capabilities 选择 Team 后提交）。
     开源仓库公开 Team ID 没有安全风险，但 fork 的贡献者需改成自己的 Team。
   - 或不提交，Archive 时在命令行传入（`make archive TEAM=<TEAM_ID>`，第三节采用此方式）。
3. 在 Xcode → Settings → Accounts 登录该账号。

### 2. Bundle ID、证书、描述文件

工程使用 Automatic 签名，Xcode 会按需创建：

- App ID `com.xrdavies.mob-ios`（Certificates, Identifiers & Profiles → Identifiers）。
  不需要额外能力：无推送、无 App Groups。后台 fetch 不需要 App ID 能力。
  若此 Bundle ID 已被其他账号注册，需要改 ID（改工程设置，且 `BGTaskSchedulerPermittedIdentifiers`
  与 `MobApp.swift` 中的刷新任务 ID 可保持不变）。
- **Apple Distribution** 证书：首次 Archive 时由 Xcode 创建。导出含私钥的 `.p12`
  （钥匙串 → 导出）离线备份；CI 也需要它（或改用 API key 云签名）。
- App Store 描述文件：Automatic 签名自动生成，无需手动管理。

### 3. App Store Connect 应用记录

App Store Connect → 我的 App → 新建 App：

| 字段 | 值 |
| --- | --- |
| 平台 | iOS |
| 名称 | `Mob`（可能已被占用；备选如 `Mob – Remote Coding Agents`） |
| 主要语言 | English (U.S.)（应用界面和官网都是英文） |
| Bundle ID | `com.xrdavies.mob-ios` |
| SKU | 自定，如 `mob-ios` |

之后补齐：

- **App 信息**：类别「效率」或「开发者工具」；内容版权；年龄分级问卷。
- **App 隐私**：隐私政策 URL `https://mob.0xd.app/privacy/`（必填）；隐私标签见第二节。
- **价格与销售范围**：免费；销售地区。中国大陆上架需要 ICP 备案号（视地区决定）。
- **TestFlight**：内部测试组（App Store Connect 用户，最多 100 人，无需审核）；
  需要外部测试时建外部组（首个构建需 Beta 审核，可生成公开链接 `testflight.apple.com/join/…`）。

### 4. 上架前的工程问题（已处理）

以下各项已在工程中完成，记录原因供以后参考：

1. **隐私清单**：代码使用 `UserDefaults`，属于 Apple「需声明理由的 API」，缺少时上传会收到
   ITMS-91053。`mob-ios/PrivacyInfo.xcprivacy` 声明 `NSPrivacyAccessedAPICategoryUserDefaults`（`CA92.1`），
   `NSPrivacyTracking = false`，不收集数据。上传后若提示 `WebRTC.xcframework` 缺少隐私清单，再处理。
2. **麦克风说明**：WebRTC 二进制引用了音频采集 API（ITMS-90683）。已设 `NSMicrophoneUsageDescription`，
   如实说明应用不录音。
3. **出口合规**：只使用 HTTPS（系统）和 WebRTC 的 DTLS-SRTP，属于豁免加密；`Info.plist` 已设
   `ITSAppUsesNonExemptEncryption = NO`，App Store Connect 不再逐个构建询问（见第二节）。
4. **iPad 多任务方向**：已为 iPad 声明四个方向（`UISupportedInterfaceOrientations~ipad`），避免 ITMS-90474。
5. **版本号**：由 `make release` 写入工程并提交，Xcode GUI 和 `make archive` 使用同一版本。

## 二、商店审核与合规要点

### App 隐私标签

依据代码现状：无分析、崩溃统计、广告 SDK，无跟踪；网络请求只发往用户自己配置的 mobd 地址。
Apple 的「收集」指开发者或第三方获取数据；数据只到用户自己运营的服务器时，可申报为
**不收集数据**（Data Not Collected）。由所有者最终确认。

### 权限说明文字

| 键 | 当前文字 | 状态 |
| --- | --- | --- |
| `NSCameraUsageDescription` | Scan the pairing QR code shown by mobd link. | 【现有】 |
| `NSLocalNetworkUsageDescription` | mob connects to mobd on your office Mac over your local network. | 【现有】；待改为 “Mob connects …” |
| `NSMicrophoneUsageDescription` | Mob does not record audio; the live desktop's WebRTC library declares microphone access. | 【现有】 |
| 照片 | 无需；`PhotosPicker` 不要求权限 | — |

说明文字为英文，与商店主要语言一致；以后支持中文时增加 `InfoPlist.strings` 本地化。

### 出口合规（加密）

上传后 App Store Connect 询问是否使用加密。应用使用标准协议（HTTPS、WebRTC 的 DTLS-SRTP），
不实现专有加密算法，属于豁免加密，`Info.plist` 已设 `ITSAppUsesNonExemptEncryption = NO`。
是否需要提交其他文件（如法国的加密申报）取决于销售地区，**需所有者确认**。

### 通知与后台

- 仅本地通知，首次启动请求授权；没有 APNs，不需要 Push Notifications 能力和 `aps-environment`。
- `UIBackgroundModes = fetch` 用于定期检查提问和任务状态；审核说明中写明用途。

### App Review 注意事项

- **审核需要看到应用工作**（准则 2.1）。没有配对的电脑应用无法演示。**采用演示视频**：录制完整流程
  （在电脑上 `mobd link` → 手机扫码配对 → 发任务 → 回答问题 → 实时桌面与控制），上传到可公开访问的
  地址，在「App 审核信息 → 备注」中给出链接，并说明 mobd 是用户在自己电脑上运行的服务端
  （https://mob.0xd.app/start/ ）。审核员仍要求实机时，再准备可从公网访问的演示 mobd。
- **ATS 例外**：`NSAllowsArbitraryLoads` 用于连接用户局域网里的 mobd（HTTP），在审核备注中说明。
- 远程控制桌面：在说明中写明只控制用户自己的电脑，需在电脑端用 `mobd link` 配对授权。

### 商店素材

- 截图：iPhone 6.9″（1320×2868）必需；因支持 iPad，iPad 13″（2064×2752）也必需。界面和演示对话用
  英文，不含个人数据；首次上架前需重新拍摄（现有截图为中文演示对话）。
- 图标 1024×1024 已在 `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`（需无透明通道）。
- 副标题、描述、关键词（英文）；支持 URL `https://mob.0xd.app/start/`（联系邮箱 mob@taoist.dev）；营销 URL `https://mob.0xd.app/`。

## 三、每次发布（手动）

### 1. 版本号规则

- `MARKETING_VERSION`（CFBundleShortVersionString）：`X.Y.Z`，与 git 标签 `vX.Y.Z` 一致。
- `CURRENT_PROJECT_VERSION`（CFBundleVersion）：与 Android 相同的公式
  `MAJOR × 1000000 + MINOR × 1000 + PATCH`（0.1.0 → `1000`）。同一版本需要重新上传时，用
  `make archive … BUILD=1000.1`（`1000.2`…）在命令行覆盖。
- 两者都由 `make release` 写入工程文件并提交，不再手改。

### 2. 发布前

1. 要发布的改动已推送到 `main`，工作区干净。
2. 测试通过：

   ```bash
   make test            # 单元测试
   make release-test    # 发布脚本测试
   ```

   `LiveStreamTests` 需要 `MOBD_URL`、`MOBD_TOKEN`，UI 测试需要模拟器里已配对的机器；发布前在真机
   手动走一遍配对、发任务、通知、实时桌面。
3. 写好面向用户的「此版本的新增内容」（英文，无私有 PR 链接）。

### iPhone Duo 验收

支持状态和逐项结果见 [Duo 适配任务](iphone-duo.md)。发布前仍需确认：

- [ ] Duo 内外屏横竖屏、连续折叠、半折叠、分屏、键盘、草稿和附件状态保留。
- [ ] 修复并复验已记录的历史滚动位置丢失及无障碍审计失败。
- [ ] WebRTC / WebSocket 的实际桌面控制、尺寸变化、前后台恢复与输入释放。
- [ ] Duo 真机的触摸坐标、缩放/拖动、长时间视频和 VoiceOver；普通 iPhone/iPad 及 iOS 17 回归。
- [x] 独立测试会话完成真实消息发送、SSE 回复接收及用量显示（2026-10-28，单轮 `pong`；边界见适配任务）。
- [ ] 准备不含个人数据的内外屏商店截图。

### 3. 提交版本并打标签

```bash
make release VERSION=v0.1.0
```

`.github/release/tag.mjs` 先检查：在 `main` 上、工作区干净、与 `origin/main` 一致、版本高于已有
标签。然后把 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 写进 `project.pbxproj`，提交
`chore(release): v0.1.0`，在该提交上打附注标签，并用 `git push --atomic` 同时推送 `main` 和标签。
推送被拒时两者都不会到达 GitHub，本地提交和标签保留，按提示重试；若远端 `main` 已有新提交，
`git tag -d vX.Y.Z && git reset --hard origin/main` 后重新运行 `make release`。

### 4. Archive 并上传

在刚打标签的提交上（工作区干净；`build/` 已在 `.gitignore`）：

```bash
make archive TEAM=<TEAM_ID>
```

`HEAD` 不是发布标签时会拒绝运行。它用工程中的版本号执行 `xcodebuild archive`，再用仓库中的
`ExportOptions.plist`（`app-store-connect`、`upload`、自动签名）导出并上传到 App Store Connect。

或在 Xcode：选择 **Any iOS Device** → Product → Archive → Organizer → Distribute App →
App Store Connect → Upload（同样使用工程中的版本号）。

上传后 App Store Connect 处理约 5–30 分钟，期间可能发来 ITMS 警告邮件（隐私清单、权限说明等），
逐条处理。保留 `build/mob-ios.xcarchive`（含 dSYM）直到下一版本，用于符号化崩溃日志。

### 5. TestFlight

1. 构建处理完成后，回答出口合规（若 `Info.plist` 已设 `ITSAppUsesNonExemptEncryption` 则跳过）。
2. 填写「测试内容」，加入内部测试组；测试人员在 TestFlight 应用中安装。
3. 需要外部测试：加入外部组，提交 Beta 审核（通常 1 天内）。
4. 在 iPhone 和 iPad 真机上验证：首次安装的相机、本地网络、通知授权弹窗；配对；发任务；后台刷新通知；
   实时桌面（WebRTC 与 WebSocket 回退）；横竖屏。

### 6. 提交 App Store 审核

1. App Store Connect → 应用 → 新版本 `X.Y.Z`，选择已通过 TestFlight 验证的构建。
2. 填「此版本的新增内容」、截图（界面变化时更新）、审核备注（演示 mobd 与配对方式）。
3. 发布方式：建议「手动发布此版本」，审核通过后自己点击发布；并开启 **分阶段发布**（7 天内
   1% → 2% → 5% → 10% → 20% → 50% → 100%，仅作用于自动更新，可暂停最多 30 天）。
4. 提交审核，通常 1–2 天。被拒时在「解决方案中心」回复或修复后重新提交。

### 7. 发布后验证

- [ ] App Store 页面可见、版本号正确，在未安装 TestFlight 的设备上能搜索并安装。
- [ ] 从上一 App Store 版本更新后，机器列表和配对凭据（Keychain）保留。
- [ ] 首次上架：在 `mob-site` 的仓库变量设置 `IOS_APP_URL=https://apps.apple.com/app/id<APP_ID>`
  并重建官网。
- [ ] Xcode Organizer → Crashes / App Store Connect → TestFlight 与「指标」观察崩溃。

## 四、回滚与热修复

- App Store **不能回退**到旧版本。发现严重问题：
  1. 分阶段发布中：App Store Connect 暂停分阶段发布，阻止继续自动更新（手动更新仍可获取）。
  2. 修复后递增 PATCH 和构建号，按第三节重新上传、TestFlight 验证、提交审核；
     严重问题可申请 **加急审核**（App Store Connect → 联系我们 → 请求加急审核）。
  3. 必要时「从销售中移除」暂时下架（已安装用户不受影响）。
- 审核前发现问题：直接上传新构建（构建号加一），在版本页替换构建。
- 已上传的构建不能删除或覆盖；构建号不能复用。

## 五、发布清单（每次）

- [ ] `main` 已推送，单元测试通过，真机手测通过。
- [ ] `make release VERSION=vX.Y.Z`：版本提交和标签已推送。
- [ ] `make archive TEAM=…` 上传成功；处理 ITMS 警告邮件。
- [ ] TestFlight 内部测试通过（iPhone + iPad）。
- [ ] 新版本页：构建、更新说明、截图、审核备注。
- [ ] 提交审核，选手动发布 + 分阶段发布。
- [ ] 审核通过后发布，完成第三节第 7 步的验证。

首次上架额外：

- [ ] Team ID、App ID、Distribution 证书（已备份 `.p12`）。
- [ ] App Store Connect 记录、隐私政策 URL、隐私标签、年龄分级、价格与地区。
- [ ] 第一节第 4 项的工程问题已处理（隐私清单、出口合规键、麦克风说明、iPad 方向）。
- [ ] 审核用演示视频已上传，链接写入审核备注。
- [ ] 英文商店截图（iPhone 6.9″、iPad 13″）和描述已上传。
- [ ] 官网 `IOS_APP_URL` 已更新。

## 六、CI 自动化（提议，未实现）

参考 mob-android：推送 `vX.Y.Z` 标签 → GitHub Actions（macOS runner）构建并上传 TestFlight，
审核提交和发布仍手动。

1. `make release` 已有；CI 只需在标签推送时运行 `make archive`。
2. App Store Connect → 用户和访问 → 集成 → App Store Connect API 创建密钥（App Manager 角色），
   下载 `.p8`（只能下载一次，离线备份）。
3. `release` 环境配置（名称待定）：

   | 类型 | 名称 | 内容 |
   | --- | --- | --- |
   | Secret | `ASC_KEY_P8_BASE64` | `.p8` 的 Base64 |
   | Variable | `ASC_KEY_ID` / `ASC_ISSUER_ID` | API 密钥 ID 与 Issuer ID |
   | Variable | `APPLE_TEAM_ID` | `<TEAM_ID>` |

4. 工作流按第三节的命令执行，追加
   `-authenticationKeyPath … -authenticationKeyID … -authenticationKeyIssuerID …`
   让 Xcode 云签名（无需导入 `.p12`）；版本和构建号直接来自 `make release` 提交的工程文件。
5. 上传后创建 GitHub Release 记录（不附 IPA）。

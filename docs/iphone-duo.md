# iPhone Duo 适配任务

记录日期：2026-10-27。状态：进行中，已修复串流尺寸同步与缩放后的按钮点击问题；交互、折叠、附件和分屏已有模拟器结果，历史位置及无障碍仍有已知失败。

目标：复用现有 iPhone/iPad 自适应界面，让聊天和远程桌面在内外屏切换、旋转、分屏和折叠时可用，保留 iOS 17 支持。

## 当前基础与缺口

- 工程已支持 iPhone + iPad；[ChatView](../mob-ios/UI/ChatView.swift) 使用 size class 切换导航，并按容器宽度排列聊天和桌面。
- [AppState.connectDesktop](../mob-ios/State/AppState.swift) 已改用实际画面容器和 `displayScale`；全屏尺寸优先，关闭后恢复缩略图尺寸。
- [StreamSession.resize](../mob-ios/Stream/StreamSession.swift) 已接到生产 UI；容器变化及视频/控制通道就绪时同步，受服务端 `streamResize` 能力保护。
- mobd 已提供 `streamResize` 能力；优先复用现有协议。
- [AppFlowTests](../mob-iosUITests/AppFlowTests.swift) 已改按实际聊天区域检查缩略图布局；新增配对和旋转检查，仍需补齐完整折叠场景。

## 1. 构建环境

- [x] 使用 Xcode 27.1 或更新版本、iOS 27.1 或更新 SDK，完成 Debug/Release 构建并检查 WebRTC 二进制依赖兼容性。
- [x] 保留 iOS 17 deployment target；若使用新 API，添加可用性判断和旧系统回退。

## 2. 远程桌面尺寸（优先修复）

涉及：`State/AppState.swift`、`UI/Desktop.swift`、`Stream/StreamSession.swift`；复用 `StreamProtocol.swift` 中的 `devicePixels`。下列已勾选项表示代码与小范围回归已完成，完整设备场景结果另见验收矩阵。

- [x] 初次连接和重连使用实际画面容器尺寸及 `displayScale`，替换 `UIScreen.main`。
- [x] 在容器尺寸或缩放比例变化、连接就绪时同步最新尺寸；支持内外屏切换、旋转、分屏和键盘开合。
- [x] 检查服务端 `streamResize` 能力后调用已有 `resize`，避免因纯尺寸变化反复重连；旧 mobd 保持可用。
- [x] 缩略图与全屏视图同时存在时，避免互相覆盖串流目标尺寸。
- [ ] 尺寸变化后验证画面清晰度、黑边、缩放和平移边界、点击坐标及拖动结束时的按键释放。模拟器坐标/黑边/手势已通过，真机清晰度和极端边界仍待确认。

## 3. 导航、输入与折叠布局

涉及：`UI/ChatView.swift`、`UI/Desktop.swift`、`UI/Composer.swift`、`App/MobApp.swift`。

- [ ] 复核 720 pt 桌面侧栏阈值及各列可用空间，继续按容器尺寸和 size class 布局。
- [ ] 内外屏切换时保留当前机器、会话、草稿、附件及滚动位置，检查键盘焦点和全屏桌面状态。
- [ ] 检查系统导航栏、工具栏、Tab 和弹层的竖向排列及不对称 safe area，确保输入框、关闭按钮和控制条可见可点。
- [ ] 检查半折叠时自定义控件是否跨越折痕；仅在实际需要时使用 `ReservedRegion` 等 API，并保留旧系统布局。

## 4. 回归与验收

涉及：`mob-iosUITests/AppFlowTests.swift`、`mob-iosTests/StreamTests.swift`、`mob-iosTests/LiveStreamTests.swift`。

- [x] UI 测试改按实际布局断言，移除 `.phone` 必然窄屏、`.pad` 才有侧栏的假设。
- [x] 为 UI 到串流的尺寸同步补小范围回归测试；现有直播测试仅直接调用 `resize`，不能证明 UI 已接线。
- [ ] 在 Device Hub 验证：外屏横竖屏、内屏横竖屏、连续展开/合上、半折叠、左右分屏及键盘开合。
- [ ] 使用专用测试 mobd，分别验证 WebRTC 和 WebSocket 路径：尺寸更新、持续出帧、点击/拖动/滚动/缩放、连接切换及后台释放输入。
- [ ] 回归普通 iPhone、iPad 和 iOS 17；在 Duo 真机确认手势、折叠、视频稳定性和 VoiceOver。

验收通过须记录设备、系统、Xcode/SDK 版本和结果。代码静态检查或模拟器截图不能代替真机结论。

### 2026-10-28 首轮模拟器测试

- 基线：`dev`，应用代码 `ea5a176`；Xcode 27.1（27A9275）、iOS Simulator 27.1（24A94425）、iPhone Duo，Apple Silicon。
- Debug 测试包和 Release 模拟器构建通过，WebRTC 155.0.0 链接通过；仍保留 iOS 17 deployment target。
- 使用模拟器签名运行现有单元测试：共 65 项，61 项通过，4 项直播测试因未提供 `MOBD_URL` / `MOBD_TOKEN` 跳过，零失败；Keychain 读写测试通过。
- 使用仓库的 `mobd/bin/mobd` 生成内网邀请，`LayoutTests.testPairMachineFromLink` 完成真实配对并通过；设备名为 `iPhone Duo Simulator Test`。应用重启后凭据仍有效，mobd 可见该设备的 `/events` 连接。
- 新增 `LayoutTests.testSettingsAndPairingAcrossRotation`，检查配对弹窗旋转、无效链接和键盘打开后的关闭按钮；外屏和内屏均已执行。
- 旧桌面用例在内屏因“缩略图应超过整屏宽度的 85%”而失败；改为与实际输入区域比较，旋转检查也不再依赖设备 idiom。
- 截图复用一次 `app.screenshot()`；外屏截图正常，但当前工具链在内屏仍可能得到黑图。内屏截图需用 `simctl io … screenshot --display=primary-1` 单独复核，不能仅依赖 XCTest 截图。
- 内外屏的配对弹窗与桌面缩略图/全屏用例均通过，各 2 项；外屏截图确认局域网 WebRTC 桌面视频（1408×792，约 26 fps）。这只证明当前查看路径可用，未验证交互控制、WebSocket 回退或尺寸同步。
- 本轮未发送聊天消息。半折叠、分屏、连续折叠时的草稿和滚动位置、旧系统及真机仍待验证，暂不改变 Duo 支持状态。

本机测试结果：`/tmp/mob-ios-duo-signed-unit.xcresult`、`/tmp/mob-ios-duo-pair-link.xcresult`、`/tmp/mob-ios-duo-outer-ui.xcresult`、`/tmp/mob-ios-duo-inner-ui-final.xcresult`；构建日志：`/tmp/mob-ios-duo-build.log`、`/tmp/mob-ios-duo-release.log`。这些临时文件和配对凭据未提交仓库。

### 2026-10-28 补测记录

应用修复提交：`e4e6b33`、`e10ea29`。后者增加 150 ms 尺寸合并、可见性检查及首次布局前的视图登记，避免瞬时小尺寸和隐藏视图回调干扰串流。环境沿用 Xcode 27.1、Duo iOS 27.1；对照设备为 iPhone 18 Pro 和 iPad Pro 13-inch (M5)，均为 iOS 27.0（24A434）模拟器。

| 项目 | 结果与边界 |
| --- | --- |
| Duo 单元测试 | 63 项通过，包含全屏尺寸优先、旋转、零尺寸、首次布局等待和过期视图移除回归 |
| 普通 iPhone / iPad | 各 63 项单元测试通过；不是这两类设备的完整 UI/真机验收 |
| WebRTC、UDP 阻断后的 WebSocket、记忆的 WebSocket、恢复 WebRTC | 4 项通过，结果包归档完成；持续出帧、指针坐标回报、640×360 resize、WebSocket 解码均有断言 |
| 首帧观测 | 一次复测为 WebRTC 262 ms，阻断 UDP 后 WebSocket 5431 ms；记忆的 WebSocket 1307 ms，恢复 WebRTC 428 ms。单次局域网观测，不代表真实网络性能 |
| 会话列表 / 设置 / 配对布局 / 桌面查看 | 通过；搜索改用无匹配结果，去掉对用户既有聊天内容的依赖 |
| 草稿旋转及前后台 | 通过；打开系统设置，并断言 Mob 确实进入后台，再返回检查草稿、输入框和 Send |
| UI 到串流尺寸同步 / 后台退出 Control | 通过；实际解码画面、全屏 UI 发出 resize、后台恢复到 View 均有断言。上述 UI 场景合并运行共 5 项，零失败，结果包完整 |
| 真实消息发送与流式回复 | 未发送：发送授权超时，工具要求按拒绝处理。新增 `MOBD_SEND_TEST_MESSAGE=1` 显式开关，默认跳过 |
| 点击、右键、文本、方向键、拖动、滚轮及后台释放 | 已补两种传输的可选测试和本地输入窗口；Mac 锁屏且解锁询问超时，尚未完成实际输入验收 |
| 连续折叠、半折叠、真实分屏 | 待解锁后在 Device Hub 执行；新增等待实际窗口尺寸变化的草稿断言。尝试运行时没有发生尺寸切换而超时，不计为通过，也不能据此判定产品失败 |
| 附件、滚动位置、触摸缩放/平移、弱网/真实远程通道 | 未完成专项验收 |
| iOS 17 / Duo 真机 / VoiceOver | 当前没有安装 iOS 17 runtime，也没有连接真机；编译目标 17.0 不等于旧系统或真机验证 |

补测同时修正了两处测试假设：内屏存在多个 New chat 按钮，需明确匹配；按 Home 不保证当前内屏应用进入后台，改为打开系统设置并检查应用状态。Mac 锁屏时不向登录界面发送测试文本。

直播测试可直接复用已配对机器的 Keychain 凭据，不导出 token。真实输入测试要求本机探针持续更新、Mac 已解锁且 mobd 地址属于该电脑；输入只在覆盖桌面的测试窗口中进行。运行方法见 [README](../README.md#setup)。后续解锁后的结果见下一节。

Xcode 首次在用例结束后自动采集模拟器诊断时停滞；采样栈定位到 `simctl diagnose`。重跑添加 `-collect-test-diagnostics never` 后正常生成结果包，不使用先前未归档的结果作为整轮通过依据。运行时仍有 XCTest/WebRTC 的内部 QoS 提示，保留在报告中。

本机证据（未提交）：

- 单元：`/tmp/mob-duo-gap-final-unit.xcresult`、`/tmp/mob-phone-gap-final-unit.xcresult`、`/tmp/mob-ipad-gap-final-unit.xcresult`。
- 直播：`/tmp/mob-duo-gap-live-final.xcresult`；首帧观测另见 `/tmp/mob-duo-gap-live-verified.log`。
- UI：`/tmp/mob-duo-gap-final-ui.xcresult`（5 项）；共享逐屏截图方法另跑 `/tmp/mob-duo-gap-shared-capture-ui.xcresult`（1 项）。逐屏截图已确认内屏可读，修复了只截主屏导致的黑图。
- Release：`/tmp/mob-duo-gap-final-release.log`；仍保留 iOS 17.0 deployment target。


### 2026-10-28 解锁后的交互与折叠补测

沿用已配对的本地 mobd 和 Duo iOS 27.1 模拟器。输入只进入隔离的 AppKit 测试窗口；附件只使用导入模拟器的合成蓝色图片，上传到本地 mobd 后保持未发送。

| 项目 | 结果与边界 |
| --- | --- |
| WebRTC / WebSocket 真实输入 | 两项通过：点击、右键、文本、方向键、拖动、滚轮、后台释放和 View 模式输入抑制；探针记录 24 个原生事件。探针增加心跳重绘，避免静态桌面停止编码导致测试误判 |
| 连续折叠与半折叠 | 四次实际尺寸切换通过：内屏 951×669、外屏 466×678，最后停在半折叠。草稿、输入框及 Send 保留可用；半折叠另跑五项 UI 用例全部通过 |
| 附件旋转、后台与折叠 | 专项用例通过；附件及草稿在旋转、打开系统设置再返回、两次内外屏切换后保留。该轮同时运行的无障碍审计失败，不能将整个结果包记为通过 |
| 左右分屏 | 草稿和合成附件在左右两侧均保留，输入框和 Send 可点；窗口实际缩至 469×669。不是仅模拟横竖屏变化 |
| 全屏触摸、缩放与平移 | 发现并修复缩放后视频层越界拦截 View/Control 按钮的问题：视频层关闭命中测试，沿用既有手势层。UI 回归通过，覆盖缩放、平移、双击复位、黑边拒绝输入、旋转后坐标、长按右键、拖动结束和键盘文本，探针收到 43 个原生事件 |
| 聊天历史滚动位置 | 未通过：从内屏切到外屏后，原先可见的历史文字消失，出现空白区域。只读现有会话的用例可稳定复现；未合入未经验证的滚动恢复方案 |
| 无障碍审计 | 未通过：工具栏部分文字裁切或 Dynamic Type 适配不足；设置页选中图标、编辑按钮及地址行有过小的点击区域。新增显式审计用例保留失败，不过滤报告；仍需修复并用 VoiceOver 验收 |
| 真实消息及流式回复 | 仍未发送：本轮发送确认超时，工具要求按拒绝处理 |
| 弱网、真实远程通道、iOS 17、Duo 真机 | 未完成；没有对应 runtime/硬件，局域网模拟器结果不能代替这些验收 |

本机证据（临时文件未提交）：

- 最终单元与真实传输：`/tmp/mob-duo-gap-input-stats.xcresult`（69 项全部通过：63 项单元、4 项连接/回退、2 项真实输入）。早期两种传输输入：`/tmp/mob-duo-gap-control-heartbeat.xcresult`（2 项通过）。
- 四次折叠：`/tmp/mob-duo-gap-fold-settled.xcresult`；半折叠 UI：`/tmp/mob-duo-gap-half-ui.xcresult`（5 项通过）。
- 附件最终专项：`/tmp/mob-duo-gap-photo-verified.xcresult`（折叠、左右分屏并恢复全屏、旋转及前后台共 3 项全部通过）。早期附件记录：`/tmp/mob-duo-gap-photo-ready.xcresult` 中的 `testDraftSurvivesRotationAndBackground`、`/tmp/mob-duo-gap-photo-fold.xcresult` 中的 `testDraftAcrossDisplayChanges` 通过；这两个结果包均同时含审计失败。
- 末轮触摸 UI：`/tmp/mob-duo-gap-input-active.xcresult` 的 `testLiveTouchCoordinatesAndZoom` 通过；同包 WebRTC 持续帧检查失败，不能记为整包通过。定位为 30 帧采样计数与低帧率冲突后，测试改用已有解码统计补充判断。
- 左右分屏：`/tmp/mob-duo-gap-split-draft.xcresult`；分屏并拖动分隔线恢复全屏：`/tmp/mob-duo-gap-split-divider.xcresult`；全屏触摸：`/tmp/mob-duo-gap-ui-touch-hit-test.xcresult`。
- 历史位置失败：`/tmp/mob-duo-gap-history-selector.xcresult`。
- 审计失败：`/tmp/mob-duo-gap-audit-details.xcresult`，可用 README 中的显式开关重现。
- 最终 Release 构建：`/tmp/mob-duo-gap-interaction-release.log`（通过，保留 iOS 17 deployment target）。


## 5. 发布材料

- [x] 更新 README 的已测工具链、Duo 验收边界和实际 `resize` 行为说明。
- [x] 在 [发布清单](releases.md) 中补 Duo 验收项。
- [ ] 准备验收通过后的内外屏商店截图及 App Store Connect 素材。

## 官方参考

- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)：旧应用兼容、新 SDK 全屏体验、size class 与屏幕尺寸处理。
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)：折痕、保留区域与自定义布局。
- [Prepare and submit your apps for iPhone Duo](https://developer.apple.com/news/?id=kkphp5qo)：开发工具和商店素材要求。

# iPhone Duo 适配任务

记录日期：2026-10-27。状态：待实施，尚未通过 Duo 模拟器或真机验收。

目标：复用现有 iPhone/iPad 自适应界面，让聊天和远程桌面在内外屏切换、旋转、分屏和折叠时可用，保留 iOS 17 支持。

## 当前基础与缺口

- 工程已支持 iPhone + iPad；[ChatView](../mob-ios/UI/ChatView.swift) 使用 size class 切换导航，并按容器宽度排列聊天和桌面。
- [AppState.connectDesktop](../mob-ios/State/AppState.swift) 仍从 `UIScreen.main` 获取串流初始尺寸，不适合内外屏和分屏场景。
- [StreamSession.resize](../mob-ios/Stream/StreamSession.swift) 已实现，生产 UI 尚未调用；README 中“尺寸变化自动发送 resize”的描述与实现不符。
- mobd 已提供 `streamResize` 能力；优先复用现有协议。
- [AppFlowTests](../mob-iosUITests/AppFlowTests.swift) 将 `.phone` 与窄屏布局关联，无法覆盖 Duo 内屏。

## 1. 构建环境

- [ ] 使用 Xcode 27.1 或更新版本、iOS 27.1 或更新 SDK，完成 Debug/Release 构建并检查 WebRTC 二进制依赖兼容性。
- [ ] 保留 iOS 17 deployment target；若使用新 API，添加可用性判断和旧系统回退。

## 2. 远程桌面尺寸（优先修复）

涉及：`State/AppState.swift`、`UI/Desktop.swift`、`Stream/StreamSession.swift`；复用 `StreamProtocol.swift` 中的 `devicePixels`。

- [ ] 初次连接和重连使用实际画面容器尺寸及 `displayScale`，替换 `UIScreen.main`。
- [ ] 在容器尺寸或缩放比例变化、连接就绪时同步最新尺寸；支持内外屏切换、旋转、分屏和键盘开合。
- [ ] 检查服务端 `streamResize` 能力后调用已有 `resize`，避免因纯尺寸变化反复重连；旧 mobd 保持可用。
- [ ] 缩略图与全屏视图同时存在时，避免互相覆盖串流目标尺寸。
- [ ] 尺寸变化后验证画面清晰度、黑边、缩放和平移边界、点击坐标及拖动结束时的按键释放。

## 3. 导航、输入与折叠布局

涉及：`UI/ChatView.swift`、`UI/Desktop.swift`、`UI/Composer.swift`、`App/MobApp.swift`。

- [ ] 复核 720 pt 桌面侧栏阈值及各列可用空间，继续按容器尺寸和 size class 布局。
- [ ] 内外屏切换时保留当前机器、会话、草稿、附件及滚动位置，检查键盘焦点和全屏桌面状态。
- [ ] 检查系统导航栏、工具栏、Tab 和弹层的竖向排列及不对称 safe area，确保输入框、关闭按钮和控制条可见可点。
- [ ] 检查半折叠时自定义控件是否跨越折痕；仅在实际需要时使用 `ReservedRegion` 等 API，并保留旧系统布局。

## 4. 回归与验收

涉及：`mob-iosUITests/AppFlowTests.swift`、`mob-iosTests/StreamTests.swift`、`mob-iosTests/LiveStreamTests.swift`。

- [ ] UI 测试改按实际布局断言，移除 `.phone` 必然窄屏、`.pad` 才有侧栏的假设。
- [ ] 为 UI 到串流的尺寸同步补小范围回归测试；现有直播测试仅直接调用 `resize`，不能证明 UI 已接线。
- [ ] 在 Device Hub 验证：外屏横竖屏、内屏横竖屏、连续展开/合上、半折叠、左右分屏及键盘开合。
- [ ] 使用专用测试 mobd，分别验证 WebRTC 和 WebSocket 路径：尺寸更新、持续出帧、点击/拖动/滚动/缩放、连接切换及后台释放输入。
- [ ] 回归普通 iPhone、iPad 和 iOS 17；在 Duo 真机确认手势、折叠、视频稳定性和 VoiceOver。

验收通过须记录设备、系统、Xcode/SDK 版本和结果。代码静态检查或模拟器截图不能代替真机结论。

## 5. 发布材料

- [ ] 验证后更新 README 的工具链要求、Duo 支持状态和 `resize` 行为说明。
- [ ] 在 [发布清单](releases.md) 中补 Duo 验收项，并准备内外屏截图及 App Store Connect 素材。

## 官方参考

- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)：旧应用兼容、新 SDK 全屏体验、size class 与屏幕尺寸处理。
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)：折痕、保留区域与自定义布局。
- [Prepare and submit your apps for iPhone Duo](https://developer.apple.com/news/?id=kkphp5qo)：开发工具和商店素材要求。

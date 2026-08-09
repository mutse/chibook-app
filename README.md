# chibook

chibook 是一款本地优先的 Flutter 阅读与听书 App，视觉与交互依据 `docs/erdu-mockup.html` 实现。项目不含书城、社交、账号或云同步，书籍与阅读设置仅保存在设备本地。

## 已实现

- 启动页与游客模式
- 阅读首页：继续阅读、真实本机统计、最近收听控制、最近阅读和上次划线
- 本地书架、网格/列表视图、置顶、删除、阅读进度
- 从系统文件选择器导入 TXT、EPUB、PDF
- TXT 自动按“第…章/回”切分；EPUB 按 OPF spine 顺序解析 XHTML
- TXT/EPUB 可重排阅读器：章节翻页、目录、字号、行距、日间/夜间/护眼主题、文本选择与划线入口、朗读文字自动高亮和跟随滚动
- 独立 PDF 固定版式阅读器：缩放、翻页、听书时自动跟随对应页面和明确的能力降级提示
- 沉浸式 TTS 播放器：播放/暂停、章节切换、0.5–2.0 倍速、定时关闭、听读位置同步
- 全局迷你播放器、章节队列、顺序/倒序/单章循环、字符级断点续听
- `audio_service` 后台音频：Android 前台媒体服务、通知/锁屏控制，iOS 后台音频模式
- 书名/作者搜索、最近搜索、真实听书历史与时长统计、全局主题同步
- TTS 引擎配置页、发音人试听、默认语速和配置持久化
- SharedPreferences JSON 本地持久化；文本标注位置模型同时支持字符偏移与 PDF 页码/归一化坐标

## 关键技术取舍

### EPUB

项目没有用 WebView。EPUB 本质上是 ZIP 容器，本项目解析 `META-INF/container.xml`、OPF manifest 与 spine，再将 XHTML 转成纯文本章节交给 Flutter Widget 重排。这样主题、字号、行距、选择菜单和 TTS 使用同一份文本位置模型，交互更可控；代价是复杂 CSS、浮动布局、脚注和内嵌多媒体不会像浏览器一样完整还原。

### PDF

PDF 使用开源 `pdfrx`/PDFium，与 TXT/EPUB 阅读器完全分离。PDF 是固定排版格式，只提供整体缩放和翻页，不伪装支持字号或行距重排。数据模型预留“页码 + 归一化矩形”标注定位。导入时优先逐页提取文本；无文本页在 Android/iOS 上使用端侧 Google ML Kit 中文模型 OCR。分栏、页眉页脚、图像清晰度和字符映射仍可能影响朗读顺序与识别质量。

### TTS 同步

系统语音逐词高亮使用 `flutter_tts` 的 progress callback。OpenAI 云端语音使用分段 MP3 的播放位置映射字符范围，并通过 `just_audio` 播放本地缓存。两种模式都由 `audio_service` 统一管理；播放器、迷你播放器与系统媒体控件共享同一状态。云端语音为 AI 合成音频，并非真人录音。

## 运行

```bash
flutter pub get
flutter run
```

验证：

```bash
flutter analyze
dart test test/models_test.dart
flutter build apk --debug
flutter build ios --debug --no-codesign
```

首次在 macOS/Android 构建 PDF 功能时，`pdfrx` 会从官方 GitHub Release 下载对应平台的 PDFium 二进制，网络较慢时需要等待。

## GitHub CI/CD

`.github/workflows/mobile.yml` 会在提交到 `main`/`master`、Pull Request、`v*` 标签及手动触发时运行：

- 执行 `flutter analyze` 与全部测试。
- 构建 Android release APK，并作为 Actions Artifact 保存 30 天。
- 构建 iOS release App，并打包成未签名 IPA Artifact 保存 30 天。未签名 IPA 仅供后续签名或越狱/测试环境使用，不能直接安装到普通 iPhone 或提交 App Store。
- 推送 `v*` 标签（例如 `v1.0.0`）时，自动创建 GitHub Release 并附加 APK 与 IPA。

Android 未配置签名 Secret 时会沿用项目的 debug 签名，便于 CI 验证。要生成可正式分发的 APK，请在 GitHub 仓库的 Actions Secrets 中配置：

- `ANDROID_KEYSTORE_BASE64`：JKS/keystore 文件的 Base64 内容。
- `ANDROID_KEYSTORE_PASSWORD`：keystore 密码。
- `ANDROID_KEY_ALIAS`：密钥别名。
- `ANDROID_KEY_PASSWORD`：密钥密码。

macOS/Linux 可用以下命令生成第一项的值：

```bash
base64 < upload-keystore.jks | tr -d '\n'
```

## 原生配置

- Android：`WAKE_LOCK`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`POST_NOTIFICATIONS`；注册 `AudioService` 与 `MediaButtonReceiver`；查询系统 TTS Service。
- iOS：Deployment Target 13.0；`UIBackgroundModes = audio`；TTS 使用 `playback` category 与 `spokenAudio` mode。

## 目录

```text
lib/
  app/          路由、全局 Riverpod 状态、启动页
  core/         数据模型、主题与设计色
  data/         本地持久化、文件导入、TXT/EPUB 解析
  features/     书架、阅读器、听书、搜索、个人中心
  services/     后台 TTS 音频处理器
```

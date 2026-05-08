# Steam Link iOS — Background Audio & AirPods Pro Spatial Audio Patch

Patch the iOS **Steam Link** app (v1.3.25) so:

- **Audio keeps playing** when the device is locked or the app is sent to the background.
- **AirPods Pro personalized Spatial Audio** activates correctly while streaming.
- **AirPods plug / unplug** and **in-ear / out-of-ear** transitions do **not** kill audio.

> *Chinese version below — 中文说明见下方。*

---

## How it works

The patch has four layers:

1. **Binary patch `Frameworks/SDL3.framework/SDL3`** — overwrite the first
   instruction of four SDL functions with ARM64 `RET` so SDL never pauses its
   audio pipeline on lifecycle events:
   - `SDL_OnApplicationWillEnterBackground`
   - `SDL_OnApplicationDidEnterBackground`
   - `SDL_PauseAudioDevice`
   - `SDL_AudioDevicePaused`
2. **Inject `LC_LOAD_DYLIB`** into the main `Steam Link` Mach-O so
   `BackgroundAudio.dylib` is loaded on launch.
3. **Edit `Info.plist`** — add `UIBackgroundModes = [audio]` and remove
   `UIRequiredDeviceCapabilities` (the arm64 whitelist rejects sideloader
   profiles with mismatched UDID signing).
4. **Inject `BackgroundAudio.dylib`** that runs at constructor time and:
   - Swizzles every `-[AVAudioSession setCategory:…]` overload to force the
     `Playback` category and strip `MixWithOthers` / `DuckOthers`
     (both are incompatible with AirPods Pro Spatial Audio).
   - Lies about `UIApplication.applicationState`, `UIScene.activationState`
     and `CADisplayLink.isPaused` so SteamLink's Qt + Steam streaming
     pipeline never notices it was backgrounded.
   - Drops the app-backgrounding notifications via `NSNotificationCenter`
     post-swizzles and no-ops the scene-delegate lifecycle methods.
   - Plays a silent 1-second WAV on an `AVAudioPlayer` infinite loop and
     seeds `MPNowPlayingInfoCenter`, which keeps iOS treating the app as an
     active media session.
   - On `AVAudioSessionRouteChangeNotification` reason=2
     (`OldDeviceUnavailable`, e.g. AirPods taken out of ear) or reason=8
     (`Override`), **synthesises `UIApplicationWillEnterForegroundNotification`
     + `UIApplicationDidBecomeActiveNotification`** — that is the only signal
     that makes iOS rebind the output from the disappeared AirPods route to
     the built-in speaker while the app is still in background.

## Project layout

```
.
├── .github/workflows/build-dylib.yml   CI: macOS runner builds BackgroundAudio.dylib
├── dylib/
│   ├── BackgroundAudio.m               the injected dylib source
│   └── build.sh                        Xcode command-line build helper
├── tools/
│   ├── macho.py                        minimal fat/thin Mach-O parser
│   ├── patch_sdl_ret.py                NOP-out SDL3 symbols
│   ├── inject_dylib.py                 append LC_LOAD_DYLIB
│   └── macho_inspect.py                diagnostic dump
├── apply_patch.py                      orchestrator: IPA in, patched IPA out
├── make_ipa.ps1                        Windows re-packaging helper (uses 7z)
└── dist/BackgroundAudio.dylib          prebuilt dylib (arm64, iOS 11+)
```

## Build `BackgroundAudio.dylib`

The dylib needs macOS with Xcode command-line tools. The repo also ships a
GitHub Actions workflow that builds it automatically on every push.

```bash
cd dylib
chmod +x build.sh
./build.sh                # produces BackgroundAudio.dylib
codesign --force --sign - --timestamp=none BackgroundAudio.dylib
```

A prebuilt dylib is included at `dist/BackgroundAudio.dylib`.

## Patch an IPA

You need a **decrypted** `Steamlink.ipa` (the App Store copy is FairPlay
encrypted; get a decrypted dump from a jailbroken / TrollStore device or use
a community decryption service).

```bash
python apply_patch.py \
    --input  steamlink1.3.25.ipa \
    --output steamlink1.3.25-bgaudio.ipa \
    --dylib  dist/BackgroundAudio.dylib
```

That single command does the SDL3 RET patch, dylib copy, `LC_LOAD_DYLIB`
injection, and `Info.plist` edit, and re-zips a ready-to-sign IPA.

## Sign and install

The patched IPA is **not** signed. Pick one of the paths below.

| Tool | Notes |
|------|-------|
| **Sideloadly** | macOS / Windows / Linux. Drag the IPA in, enter your Apple ID, press **Start**. |
| **AltStore / SideStore** | Same flow, works on-device. |
| **Feather / ESign** | iOS-native sideload apps with enterprise / Apple ID signing. |
| **TrollStore** | Needs no signing. Just install the IPA directly. |
| **`codesign` + your dev profile** | macOS only. Sign the dylib, SDL3 framework and main binary, then repackage. |
| **`ldid -S` (any OS)** | Ad-hoc sign each binary if your sideloader doesn't touch injected frameworks. |

> ⚠️ **Do NOT install via LiveContainer.** `UIBackgroundModes` is ignored
> inside a container app — background audio will not work.

## Runtime configuration (optional)

Three environment variables, settable via TrollStore's "Run as" panel or an
`LC_ENVIRONMENT` load command, let you change the dylib's behaviour:

| Variable | Meaning |
|----------|---------|
| `BGAUDIO_MIX_WITH_OTHERS=1` | Keep `AVAudioSessionCategoryOptionMixWithOthers` (lets Apple Music / podcasts keep playing alongside Steam Link, but **disables AirPods Pro Spatial Audio**). |
| `BGAUDIO_ROUTE_POLICY=longformvideo\|longformaudio\|default\|<int>` | Override `routeSharingPolicy`. Auto-detected by iOS version otherwise. |
| `BGAUDIO_MOVIE_MODE=1` | Use `AVAudioSessionModeMoviePlayback` instead of `Default`. |

By default nothing needs to be set.

## Troubleshooting

- **`dyld: library not loaded: …BackgroundAudio.dylib`** — the dylib is
  missing from `Frameworks/` or wasn't re-signed together with the app. Use
  `ldid -S` on every binary or re-sign via Sideloadly.
- **Audio still stops on lock** — verify the installed `Info.plist` really
  contains `UIBackgroundModes = [audio]`. Some sideloaders rewrite the plist.
- **No Spatial Audio option on AirPods Pro** — confirm iOS Settings →
  Bluetooth → AirPods Pro → **Spatial Audio** is set to **Automatic** or
  **Fixed**, and that `BGAUDIO_MIX_WITH_OTHERS` is **not** set.
- **Diagnostic log** — the dylib writes `Documents/bgaudio.log` on the
  device. Grab it via the Files app or Finder iTunes File Sharing when
  filing an issue.
- **Roll back** — `Steam Link.bak` and `SDL3.bak` are written next to the
  patched binaries inside the bundle. Restore either to undo that layer.

## License

For educational and personal use only. Steam Link is © Valve Corporation.
SDL3 is © Sam Lantinga / libsdl.org.

---

# Steam Link iOS 后台音频 + AirPods Pro 空间音频补丁

给 iOS 版 **Steam Link**（1.3.25）打补丁，实现：

- 锁屏或切到后台时**声音不断**。
- AirPods Pro **个性化空间音频**能激活（普通 iOS 串流常见的问题）。
- AirPods **插拔** / **戴上摘下**时声音不再中断。

## 工作原理

补丁分四层：

1. **二进制 patch `Frameworks/SDL3.framework/SDL3`**：把 4 个 SDL 函数首条指令改成 ARM64 `RET`，让 SDL 在任何生命周期事件里都没法暂停音频管线：
   - `SDL_OnApplicationWillEnterBackground`
   - `SDL_OnApplicationDidEnterBackground`
   - `SDL_PauseAudioDevice`
   - `SDL_AudioDevicePaused`
2. **向主二进制 `Steam Link` 注入 `LC_LOAD_DYLIB`**，让它启动时加载 `BackgroundAudio.dylib`。
3. **修改 `Info.plist`**：加 `UIBackgroundModes = [audio]`，删掉 `UIRequiredDeviceCapabilities`（那个 arm64 白名单会让旧签名工具拒装）。
4. **`BackgroundAudio.dylib` 在 constructor 阶段**：
   - swizzle 所有 `-[AVAudioSession setCategory:…]` 重载，强制 `Playback` 类别并剥离 `MixWithOthers` / `DuckOthers`（这两个 option 都会让 AirPods Pro 的空间音频激活失败）。
   - 对 `UIApplication.applicationState`、`UIScene.activationState`、`CADisplayLink.isPaused` 全部谎报成"前台激活"，让 SteamLink 里 Qt + Steam 串流流水线根本察觉不到后台。
   - 通过 swizzle `NSNotificationCenter postNotification…` 系列，把切后台相关的通知全部丢掉；把场景代理的相关生命周期方法也替换成空实现。
   - 常驻一个**1 秒静音 WAV** 的 `AVAudioPlayer` 无限循环，并灌注 `MPNowPlayingInfoCenter`，这样 iOS 始终把 App 当作活跃的媒体会话。
   - `AVAudioSessionRouteChangeNotification` 的 reason=2（AirPods 从耳朵里拿出/断开）或 reason=8（Override）时，**伪造 `UIApplicationWillEnterForegroundNotification` + `UIApplicationDidBecomeActiveNotification`** — 这是让 iOS 在 App 仍在后台时真正重新绑定输出设备（从失效的 AirPods 路由切到外放）的唯一可靠信号。

## 目录结构

```
.
├── .github/workflows/build-dylib.yml   CI：macOS runner 自动构建 dylib
├── dylib/
│   ├── BackgroundAudio.m               注入 dylib 的源码
│   └── build.sh                        Xcode 命令行构建脚本
├── tools/
│   ├── macho.py                        轻量 fat/thin Mach-O 解析
│   ├── patch_sdl_ret.py                把 SDL3 几个符号首条指令改为 RET
│   ├── inject_dylib.py                 追加 LC_LOAD_DYLIB
│   └── macho_inspect.py                诊断/查看
├── apply_patch.py                      一键脚本：原版 IPA 进，改好的 IPA 出
├── make_ipa.ps1                        Windows 下重新打包 IPA（依赖 7z）
└── dist/BackgroundAudio.dylib          已构建好的 dylib（arm64, iOS 11+）
```

## 编译 `BackgroundAudio.dylib`

需要 macOS + Xcode 命令行工具。仓库也带了 GitHub Actions 工作流，每次 push 都会自动编译。

```bash
cd dylib
chmod +x build.sh
./build.sh                # 产出 BackgroundAudio.dylib
codesign --force --sign - --timestamp=none BackgroundAudio.dylib
```

`dist/BackgroundAudio.dylib` 里也附带了编译好的 dylib，可以直接用。

## 给 IPA 打补丁

你需要一个**已脱壳**的 `Steamlink.ipa`（App Store 里下的原版是 FairPlay 加密的；可以从越狱 / TrollStore 设备导出一份）。

```bash
python apply_patch.py \
    --input  steamlink1.3.25.ipa \
    --output steamlink1.3.25-bgaudio.ipa \
    --dylib  dist/BackgroundAudio.dylib
```

这一条命令包办 SDL3 RET 补丁、dylib 拷贝、`LC_LOAD_DYLIB` 注入、`Info.plist` 修改、最后重新压成 IPA。

## 签名安装

产出的 IPA **没有签名**。可以选下面任意一种：

| 工具 | 备注 |
|------|------|
| **Sideloadly** | macOS/Windows/Linux 都行，拖进去、输 Apple ID、点 Start。 |
| **AltStore / SideStore** | 同样流程，设备上就能签。 |
| **Feather / ESign**（轻松签 / 爱思/ e-sign） | iOS 原生签名工具，支持 Apple ID / 企业证书。 |
| **TrollStore（巨魔商店）** | **免签直装**。 |
| **`codesign` + 开发者证书** | 仅 macOS。需要对 dylib、SDL3.framework、主二进制都签一遍，然后重新打 IPA。 |
| **`ldid -S`**（任何系统） | 如果签名工具不会自动把注入的 dylib 加到签名资源列表里，先用 `ldid -S` ad-hoc 签一下每个二进制。 |

> ⚠️ **别用 LiveContainer 启动。** 容器里 `UIBackgroundModes` 不会生效，后台音频不会工作。

## 运行时开关（可选）

可以通过 TrollStore 的 "Run as" 面板或给主二进制加 `LC_ENVIRONMENT` 设以下变量：

| 变量 | 含义 |
|------|------|
| `BGAUDIO_MIX_WITH_OTHERS=1` | 保留 `AVAudioSessionCategoryOptionMixWithOthers`（允许 Apple Music / 播客和 Steam Link 一起放，但**会禁掉 AirPods Pro 空间音频**）。 |
| `BGAUDIO_ROUTE_POLICY=longformvideo\|longformaudio\|default\|<int>` | 覆盖 `routeSharingPolicy`。不设的话会按 iOS 版本自动选。 |
| `BGAUDIO_MOVIE_MODE=1` | 用 `AVAudioSessionModeMoviePlayback` 而不是 `Default`。 |

通常什么都不需要改。

## 常见问题

- **启动崩溃，`dyld: library not loaded: …BackgroundAudio.dylib`** — dylib 没进 `Frameworks/`，或者没和主体一起签名。`ldid -S` 每个二进制或用 Sideloadly 重签。
- **锁屏还是断音** — 检查装上去的 `Info.plist` 里 `UIBackgroundModes = [audio]` 是不是真的存在；某些签名工具会重写 plist。
- **AirPods Pro 上看不到空间音频选项** — 确认 iOS 设置 → 蓝牙 → AirPods Pro → **空间音频**设为「**自动**」或「**固定**」，并且**没有**设置 `BGAUDIO_MIX_WITH_OTHERS`。
- **看日志** — dylib 会把诊断信息写到设备的 `Documents/bgaudio.log`。文件 App 或 Finder iTunes 共享抓出来。
- **回滚** — patch 过程会在每个被改的文件旁边留 `Steam Link.bak` 和 `SDL3.bak`；恢复即可撤销那一层。

## 授权

仅供学习和个人使用。Steam Link 归 Valve 所有；SDL3 归 Sam Lantinga / libsdl.org 所有。

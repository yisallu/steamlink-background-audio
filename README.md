# Steam Link Background Audio Patch

Patch for the iOS Steam Link app to keep audio playing when the screen is locked or the app is in the background.

## How It Works

1. **Binary patch SDL3.framework** — NOP out `SDL_OnApplicationDidEnterBackground`, `SDL_OnApplicationWillEnterBackground`, `SDL_PauseAudioDevice`, `SDL_AudioDevicePaused`, and `audioSessionInterruption:` by replacing the first instruction with `RET`
2. **Force AVAudioSession category** — Patch ARM64 instructions that load `AVAudioSessionCategoryAmbient`/`SoloAmbient` to load `AVAudioSessionCategoryPlayback` instead
3. **Inject BackgroundAudio.dylib** — Runtime hooks that:
   - Swizzle all `AVAudioSession setCategory:` calls to force Playback
   - Register `MPNowPlayingInfoCenter` to keep speaker output alive on lock screen
   - Disable `SDL_EVENT_WILL_ENTER_BACKGROUND` / `SDL_EVENT_DID_ENTER_BACKGROUND` via `SDL_SetEventEnabled`
   - Swizzle `applicationWillResignActive:` to prevent pause on lock
4. **Modify Info.plist** — Add `UIBackgroundModes: audio` and remove `UISupportedDevices` restriction

## Usage

### Automatic (GitHub Actions)

1. Place your **decrypted** `Steamlink.ipa` in the repo root (or provide it as a workflow input)
2. Push — GitHub Actions will build the dylib and produce the patched IPA as an artifact

### Manual

```bash
# 1. Build the dylib (requires macOS + Xcode)
cd tweak
make

# 2. Run the patch script
python apply_patch.py --input Steamlink.ipa --output Steamlink_patched.ipa --dylib tweak/BackgroundAudio.dylib
```

### Install

- **Sideloadly** — Sign and install directly (recommended)
- **TrollStore** — Install without signing
- **AltStore** — Sign and install

> ⚠️ Do NOT use LiveContainer — `UIBackgroundModes` won't take effect inside a container app.

## Compatibility

- Steam Link 1.3.25 (tested)
- iOS 14.0+
- arm64 only

## Project Structure

```
├── tweak/
│   ├── BackgroundAudio.m    # Injected dylib source
│   ├── Makefile             # Build dylib
│   └── .github/workflows/  # CI build
├── apply_patch.py           # Automated patch script
└── README.md
```

## License

For educational and personal use only.

---

# Steam Link 后台音频补丁

修改 iOS 版 Steam Link，使其在锁屏或后台时音频不中断。

## 原理

1. **二进制 Patch SDL3.framework** — 将 `SDL_OnApplicationDidEnterBackground`、`SDL_OnApplicationWillEnterBackground`、`SDL_PauseAudioDevice`、`SDL_AudioDevicePaused`、`audioSessionInterruption:` 的第一条指令改为 `RET`（直接返回）
2. **强制 AVAudioSession Category** — 修改 ARM64 指令，将加载 `Ambient`/`SoloAmbient` 的代码改为加载 `Playback`
3. **注入 BackgroundAudio.dylib** — 运行时 Hook：
   - Swizzle `AVAudioSession setCategory:` 强制使用 Playback
   - 注册 `MPNowPlayingInfoCenter` 保持锁屏扬声器输出
   - 通过 `SDL_SetEventEnabled` 禁用后台事件
   - Swizzle `applicationWillResignActive:` 阻止锁屏暂停
4. **修改 Info.plist** — 添加 `UIBackgroundModes: audio`，删除设备白名单限制

## 使用方法

### 自动（GitHub Actions）

1. 将脱壳后的 `Steamlink.ipa` 放在仓库根目录
2. Push 后 GitHub Actions 自动编译 dylib 并生成修改后的 IPA

### 手动

```bash
# 1. 编译 dylib（需要 macOS + Xcode）
cd tweak
make

# 2. 运行 patch 脚本
python apply_patch.py --input Steamlink.ipa --output Steamlink_patched.ipa --dylib tweak/BackgroundAudio.dylib
```

### 安装

- **Sideloadly** — 直接签名安装（推荐）
- **TrollStore（巨魔）** — 免签安装
- **AltStore** — 签名安装

> ⚠️ 不要用 LiveContainer 启动 — 容器内 `UIBackgroundModes` 不会生效。

## 兼容性

- Steam Link 1.3.25（已测试）
- iOS 14.0+
- 仅支持 arm64

## 许可

仅供学习和个人使用。

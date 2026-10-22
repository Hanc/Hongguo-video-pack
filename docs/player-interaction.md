# 播放页操作逻辑（对齐红果短剧）

更新：2026-10-22。目标是把播放页的手感对齐红果短剧，而不是自己发明一套。

## 为什么是对齐"逻辑"而不是直接引依赖

- 红果自家 Web 播放器 `https://hongguoduanju.com/player/{id}` 是纯点击式播放页：
  脚本 `player.6bc08ec74d.js` 里没有 `touchstart` / `dblclick` / `playbackRate`
  等任何手势或倍速实现，复用它拿不到移动端手感。
- 我们依赖的 `media_kit_video 2.0.1` 内置了一套成熟实现
  （`MediaKitVideoControlsThemeDataFullscreen`）：
  `volumeGesture` / `brightnessGesture` / `seekGesture`、
  `seekOnDoubleTap`（左中右三段，±10 秒）、`speedUpOnLongPress` +
  `speedUpFactor: 2.0`、`controlsHoverDuration: 3 秒`、
  `seekOnDoubleTapLayoutTapsRatios` 等。
- 但它的"上下滑"被亮度/音量占用（`material.dart:933-941` 起按左右半屏分流），
  且控制栏在**指针按下**时就切换显隐（`material.dart:794-796`
  `_handlePointerDown → onTap()`），长按会顺带把控制栏闪出来。
  这两点与红果"上下滑切集 + 长按只加速"直接冲突，因此手势层仍由自己实现，
  但参数与语义照抄上面这套参考实现。

## 当前映射

| 操作 | 行为 |
| --- | --- |
| 单击（无位移，抬手时判定） | 显示 / 隐藏控制栏 |
| 双击左三分之一 | 后退 10 秒 |
| 双击右三分之一 | 前进 10 秒 |
| 双击中间三分之一 | 播放 / 暂停 |
| 长按 400ms（不移动） | 临时顶到最高倍速（当前为 2.0x），松手回到上次选择的档位 |
| 按住后移动 | 取消长按加速，转为拖动 |
| 横向拖动 | 调整进度，整宽 2 分钟，两端夹紧 |
| 上滑 | 播放下一集 |
| 下滑 | 播放上一集 |
| 播放中 | 3 秒后自动收起控制栏；暂停时常驻 |

亮度、音量**不占用**画面手势（红果用上下滑切集，二者冲突）。音量走系统音量，
后续如果需要在控制栏加滑块，另起入口，不再抢画面手势。

## 平台差异

- 手势层在 Windows 与 Android 上都生效，行为一致（桌面用鼠标拖动等同于手指滑动），
  这样同一套代码不需要分平台分支；代价是在桌面上竖向拖动画面会切集。
- 桌面端额外提供"鼠标划过浮出控制栏、移出 3 秒后收起"，移动端只能靠单击。
- 横竖屏方向由 `orientationsFor` 按视频宽高决定（竖屏短剧保持 AppPortraitOnly），
  与媒体来源无关。

## 实现位置

- `lib/playback_gestures.dart`：全部手势（`Listener` 原始指针事件，避免与纹理、
  控制栏的手势竞技场互相抢占；方向在 16 逻辑像素后锁定）。
- `lib/playback_view.dart`：控制栏（顶部返回、底部进度与按钮）、自动收起计时、
  长按加速接线（`PlaybackController.startBoost/endBoost`）。
- 阈值常量集中在 `_PlaybackGesturesState`：`holdDelay 400ms`、
  `directionSlop 16`、`episodeThreshold 48`、`doubleTapStep 10s`、
  `doubleTapWindow 350ms`、`seekSpan 2min`。

## 验证

`flutter test test/playback_gestures_test.dart` 覆盖：整屏上下滑切集与方向锁定、
阈值以下不切集、进度夹紧、取消的拖动不提交、双击三段、长按只加速不弹控制栏。
真机手感仍需人工确认；自动化测试不能证明"像红果"。

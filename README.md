# AutoFn

<p align="center">
  <img src="macos/AutoFnMenuBar/Resources/AppIcon.svg" width="180" alt="AutoFn 图标">
</p>

支持两种触发方式：输入框聚焦触发 / 输入框内长按左键触发（自动启用微信/豆包语音输入法）


## 快速开始

脚本版（推荐用普通组合键）：

```bash
cd /Users/lessismore/Code/autofn
swift scripts/auto_hold_fn_on_input_focus.swift --hotkey ctrl+space
```

菜单栏 App：

```bash
cd /Users/lessismore/Code/autofn
bash scripts/build_auto_fn_menu_bar_app.sh
open dist/AutoFn.app
```

在菜单栏 `Trigger Mode` 里可切换：
- `Focus/Blur`（原方案）
- `Long Press In Input`（在输入框内长按左键触发，松开结束）

DMG 打包：

```bash
cd /Users/lessismore/Code/autofn
bash scripts/build_auto_fn_menu_bar_app.sh
bash scripts/build_dmg.sh
```

## 注意

- 需要在 macOS「系统设置 -> 隐私与安全性 -> 辅助功能」里给运行主体授权（终端或 AutoFnMenuBar.app）。

## 参考

- 本项目在输入框识别逻辑上参考了 [InputSourcePro](https://github.com/runjuu/InputSourcePro)。

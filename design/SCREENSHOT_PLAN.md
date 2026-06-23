# Screenshot 完善计划（Snipaste-clone MVP+）

目标：把当前 Screenshot feature 从「能截图能框选」做到 Snipaste 同等水平的 MVP+。

---

## P0 · 修通现有路径

### P0-3 工具栏视觉与交互打磨 ✨ 新增
- **悬浮感**：material 背景 → `.regularMaterial` + 更明显阴影（offsetY 4, blur 12）+ 1.5px 圆角描边
- **点击反馈**：自定义 `ButtonStyle`，按下时背景 0.2 透明度高亮 + 轻微 scale (0.95)
- **hover 反馈**：鼠标悬停时背景淡蓝高亮（用 `onHover`）
- **未实现工具暂时隐藏**：`isAvailable == false` 的工具直接从工具栏 `ForEach` 过滤掉，避免"灰色按钮点了无反应"的困惑

### P0-4 选区可调整 ✨ 新增
框选完成后，进入 annotation 阶段时让选区**仍然可调**：
- 8 个 handle（4 角 + 4 边中点）显示在选区边框上
- 鼠标移到 handle 时光标变向（NSCursor.resizeUpDown / resizeLeftRight 等）
- 拖 handle 调整选区，canvas + 工具栏跟着重新定位
- 拖 handle 时**重新截图对应区域**（不是缩放原图）—— 关键，否则边缘像素丢失

### P0-5 边缘放大镜 ✨ 新增
- selecting 阶段：鼠标周围 11x11 像素 8x 放大显示（约 88x88pt 跟随光标）
- 含十字线 + 中央像素 RGB 文本
- annotation 阶段调 handle 时也显示，方便像素级对齐

### P0-1 工具栏可见 & 可点击 ⭐ root cause（已完成）
**症状**：工具栏出现在选区外的 dim 区域时整个变灰、按钮无响应。
**原因**：
- `SelectionOverlayWindow.level = .screenSaver` (1000)
- `AnnotationToolbarPanel.level = .popUpMenu` (101)
- overlay 在工具栏之上 → dim 罩住视觉 + 吞掉鼠标事件

**改法**（`AnnotationToolbarPanel.swift`）：
```swift
self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
```
**验收**：选框后工具栏完全不透明、6 个按钮都能点。

### P0-2 工具栏定位智能避让（已完成）
当前 `position(adjacentTo:)` 在选区贴边时仍可能放进 dim 区。改进：
- 选区下方有空间 → 放下方（默认）
- 否则放上方
- 都不够 → 叠在选区右下角内部

---

## P1 · 标注工具补齐（Snipaste 核心）

### P1-1 颜色 & 粗细控件
- 工具栏新增：当前色色块（点击弹 8 色快选 + system color picker）
- 粗细：3 档（细/中/粗），按当前工具记忆
- 状态保存：`AnnotationCanvasView.currentColor / currentStrokeWidth` → 提升到 `AnnotationToolbarModel`

### P1-2 箭头工具（arrow）
- `Annotation.arrow(start, end)` 几何已有
- 绘制：粗线 + 三角形箭头头（10pt 默认，随 strokeWidth 缩放）

### P1-3 自由画笔（pen）
- 收集 mouseDragged 的点 → `Annotation.pen(points)`
- `NSBezierPath` + lineCap=.round, lineJoin=.round
- 性能：长 path 用道格拉斯-普克简化保持 < 200 点

### P1-4 高亮笔（highlight）
- 复用 pen，但 alpha 0.4、宽度 2x、blendMode = `.multiply`

### P1-5 文字（text）
- mouseDown 处弹 in-place `NSTextField`
- Enter / 失焦 → 提交；ESC 取消未提交
- 字号联动 strokeWidth（细=12 / 中=18 / 粗=28）

### P1-6 马赛克（mosaic）
- 路径化：`Annotation.mosaic(points, blockSize)`，默认 blockSize=12pt
- 实现：缩小 baseImage 到 1/blockSize → nearest neighbor 放大 → path mask

---

## P2 · Pin 窗口增强（Snipaste 灵魂）

### P2-1 缩放
- Cmd+滚轮 / `+` `-` 键：在锚点处放大缩小（10%–500%）
- `0` 重置 100%
- 短暂 HUD 显示当前比例

### P2-2 透明度
- Cmd+Shift+滚轮 / Alt+`+` Alt+`-` 调整 0.1–1.0
- 双击右键 → 切换"穿透模式"

### P2-3 编辑模式
- 双击 pin → 在 pin 上叠 `AnnotationCanvasView` + 同款工具栏
- 完成后保存回 pin 的 image

### P2-4 ESC 行为修正
- 当前 ESC 关窗 → 改为「隐藏」+ 进菜单栏隐藏列表
- 真正关闭：右键 Close 或 ⌘W

### P2-5 旋转 & 翻转（可选）
- `R` 旋转 90°，`H` 水平翻转，`V` 垂直翻转

---

## P3 · 体验细节

### P3-1 选择阶段精确控制
- 方向键 ±1 px 微调右下角；Shift+方向键 ±10 px
- 放大镜：mouse 周围 10x10 区域 8x 放大，含十字线 + RGB

### P3-2 颜色拾取（Snipaste 截图前 Cmd+C）
- 选框前 Cmd+C → 复制光标下像素颜色到剪贴板（hex）

### P3-3 F3 = 从剪贴板贴出浮动图
- 全局快捷键，复用 `HotkeyTap`
- 剪贴板 image → `PinnedImageWindow` 浮在屏幕中心

### P3-4 智能选区（窗口吸附）
- 鼠标悬停检测下方窗口 → 高亮 frame，点击直接选中
- 用 `CGWindowListCopyWindowInfo` 拿窗口 bounds

---

## P4 · 持久化 & 历史

### P4-1 Pin 列表持久化
- 序列化所有 pin（PNG bytes + frame + opacity + zoom）到 `~/Library/Application Support/CapyBuddy/pins/`
- 启动恢复，设置项开关

### P4-2 截图历史
- 每次 commit 存一份（环形缓冲 50 张）
- 菜单栏 Recent Captures 子菜单，缩略图 + 时间，点击重新 pin

### P4-3 设置面板新增
- 历史保留数量 / 历史路径
- 默认保存路径 / 默认文件名模板（`Screenshot_{date}_{time}.png`）

---

## 工程项（贯穿）

- **A. SnapBuddy → Screenshot rename**（已完成）
- **B. 拆 `ToolHandler` 协议**（P1 开工前重构 `AnnotationCanvasView` 的 mouse switch）
- **C. 颜色 / 粗细持久化** —— `UserDefaults` 存每个工具的最近偏好

---

## 执行顺序

1. P0-1, P0-2
2. 工程项 A（rename）
3. 工程项 B（ToolHandler 重构）
4. P1-1 → P1-6
5. P2 一起规划（互相依赖）
6. P3, P4 按优先级取舍

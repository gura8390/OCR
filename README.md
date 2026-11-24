# 文字识别 OCR

Windows x64 离线文字识别工具。0.2.0 按 Umi-OCR Paddle v2.1.5 的首屏、双栏工作区和标签导航重做界面，沿用原版图标与五套主题。桌面、截图、任务调度和接口用 Rust 实现，CPU 推理由随包的 ONNX Runtime 运行。

## 优势

- 推理放在独立子进程中，闲置后自动退出并归还内存，平时只剩一个轻量托盘。
- 模型加载后的内存、识别延迟和 CPU 占用都远低于 Umi-OCR，同时错字更少。
- 默认使用 PaddlePaddle 的 PP-OCRv6 Tiny 模型（[说明](https://huggingface.co/blog/PaddlePaddle/pp-ocrv6)），体积小、速度快。
- 完全离线，模型和运行库随包，不需要账号、网络或 Windows OCR 语言包。
- 一个程序覆盖截图、批量图片、PDF 等文档、双层 PDF、二维码、排版解析、Umi 兼容 HTTP 接口、命令行和无障碍。
- 用 Rust 原生实现，不依赖 Python 或 Qt 运行时。

| 指标 | 本工具（v6 Tiny） | Umi-OCR 2.1.5 | 本工具 / Umi |
| --- | --- | --- | --- |
| 服务就绪后闲置工作集 | 10.06 MiB | 189.52 MiB | 5.3% |
| 模型加载后工作集 | 129.18 MiB | 1114.61 MiB | 11.6% |
| 识别峰值工作集 | 139.55 MiB | 1129.48 MiB | 12.4% |
| 服务就绪时间 | 25.70 ms | 2034.38 ms | 1.3% |
| 首张延迟 | 101.87 ms | 672.35 ms | 15.2% |
| 热态中位延迟 | 39.23 ms | 105.03 ms | 37.4% |
| 热态 p95 延迟 | 121.20 ms | 416.01 ms | 29.1% |
| 吞吐 | 21.87 张/秒 | 6.56 张/秒 | 333.4% |
| 每张 CPU 时间 | 88.22 ms | 1018.45 ms | 8.7% |
| 字符错误率 | 0.44% | 1.98% | 22.2% |
| 托盘待机工作集 | 11.34 MiB | — | — |
| 识别后闲置卸载工作集 | 0.88 MiB | — | — |

测试条件：Intel Core i9-14900HX，Windows 11 build 26100，平衡电源；CPU 推理、4 线程、长边限制 960，经本机 HTTP 串行识别 8 张合成图（455 个字符）。字符错误率的样本量小，仅作相对参考。数据来自 [0.2.0 性能对照](docs/性能对照.md)；[11-06 复测](verification/retest-20261106/复测报告.md)的内存数据基本一致，热态中位延迟为 51.47 ms 对 164.96 ms。托盘待机为隐藏托盘、未加载模型时测得；闲置卸载为 3 秒阈值、小图样本下测得（[回归记录](docs/空闲卸载回归.md)）。Umi 没有同模式的数据。

竞品功能对照（基于公开资料，非同机实测）：

| | 本工具 | [Umi-OCR](https://github.com/hiroi-sora/Umi-OCR/releases) | [PowerToys 文本提取器](https://learn.microsoft.com/en-us/windows/powertoys/text-extractor) | [Text-Grab](https://github.com/TheJoeFin/Text-Grab) | [PixPin](https://pixpin.com/zh-hans/docs/getting-started/membership) |
| --- | --- | --- | --- | --- | --- |
| 识别引擎 | PP-OCRv6 Tiny 及 Paddle 旧模型（ONNX Runtime） | PaddleOCR-json 或 RapidOCR 插件 | Windows.Media.Ocr | Windows OCR；4.17 测试版内置英文 Tesseract | 本地 OCR，引擎未公开 |
| 识别中文的前提 | 开箱即用 | 开箱即用 | 安装中文 OCR 语言包 | 安装中文 OCR 语言包 | 开箱即用 |
| 批量与文档 | 批量图片，PDF 等 6 种文档格式，双层 PDF | 批量图片，文档识别 | 仅屏幕选区 | 文件夹内全部图片，PDF 多页抓取 | 文档识别为会员功能 |
| 本机 HTTP 接口 | 有，兼容 Umi | 有 | 无 | 无，4.17 测试版在做无界面 OCR | 未查到 |
| 需联网的功能 | 无 | 无 | 无 | 无 | 翻译、表格、公式 |
| 最新版本 | 0.2.3-p3（2026-11） | 2.1.5（2025-03） | 随 PowerToys 更新 | 4.16.0（2026-10） | 3.6.6.0（2026-10） |

竞品信息核对于 2026-11-24。本工具暂不提供表格结构识别、翻译、公式识别和贴图。

## 使用

从 [GitHub Releases](https://github.com/gura8390/OCR/releases) 选择 Windows x64 安装程序或便携 ZIP。安装程序为当前用户创建开始菜单入口并提供卸载。便携包解压后运行 `OCR.exe`，程序、`models` 和同目录运行库需一起保留。

按 **F4** 后拖选屏幕区域。拖动时黄色边框标出识别范围，松开鼠标开始识别。`Esc` 和右键取消选区。关闭主窗口默认留在托盘，Windows 将图标折叠时，从时钟旁的上箭头展开。托盘菜单提供截图、粘贴、扫码、打开主窗和退出。`Alt+F4` 保持系统行为。

开启截图页“识图后的操作 → 复制结果”后，截图和托盘剪贴板识别在后台完成，自动把非空结果写入剪贴板，主窗口保持隐藏。通过托盘打开主窗可查看、编辑或重新复制记录。关闭该选项后，识别时显示主窗。取消截图会恢复截图前的窗口状态。二维码扫描保留显示结果的行为。

- **截图OCR**的左侧是图片与文本框，右侧切换设置和记录。支持重截上一选区、粘贴、复制文本框及编辑识别文字。
- **批量OCR**和**批量文档**先添加待处理文件，再按开始。可预览、设置忽略区域、暂停和停止，以及按选定格式导出。
- **文档**支持 PDF、XPS、CBZ、EPUB、FB2 和传统无 DRM 的 MOBI，支持 PDF 文字层优先、密码 PDF、双层和纯文本 PDF 导出。EPUB、FB2 和 MOBI 以重排版式呈现，插图另页交给 OCR。忽略区域按原图像素设置。纯文本 PDF 从系统中选择可嵌入的字体。
- **二维码**支持截图、剪贴板和图片扫描，以及生成二维码并保存。扫描底层使用 Rust 的 ZXing 移植实现。
- **全局设置**保存在 `%LOCALAPPDATA%\OCR\settings.json`。主题提供赛博朋克、珍珠白、云墨黑及两套 Solarized。标签栏可置顶窗口、锁定标签。`Ctrl+T` 新建标签，`Ctrl+W` 关闭当前标签。登录启动可单独开启，默认关闭。高级设置中的“OCR 推理”可调整线程数与闲置卸载时间（默认 90 秒，设为 0 表示常驻）。
- **无障碍**通过 Windows UI Automation 提供按钮、队列、进度、设置状态和文本输入。截图记录和二维码文本可通过语义动作读写。忽略区域也可通过数字坐标输入。

新建桌面配置默认使用 PP-OCRv6 Tiny，基于本机中英样本的耗时、内存和错字率选择。传统六套模型在设置的语言下拉框保留，日语、韩语和西里尔文可选各自的模型。命令行和 API 默认沿用简体中文旧模型，便于替换原调用。模型文件及校验值见 [上游来源与许可](NOTICE.md)。

## 命令行和 API

```powershell
# 让正在运行的程序截屏
.\OCR.exe --screenshot

# 在后台识别一张图片并输出文件
Start-Process -FilePath .\OCR.exe -ArgumentList '--path "C:\test\input.png" --language v6_tiny --output "C:\test\result.txt"' -Wait -WindowStyle Hidden

# 本机 HTTP 服务，默认监听 127.0.0.1:1225
.\OCR.exe --serve --port 1225 --threads 4
```

`--show`、`--hide`、`--quit`、`--reload`、`--repeat`、`--clipboard` 可控制同一桌面实例。用 `--hide` 启动时，先初始化原生托盘和 F4；启用复制结果时，后台识别和历史保留也不创建主窗，直到用户明确打开界面。桌面端与 HTTP 服务的 OCR 推理均运行在独立子进程中，连续任务复用模型会话，闲置达到设定时间（默认 90 秒，可用 `--idle-seconds` 覆盖）后自动退出推理子进程并执行 `EmptyWorkingSet` 释放工作集；下次识别时自动拉起子进程，主进程退出或异常中止时由 Windows Job Object 自动清理子进程。`--path`、带 `screen=0 rect=x,y,w,h` 的 `--screenshot`、`--qrcode_read` 和 `--qrcode_create` 可单独调用。GUI 子系统程序可用 `Start-Process -Wait` 等待批处理结束。`--output`、`--output_append`、`--clip` 和 `--json` 可控制输出。

HTTP 服务提供 Umi 风格的 `/api/ocr`、`/api/ocr/get_options`、`/api/qrcode`、`/api/doc/*`。文档接口支持 PDF 和 CBZ。上传、结果读取和下载需使用同一服务进程。监听默认限于本机。

## 构建和验证

```powershell
.\tools\build.ps1 -Package
```

在源码目录运行构建和测试命令。构建使用 Rust 1.95 及以上、MSVC x64 和 Windows SDK。脚本先执行锁定依赖的 release 测试和编译，再打包程序、模型与运行库。发布构建可用 `-RemapBuildPaths` 替换编译器记录的本机路径。便携目录与 ZIP 各有 SHA-256 清单。安装包的构建步骤见 [安装程序源码说明](installer/README.md)。

- [0.2.0 性能对照](docs/性能对照.md)
- [2026-11-06 本机复测报告与原始数据](verification/retest-20261106/复测报告.md)
- [0.2.0 功能与验证范围](docs/验证范围.md)
- [0.2.3-p1 OCR 推理子进程与闲置卸载回归](docs/空闲卸载回归.md)

兼容范围以本说明列出的工作流和接口为准。每种功能页在本版保留一个标签。原版的独立重复标签、Python/QML 插件、完整配置迁移和文档逐页范围属于仍有差异的部分。

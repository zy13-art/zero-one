# codex-wallpaper-chat background-miku

Windows Codex 桌面应用的全窗口动态壁纸工具：暗色外观、边缘羽化、磨砂面板、Miku 星光局部增强，以及原 Codex 启动入口自动联动。

## 安装

1. 完整解压文件夹，准备 `wallpapers` 顶层的 MP4。公开源码包不包含个人媒体；本地个人包已放入 4K60 播放版。
2. 运行 `install.cmd`，或者 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`。
3. 保存输入并完整退出 Codex（包括托盘）一次，再从原桌面、任务栏或开始菜单入口启动。

默认只创建隐藏的 Windows 登录启动项，保留原 Codex 图标，不创建第二个桌面图标。普通启动需要补参数时会自动中转重开一次；现有会话作为基线保留，不会被监视器关闭。

只保存启动配置、暂不启用后台程序：

```powershell
.\install.ps1 -NoStart
```

完整的参数、视频要求、故障处理和可交给本地 Codex 的操作提示词，请阅读 [wallpaper美化包安装须知.txt](wallpaper美化包安装须知.txt)（内容为 Markdown）。

## 参数

```json
{"opacity":0.68,"veil":0.16,"appearance":"dark","starHighlights":true,"highlightOpacity":0.98}
```

- 68% 视频层、16% 暗色遮罩、98% 星光叠层；面板及边缘另有渐变羽化。
- 视频采用居中 `cover`，静音循环；多个视频按文件名排序依次播放。
- 推荐 H.264/yuv420p MP4、16:9、1080p/4K、30/60fps。
- 每个自动播放 MP4 ≤64 MiB，全部合计 ≤128 MiB。12K 母版单独保存在本地 `masters`，不加入播放列表。
- 特定 Miku 构图保留文件名 `miku.mp4`；其他视频不需要重命名为此名称。

## 控制

```powershell
.\pause.ps1
.\resume.ps1
.\stop.ps1
.\watcher-start.ps1
.\watcher-start.ps1 -CheckOnly
.\uninstall-autostart.ps1
```

更新素材或配置后停止并重新启动后台程序。旧版进程若拒绝停止，在普通 Windows 会话运行 `install.cmd`；必要时注销后登录。不要将“配置保存成功”当作当前窗口已经加载成功。

## 工作方式

隐藏的登录启动项启动两个后台程序：普通 Codex 启动监视器和壁纸控制器。监视器只处理中转阶段的新官方实例，核对本机端口、可执行文件、PID、精确创建时间和原始启动参数；读取失败时保留原应用并记录原因。

本机 CDP 只监听 `127.0.0.1:9335`，专用应用配置位于 `%LOCALAPPDATA%\CodexChatWallpaper\profile`。不修改 WindowsApps 安装包。这是非官方桌面定制工具，Codex 更新可能需要调整页面选择器。

`%LOCALAPPDATA%\CodexChatWallpaper` 保存后台日志与进程记录。不要上传该目录或其 profile。

## 检查

Node.js 22+；Windows PowerShell 5.1 或 PowerShell 7。

```powershell
node --check renderer.js
node --check wallpaper.mjs
node wallpaper.mjs --validate
.\tests\test-wallpaper-startup.ps1
.\tests\test-wallpaper-connection.ps1
```

## 许可

代码与文档采用 [MIT](LICENSE)。个人媒体不属于代码许可证；源码仓库不包含个人视频、图片、账号或日志。第三方项目见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
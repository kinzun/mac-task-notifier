# Mac 任务通知

任务完成时，在 Mac 右上角铃铛下方弹出原生小浮层。一个接收地址，一个 Codex Stop Hook；支持本机和可信局域网。

## 安装 Mac 应用

1. 从 [Releases](https://github.com/kinzun/mac-task-notifier/releases) 下载 Apple Silicon 应用包并解压。
2. 将 **Mac 任务通知.app** 放入“应用程序”文件夹，双击运行。应用自带运行环境，无需终端。
3. 右上角菜单栏出现铃铛，设置页显示接收地址和密钥。点击“发送测试通知”。

收到消息会展开约 6 秒的原生浮层；也可通过铃铛菜单“查看最近消息”再次查看。消息仅在内存保留最近一条。允许本应用的系统通知权限后，也会尝试发送 macOS 通知横幅。

关闭设置窗口会继续后台接收；只有菜单里的“退出 Mac 任务通知”或 ⌘Q 才停止。重复打开不同目录副本不会启动第二个接收服务。

此包在 Apple Silicon / macOS 15.7 上验证，最低构建目标为 macOS 13。当前为本地临时签名，尚无 Developer ID 签名及 Apple 公证；新 Mac 的系统安全提示与当前机器可能不同。

## 安装 Codex 插件

```bash
codex plugin marketplace add kinzun/mac-task-notifier
codex plugin add mac-task-notifier@mac-task-notifier
```

在 Mac 应用设置中点击 **连接本机 Hook**，保存一次发送配置。然后到 Codex **Settings → Hooks**（CLI 使用 `/hooks`）审阅并信任插件中的 Stop Hook。若当前会话尚未加载新插件，重开会话。

插件从 PATH 查找 Node，也可使用标准“应用程序”目录中本应用内置的 Node。只安装发送端、未安装 Mac 应用的设备需要 Node 20+。首版验证 macOS 本地 Codex，未承诺普通 ChatGPT 云端聊天或 Windows Hook 支持。

插件每次 Stop 后台发送固定短消息，不读取或上传对话。2 秒硬超时、不重试、异常退出码为 0，不阻止原任务；不更改其他插件或 Hook。回复结束不等于业务任务已成功。

### 同一局域网的其他设备

在接收 Mac 复制发送配置，将 JSON 保存到发送设备的 `~/.config/mac-task-notifier/sender.json`，权限设为 `600`。配置含 `url` 和 `token`；安装并信任相同插件即可。网络地址变化后重新复制配置。

配置与密钥仅保存在本地。连接本机操作不会覆盖已经指向其他接收端的配置；需要切换时先自行备份原配置。

## 接口

```http
POST /notify
Authorization: Bearer <本地接收密钥>
Content-Type: application/json

{"title":"任务完成","message":"可以回来看看了。"}
```

`202` 表示提醒已提交，不代表用户已经看到。标题最多 120 字符、正文最多 1000 字符、请求最多 8 KiB。`GET /health` 不含密钥；设置页和配置接口仅允许本机访问。

HTTP 未加密，仅用于可信局域网，不应暴露公网。Mac 必须清醒且应用运行，防火墙或网络隔离可能阻止跨机访问。首版无离线队列、自动发现、自动更新或开机自启。

## 从源码运行与构建

需要 Node 20+；构建 Mac 应用还需要 Command Line Tools、独立 Node 二进制及其原始 LICENSE。

```bash
git clone https://github.com/kinzun/mac-task-notifier.git
cd mac-task-notifier
npm test
python3 scripts/build-mac-app.py "$(command -v node)"
python3 scripts/check-mac-app.py
```

应用生成在仓库的上一级目录。构建打包会保留所有源文件，附带 Node 原始许可证，不复制用户配置。开发时可用 `npm start` 启动 HTTP 服务和网页测试页；不要与 Mac 应用同时占用 8765 端口。

接收配置默认位于 `~/.config/mac-task-notifier/receiver.json`，发送配置位于同目录 `sender.json`。开发可使用 `MAC_NOTIFY_PORT`、`MAC_NOTIFY_CONFIG_DIR`、`MAC_NOTIFY_CONFIG` 指定端口或配置位置，不提交真实配置到 Git。

## 验证与更新

```bash
npm run test:coverage
python3 scripts/check-running-app.py
```

自动检查覆盖鉴权、私有配置与防覆盖、跨站保护、中文分段输入、原生参数桥接、插件结构、带空格路径和发送超时。原生菜单栏、浮层、关闭窗口继续运行及退出行为需在 Mac 实机检查。

应用更新：退出旧应用，再从 Release 下载替换，配置留在用户目录。插件可刷新 marketplace 后按 Codex 当前支持的安装流程更新，修改后的 Hook 可能需要重新审阅信任。尚未验证第二台设备的实际投递，不将本机网络接口检查视为跨设备验收。

## 卸载

从 Codex 插件设置卸载本插件，退出并移走 Mac 应用即可。接收与发送配置由用户自行保留或删除，不影响 Session Start Trust 等其他插件。

## License

本项目为 MIT；应用内置 Node 的原始许可证位于 `Contents/Resources/LICENSE.node`。

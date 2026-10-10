# Orvia 设置文件格式 v3（应用版本 0.20.5 起，兼容导入 v1/v2）

[返回中文首页](../README.md) · [使用指南](user-guide.zh-CN.md)

## 用途

单个 UTF-8 JSON 文件，建议命名 Orvia-settings.json。缩进两空格、按键名排序、末尾换行；不依赖字段顺序。最多 16 MiB。

机器可读约束见同目录 settings-format.schema.json（JSON Schema 2020-12）。示例见 settings-example.json。

## 顶层字段（全部必需）

format: 固定字符串 "magic-wheel-settings"（Orvia 更名前的格式标识，继续保留以兼容现有文件）。

version: 当前导出为整数 3，可导入 1、2 或 3。格式版本独立于应用版本；不支持的版本会整份拒绝，不能降级猜测。

preferences: 通用偏好。

global: 全局轮盘。

applicationGroups: 命名场景数组，可为空；沿用旧字段名以便兼容历史数据。

scenes: 旧版独立文本输入配置数组，可为空；本版只支持 textInput。

## preferences

language: "zh-Hans" 或 "en"。

theme: 当前导出为 "minimal" 或 "glass"；导入兼容旧 "frosted"、"gta"、"cyberpunk"、"colorful" 并迁移到 "glass"。

enabled: 是否启用轮盘，布尔值。

holdSeconds: 长按阈值，单位秒，0.30–1.20（含边界）。

travel: 触控板归一化选择距离，0.07–0.25（含边界）。

launchAtLogin: 是否开机启动，布尔值；导入时可取消应用这一项，系统可能仍需批准。

两指手势固定，不是可编辑偏好。系统辅助功能授权、窗口位置、实时设备与焦点状态不属于可迁移设置。

## 轮盘对象

rotation: 弧度，[0, 2π)。

onRelease: 未指定单键触发方式时是否默认松手触发；修饰键默认保持逻辑与应用一致。

slots: 顺序数组，每项包含 action 和 appearance。数组顺序就是扇区顺序，空数组表示显式空轮盘，不回退其他配置。

## appearance

showName、showIcon: 必需布尔值。

name、icon: 可选字符串，缺失或 null 表示使用动作默认显示；空字符串是明确的空白显示。

trigger: 可选 "onEntry"（移入）、"onRelease"（松手）、"whileInside"（移入按住/移出释放）。缺失或 null 使用默认行为。

文本、快捷指令、设置操作及空动作不能使用 whileInside；文件若包含这种组合会被拒绝。

## 四种 action

1. {"type":"binding", "value":"return"}

   内置动作或旧版快捷键表达式。内置 ID 包括 clearText、virtualKeyboard、settings、spotlight、screenshot、option、return、delete、escape、copy、paste、undo、tab、up、down、left、right、space、selectAll、redo、command、control、shift。

   value="" 表示空键位。旧版表达式（例如 command+f1）按原字符串保存。无法识别的字符串保留但禁用。

   此类型不能以 recorded:、text:、text-enter:、mac-shortcut: 开头；这些动作应使用以下结构。

2. {"type":"key", "key":{"key":61,"flags":524352,"label":"右 Option","modifier":true}}

   key.key: macOS 虚拟键码，整数 0–127。

   key.flags: CGEventFlags 原始无符号 64 位整数，保留左右修饰键标记，不是键码。读取工具应使用精确整数。

   key.label: 非空显示标签；key.modifier: 是否为修饰键。

   modifier 必须与键码一致：54、55、56、57、58、59、60、61、62、63 为修饰键，其余为普通键。

3. {"type":"text", "value":"第一行\nSecond line🙂"}

   完整 Unicode 文本，保留空白、换行和空字符串；空字符串保持文字编辑模式但不执行动作。

   v3 可选 sendReturn 布尔值（缺省 false）：例如 {"type":"text", "value":"你好🙂", "sendReturn":true}。完整文字输入后按一次 Enter；是否发送或换行取决于目标应用。空文字不按 Enter。此字段只允许出现在 text 动作，v1/v2 必须省略。

4. {"type":"shortcut", "shortcut":{"identifier":"00000000-0000-0000-0000-000000000001","name":"示例快捷指令"}}

   identifier 是系统“快捷指令”的 UUID，name 为非空名称。文件只保存引用，不包含或运行快捷指令本体；另一台 Mac 需另行安装对应快捷指令并重新选择绑定。

每种 action 只能携带对应有效载荷；其他已定义的载荷字段必须省略或为 null。

## 命名场景（applicationGroups）

每项包含 id（稳定非空标识）、name（非空名称）、applications（应用范围）、wheel（轮盘对象）。

新增可选 scenes（当前仅支持 textInput）和 matchMode（all / any，缺省 all）。

applications 为空表示不限制应用；scenes 为空表示不要求文本框聚焦。两者不能同时为空。

同一场景内的 Bundle ID 和文本条件不得重复；v2 允许同一应用参与多个不同场景，保存时不会从其他场景移出。

场景编辑界面只有“仅在文本框聚焦时”勾选项，新建及编辑保存使用 all：必须匹配所选应用范围，勾选文本聚焦后还必须聚焦文本控件。应用范围内任意一个应用符合即可。

any 仅保留为旧版 v2 设置的读取兼容值，含义仍为应用范围或文本框聚焦任一符合；界面不再提供该选项，重新保存条件会使用 all。

匹配优先级：指定应用且要求文本框聚焦的 all 配置 > 文本条件命中 > 仅应用命中 > 全局。同一优先级按数组先后顺序匹配，编辑时保持原位置。any 配置不会成为最高优先级。

每个应用包含 bundleIdentifier（非空、无空白的 Bundle ID）和 name（非空显示名称）。匹配只使用 Bundle ID。

文件不包含本机应用路径。图标在导入的 Mac 上按 Bundle ID 查找；尚未安装的应用仍保留配置。

新场景从全局轮盘复制；修改名称、应用范围或文本勾选保留已有键位及配置 ID。

## 旧文本输入配置（scenes）

每项包含 id（只支持 textInput）和 wheel，ID 不可重复；优先于应用条件，低于指定应用且要求文本框聚焦的 all 配置。

旧配置保留原有轮盘，点击编辑可改名并增加应用条件，保存时迁移为命名场景。

配置编辑目标与运行时目标分离，打开的轮盘继续使用唤出时的快照。

## 版本兼容

v1 保留原有约束：应用不能跨组合重复，也不允许新增文本条件和 matchMode 行为。

v2 用于防止旧版应用忽略条件并错误匹配。v3 增加快捷文字输入后自动按 Enter；旧版应用会拒绝不支持的版本，避免丢失自动发送选项。

## 导入语义与恢复

整份替换，不合并。读取与完整校验在任何设置变更前完成。畸形 JSON、缺失必需字段、类型错误、未知枚举/场景、数值越界、重复身份与非法触发方式都会拒绝，当前设置保持不变。

未知的附加对象字段忽略，便于非破坏性扩展；新增必需行为需升级 version。

导入确认显示全局键位数、组合/应用数和场景数。确认后先以相同格式自动备份当前全部设置，再应用导入内容。

备份目录：~/Library/Application Support/MagicWheel/Backups/。

备份创建失败时不继续替换。可直接导入备份恢复。不会因导入而执行任何轮盘动作。

导入结束切回全局编辑器，运行中的轮盘关闭并释放保持按键。

导出/导入/再导出结果按语义及 JSON 字段值保持一致；本地历史键位的内部 Base64 键顺序会规范化，不改变按键含义。

--settings-review 隔离验证使用独立偏好域和 ReviewBackups，且不应用系统登录项更改。

## 兼容旧设置

现有 wheelLibrary.v1 单应用记录自动作为单成员组合使用，轮盘内容与身份保留；场景和全局数据不变。

此公开 JSON 格式不等同于 UserDefaults 内部数据。不能将原始偏好文件直接作为导入文件。

## 0.19.0 主题兼容

当前导出 theme 取值为 minimal（简约）或 glass（液态玻璃）。旧文件的 frosted（冰蓝玻璃）、gta、cyberpunk、colorful 会导入为 glass；其他未知值继续拒绝。主题迁移行为在 v1/v2 中一致。

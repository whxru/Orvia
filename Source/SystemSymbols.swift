import AppKit
import SwiftUI

struct SystemSymbol: Identifiable {
    let name: String
    let searchText: String
    var id: String { name }

    func matches(_ query: String) -> Bool {
        query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "." }).allSatisfy {
            searchText.localizedStandardContains(String($0))
        }
    }
}

enum SystemSymbolIndex {
    // Names only: artwork is always rendered by AppKit. Keep a bundled snapshot
    // because the system's catalog files are not a guaranteed public interface.
    static func candidates(fallbackURL: URL? = Bundle.main.url(forResource: "SymbolCatalog", withExtension: "plist"), systemDirectory: URL? = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")) -> [SystemSymbol] {
        func read(_ url: URL?) -> Any? {
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        }
        let fallback = read(fallbackURL) as? [String: Any] ?? [:]
        let systemNames = read(systemDirectory?.appendingPathComponent("symbol_order.plist")) as? [String] ?? []
        let keywords = read(systemDirectory?.appendingPathComponent("symbol_search.plist")) as? [String: [String]]
            ?? fallback["keywords"] as? [String: [String]] ?? [:]
        let aliases = read(systemDirectory?.appendingPathComponent("name_aliases.strings")) as? [String: String]
            ?? fallback["aliases"] as? [String: String] ?? [:]
        let preferred = ["mic", "magnifyingglass", "return", "camera", "scissors", "doc.on.clipboard", "gearshape", "star", "heart", "bolt"]
        var seen = Set<String>()
        return (preferred + systemNames + (fallback["names"] as? [String] ?? []) + aliases.keys.sorted()).filter { seen.insert($0).inserted }.map { name in
            let canonical = aliases[name] ?? name
            let parts = canonical.split(separator: ".").map(String.init)
            var terms = [name, canonical, parts.joined(separator: " ")]
            for length in 1...parts.count {
                terms += keywords[parts.prefix(length).joined(separator: ".")] ?? []
            }
            for (english, chinese) in translations where parts.contains(english) || terms.contains(english) {
                terms.append(chinese)
            }
            return SystemSymbol(name: name, searchText: terms.joined(separator: " ").lowercased())
        }
    }

    // Common Chinese concepts supplement the system's English search keywords.
    private static let translations: [(String, String)] = [
        ("mic", "麦克风 语音 录音 话筒"), ("magnifyingglass", "搜索 查找 放大镜"),
        ("microphone", "麦克风 语音 录音 话筒 mic"),
        ("return", "回车 返回"), ("camera", "相机 拍照 摄影"), ("scissors", "剪刀 剪切"),
        ("clipboard", "剪贴板 粘贴"), ("doc", "文档 文件"), ("gearshape", "设置 齿轮"),
        ("gear", "设置 齿轮"), ("star", "星星 收藏"), ("heart", "爱心 心脏 喜欢 健康"),
        ("bolt", "闪电 电量"), ("house", "房屋 首页 家"), ("person", "人物 用户 联系人"),
        ("figure", "人物 运动"), ("message", "消息 聊天 对话"), ("bubble", "消息 气泡 聊天"),
        ("phone", "电话 通话"), ("envelope", "邮件 信封"), ("bell", "铃铛 通知 提醒"),
        ("speaker", "扬声器 声音 音量"), ("headphones", "耳机 音乐"), ("music", "音乐 音符"),
        ("play", "播放"), ("pause", "暂停"), ("stop", "停止"), ("record", "录制 录音"),
        ("video", "视频 摄像"), ("photo", "照片 图片 相册"), ("folder", "文件夹 文件"),
        ("trash", "垃圾桶 删除"), ("pencil", "铅笔 编辑 写作"), ("eraser", "橡皮 擦除"),
        ("paperclip", "附件 回形针"), ("link", "链接"), ("lock", "锁 安全 隐私"),
        ("key", "钥匙 密码"), ("eye", "眼睛 查看 可见"), ("hand", "手 手势"),
        ("keyboard", "键盘 按键"), ("command", "命令 修饰键"), ("option", "选项 修饰键"),
        ("shift", "上档 修饰键"), ("control", "控制 修饰键"), ("escape", "退出 取消"),
        ("arrow", "箭头 方向"), ("up", "向上 上传"), ("down", "向下 下载"),
        ("left", "向左"), ("right", "向右"), ("plus", "加号 添加"), ("minus", "减号 减少"),
        ("checkmark", "勾 确认 完成"), ("xmark", "叉 关闭 取消"), ("clock", "时钟 时间"),
        ("timer", "计时器 时间"), ("calendar", "日历 日期"), ("alarm", "闹钟"),
        ("sun", "太阳 天气"), ("moon", "月亮 夜晚"), ("cloud", "云 天气"),
        ("snowflake", "雪花 冬天"), ("flame", "火焰 热"), ("drop", "水滴"),
        ("leaf", "树叶 自然"), ("tree", "树 自然"), ("wifi", "无线 网络"),
        ("network", "网络"), ("antenna", "天线 信号"), ("globe", "地球 网络 世界"),
        ("display", "显示器 屏幕"), ("desktopcomputer", "电脑 桌面"), ("laptopcomputer", "笔记本 电脑"),
        ("iphone", "手机 苹果"), ("ipad", "平板 苹果"), ("applewatch", "手表 苹果"),
        ("battery", "电池 电量"), ("printer", "打印机 打印"), ("gamecontroller", "游戏 手柄"),
        ("car", "汽车 交通"), ("bus", "公交 巴士 交通"), ("airplane", "飞机 旅行"),
        ("tram", "电车 交通"), ("bicycle", "自行车 骑行"), ("map", "地图 导航"),
        ("location", "位置 定位"), ("cart", "购物车 购物"), ("bag", "袋子 购物"),
        ("creditcard", "信用卡 支付"), ("gift", "礼物"), ("bookmark", "书签 收藏"),
        ("book", "书 阅读"), ("text", "文字 文本"), ("list", "列表 清单"),
        ("square", "方形"), ("circle", "圆形"), ("triangle", "三角形"),
        ("fill", "填充 实心"), ("slash", "斜线 禁用"), ("exclamationmark", "感叹号 警告"),
        ("questionmark", "问号 帮助"), ("info", "信息 帮助"), ("sparkles", "星光 闪烁")
    ]
}

@MainActor final class SystemSymbolCatalog: ObservableObject {
    @Published private(set) var symbols: [SystemSymbol] = []
    @Published private(set) var loading = true
    private static var cached: [SystemSymbol]?

    func load() async {
        if let cached = Self.cached { symbols = cached; loading = false; return }
        let candidates = await Task.detached { SystemSymbolIndex.candidates() }.value
        var available: [SystemSymbol] = []
        for (index, symbol) in candidates.enumerated() {
            guard !Task.isCancelled else { return }
            if NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) != nil { available.append(symbol) }
            if index % 128 == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        Self.cached = available; symbols = available; loading = false
    }
}

struct SystemIconPicker: View {
    var language: AppLanguage = .chinese
    private func l(_ text: String) -> String { language.text(text) }
    let current: String
    let dismiss: () -> Void
    let choose: (String) -> Void
    @State private var search = ""
    @StateObject private var catalog = SystemSymbolCatalog()
    @FocusState private var searchFocused: Bool
    private var results: [SystemSymbol] {
        let matches = catalog.symbols.filter { $0.matches(search) }
        let tokens = search.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "." }).map(String.init)
        guard !tokens.isEmpty else { return matches }
        // Prefer names over related metadata (e.g. camera before camera flash).
        func nameMatches(_ symbol: SystemSymbol) -> Bool { tokens.allSatisfy { symbol.name.contains($0) } }
        return matches.filter(nameMatches) + matches.filter { !nameMatches($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(l("选择图标")).font(.title2.weight(.semibold))
                Spacer()
                Button(l("取消"), action: dismiss).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(l("搜索图标名称或关键词，如：麦克风、camera"), text: $search)
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel(l("搜索图标"))
                if !search.isEmpty {
                    Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(l("清除图标搜索"))
                }
            }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            if catalog.loading {
                Spacer(); HStack { Spacer(); ProgressView(l("正在读取图标…")); Spacer() }; Spacer()
            } else {
                Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? (language == .chinese ? "\(catalog.symbols.count) 个系统图标" : "\(catalog.symbols.count) system icons")
                     : (language == .chinese ? "找到 \(results.count) 个图标" : "\(results.count) icons found"))
                    .font(.callout).foregroundColor(.secondary)
                if results.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.largeTitle)
                        Text(l("没有匹配的图标")).font(.headline)
                        Text(l("试试其他关键词或系统图标名称。"))
                    }.foregroundColor(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                                ForEach(results) { symbol in
                                    Button { choose(symbol.name) } label: {
                                        VStack(spacing: 8) {
                                            Image(systemName: symbol.name).font(.system(size: 25)).frame(height: 34)
                                            Text(symbol.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.85)
                                                .frame(maxWidth: .infinity, minHeight: 26)
                                        }.padding(8).frame(maxWidth: .infinity)
                                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(symbol.name == current ? 0.12 : 0.035)))
                                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(symbol.name == current ? 0.4 : 0.06)))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(symbol.name)
                                        .accessibilityLabel(symbol.name).accessibilityValue(symbol.name == current ? l("已选中") : l("未选中"))
                                        .id(symbol.name)
                                }
                            }.padding(2)
                        }.onChange(of: search) { _ in
                            if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }
            Divider()
            Text(l("点击图标立即保存。可搜索中文常用关键词或英文名称。"))
                .font(.caption).foregroundColor(.secondary)
        }.padding(22).frame(width: 650, height: 550).tint(.primary)
            .task { searchFocused = true; await catalog.load() }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TokenMoonCore

struct DisplayTimeContext<Content: View>: View {
    let model: AppModel
    let content: Content

    var body: some View {
        content
            .environment(\.calendar, model.displayCalendar)
            .environment(\.timeZone, model.displayTimeZone)
    }
}

struct DisplayTimeZoneSetting: View {
    @Binding var selection: String
    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private static let identifiers = Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted()

    private var isSystem: Bool { selection == UsageDisplayTime.system }
    private var title: String { isSystem ? "跟随系统" : Self.localizedName(selection) }

    var body: some View {
        LabeledContent("时区") {
            Button {
                query = ""
                isPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("显示时区")
            .accessibilityValue(title)
            .help("影响日期显示和用量分组；原始时间与同步文件不变。")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                choices
            }
        }
    }

    private var choices: some View {
        let filtered = Self.identifiers.filter { id in
            query.isEmpty || id.localizedStandardContains(query) || Self.localizedName(id).localizedStandardContains(query)
                || (id == "Asia/Shanghai" && ["北京", "北京时间", "上海"].contains(query))
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("显示时区").font(.headline)
            TextField("搜索城市或时区 ID", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if query.isEmpty {
                choice(UsageDisplayTime.system, title: "跟随系统", subtitle: TimeZone.autoupdatingCurrent.identifier)
                Divider()
            }
            if filtered.isEmpty {
                Text("没有匹配的时区").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.self) { id in
                            choice(id, title: Self.localizedName(id), subtitle: id)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 338, height: 350)
        .onAppear { searchFocused = true }
    }

    private func choice(_ id: String, title: String, subtitle: String) -> some View {
        Button {
            selection = id
            isPresented = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if title != subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    private static func localizedName(_ id: String) -> String {
        if id == "UTC" { return "UTC" }
        return TimeZone(identifier: id)?.localizedName(for: .generic, locale: Locale(identifier: "zh_CN")) ?? id
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct ChartSeriesLegend: View {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let detailName: String
        let color: Color
    }

    let title: String
    let entries: [Entry]
    @State private var showingAll = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let displayed = Array(entries.prefix(7))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(.caption.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(contrast == .increased ? 1 : 0.77))
                Spacer(minLength: 0)
                if entries.count > displayed.count {
                    Button { showingAll.toggle() } label: {
                        Text("全部 \(entries.count) 个").font(.caption).foregroundStyle(Color.accentColor)
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看全部 \(entries.count) 个\(title)图例")
                        .popover(isPresented: $showingAll, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(title)图例").font(.headline)
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        ForEach(entries) { legendEntry($0) }
                                    }
                                }.frame(height: min(CGFloat(entries.count) * 23, 270))
                            }.padding(14).frame(width: 265)
                        }
                }
            }
            FullWidthLegendGrid {
                ForEach(displayed) { legendEntry($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("同一\(title)在所有指标中保持相同颜色；没有有效读数的系列不绘制。")
    }

    private func legendEntry(_ entry: Entry) -> some View {
        HStack(spacing: 5) {
            Circle().fill(entry.color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(entry.detailName)
    }
}

/// Every occupied column gets an equal share of the row; spare space doesn't
/// accumulate on the right when the active filter has only a few identities.
private struct FullWidthLegendGrid: Layout {
    private let minimumColumnWidth: CGFloat = 132
    private let columnSpacing: CGFloat = 10
    private let rowSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = CGFloat(max(1, subviews.count)) * (minimumColumnWidth + columnSpacing) - columnSpacing
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal)
        let grid = plan(width: width, subviews: subviews)
        return CGSize(width: width, height: grid.rowHeights.reduce(0, +) + CGFloat(max(0, grid.rowHeights.count - 1)) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = plan(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in grid.rowHeights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard subviews.indices.contains(index) else { break }
                let x = bounds.minX + CGFloat(column) * (grid.cellWidth + columnSpacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: grid.cellWidth, height: nil))
            }
            y += height + rowSpacing
        }
    }

    private func plan(width: CGFloat, subviews: Subviews) -> (columns: Int, cellWidth: CGFloat, rowHeights: [CGFloat]) {
        let capacity = floor((width + columnSpacing) / (minimumColumnWidth + columnSpacing))
        let columns = max(1, Int(min(CGFloat(subviews.count), capacity)))
        let cellWidth = max(0, (width - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns))
        let cell = ProposedViewSize(width: cellWidth, height: nil)
        var heights: [CGFloat] = []
        for index in subviews.indices {
            let row = index / columns
            let height = subviews[index].sizeThatFits(cell).height
            if heights.count == row { heights.append(height) }
            else { heights[row] = max(heights[row], height) }
        }
        return (columns, cellWidth, heights)
    }
}

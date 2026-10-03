import SwiftUI
import UIKit

extension View {
    @ViewBuilder func glassCard() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        }
    }
}

// One production sprite sheet, sliced once into six reusable local images.
@MainActor
private enum StickerImages {
    static let images = slice("StickerSheet")
    static let clay = slice("ClaySheet")
    private static func slice(_ name: String) -> [UIImage] {
        guard let sheet = UIImage(named: name)?.cgImage else { return [] }
        let w = sheet.width / 3, h = sheet.height / 2
        return (0..<6).compactMap { i in
            sheet.cropping(to: CGRect(x: (i % 3) * w, y: (i / 3) * h, width: w, height: h)).map { UIImage(cgImage: $0) }
        }
    }
}

struct PooSticker: View {
    let kind: PooKind
    var body: some View {
        Group {
            if StickerImages.images.count == 6 {
                Image(uiImage: StickerImages.images[kind.index]).resizable().scaledToFit()
            } else {
                Image(systemName: "exclamationmark.triangle").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(kind.title)
    }
}

struct PooHero: View {
    let kind: PooKind
    var body: some View {
        Group {
            if StickerImages.clay.count == 6 {
                Image(uiImage: StickerImages.clay[kind.index]).resizable().scaledToFit()
            } else {
                PooSticker(kind: kind)
            }
        }
        .accessibilityLabel(kind.title)
    }
}

struct WeekCard: View {
    @EnvironmentObject var store: CheckInStore
    let now: Date
    let openCalendar: () -> Void
    private let names = ["一", "二", "三", "四", "五", "六", "日"]
    var body: some View {
        Button(action: openCalendar) {
            VStack(spacing: 12) {
                HStack {
                    Text("我的打卡日历").font(.headline)
                    Spacer()
                    Text("连续 \(store.book.streak(now: now)) 天").font(.subheadline).foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.right").font(.caption)
                }
                HStack(spacing: 3) {
                    ForEach(Array(DayKey.week(now).enumerated()), id: \.offset) { index, day in
                        VStack(spacing: 3) {
                            Text(names[index]).font(.caption2).foregroundStyle(.secondary)
                            Text("\(Calendar.current.component(.day, from: day))").font(.caption)
                            if let record = store.book.record(on: day) {
                                PooSticker(kind: record.kind).frame(height: 36)
                            } else {
                                Circle().fill(Color.accentColor.opacity(Calendar.current.isDate(day, inSameDayAs: now) ? 0.12 : 0.035))
                                    .frame(width: 27, height: 27).frame(height: 36)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(store.book.record(on: now) == nil ? "今天还未记录" : "今天已点亮，明天再来呀")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18).glassCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开我的打卡日历")
    }
}

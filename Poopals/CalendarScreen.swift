import SwiftUI

struct CalendarScreen: View {
    @EnvironmentObject var store: CheckInStore
    @State private var month = Date()
    @State private var selected = Date()
    @State private var editing: CheckIn?
    @State private var deleteConfirmation = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var selectedRecord: CheckIn? { store.book.record(on: selected) }
    private var monthCount: Int {
        let prefix = String(DayKey.make(month).prefix(7))
        return store.book.records.filter { $0.day.hasPrefix(prefix) }.count
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                    Spacer()
                    Text(month.formatted(.dateTime.year().month(.wide))).font(.title2.bold())
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下个月")
                }
                Text("每天一只噗噗，记录生活的小轻松").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 15) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(DayKey.monthDays(month).enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date)
                        } else { Color.clear.frame(height: 75).accessibilityHidden(true) }
                    }
                }
                Divider()
                HStack {
                    Text("本月 \(monthCount) 天")
                    Spacer()
                    Text("连续 \(store.book.streak()) 天").foregroundStyle(Color.accentColor)
                }.font(.headline)
                if let record = selectedRecord {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(selected.formatted(.dateTime.month().day())).font(.title3.bold())
                        HStack(spacing: 16) {
                            PooSticker(kind: record.kind).frame(width: 85, height: 90)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(record.kind.title).font(.headline)
                                Text("\(record.size.rawValue) 号 · \(record.createdAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("今天也要轻松一点呀～").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Button("修改记录") { editing = record }.buttonStyle(.bordered)
                            Spacer()
                            Button("删除", role: .destructive) { deleteConfirmation = true }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    ContentUnavailableView("这一天还没有记录", systemImage: "calendar", description: Text("\(selected.formatted(.dateTime.month().day()))\n回到今日页面，留下一只今天的噗噗。"))
                }
                Text("小小的记录，慢慢的坚持。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical)
            }.padding(20)
        }
        .navigationTitle("噗噗日历").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("今天") { month = Date(); selected = Date() } }
        .sheet(item: $editing) { record in EditRecordScreen(record: record) }
        .confirmationDialog("删除这一天的记录？删除后无法撤销。", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("删除记录", role: .destructive) { if let r = selectedRecord { store.delete(day: r.day) } }
        }
    }
    private func shift(_ amount: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: amount, to: month) else { return }
        month = next
        selected = Calendar.current.dateInterval(of: .month, for: next)!.start
    }
    private func dayCell(_ date: Date) -> some View {
        let record = store.book.record(on: date)
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selected)
        return Button { selected = date } label: {
            VStack(spacing: 2) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: Circle())
                if let record { PooSticker(kind: record.kind).frame(height: 43) }
                else { Color.clear.frame(height: 43) }
            }.frame(maxWidth: .infinity)
                .foregroundStyle(DayKey.make(date) > DayKey.make(Date()) ? Color.secondary : Color.primary)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(date.formatted(.dateTime.month().day()))，\(record.map { $0.kind.title + "，" + $0.size.rawValue + "号" } ?? "未记录")")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct EditRecordScreen: View {
    @EnvironmentObject var store: CheckInStore
    @Environment(\.dismiss) private var dismiss
    let record: CheckIn
    @State private var kind: PooKind
    @State private var size: PooSize
    init(record: CheckIn) {
        self.record = record
        _kind = State(initialValue: record.kind)
        _size = State(initialValue: record.size)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(record.day) {
                    PooSticker(kind: kind).frame(height: 160).frame(maxWidth: .infinity)
                    Picker("噗噗", selection: $kind) { ForEach(PooKind.allCases) { Text($0.title).tag($0) } }
                    Picker("大小", selection: $size) { ForEach(PooSize.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                }
            }
            .navigationTitle("修改记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let date = DayKey.date(record.day), store.save(day: date, kind: kind, size: size) { dismiss() }
                    }.disabled(!store.writable)
                }
            }
        }
    }
}

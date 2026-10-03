import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: CheckInStore
    @EnvironmentObject var account: AccountService
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind: PooKind = .yellow
    @State private var size: PooSize = .m
    @State private var today = Date()
    @State private var calendarOpen = false
    @State private var settingsOpen = false
    @State private var accountOpen = false
    @State private var celebrating = false
    @State private var confirmReplace = false
    private let midnightCheck = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("每天记录一点，轻松一点").foregroundStyle(.secondary)
                    WeekCard(now: today) { calendarOpen = true }
                    Button { accountOpen = true } label: {
                        Label(account.session == nil ? "记录已留在本机 · 开启云备份" : account.status, systemImage: account.session == nil ? "icloud" : "icloud.and.arrow.up")
                            .font(.caption)
                    }
                    VStack(spacing: 14) {
                        HStack { Text("今天的大小").font(.headline); Spacer() }
                        Picker("今天的大小", selection: $size) {
                            ForEach(PooSize.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        GeometryReader { geometry in
                            ZStack {
                                PooHero(kind: PooKind.allCases[(kind.index + 5) % 6])
                                    .frame(width: 130, height: 160)
                                    .opacity(0.45).offset(x: -geometry.size.width / 2)
                                PooHero(kind: PooKind.allCases[(kind.index + 1) % 6])
                                    .frame(width: 130, height: 160)
                                    .opacity(0.45).offset(x: geometry.size.width / 2)
                                PooHero(kind: kind)
                                    .frame(width: min(260, geometry.size.width * 0.86), height: 235)
                                    .scaleEffect(size == .s ? 0.78 : size == .m ? 0.9 : size == .l ? 0.97 : 1.04)
                                    .animation(.easeInOut(duration: 0.2), value: size)
                            }
                            .frame(width: geometry.size.width, height: 235)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                                if abs(value.translation.width) > abs(value.translation.height) {
                                    move(value.translation.width < 0 ? 1 : -1)
                                }
                            })
                        }
                        .frame(height: 235).clipped()
                        HStack {
                            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                                .accessibilityLabel("上一个噗噗")
                            Spacer()
                            Text(kind.title).font(.title2.bold())
                            Spacer()
                            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                                .accessibilityLabel("下一个噗噗")
                        }
                        Text("左右滑动，选择今天的噗噗").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(PooKind.allCases) { item in
                                Circle().fill(item == kind ? Color.accentColor : Color.gray.opacity(0.22)).frame(width: 7, height: 7)
                            }
                        }.accessibilityHidden(true)
                    }.padding(20).glassCard()
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("今日噗噗")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { calendarOpen = true } label: { Image(systemName: "calendar") }.accessibilityLabel("打卡日历")
                    Button { settingsOpen = true } label: { Image(systemName: "bell") }.accessibilityLabel("提醒设置")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        today = Date()
                        if store.book.record(on: today) != nil { confirmReplace = true } else { save() }
                    } label: {
                        Label(store.book.record(on: today) == nil ? "记录到日历" : "更新今日记录", systemImage: "checkmark.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(!store.writable || celebrating)
                    Text("选好噗噗，点亮今天").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.vertical, 10).background(.regularMaterial)
            }
            .navigationDestination(isPresented: $calendarOpen) { CalendarScreen() }
            .navigationDestination(isPresented: $accountOpen) { AccountScreen() }
            .sheet(isPresented: $settingsOpen) { SettingsScreen() }
            .fullScreenCover(isPresented: $celebrating, onDismiss: { calendarOpen = true }) {
                SuccessScreen(kind: kind, streak: store.book.streak()) { celebrating = false }
            }
            .confirmationDialog("今天已经记录过，要替换为当前选择吗？", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("更新今日记录") { save() }
                Button("取消", role: .cancel) { }
            }
            .onAppear {
                refreshToday()
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--show-account") {
                    try? await Task.sleep(for: .seconds(1))
                    accountOpen = true
                }
                #endif
            }
            .onReceive(midnightCheck) { _ in today = Date() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshToday() } }
        }
    }
    private func move(_ delta: Int) {
        withAnimation { kind = PooKind.allCases[(kind.index + delta + PooKind.allCases.count) % PooKind.allCases.count] }
    }
    private func refreshToday() {
        today = Date()
        if let record = store.book.record(on: today) { kind = record.kind; size = record.size }
    }
    private func save() {
        if store.save(day: today, kind: kind, size: size) {
            celebrating = true
            Task { await account.sync(store: store) }
        }
    }
}

struct SuccessScreen: View {
    let kind: PooKind
    let streak: Int
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var finished = false
    var body: some View {
        VStack(spacing: 20) {
            Text("噗噗搭子").font(.headline).padding(.top, 35)
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.055)).frame(width: 280, height: 280)
                PooSticker(kind: kind).frame(width: 255, height: 255)
                    .scaleEffect(visible || reduceMotion ? 1 : 0.72)
                    .offset(y: visible || reduceMotion ? 0 : 25)
                if !reduceMotion {
                    ForEach(0..<24, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill([Color.purple, .pink, .orange, .mint][i % 4])
                            .frame(width: 6, height: i % 2 == 0 ? 13 : 7)
                            .rotationEffect(.degrees(Double(i * 37)))
                            .offset(x: visible ? CGFloat((i * 53) % 310 - 155) : 0,
                                    y: visible ? CGFloat((i * 37) % 310 - 155) : 0)
                            .opacity(visible ? 0.85 : 0)
                    }
                }
            }
            Text("今日打卡完成！").font(.largeTitle.bold())
            Text("又认真记录了一天").foregroundStyle(.secondary)
            Text("连续 \(streak) 天 · 今天已点亮").foregroundStyle(Color.accentColor)
            Spacer()
            Button("查看日历") { finish() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            Text("正在收进你的日历…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity).background(Color(.systemBackground))
        .task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.55)) { visible = true }
            do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
            finish()
        }
        .accessibilityElement(children: .contain)
    }
    private func finish() { guard !finished else { return }; finished = true; done() }
}

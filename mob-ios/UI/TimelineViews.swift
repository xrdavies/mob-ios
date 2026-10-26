import SwiftUI

private let runnerLabels = ["codex": "Codex", "claude": "Claude Code", "pi": "Pi"]

/// One timeline entry. `last` marks the newest turn footer (it offers Retry).
struct TimelineRow: View {
    @Environment(AppState.self) private var app
    let item: TimelineItem
    let runner: String?
    let last: Bool

    var body: some View {
        switch item {
        case .user(_, let m, let task): UserMessage(message: m, task: task)
        case .assistant(_, let m):
            let task = app.chat.detail?.tasks.first { $0.id == m.taskId }
            AssistantMessage(message: m, runner: task?.runner ?? runner, model: task?.modelLabel ?? "Model not reported")
        case .steps(_, let acts): VStack(alignment: .leading, spacing: 0) { ForEach(acts) { ActivityRow(a: $0) } }.padding(.leading, 34)
        case .group(_, let acts): ActivityGroup(activities: acts).padding(.leading, 34)
        case .ask(_, let q): QuestionCard(q: q).padding(.leading, 34)
        case .queued(_, let t):
            Label(queuedLabel(t), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
        case .working(_, let t, let latest, let waiting): WorkingRow(task: t, latest: latest, waiting: waiting).padding(.leading, 34)
        case .footer(_, let t): TurnFooter(task: t, last: last).padding(.leading, 34)
        }
    }
}

/// The running turn's state and how long it has run; the only place the chat shows it.
private struct WorkingRow: View {
    @Environment(AppState.self) private var app
    let task: AgentTask
    let latest: Activity?
    let waiting: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let time = duration(task.startedAt, nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.modelLabel).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if app.chat.cancelling {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Stopping…").foregroundStyle(.red)
                    } else if waiting {
                        Circle().fill(Color.waiting).frame(width: 8, height: 8)
                        Text("Waiting for your answer").foregroundStyle(Color.waiting)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text((["Working", time] + [latest?.title].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .font(.caption).lineLimit(1)
        }
    }
}

private struct UserMessage: View {
    @Environment(AppState.self) private var app
    let message: Message
    let task: AgentTask?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let ids = task?.attachments, !ids.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ids, id: \.self) { id in
                            RemoteImage(client: app.apiClient, url: app.apiClient.artifactURL(id))
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxWidth: 300).fixedSize(horizontal: true, vertical: false)
            }
            Text(message.content)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

private struct AssistantMessage: View {
    let message: Message
    let runner: String?
    let model: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.caption).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Mob").font(.caption.weight(.semibold))
                    Text(runnerLabels[runner ?? "codex"] ?? runner ?? "").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { UIPasteboard.general.string = message.content } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel("Copy reply")
                }
                Text(model).font(.caption2).foregroundStyle(.secondary)
                MarkdownView(text: message.content)
            }
        }
    }
}

private func icon(_ a: Activity) -> String {
    switch a.kind {
    case "tool":
        switch a.tool {
        case "click": return "cursorarrow.click"
        case "type_text", "key": return "keyboard"
        case "screenshot": return "camera"
        case "open_app", "list_windows": return "macwindow"
        default: return "wrench.and.screwdriver"
        }
    case "command": return "terminal"
    case "reasoning": return "brain"
    case "plan": return "checklist"
    case "file_change": return "doc.badge.plus"
    case "web_search": return "globe"
    case "notice": return "exclamationmark.triangle"
    default: return "circle"
    }
}

/// One agent step: tool call, command, reasoning, plan, file change, search or notice. Tap for details.
struct ActivityRow: View {
    let a: Activity
    @State private var open = false

    var body: some View {
        let notice = a.kind == "notice"
        let meta = a.kind == "tool" ? (a.tool ?? "") : a.kind == "command" ? "shell" : (a.kind == "reasoning" || notice) ? "" : a.kind.replacingOccurrences(of: "_", with: " ")
        let took = a.status == "running" || notice ? "" : duration(a.startedAt, a.updatedAt)
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Group {
                        if a.status == "running" { ProgressView().controlSize(.mini) }
                        else if a.status == "failed" { Image(systemName: "xmark").foregroundStyle(.red) }
                        else { Image(systemName: icon(a)).foregroundStyle(notice ? Color.waiting : .secondary) }
                    }
                    .font(.caption).frame(width: 18)
                    Text(a.title).font(.subheadline).lineLimit(1)
                        .italic(a.kind == "reasoning")
                        .foregroundStyle(notice ? Color.waiting : a.kind == "reasoning" ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text([meta, took].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { ActivityDetails(a: a).padding(.leading, 26) }
        }
    }
}

private struct Mono: View {
    let text: String
    var italic = false
    @State private var all = false

    var body: some View {
        let long = text.split(separator: "\n", omittingEmptySubsequences: false).count > 16 || text.count > 1500
        VStack(spacing: 0) {
            Text(long && !all ? String(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(16).joined(separator: "\n").prefix(1500)) + "\n…" : text)
                .font(.system(.caption, design: .monospaced)).italic(italic)
                .foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            if long { Button(all ? "Show less" : "Show all") { all.toggle() }.font(.caption).padding(.bottom, 6) }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActivityDetails: View {
    @Environment(AppState.self) private var app
    let a: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if a.kind == "tool", let args = a.arguments, !args.isEmpty {
                ForEach(args.keys.sorted(), id: \.self) { k in
                    HStack(alignment: .firstTextBaseline) {
                        Text(k).font(.caption2).foregroundStyle(.secondary).frame(minWidth: 60, alignment: .leading)
                        Text(args[k]?.description ?? "").font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if a.kind == "command", let c = a.command, !c.isEmpty { Mono(text: "$ \(c)") }
            ForEach(a.images ?? [], id: \.self) { id in
                RemoteImage(client: app.apiClient, url: app.apiClient.artifactURL(id), fit: true)
                    .frame(maxWidth: .infinity).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if a.kind == "plan" {
                ForEach(Array((a.items ?? []).enumerated()), id: \.offset) { _, it in
                    Label {
                        Text(it.text).font(.caption).strikethrough(it.completed == true)
                            .foregroundStyle(it.completed == true ? .secondary : .primary)
                    } icon: {
                        Image(systemName: it.completed == true ? "checkmark.square.fill" : "square")
                            .foregroundStyle(it.completed == true ? Color.success : .secondary)
                    }
                }
            }
            if a.kind == "file_change" {
                ForEach(Array((a.changes ?? []).enumerated()), id: \.offset) { _, c in
                    HStack {
                        Text(c.kind ?? "").font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        Text(c.path).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if let t = a.text, !t.isEmpty, a.tool != "screenshot" {
                Mono(text: t + (a.truncated == true ? "\n… (truncated)" : ""), italic: a.kind == "reasoning")
            }
            if a.kind == "command", let code = a.exitCode {
                Text("exit \(code)").font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(code == 0 ? Color.success : .red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((code == 0 ? Color.success : .red).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            if let e = a.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.bottom, 6)
    }
}

/// Three or more consecutive steps, folded: "5 steps · 0:42 · latest step".
private struct ActivityGroup: View {
    let activities: [Activity]
    @State private var open = false

    var body: some View {
        let latest = activities.last!
        let failed = activities.filter { $0.status == "failed" }.count
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    if activities.contains(where: { $0.status == "running" }) { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary) }
                    Text("\(activities.count) steps").font(.subheadline.weight(.medium))
                    Text("· \(duration(activities.first?.startedAt, latest.updatedAt))").font(.caption).foregroundStyle(.secondary)
                    if failed > 0 { Text("· \(failed) failed").font(.caption).foregroundStyle(.red) }
                    Text(open ? "" : latest.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { VStack(alignment: .leading, spacing: 0) { ForEach(activities) { ActivityRow(a: $0) } }.padding(.horizontal, 6).padding(.bottom, 4) }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
    }
}

private struct TurnFooter: View {
    @Environment(AppState.self) private var app
    let task: AgentTask
    let last: Bool

    var body: some View {
        let u = task.usage
        let total = (u?.inputTokens ?? 0) + (u?.outputTokens ?? 0)
        let meta = [
            task.startedAt == nil ? nil : duration(task.startedAt, task.finishedAt),
            total > 0 ? "\(compactNumber(total)) tokens" : nil,
            u?.costUsd.flatMap { $0 > 0 ? String(format: $0 < 0.01 ? "$%.4f" : "$%.2f", $0) : nil },
            task.modelLabel,
            task.effort.map { "effort \($0)" },
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: 6) {
            if task.status == Status.failed {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn failed").font(.subheadline.weight(.medium)).foregroundStyle(.red)
                        if let e = task.error { Text(e).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if last {
                        Button {
                            app.chat.send(task.prompt ?? "", model: task.model, effort: task.effort, attachments: task.attachments ?? [])
                        } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(app.chat.sending || app.chat.detail?.busy == true || !app.isConnected)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.25)))
            }
            if task.status == Status.cancelled {
                Label("Cancelled", systemImage: "nosign").font(.caption2).foregroundStyle(.secondary)
            }
            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// A decision the agent is waiting for, answered in the chat; settled ones show the outcome.
struct QuestionCard: View {
    @Environment(AppState.self) private var app
    let q: Question
    @State private var text = ""
    @State private var sending = false

    var body: some View {
        if q.isPending { pending } else { settled }
    }

    private var settled: some View {
        let (line, color): (String, Color) = {
            if q.status == "answered" && q.isApproval { return (q.approved == true ? "Approved" : "Denied", q.approved == true ? .success : .red) }
            if q.status == "answered" { return ("You answered: \(q.answer ?? "")", .secondary) }
            if q.status == "expired" { return (q.isApproval ? "No answer in time — treated as denied" : "No answer in time", .secondary) }
            return ("Cancelled", .secondary)
        }()
        let note = q.isApproval && q.status == "answered" && !(q.answer ?? "").isEmpty ? " · “\(q.answer!)”" : ""
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: q.isApproval ? "checkmark.shield" : "questionmark.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(q.text).font(.subheadline)
                Text(line + note).font(.caption).foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
    }

    private func answer(_ answer: String?, _ approved: Bool?) {
        sending = true
        app.chat.answer(q, answer: answer, approved: approved) { if !$0 { sending = false } }
    }

    private var pending: some View {
        let options = q.options ?? []
        let freeText = q.allowText == true || options.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: q.isApproval ? "checkmark.shield" : "questionmark.circle").foregroundStyle(Color.waiting)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.isApproval ? "APPROVAL NEEDED" : "THE AGENT ASKS").font(.caption2.weight(.semibold)).foregroundStyle(Color.waiting)
                    Text(q.text).font(.body.weight(.medium))
                    if let d = q.details, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if q.isApproval {
                TextField("Optional note for the agent", text: $text).textFieldStyle(.roundedBorder).disabled(sending)
                HStack {
                    Button { answer(text.isEmpty ? nil : text, true) } label: { Label("Approve", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { answer(text.isEmpty ? nil : text, false) } label: { Label("Deny", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                }
                .disabled(sending)
            } else {
                if !options.isEmpty {
                    FlowButtons(options: options) { answer($0, nil) }.disabled(sending)
                }
                if freeText {
                    HStack {
                        TextField(options.isEmpty ? "Type your answer" : "Or type another answer", text: $text)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") { answer(text.trimmingCharacters(in: .whitespaces), nil) }
                            .buttonStyle(.borderedProminent)
                            .disabled(sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .disabled(sending)
                }
            }
        }
        .padding(12)
        .background(Color.waiting.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.waiting.opacity(0.45)))
    }
}

/// Option buttons that wrap onto new lines.
private struct FlowButtons: View {
    let options: [String]
    let action: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(options, id: \.self) { o in Button(o) { action(o) }.buttonStyle(.bordered) }
    }
}

/// A message on its way to mobd: shown at once, dimmed, until mobd's copy replaces it.
struct OutgoingMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.accentColor.opacity(0.6), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18))
            Label("Sending…", systemImage: "arrow.up.circle").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .accessibilityLabel("Sending: \(text)")
    }
}

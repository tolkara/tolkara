import SwiftUI

enum CheckStatus {
    case ok, warning, failed, checking, waiting

    @ViewBuilder var icon: some View {
        switch self {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .checking: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ok: "Done"
        case .warning: "Needs attention"
        case .failed: "Not done"
        case .checking: "Checking"
        case .waiting: "Waiting"
        }
    }
}

/// One verified requirement: what it is, what we found, and how to fix it.
struct CheckRow<Accessory: View>: View {
    var title: String
    var detail: String?
    var status: CheckStatus
    @ViewBuilder var accessory: Accessory

    init(_ title: String, detail: String? = nil, status: CheckStatus, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.status = status
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            status.icon
                .frame(width: 18)
                .accessibilityLabel(status.accessibilityLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension CheckRow where Accessory == EmptyView {
    init(_ title: String, detail: String? = nil, status: CheckStatus) {
        self.init(title, detail: detail, status: status) { EmptyView() }
    }
}

/// A coloured note for something the user should know or do.
struct Callout<Actions: View>: View {
    enum Kind { case info, warning, error, success }
    var kind: Kind
    var title: String
    var message: String?
    @ViewBuilder var actions: Actions

    init(_ kind: Kind, _ title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions()
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.seal.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

extension Callout where Actions == EmptyView {
    init(_ kind: Kind, _ title: String, message: String? = nil) {
        self.init(kind, title, message: message) { EmptyView() }
    }
}

/// Short numbered instructions.
struct NumberedSteps: View {
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(.init(step))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The page for one setup step: a title, what the step is for, its content
/// and the Back and Continue buttons.
struct StepPage<Content: View>: View {
    @Environment(SetupModel.self) private var model
    var step: SetupStep
    var summary: String
    var continueTitle = "Continue"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(step.title, systemImage: step.symbol)
                            .font(.largeTitle.weight(.semibold))
                            .labelStyle(.titleOnly)
                            .accessibilityAddTraits(.isHeader)
                        Text(summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let job = model.job, job.isRunning {
                    ProgressView().controlSize(.small)
                    Text(job.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let previous = model.previous {
                    Button("Back") { model.selection = previous }
                        .keyboardShortcut("[", modifiers: .command)
                }
                if let next = model.next {
                    Button(continueTitle) { model.goNext() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(model.isComplete(step) || step == .welcome) || model.job?.isRunning == true)
                        .help(model.isComplete(step) || step == .welcome ? "Go to \(next.title)" : "Finish this step first")
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

/// A running or finished job: what it is doing, what the user should do,
/// and, if it failed, why and how to fix it.
struct JobPanel: View {
    @Environment(SetupModel.self) private var model
    var job: Job
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.isRunning {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.phase).font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: job.started, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(job.started)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView().progressViewStyle(.linear)
                if let detail = job.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let hint = job.hint {
                    Label(hint, systemImage: "hand.point.up.left")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Stop", role: .cancel) { model.cancelJob() }
                }
            } else if let failure = job.failure {
                Callout(.error, job.diagnosis?.title ?? "\(job.title) did not finish",
                        message: job.diagnosis?.advice ?? (failure == "Stopped." ? "You stopped it. You can start again at any time." : failure)) {
                    if let step = job.diagnosis?.step, step != model.selection {
                        Button("Go to \(step.title)") { model.selection = step }
                    }
                }
            } else {
                Callout(.success, job.phase)
            }
            if !job.lines.isEmpty || job.failure != nil {
                DisclosureGroup("Details", isExpanded: $showLog) {
                    VStack(alignment: .trailing) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(job.output.isEmpty ? (job.failure ?? "") : job.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("log")
                            }
                            .frame(height: 160)
                            .onChange(of: job.lines.count) { proxy.scrollTo("log", anchor: .bottom) }
                        }
                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.output + (job.failure.map { "\n\($0)" } ?? ""), forType: .string)
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// A grouped form inside a step page: aligned with the page's other
    /// content and as tall as its rows, since the page itself scrolls.
    func pageForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            // A grouped form insets its sections by 20 points on each side.
            .padding(.horizontal, -20)
            .padding(.vertical, -12)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

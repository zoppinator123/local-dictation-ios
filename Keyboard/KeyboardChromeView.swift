import UIKit

final class KeyboardChromeView: UIView {
    var onMicDown: (() -> Void)?
    var onMicUp: (() -> Void)?
    var onMicTap: (() -> Void)?
    var onKey: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onNextKeyboard: (() -> Void)?
    var onOpenApp: (() -> Void)?

    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let stack = UIStackView()
    private var shifted = false
    private var holdToTalk = true
    private let letterRows = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "Tap the mic and speak"
        stack.addArrangedSubview(statusLabel)

        micButton.setImage(UIImage(systemName: "mic.circle.fill"), for: .normal)
        micButton.tintColor = .systemRed
        micButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        micButton.setTitle("  Hold to talk", for: .normal)
        micButton.addTarget(self, action: #selector(micDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        micButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stack.addArrangedSubview(micButton)

        for (index, row) in letterRows.enumerated() {
            stack.addArrangedSubview(makeLetterRow(row, includeShift: index == 2, includeDelete: index == 2))
        }
        stack.addArrangedSubview(makeBottomRow())
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ snapshot: KeyboardSnapshot, holdToTalk: Bool) {
        self.holdToTalk = holdToTalk
        statusLabel.text = snapshot.lastTranscript ?? snapshot.status
        micButton.tintColor = snapshot.phase == .recording ? .systemGreen : .systemRed
        let title: String
        switch snapshot.phase {
        case .recording: title = "  Listening…"
        case .transcribing: title = "  Transcribing…"
        case .needsSetup, .error: title = "  Setup"
        default: title = holdToTalk ? "  Hold to talk" : "  Tap to talk"
        }
        micButton.setTitle(title, for: .normal)
    }

    func setPartial(_ text: String) {
        statusLabel.text = text
    }

    @objc private func micDown() {
        if holdToTalk { onMicDown?() } else { onMicTap?() }
    }

    @objc private func micUp() {
        if holdToTalk { onMicUp?() }
    }

    private func makeLetterRow(_ letters: [String], includeShift: Bool, includeDelete: Bool) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.distribution = .fillEqually
        if includeShift {
            row.addArrangedSubview(actionButton("⇧") { [weak self] in
                self?.shifted.toggle()
                self?.reloadLetters()
            })
        }
        for letter in letters {
            let button = UIButton(type: .system)
            button.setTitle(letter, for: .normal)
            button.backgroundColor = .systemBackground
            button.layer.cornerRadius = 6
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let value = self.shifted ? letter.uppercased() : letter
                self.onKey?(value)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        if includeDelete {
            row.addArrangedSubview(actionButton("⌫") { [weak self] in self?.onDelete?() })
        }
        return row
    }

    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.distribution = .fill
        row.addArrangedSubview(actionButton("🌐") { [weak self] in self?.onNextKeyboard?() })
        row.addArrangedSubview(actionButton("123") { [weak self] in self?.onKey?("1") })
        let space = actionButton("space") { [weak self] in self?.onSpace?() }
        row.addArrangedSubview(space)
        row.addArrangedSubview(actionButton("return") { [weak self] in self?.onReturn?() })
        row.addArrangedSubview(actionButton("App") { [weak self] in self?.onOpenApp?() })
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return row
    }

    private func actionButton(_ title: String, handler: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 6
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    private func reloadLetters() {
        // Titles on letter buttons update on next apply; shift applies at insert time.
    }
}

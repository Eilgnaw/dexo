import PhotosUI
import UIKit

/// Markdown editor for composing a private message. Used from the user profile
/// (no prefill) and from a topic's avatar entry (subject + body link prefilled
/// to mirror the web "message user about this topic" flow). Mirrors
/// `ReplyComposerViewController`'s Markdown toolbar / emoji / image plumbing,
/// with a recipient header and a subject field on top.
final class MessageComposerViewController: BaseViewController {
    private let api: DiscourseAPI
    private let recipients: String
    private let prefillTitle: String?
    private let prefillBody: String?
    /// Called after the message is sent successfully (e.g. to show a toast).
    var onSent: (() -> Void)?

    private var isEmojiPickerVisible = false
    private var hasLoadedEmojiCatalog = false

    // MARK: - UI

    private let recipientLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subjectField: UITextField = {
        let tf = UITextField()
        tf.placeholder = String(localized: "message.compose.subject_placeholder")
        tf.font = FontManager.shared.font(size: 17, weight: .semibold)
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.returnKeyType = .next
        return tf
    }()

    private let bodyTextView: UITextView = {
        let tv = UITextView()
        tv.font = FontManager.shared.font(size: 16)
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        return tv
    }()

    private let bodyPlaceholder: UILabel = {
        let label = UILabel()
        label.text = String(localized: "message.compose.body_placeholder")
        label.font = FontManager.shared.font(size: 16)
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var markdownToolbar: MarkdownToolbarView = {
        let toolbar = MarkdownToolbarView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        toolbar.onAction = { [weak self] action in
            self?.handleToolbarAction(action)
        }
        return toolbar
    }()

    private lazy var emojiPickerInputView: EmojiPickerView = {
        let picker = EmojiPickerView(
            forumIdentifier: api.baseURL,
            frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 300)
        )
        picker.autoresizingMask = .flexibleWidth
        picker.onEmojiSelected = { [weak self] emoji in
            self?.insertText(emoji)
        }
        picker.onDeleteBackward = { [weak self] in
            self?.bodyTextView.deleteBackward()
        }
        picker.onPresentSearch = { [weak self] controller in
            self?.present(controller, animated: true)
        }
        picker.onSearchFinished = { [weak self] in
            guard let self, self.isEmojiPickerVisible else { return }
            self.bodyTextView.inputView = self.emojiPickerInputView
            self.bodyTextView.reloadInputViews()
            self.bodyTextView.becomeFirstResponder()
        }
        return picker
    }()

    private lazy var sendButton: UIBarButtonItem = {
        UIBarButtonItem(title: String(localized: "message.compose.send"), style: .done, target: self, action: #selector(sendTapped))
    }()

    private lazy var sendSpinner: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    private func makeSeparator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    // MARK: - Init

    init(api: DiscourseAPI, recipients: String, prefillTitle: String? = nil, prefillBody: String? = nil) {
        self.api = api
        self.recipients = recipients
        self.prefillTitle = prefillTitle
        self.prefillBody = prefillBody
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "message.compose.title")

        let cancelItem = UIBarButtonItem(title: String(localized: "action.cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.leftBarButtonItem = cancelItem
        navigationItem.rightBarButtonItem = sendButton

        recipientLabel.text = String(localized: "message.compose.recipient \(recipients)")
        recipientLabel.textColor = .label
        setupLayout()

        subjectField.delegate = self
        bodyTextView.delegate = self
        bodyTextView.inputAccessoryView = markdownToolbar

        // Prefill (topic entry): subject = topic title, body = topic link.
        if let prefillTitle { subjectField.text = prefillTitle }
        if let prefillBody {
            bodyTextView.text = prefillBody
            bodyPlaceholder.isHidden = !prefillBody.isEmpty
        }
        updateSendButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Land focus where the user still needs to type: an empty subject first,
        // otherwise the body (prefilled topic case).
        if (subjectField.text ?? "").isEmpty {
            subjectField.becomeFirstResponder()
        } else {
            // Drop the cursor at the end (after the prefilled topic link) so the
            // user types their message below it.
            bodyTextView.selectedRange = NSRange(location: bodyTextView.text.count, length: 0)
            bodyTextView.becomeFirstResponder()
        }
    }

    // MARK: - Layout

    private func setupLayout() {
        let sep1 = makeSeparator()
        let sep2 = makeSeparator()

        let recipientRow = UIView()
        recipientRow.translatesAutoresizingMaskIntoConstraints = false
        recipientRow.addSubview(recipientLabel)
        NSLayoutConstraint.activate([
            recipientRow.heightAnchor.constraint(equalToConstant: 44),
            recipientLabel.leadingAnchor.constraint(equalTo: recipientRow.leadingAnchor, constant: 16),
            recipientLabel.trailingAnchor.constraint(equalTo: recipientRow.trailingAnchor, constant: -16),
            recipientLabel.centerYAnchor.constraint(equalTo: recipientRow.centerYAnchor),
        ])

        let headerStack = UIStackView(arrangedSubviews: [
            recipientRow, sep1,
            subjectField, sep2,
        ])
        headerStack.axis = .vertical
        headerStack.spacing = 0
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(bodyTextView)
        view.addSubview(bodyPlaceholder)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            subjectField.heightAnchor.constraint(equalToConstant: 48),
            subjectField.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor, constant: 16),
            subjectField.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor, constant: -16),

            bodyTextView.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            bodyTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyTextView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            bodyPlaceholder.topAnchor.constraint(equalTo: bodyTextView.topAnchor, constant: 12),
            bodyPlaceholder.leadingAnchor.constraint(equalTo: bodyTextView.leadingAnchor, constant: 13),
        ])
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        let title = (subjectField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = bodyTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !raw.isEmpty else { return }

        navigationItem.rightBarButtonItem = sendSpinner
        bodyTextView.isEditable = false
        subjectField.isEnabled = false

        Task {
            do {
                _ = try await api.createPrivateMessage(targetRecipients: recipients, title: title, raw: raw)
                dismiss(animated: true) { [weak self] in
                    self?.onSent?()
                }
            } catch {
                navigationItem.rightBarButtonItem = sendButton
                bodyTextView.isEditable = true
                subjectField.isEnabled = true
                updateSendButton()
                if handleCloudflareChallengeIfNeeded(error: error, on: api) {
                    return
                }
                let alert = UIAlertController(
                    title: String(localized: "message.compose.send.failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    // MARK: - Toolbar Actions

    private func handleToolbarAction(_ action: MarkdownAction) {
        switch action {
        case .bold:
            wrapSelection(prefix: "**", suffix: "**")
        case .italic:
            wrapSelection(prefix: "_", suffix: "_")
        case .heading:
            prependToCurrentLine("## ")
        case .link:
            insertLinkTemplate()
        case .bulletList:
            prependToCurrentLine("- ")
        case .quote:
            prependToCurrentLine("> ")
        case .code:
            insertCode()
        case .pickImage:
            presentImagePicker()
        case .toggleEmoji:
            toggleEmojiPicker()
        }
    }

    // MARK: - Markdown Helpers

    private func wrapSelection(prefix: String, suffix: String) {
        guard let range = bodyTextView.selectedTextRange else { return }
        let selected = bodyTextView.text(in: range) ?? ""
        let replacement = prefix + selected + suffix
        bodyTextView.replace(range, withText: replacement)
        if selected.isEmpty {
            if let newPos = bodyTextView.position(from: range.start, offset: prefix.count) {
                bodyTextView.selectedTextRange = bodyTextView.textRange(from: newPos, to: newPos)
            }
        }
        textViewDidChange(bodyTextView)
    }

    private func prependToCurrentLine(_ prefix: String) {
        let text = bodyTextView.text ?? ""
        let nsRange = bodyTextView.selectedRange
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: nsRange.location, length: 0))
        let mutable = NSMutableString(string: text)
        mutable.insert(prefix, at: lineRange.location)
        bodyTextView.text = mutable as String
        bodyTextView.selectedRange = NSRange(location: nsRange.location + prefix.count, length: 0)
        textViewDidChange(bodyTextView)
    }

    private func insertLinkTemplate() {
        guard let range = bodyTextView.selectedTextRange else { return }
        let selected = bodyTextView.text(in: range) ?? ""
        if selected.isEmpty {
            bodyTextView.replace(range, withText: "[](url)")
            if let newPos = bodyTextView.position(from: range.start, offset: 1) {
                bodyTextView.selectedTextRange = bodyTextView.textRange(from: newPos, to: newPos)
            }
        } else {
            let replacement = "[\(selected)](url)"
            bodyTextView.replace(range, withText: replacement)
            if let urlStart = bodyTextView.position(from: range.start, offset: selected.count + 3),
               let urlEnd = bodyTextView.position(from: urlStart, offset: 3) {
                bodyTextView.selectedTextRange = bodyTextView.textRange(from: urlStart, to: urlEnd)
            }
        }
        textViewDidChange(bodyTextView)
    }

    private func insertCode() {
        guard let range = bodyTextView.selectedTextRange else { return }
        let selected = bodyTextView.text(in: range) ?? ""
        if selected.contains("\n") {
            bodyTextView.replace(range, withText: "```\n\(selected)\n```")
        } else {
            wrapSelection(prefix: "`", suffix: "`")
        }
    }

    private func insertText(_ text: String) {
        guard let range = bodyTextView.selectedTextRange else {
            bodyTextView.text.append(text)
            textViewDidChange(bodyTextView)
            return
        }
        var padded = text
        if let before = bodyTextView.position(from: range.start, offset: -1),
           let beforeRange = bodyTextView.textRange(from: before, to: range.start),
           let prev = bodyTextView.text(in: beforeRange),
           let ch = prev.last, !ch.isWhitespace && !ch.isNewline {
            padded = " " + padded
        }
        if let after = bodyTextView.position(from: range.end, offset: 1),
           let afterRange = bodyTextView.textRange(from: range.end, to: after),
           let next = bodyTextView.text(in: afterRange),
           let ch = next.first, !ch.isWhitespace && !ch.isNewline {
            padded = padded + " "
        }
        bodyTextView.replace(range, withText: padded)
        textViewDidChange(bodyTextView)
    }

    // MARK: - Emoji Picker

    private func toggleEmojiPicker() {
        isEmojiPickerVisible.toggle()
        if isEmojiPickerVisible {
            bodyTextView.inputView = emojiPickerInputView
            loadEmojiCatalog()
        } else {
            bodyTextView.inputView = nil
        }
        markdownToolbar.updateEmojiButtonIcon(isEmojiVisible: isEmojiPickerVisible)
        bodyTextView.reloadInputViews()
        if !bodyTextView.isFirstResponder {
            bodyTextView.becomeFirstResponder()
        }
    }

    private func loadEmojiCatalog() {
        guard !hasLoadedEmojiCatalog else { return }
        hasLoadedEmojiCatalog = true
        emojiPickerInputView.showLoading()
        Task {
            let groups = await api.fetchEmojiCatalog()
            emojiPickerInputView.setEmojiCatalog(groups)
        }
    }

    // MARK: - Image Upload

    private func presentImagePicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func uploadImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let filename = "image_\(Int(Date().timeIntervalSince1970)).jpg"

        let placeholder = "[" + String(localized: "compose.uploading") + "]"
        let insertRange = bodyTextView.selectedTextRange ?? bodyTextView.textRange(
            from: bodyTextView.endOfDocument, to: bodyTextView.endOfDocument
        )!
        bodyTextView.replace(insertRange, withText: placeholder)
        textViewDidChange(bodyTextView)

        bodyTextView.isEditable = false
        bodyTextView.textColor = .placeholderText

        Task {
            do {
                let response = try await api.uploadImage(data: data, filename: filename)
                let markdown = "![\(response.originalFilename)](\(response.shortUrl))"
                if let range = (bodyTextView.text as NSString?)?.range(of: placeholder),
                   range.location != NSNotFound {
                    let mutable = NSMutableString(string: bodyTextView.text)
                    mutable.replaceCharacters(in: range, with: markdown)
                    bodyTextView.text = mutable as String
                }
                textViewDidChange(bodyTextView)
            } catch {
                if let range = (bodyTextView.text as NSString?)?.range(of: placeholder),
                   range.location != NSNotFound {
                    let mutable = NSMutableString(string: bodyTextView.text)
                    mutable.deleteCharacters(in: range)
                    bodyTextView.text = mutable as String
                }
                textViewDidChange(bodyTextView)
                let alert = UIAlertController(
                    title: String(localized: "compose.upload.failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
            bodyTextView.isEditable = true
            bodyTextView.textColor = .label
        }
    }

    // MARK: - State

    private func updateSendButton() {
        let hasSubject = !(subjectField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !bodyTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasSubject && hasBody
    }
}

// MARK: - UITextFieldDelegate

extension MessageComposerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === subjectField {
            bodyTextView.becomeFirstResponder()
        }
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // Defer so `text` reflects the edit before we re-evaluate the send button.
        DispatchQueue.main.async { [weak self] in self?.updateSendButton() }
        return true
    }
}

// MARK: - UITextViewDelegate

extension MessageComposerViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        bodyPlaceholder.isHidden = !textView.text.isEmpty
        updateSendButton()
    }
}

// MARK: - PHPickerViewControllerDelegate

extension MessageComposerViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage else { return }
            Task { @MainActor in
                self.uploadImage(image)
            }
        }
    }
}

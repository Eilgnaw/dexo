import PhotosUI
import UIKit

final class TopicComposerViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: TopicComposerViewModel
    var onTopicCreated: ((Int) -> Void)?
    var onTopicUpdated: (() -> Void)?
    private var didNotifyTopicUpdated = false

    private var isEmojiPickerVisible = false
    private var hasLoadedEmojiCatalog = false

    // MARK: - UI Elements

    private let titleField: UITextField = {
        let tf = UITextField()
        tf.placeholder = String(localized: "compose.title.placeholder")
        tf.font = FontManager.shared.font(size: 17, weight: .semibold)
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.returnKeyType = .next
        return tf
    }()

    private let categoryButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "compose.category.select")
        config.image = UIImage(systemName: "folder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = FontManager.shared.font(size: 15, weight: .medium)
            return a
        }
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        return button
    }()

    private let tagField: UITextField = {
        let tf = UITextField()
        tf.placeholder = String(localized: "compose.tags.placeholder")
        tf.font = FontManager.shared.font(size: 15)
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.returnKeyType = .done
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        return tf
    }()

    private let tagIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "tag", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)))
        iv.tintColor = .secondaryLabel
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setContentHuggingPriority(.required, for: .horizontal)
        return iv
    }()

    private let tagChipsContainer: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.spacing = 6
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var tagSuggestionsBackdrop: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private lazy var tagSuggestionsScroll: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
        return sv
    }()

    private lazy var tagSuggestionsStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.spacing = 6
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var tagSuggestionsDoneButton: UIButton = {
        let button = UIButton(type: .system)
        let img = UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        )
        button.setImage(img, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.addTarget(self, action: #selector(dismissTagField), for: .touchUpInside)
        return button
    }()

    private var tagSearchDebounceTask: Task<Void, Never>?
    /// Category id from a restored draft waiting for `loadCategories()` to finish
    /// so we can resolve it to the concrete `DiscourseCategory`.
    private var pendingDraftCategoryId: Int?

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
        label.text = String(localized: "compose.body.placeholder")
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
        let title = viewModel.isEditing
            ? String(localized: "action.save")
            : String(localized: "compose.send")
        return UIBarButtonItem(title: title, style: .done, target: self, action: #selector(sendTapped))
    }()

    private lazy var sendSpinner: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    private lazy var uploadOverlay: UIView = {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        overlay.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        return overlay
    }()

    private func makeSeparator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    // MARK: - Init

    init(api: DiscourseAPI, mode: TopicComposerMode = .create) {
        self.api = api
        self.viewModel = TopicComposerViewModel(api: api, mode: mode)
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(
        api: DiscourseAPI,
        editing topic: DiscourseTopicDetail,
        post: DiscourseTopicDetail.Post
    ) {
        self.init(api: api, mode: .edit(topic: topic, post: post))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = viewModel.isEditing
            ? String(localized: "edit.topic.title")
            : String(localized: "compose.title")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "action.cancel"), style: .plain,
            target: self, action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = sendButton

        setupLayout()

        titleField.delegate = self
        tagField.delegate = self
        bodyTextView.delegate = self
        bodyTextView.inputAccessoryView = markdownToolbar

        titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        tagField.addTarget(self, action: #selector(tagFieldChanged), for: .editingChanged)

        if viewModel.isEditing {
            titleField.text = viewModel.title
            bodyTextView.text = viewModel.body
            bodyPlaceholder.isHidden = !viewModel.body.isEmpty
        } else {
            restoreDraftIfAny()
        }

        Task {
            await viewModel.loadCategories()
            // Resolve the category the draft was composed against once categories are available.
            if let id = pendingDraftCategoryId, let match = viewModel.findCategory(id: id) {
                viewModel.selectedCategory = match
            }
            pendingDraftCategoryId = nil
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if viewModel.isEditing {
            navigationController?.presentationController?.delegate = self
        }
        titleField.becomeFirstResponder()
    }

    // MARK: - Layout

    private func setupLayout() {
        let sep1 = makeSeparator()
        let sep2 = makeSeparator()
        let sep3 = makeSeparator()

        let tagRow = makeTagRow()

        let headerStack = UIStackView(arrangedSubviews: [
            titleField, sep1,
            categoryButton, sep2,
            tagRow, sep3,
        ])
        headerStack.axis = .vertical
        headerStack.spacing = 0
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(bodyTextView)
        view.addSubview(bodyPlaceholder)
        view.addSubview(uploadOverlay)
        view.addSubview(tagSuggestionsBackdrop)
        view.addSubview(tagSuggestionsScroll)
        view.addSubview(tagSuggestionsDoneButton)
        tagSuggestionsScroll.addSubview(tagSuggestionsStack)

        let titleHeight: CGFloat = 48
        let rowHeight: CGFloat = 44
        let suggestionsHeight: CGFloat = 32

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            titleField.heightAnchor.constraint(equalToConstant: titleHeight),
            titleField.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor, constant: -16),

            categoryButton.heightAnchor.constraint(equalToConstant: rowHeight),

            bodyTextView.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            bodyTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyTextView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            uploadOverlay.topAnchor.constraint(equalTo: bodyTextView.topAnchor),
            uploadOverlay.leadingAnchor.constraint(equalTo: bodyTextView.leadingAnchor),
            uploadOverlay.trailingAnchor.constraint(equalTo: bodyTextView.trailingAnchor),
            uploadOverlay.bottomAnchor.constraint(equalTo: bodyTextView.bottomAnchor),

            bodyPlaceholder.topAnchor.constraint(equalTo: bodyTextView.topAnchor, constant: 12),
            bodyPlaceholder.leadingAnchor.constraint(equalTo: bodyTextView.leadingAnchor, constant: 13),

            tagSuggestionsBackdrop.topAnchor.constraint(equalTo: tagRow.bottomAnchor),
            tagSuggestionsBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tagSuggestionsBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tagSuggestionsBackdrop.bottomAnchor.constraint(equalTo: tagSuggestionsScroll.bottomAnchor, constant: 6),

            tagSuggestionsScroll.topAnchor.constraint(equalTo: tagRow.bottomAnchor, constant: 4),
            tagSuggestionsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tagSuggestionsScroll.trailingAnchor.constraint(equalTo: tagSuggestionsDoneButton.leadingAnchor, constant: -8),
            tagSuggestionsScroll.heightAnchor.constraint(equalToConstant: suggestionsHeight),

            tagSuggestionsStack.topAnchor.constraint(equalTo: tagSuggestionsScroll.topAnchor),
            tagSuggestionsStack.leadingAnchor.constraint(equalTo: tagSuggestionsScroll.leadingAnchor),
            tagSuggestionsStack.trailingAnchor.constraint(equalTo: tagSuggestionsScroll.trailingAnchor),
            tagSuggestionsStack.bottomAnchor.constraint(equalTo: tagSuggestionsScroll.bottomAnchor),
            tagSuggestionsStack.heightAnchor.constraint(equalTo: tagSuggestionsScroll.heightAnchor),

            tagSuggestionsDoneButton.centerYAnchor.constraint(equalTo: tagSuggestionsScroll.centerYAnchor),
            tagSuggestionsDoneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tagSuggestionsDoneButton.widthAnchor.constraint(equalToConstant: 32),
            tagSuggestionsDoneButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func makeTagRow() -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(tagChipsContainer)

        row.addSubview(tagIcon)
        row.addSubview(scrollView)
        row.addSubview(tagField)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 44),
            tagIcon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            tagIcon.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: tagIcon.trailingAnchor, constant: 8),
            scrollView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 28),

            tagChipsContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            tagChipsContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            tagChipsContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            tagChipsContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            tagChipsContainer.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

            tagField.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 4),
            tagField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            tagField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            tagField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        // Let chips scroll shrink when no chips
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tagField.setContentCompressionResistancePriority(.required, for: .horizontal)

        return row
    }

    // MARK: - updateUI (ObservableViewController)

    override func updateUI() {
        sendButton.isEnabled = viewModel.canSubmit
        categoryButton.menu = UIMenu(title: "", children: buildCategoryMenuElements())
        updateCategoryButton()
        bodyPlaceholder.isHidden = !bodyTextView.text.isEmpty
        updateTagSuggestions()
        rebuildTagChips()
        let theme = ThemeManager.shared
        uploadOverlay.backgroundColor = theme.cardBackgroundColor.withAlphaComponent(0.82)
        view.backgroundColor = theme.cardBackgroundColor
    }

    // MARK: - Category Menu

    private func buildCategoryMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        for cat in viewModel.categories {
            let state: UIMenuElement.State = viewModel.selectedCategory?.id == cat.id ? .on : .off
            let catColor = Self.color(fromHex: cat.color)
            let catImage = Self.colorDotImage(color: catColor)
            let catAction = UIAction(title: cat.name, image: catImage, state: state) { [weak self] _ in
                self?.viewModel.selectedCategory = cat
                self?.refreshTagSuggestionsIfNeeded()
            }
            if let subs = cat.subcategoryList, !subs.isEmpty {
                var groupChildren: [UIMenuElement] = [catAction]
                for sub in subs {
                    let subState: UIMenuElement.State = viewModel.selectedCategory?.id == sub.id ? .on : .off
                    let subColor = Self.color(fromHex: sub.color)
                    let subImage = Self.colorDotImage(color: subColor)
                    let subAction = UIAction(title: sub.name, image: subImage, state: subState) { [weak self] _ in
                        self?.viewModel.selectedCategory = sub
                        self?.refreshTagSuggestionsIfNeeded()
                    }
                    groupChildren.append(subAction)
                }
                elements.append(UIMenu(title: cat.name, image: catImage, children: groupChildren))
            } else {
                elements.append(catAction)
            }
        }
        return elements
    }

    private func updateCategoryButton() {
        var config = categoryButton.configuration ?? UIButton.Configuration.plain()
        if let cat = viewModel.selectedCategory {
            config.title = cat.name
            if let color = Self.color(fromHex: cat.color) {
                config.image = UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
                config.baseForegroundColor = color
            }
        } else {
            config.title = String(localized: "compose.category.select")
            config.image = UIImage(systemName: "folder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
            config.baseForegroundColor = .secondaryLabel
        }
        categoryButton.configuration = config
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        if viewModel.isEditing {
            guard viewModel.hasUnsavedChanges else {
                dismissAfterEdit()
                return
            }
            let alert = UIAlertController(
                title: String(localized: "edit.discard.title"),
                message: String(localized: "edit.discard.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: String(localized: "compose.discard.action"),
                style: .destructive
            ) { [weak self] _ in
                self?.dismissAfterEdit()
            })
            alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
            present(alert, animated: true)
            return
        }
        if viewModel.hasUnsavedChanges {
            let alert = UIAlertController(
                title: String(localized: "compose.discard.title"),
                message: String(localized: "compose.discard.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "compose.draft.save"), style: .default) { [weak self] _ in
                self?.viewModel.saveDraft()
                self?.dismiss(animated: true)
            })
            alert.addAction(UIAlertAction(title: String(localized: "compose.discard.action"), style: .destructive) { [weak self] _ in
                self?.viewModel.clearDraft()
                self?.dismiss(animated: true)
            })
            alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
            present(alert, animated: true)
        } else {
            viewModel.clearDraft()
            dismiss(animated: true)
        }
    }

    @objc private func sendTapped() {
        navigationItem.rightBarButtonItem = sendSpinner
        setFormEnabled(false)

        Task { [self] in
            do {
                let result = try await viewModel.submit()
                switch result {
                case .created(let topicId):
                    viewModel.clearDraft()
                    dismiss(animated: true) { [weak self] in
                        self?.onTopicCreated?(topicId)
                    }
                case .updated:
                    dismissAfterEdit()
                }
            } catch {
                // Auto-save so the user doesn't lose their post when the network flakes.
                if !viewModel.isEditing { viewModel.saveDraft() }
                navigationItem.rightBarButtonItem = sendButton
                setFormEnabled(true)
                sendButton.isEnabled = viewModel.canSubmit
                let underlyingError = (error as? TopicEditSaveError)?.underlyingError ?? error
                if presentChallengePromptIfNeeded(error: underlyingError, on: api) {
                    return
                }
                let partialSave = (error as? TopicEditSaveError)?.bodyWasSaved == true
                let failureTitle = viewModel.isEditing
                    ? String(localized: "edit.save.failed")
                    : String(localized: "compose.send.failed")
                let alert = UIAlertController(
                    title: partialSave
                        ? String(localized: "edit.topic.partial.title")
                        : failureTitle,
                    message: partialSave
                        ? String(localized: "edit.topic.partial.message \(underlyingError.localizedDescription)")
                        : underlyingError.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func setFormEnabled(_ enabled: Bool) {
        bodyTextView.isEditable = enabled
        titleField.isEnabled = enabled
        categoryButton.isEnabled = enabled
        tagField.isEnabled = enabled
    }

    private func dismissAfterEdit() {
        let callback = consumeTopicUpdatedCallback()
        dismiss(animated: true) {
            callback?()
        }
    }

    private func consumeTopicUpdatedCallback() -> (() -> Void)? {
        guard viewModel.hasServerChanges, !didNotifyTopicUpdated else { return nil }
        didNotifyTopicUpdated = true
        return onTopicUpdated
    }

    @objc private func titleChanged() {
        viewModel.title = titleField.text ?? ""
    }

    @objc private func dismissTagField() {
        tagField.resignFirstResponder()
    }

    @objc private func tagFieldChanged() {
        let query = tagField.text ?? ""
        tagSearchDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // With a category selected we always query (empty q returns top-5 tags for that category);
        // without one we only search after the user types something.
        if trimmed.isEmpty, viewModel.selectedCategory == nil {
            viewModel.tagSuggestions = []
            return
        }
        tagSearchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.searchTags(query: query)
        }
    }

    private func refreshTagSuggestionsIfNeeded() {
        guard tagField.isFirstResponder else { return }
        tagSearchDebounceTask?.cancel()
        let query = tagField.text ?? ""
        tagSearchDebounceTask = Task {
            await viewModel.searchTags(query: query)
        }
    }

    // MARK: - Draft

    private func restoreDraftIfAny() {
        guard let draft = viewModel.loadDraft() else { return }
        viewModel.title = draft.title
        viewModel.body = draft.body
        viewModel.selectedTags = draft.tags
        // The UI fields aren't observable — populate them directly.
        titleField.text = draft.title
        bodyTextView.text = draft.body
        bodyPlaceholder.isHidden = !draft.body.isEmpty
        // Category must wait until categories are fetched.
        pendingDraftCategoryId = draft.categoryId
    }

    // MARK: - Tag Chips & Suggestions

    private func rebuildTagChips() {
        tagChipsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tag in viewModel.selectedTags {
            let chip = makeTagChip(tag)
            tagChipsContainer.addArrangedSubview(chip)
        }
    }

    private func makeTagChip(_ tag: String) -> UIView {
        let container = UIView()
        container.backgroundColor = ThemeManager.shared.accentColor.withAlphaComponent(0.15)
        container.layer.cornerRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = tag
        label.font = FontManager.shared.font(size: 13, weight: .medium)
        label.textColor = ThemeManager.shared.accentColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        removeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        removeButton.tintColor = ThemeManager.shared.accentColor
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.addAction(UIAction { [weak self] _ in
            self?.removeTag(tag)
        }, for: .touchUpInside)

        container.addSubview(label)
        container.addSubview(removeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            removeButton.heightAnchor.constraint(equalToConstant: 18),
            container.heightAnchor.constraint(equalToConstant: 26),
        ])

        return container
    }

    private func removeTag(_ tag: String) {
        viewModel.selectedTags.removeAll { $0 == tag }
    }

    private func selectTag(_ tag: String) {
        guard !viewModel.selectedTags.contains(tag) else { return }
        viewModel.selectedTags.append(tag)
        tagField.text = ""
        // Keep the suggestions list open so the user can keep picking more tags.
        if viewModel.selectedCategory != nil {
            tagSearchDebounceTask?.cancel()
            tagSearchDebounceTask = Task { [weak self] in
                await self?.viewModel.searchTags(query: "")
            }
        } else {
            viewModel.tagSuggestions = []
        }
    }

    /// Suggestions with already-picked tags hidden, so tapping one never re-adds it
    /// and the list shrinks naturally as the user selects.
    private var displayedTagSuggestions: [DiscourseTag] {
        viewModel.tagSuggestions.filter { !viewModel.selectedTags.contains($0.text) }
    }

    private func updateTagSuggestions() {
        let tags = displayedTagSuggestions
        let hasSuggestions = !tags.isEmpty
        tagSuggestionsBackdrop.isHidden = !hasSuggestions
        tagSuggestionsScroll.isHidden = !hasSuggestions
        tagSuggestionsDoneButton.isHidden = !hasSuggestions
        tagSuggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard hasSuggestions else { return }
        for tag in tags {
            tagSuggestionsStack.addArrangedSubview(makeSuggestionChip(tag))
        }
        tagSuggestionsBackdrop.backgroundColor = ThemeManager.shared.cardBackgroundColor
        tagSuggestionsDoneButton.tintColor = ThemeManager.shared.accentColor
        view.bringSubviewToFront(tagSuggestionsBackdrop)
        view.bringSubviewToFront(tagSuggestionsScroll)
        view.bringSubviewToFront(tagSuggestionsDoneButton)
        tagSuggestionsScroll.contentOffset = .zero
    }

    private func makeSuggestionChip(_ tag: DiscourseTag) -> UIView {
        let accent = ThemeManager.shared.accentColor
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = tag.count > 0 ? "\(tag.text) · \(tag.count)" : tag.text
        config.baseForegroundColor = accent
        config.background.backgroundColor = accent.withAlphaComponent(0.10)
        config.background.strokeColor = accent.withAlphaComponent(0.30)
        config.background.strokeWidth = 0.5
        config.background.cornerRadius = 14
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = FontManager.shared.font(size: 13, weight: .medium)
            return a
        }
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in
            self?.selectTag(tag.text)
        }, for: .touchUpInside)
        return button
    }

    // MARK: - Markdown Toolbar

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

    private func wrapSelection(prefix: String, suffix: String) {
        guard let range = bodyTextView.selectedTextRange else { return }
        let selected = bodyTextView.text(in: range) ?? ""
        let replacement = prefix + selected + suffix
        bodyTextView.replace(range, withText: replacement)

        // Place cursor between prefix/suffix if no selection
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

        // Find the start of the current line
        let lineRange = nsText.lineRange(for: NSRange(location: nsRange.location, length: 0))
        let lineStart = lineRange.location

        // Insert prefix at line start
        let mutable = NSMutableString(string: text)
        mutable.insert(prefix, at: lineStart)
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
            // Select "url" for easy replacement
            if let urlStart = bodyTextView.position(from: range.start, offset: selected.count + 3),
               let urlEnd = bodyTextView.position(from: urlStart, offset: 3)
            {
                bodyTextView.selectedTextRange = bodyTextView.textRange(from: urlStart, to: urlEnd)
            }
        }
        textViewDidChange(bodyTextView)
    }

    private func insertCode() {
        guard let range = bodyTextView.selectedTextRange else { return }
        let selected = bodyTextView.text(in: range) ?? ""
        if selected.contains("\n") {
            let replacement = "```\n\(selected)\n```"
            bodyTextView.replace(range, withText: replacement)
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

        // Insert placeholder
        let placeholder = "[" + String(localized: "compose.uploading") + "]"
        let insertRange = bodyTextView.selectedTextRange ?? bodyTextView.textRange(
            from: bodyTextView.endOfDocument, to: bodyTextView.endOfDocument
        )!
        bodyTextView.replace(insertRange, withText: placeholder)
        textViewDidChange(bodyTextView)

        // Prevent edits while the upload is in flight so the placeholder stays intact.
        bodyTextView.isEditable = false
        bodyTextView.textColor = .placeholderText
        uploadOverlay.isHidden = false

        Task {
            do {
                let response = try await viewModel.uploadImage(data: data, filename: filename)
                let markdown = "![\(response.originalFilename)](\(response.shortUrl))"
                if let range = (bodyTextView.text as NSString?)?.range(of: placeholder),
                   range.location != NSNotFound
                {
                    let mutable = NSMutableString(string: bodyTextView.text)
                    mutable.replaceCharacters(in: range, with: markdown)
                    bodyTextView.text = mutable as String
                }
                viewModel.body = bodyTextView.text
                textViewDidChange(bodyTextView)
            } catch {
                // Remove placeholder on failure
                if let range = (bodyTextView.text as NSString?)?.range(of: placeholder),
                   range.location != NSNotFound
                {
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
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            bodyTextView.isEditable = true
            bodyTextView.textColor = .label
            uploadOverlay.isHidden = true
        }
    }

    // MARK: - Helpers

    private static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func colorDotImage(color: UIColor?) -> UIImage? {
        guard let color else { return nil }
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - UITextFieldDelegate

extension TopicComposerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === titleField {
            tagField.becomeFirstResponder()
        } else if textField === tagField {
            let text = (tagField.text ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                selectTag(text)
            }
            bodyTextView.becomeFirstResponder()
        }
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // When the tag field gains focus and a category is selected, prefetch
        // the top tags scoped to that category so the user can pick without typing.
        guard textField === tagField, viewModel.selectedCategory != nil else { return }
        refreshTagSuggestionsIfNeeded()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard textField === tagField else { return }
        tagSearchDebounceTask?.cancel()
        viewModel.tagSuggestions = []
    }
}

// MARK: - UITextViewDelegate

extension TopicComposerViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        viewModel.body = textView.text
        bodyPlaceholder.isHidden = !textView.text.isEmpty
    }
}

// MARK: - PHPickerViewControllerDelegate

extension TopicComposerViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage else { return }
            Task { @MainActor [weak self] in
                self?.uploadImage(image)
            }
        }
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension TopicComposerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !viewModel.isEditing || !viewModel.hasUnsavedChanges
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        cancelTapped()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        consumeTopicUpdatedCallback()?()
    }
}

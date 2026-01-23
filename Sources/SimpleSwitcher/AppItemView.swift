import Cocoa

protocol AppItemViewDelegate: AnyObject {
    func appItemHovered(_ view: AppItemView)
}

class AppItemView: NSView {
    weak var delegate: AppItemViewDelegate?

    let appInfo: AppInfo
    private let iconImageView: NSImageView
    private let nameLabel: NSTextField
    private var isSelected = false

    private let itemWidth: CGFloat = 80
    private let itemHeight: CGFloat = 100
    private let iconSize: CGFloat = 64

    init(appInfo: AppInfo) {
        self.appInfo = appInfo

        // Create icon view
        iconImageView = NSImageView()
        iconImageView.image = appInfo.icon
        iconImageView.imageScaling = .scaleProportionallyUpOrDown

        // Create name label
        nameLabel = NSTextField(labelWithString: appInfo.name)
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.textColor = .white
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2

        super.init(frame: NSRect(x: 0, y: 0, width: itemWidth, height: itemHeight))

        setupViews()
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8

        // Add icon
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        // Add label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            // Icon constraints
            iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),

            // Label constraints
            nameLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            // Self constraints
            widthAnchor.constraint(equalToConstant: itemWidth),
            heightAnchor.constraint(equalToConstant: itemHeight)
        ])
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        updateAppearance()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Mouse Tracking

    override func mouseEntered(with event: NSEvent) {
        delegate?.appItemHovered(self)
    }

    override func mouseExited(with event: NSEvent) {
        // Selection will be handled by delegate
    }
}

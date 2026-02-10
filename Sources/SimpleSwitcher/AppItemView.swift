import Cocoa

protocol AppItemViewDelegate: AnyObject {
    func appItemHovered(_ view: AppItemView)
}

class AppItemView: NSView {
    weak var delegate: AppItemViewDelegate?

    let appInfo: AppInfo
    private let iconImageView: NSImageView
    private var badgeView: NSView?
    private var badgeLabel: NSTextField?
    private var isSelected = false

    private let itemSize: CGFloat = 76
    private let iconSize: CGFloat = 76

    init(appInfo: AppInfo) {
        self.appInfo = appInfo

        // Create icon view
        iconImageView = NSImageView()
        iconImageView.image = appInfo.icon
        iconImageView.imageScaling = .scaleProportionallyUpOrDown

        super.init(frame: NSRect(x: 0, y: 0, width: itemSize, height: itemSize))

        setupViews()
        setupBadge()
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        if UserDefaults.standard.bool(forKey: "grayscaleIcons") {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(0, forKey: kCIInputSaturationKey)
            layer?.filters = [filter]
        }

        // Add icon
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            // Icon centered in view
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),

            // Self constraints
            widthAnchor.constraint(equalToConstant: itemSize),
            heightAnchor.constraint(equalToConstant: itemSize)
        ])
    }

    private func setupBadge() {
        guard let badgeText = appInfo.badge else { return }

        // Create badge background (red circle)
        let badgeSize: CGFloat = 20
        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeContainer.layer?.cornerRadius = badgeSize / 2
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)
        self.badgeView = badgeContainer

        // Create badge label
        let label = NSTextField(labelWithString: formatBadge(badgeText))
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(label)
        self.badgeLabel = label

        NSLayoutConstraint.activate([
            // Badge in top-right corner
            badgeContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeSize),
            badgeContainer.heightAnchor.constraint(equalToConstant: badgeSize),

            // Label centered in badge
            label.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: badgeContainer.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.trailingAnchor, constant: -4)
        ])
    }

    private func formatBadge(_ badge: String) -> String {
        // If it's a number greater than 99, show "99+"
        if let num = Int(badge), num > 99 {
            return "99+"
        }
        return badge
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

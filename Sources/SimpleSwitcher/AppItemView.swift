import Cocoa

protocol AppItemViewDelegate: AnyObject {
    func appItemHovered(_ view: AppItemView)
}

class AppItemView: NSView {
    weak var delegate: AppItemViewDelegate?

    let appInfo: AppInfo
    private let iconImageView: NSImageView
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

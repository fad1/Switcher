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

    private let itemSize: CGFloat
    private let iconSize: CGFloat

    init(appInfo: AppInfo, itemSize: CGFloat = 76) {
        self.appInfo = appInfo
        self.itemSize = itemSize
        self.iconSize = itemSize

        iconImageView = NSImageView()
        iconImageView.image = Preferences.grayscaleIcons
            ? AppItemView.desaturated(appInfo.icon, pointSize: itemSize)
            : appInfo.icon
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

        // Create badge background (red circle), scaled to icon size
        let badgeSize: CGFloat = max(20, itemSize * 0.26)
        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        // Grayscale badge must be an explicitly neutral gray: systemGray has a
        // blue cast (R152 G152 B157) that reads as a bluish blotch next to the
        // desaturated icons, most visibly on wide-gamut Retina displays.
        // 0.47 ≈ the luma the old whole-layer filter gave the red badge.
        badgeContainer.layer?.backgroundColor =
            (Preferences.grayscaleIcons
                ? NSColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1)
                : NSColor.systemRed).cgColor
        badgeContainer.layer?.cornerRadius = badgeSize / 2
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)
        self.badgeView = badgeContainer

        // Create badge label
        let label = NSTextField(labelWithString: formatBadge(badgeText))
        label.font = NSFont.systemFont(ofSize: max(11, itemSize * 0.145), weight: .bold)
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

    // Grayscale is baked into the icon image instead of using layer.filters:
    // a CI filter on the item's layer makes CA re-rasterize the icon+badge
    // group every time the selection highlight (backgroundColor on that same
    // layer) changes, and successive renders can pixel-snap differently —
    // visible as icons/badges subtly wobbling on hover, worst on 1x displays.
    //
    // The gray must be produced in an EXPLICIT colorspace (sRGB here), not via
    // .saturation blend modes or CI at draw time: those compute "equal RGB" in
    // the destination context's space, which for a window is the display's
    // device space — equal device-RGB is the panel's native white point, so on
    // wide-gamut Retina panels the grays came out bluish (unlike every other
    // color-managed gray on screen). A tagged-sRGB bitmap gets converted per
    // display like everything else. Reps at 1x and 2x keep Retina crisp.
    private static func desaturated(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [1, 2] {
            let px = Int(pointSize) * scale
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = CGContext(data: nil, width: px, height: px,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            if let data = cg.data {
                let buf = data.bindMemory(to: UInt8.self, capacity: cg.bytesPerRow * px)
                for y in 0..<px {
                    let row = buf + y * cg.bytesPerRow
                    for x in 0..<px {
                        let p = row + x * 4  // premultiplied RGBA
                        let luma = UInt8(min(255, (299 * Int(p[0]) + 587 * Int(p[1]) + 114 * Int(p[2])) / 1000))
                        p[0] = luma; p[1] = luma; p[2] = luma
                    }
                }
            }
            guard let outImage = cg.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: outImage)
            rep.size = NSSize(width: pointSize, height: pointSize)
            result.addRepresentation(rep)
        }
        return result.representations.isEmpty ? image : result
    }

    private func formatBadge(_ badge: String) -> String {
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
        guard selected != isSelected else { return }
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
        // Deliberately empty: selection persists once the pointer leaves an icon,
        // so moving through the gaps between icons doesn't clear the highlight.
    }
}

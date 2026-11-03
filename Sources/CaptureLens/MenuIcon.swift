import AppKit

/// Icons in menus. macOS 27 draws no menu item images, so an icon goes at the start of the
/// item's title instead, centered in a slot of fixed width so the titles of items with icons line up.
/// Kept for a menu's most-used items, which the icons set apart. The same file is in every app.
extension NSMenuItem {
    /// An SF Symbol at the menu's text size. It is a template, so it turns white with the text
    /// when the item is highlighted.
    @discardableResult
    func showIcon(_ symbol: String) -> NSMenuItem {
        let font = NSFont.menuFont(ofSize: 0)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)) else { return self }
        return showIcon(image)
    }

    /// Any picture (an app's icon, say), scaled down to fit the slot. The picture itself goes in
    /// the title, not a copy drawn into the slot, so a template still turns white when highlighted;
    /// spacing on both sides centers it in the slot.
    @discardableResult
    func showIcon(_ image: NSImage) -> NSMenuItem {
        let font = NSFont.menuFont(ofSize: 0)
        let side = (font.pointSize * 1.5).rounded()
        let scale = min(1, side / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let pad = (side - size.width) / 2
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        let title = NSMutableAttributedString(string: "\u{200B}", attributes: [.kern: pad])
        title.append(NSAttributedString(attachment: attachment))
        title.addAttribute(.kern, value: pad, range: NSRange(location: 1, length: 1))
        title.append(NSAttributedString(string: " " + plainTitle))
        title.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.length))
        attributedTitle = title
        // An image as well would show twice if menus draw images again.
        self.image = nil
        return self
    }

    /// The title without the icon (which reads as a space and an attachment character in `title`).
    var plainTitle: String { title.replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\u{FFFC} ", with: "") }

    /// The icon `showIcon` put in the title.
    var titleIcon: NSImage? {
        guard let title = attributedTitle, title.length > 1 else { return nil }
        return (title.attribute(.attachment, at: 1, effectiveRange: nil) as? NSTextAttachment)?.image
    }
}

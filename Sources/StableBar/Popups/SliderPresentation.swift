import AppKit

extension PopupBlock {
    func automaticallyFillsSlider(roles: [String: WidgetStyle]) -> Bool {
        guard case .slider = content, sliderFilled == nil, role == nil || role == .slider else { return false }
        return roles[PresentationRole.slider.rawValue].map { $0 != WidgetStyle() } ?? false
    }

    func effectiveRole(roles: [String: WidgetStyle]) -> PresentationRole? {
        automaticallyFillsSlider(roles: roles) ? .slider : role
    }
}

extension WidgetStyle {
    /// The bar owns its height. A theme's control height must fit inside its vertical padding.
    @MainActor var inlineControlHeight: Double {
        if let height {
            let top = paddingTop ?? paddingVertical ?? 6
            let bottom = paddingBottom ?? paddingVertical ?? 6
            return max(height - top - bottom, 1)
        }
        return lineHeight
    }

    /// A line of the style's text.
    @MainActor var lineHeight: Double {
        let size = fontSize ?? 13
        let font = fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    func limitingSliderHeight(to limit: Double?) -> WidgetStyle {
        guard let limit else { return self }
        var box = self
        let height = max(min(self.height ?? 28, limit), 1)
        let top = max(paddingTop ?? paddingVertical ?? 0, 0)
        let bottom = max(paddingBottom ?? paddingVertical ?? 0, 0)
        let scale = top + bottom > 0 ? min((height - 1) / (top + bottom), 1) : 1
        box.height = height
        box.paddingTop = top * scale
        box.paddingBottom = bottom * scale
        return box
    }
}

extension BlockStyle {
    func limitingSliderHeight(to limit: Double?) -> BlockStyle {
        BlockStyle(inherited: inherited, text: text, box: box.limitingSliderHeight(to: limit))
    }
}

extension Configuration {
    func usesSliderModeStates(_ widget: WidgetConfiguration) -> Bool {
        widget.layout == nil && providerType(of: widget) == "audio" && roleStyle(.slider).usesModeStates
    }
}

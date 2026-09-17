import CoreGraphics

public enum CanvasEdgePan {
    public static let defaultEdgeInset: CGFloat = 32
    public static let maximumSpeed: CGFloat = 760

    public static func horizontalInset(boundsWidth: CGFloat, edgeInset: CGFloat = defaultEdgeInset) -> CGFloat {
        min(edgeInset, boundsWidth * 0.25)
    }

    public static func verticalInset(boundsHeight: CGFloat, edgeInset: CGFloat = defaultEdgeInset) -> CGFloat {
        min(edgeInset, boundsHeight * 0.25)
    }

    /// Determines if a pointer position (in top-left coordinate system) falls within the edge panning trigger zone.
    public static func isPointerInEdgeZone(
        pointer: CGPoint,
        bounds: CGSize,
        edgeInset: CGFloat = defaultEdgeInset
    ) -> Bool {
        let hInset = horizontalInset(boundsWidth: bounds.width, edgeInset: edgeInset)
        let vInset = verticalInset(boundsHeight: bounds.height, edgeInset: edgeInset)
        guard hInset > 0, vInset > 0 else { return false }
        return pointer.x < hInset
            || (bounds.width - pointer.x) < hInset
            || pointer.y < vInset
            || (bounds.height - pointer.y) < vInset
    }
}

public enum CanvasSpacePan {
    public static let spaceKeyCode: UInt16 = 49

    /// Validates if a key event corresponds to a plain Space key press
    /// (disqualifying Command, Control, and Option to preserve shortcuts/IME toggles).
    public static func isPlainSpace(
        keyCode: UInt16,
        hasCommand: Bool,
        hasControl: Bool,
        hasOption: Bool
    ) -> Bool {
        keyCode == spaceKeyCode && !hasCommand && !hasControl && !hasOption
    }
}

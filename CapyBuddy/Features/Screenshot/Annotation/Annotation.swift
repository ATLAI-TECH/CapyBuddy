import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable, Hashable {
    case rectangle
    case rectangleDashed
    case ellipse
    case ellipseDashed
    case arrow
    case arrowLine
    case arrowDashed
    case line
    case pen
    case highlight
    case mosaic
    case text

    var id: String { rawValue }

    var iconSystemName: String {
        switch self {
        case .rectangle:        return "rectangle"
        case .rectangleDashed:  return "rectangle.dashed"
        case .ellipse:          return "circle"
        case .ellipseDashed:    return "circle.dashed"
        case .arrow:            return "arrowshape.right.fill"
        case .arrowLine:        return "arrow.up.right"
        case .arrowDashed:      return "arrow.up.right.and.arrow.down.left.rectangle"
        case .line:             return "line.diagonal"
        case .pen:              return "pencil.tip"
        case .highlight:        return "highlighter"
        case .mosaic:           return "square.grid.3x3.fill"
        case .text:             return "textformat"
        }
    }

    /// Single-word label used in popup menus (Snipaste-style).
    var menuLabel: String {
        switch self {
        case .rectangle:        return "Rect"
        case .rectangleDashed:  return "Dashed"
        case .ellipse:          return "Ellipse"
        case .ellipseDashed:    return "Dashed"
        case .arrow:            return "Solid"
        case .arrowLine:        return "Line"
        case .arrowDashed:      return "Dashed"
        case .line:             return "Plain"
        case .pen:              return "Pen"
        case .highlight:        return "Marker"
        case .mosaic:           return "Mosaic"
        case .text:             return "Text"
        }
    }

    /// Full hover-tooltip phrasing — describes the specific variant rather
    /// than just the parent group, so a user can tell at a glance whether
    /// the active arrow button is the solid one, the line one, etc.
    var tooltip: String {
        switch self {
        case .rectangle:        return "Rectangle"
        case .rectangleDashed:  return "Dashed rectangle"
        case .ellipse:          return "Ellipse"
        case .ellipseDashed:    return "Dashed ellipse"
        case .arrow:            return "Arrow"
        case .arrowLine:        return "Thin arrow"
        case .arrowDashed:      return "Dashed arrow"
        case .line:             return "Line"
        case .pen:              return "Pen"
        case .highlight:        return "Highlighter"
        case .mosaic:           return "Mosaic / blur"
        case .text:             return "Text"
        }
    }

    var group: ToolGroup {
        switch self {
        case .rectangle, .rectangleDashed,
             .ellipse, .ellipseDashed:                return .shape
        case .arrow, .arrowLine, .arrowDashed, .line: return .arrow
        case .pen, .highlight, .mosaic:               return .brush
        case .text:                                   return .text
        }
    }

    /// The arrow style this tool creates. Non-arrow tools return `.solid`
    /// (unused). Used by `ArrowTool` to draw and persist the right variant.
    var arrowStyle: ArrowStyle {
        switch self {
        case .arrow:       return .solid
        case .arrowLine:   return .line
        case .arrowDashed: return .dashed
        case .line:        return .plain
        default:           return .solid
        }
    }

    /// The shape outline style this tool creates. Non-shape tools return
    /// `.solid` (unused).
    var shapeStyle: ShapeStyle {
        switch self {
        case .rectangleDashed, .ellipseDashed: return .dashed
        default:                               return .solid
        }
    }

    /// Whether this tool has a working handler. Currently all are
    /// implemented; kept as the toolbar's filter knob so we can re-disable
    /// one behind a feature flag without ripping out call sites.
    var isAvailable: Bool { true }
}

/// Top-level grouping shown in the toolbar. Each group exposes a split-menu
/// button: clicking the icon activates the last-used member; clicking the
/// chevron picks a different member.
enum ToolGroup: String, CaseIterable, Identifiable, Hashable {
    case shape
    case arrow
    case brush
    case text

    var id: String { rawValue }

    var members: [AnnotationTool] {
        switch self {
        case .shape: return [.rectangle, .rectangleDashed, .ellipse, .ellipseDashed]
        case .arrow: return [.arrow, .arrowLine, .arrowDashed, .line]
        case .brush: return [.pen, .highlight, .mosaic]
        case .text:  return [.text]
        }
    }

    var help: String {
        switch self {
        case .shape: return "Shape"
        case .arrow: return "Arrow"
        case .brush: return "Brush"
        case .text:  return "Text"
        }
    }
}

/// Bold / italic / underline flags carried by a text annotation.
struct TextStyle: Equatable {
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false

    static let plain = TextStyle()
}

/// Visual variant for the arrow group.
/// - `solid`  : filled triangular head + thick shaft (default)
/// - `line`   : open chevron head + thin shaft
/// - `dashed` : filled triangular head + dashed shaft
/// - `plain`  : no head, just a straight line
enum ArrowStyle: String, Hashable {
    case solid
    case line
    case dashed
    case plain
}

/// Outline style for shape annotations (rectangle, ellipse).
enum ShapeStyle: String, Hashable {
    case solid
    case dashed
}

/// Geometry payload for an annotation. Each tool uses one variant.
enum AnnotationGeometry {
    case rectangle(NSRect, style: ShapeStyle)
    case ellipse(NSRect, style: ShapeStyle)
    case arrow(start: NSPoint, end: NSPoint, style: ArrowStyle)
    case pen(points: [NSPoint])
    case highlight(points: [NSPoint])
    case text(origin: NSPoint, string: String, style: TextStyle)
    case mosaic(points: [NSPoint], blockSize: CGFloat)
}

struct Annotation: Identifiable {
    let id: UUID
    let tool: AnnotationTool

    /// Bumped on every geometry / strokeWidth / color mutation. Used as a
    /// cache token so derived data (boundingBox, mosaic raster) can detect
    /// whether their snapshot is still fresh without an equality compare on
    /// the geometry payload.
    private(set) var generation: Int

    var geometry: AnnotationGeometry {
        didSet {
            generation &+= 1
            _cachedBoundingBox = nil
        }
    }
    var color: NSColor {
        didSet {
            generation &+= 1
            // Color affects text bbox via measurement → invalidate.
            _cachedBoundingBox = nil
        }
    }
    var strokeWidth: CGFloat {
        didSet {
            generation &+= 1
            _cachedBoundingBox = nil
        }
    }

    /// Lazily computed bounding box. Mutating any of {geometry, color,
    /// strokeWidth} invalidates this; accessors use the `Annotation`
    /// extension in `Selection.swift` which falls through to `_cachedBoundingBox`.
    /// Marked `internal` so the extension can populate it.
    var _cachedBoundingBox: NSRect?

    init(tool: AnnotationTool, geometry: AnnotationGeometry, color: NSColor, strokeWidth: CGFloat) {
        self.id = UUID()
        self.tool = tool
        self.geometry = geometry
        self.color = color
        self.strokeWidth = strokeWidth
        self.generation = 0
        self._cachedBoundingBox = nil
    }
}

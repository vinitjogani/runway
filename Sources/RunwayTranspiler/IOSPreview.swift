import SwiftParser
import SwiftSyntax

/// Selects the mobile branches of the sources Runway compiles for its host runtime.
public struct IOSPreview: Sendable {
    public let includingSimulatorCode: Bool

    public init(includingSimulatorCode: Bool = false) {
        self.includingSimulatorCode = includingSimulatorCode
    }

    public func rewriteConditions(in source: String) -> String {
        guard source.contains("#if"), source.contains("os") || source.contains("targetEnvironment") else { return source }
        let visitor = IOSConditionVisitor(includingSimulatorCode: includingSimulatorCode)
        visitor.walk(Parser.parse(source: source))
        guard !visitor.edits.isEmpty else { return source }
        return String(decoding: RunwayTranspiler.apply(visitor.edits, to: Array(source.utf8)), as: UTF8.self)
    }
}

private final class IOSConditionVisitor: SyntaxVisitor {
    var edits: [Edit] = []
    let includingSimulatorCode: Bool

    init(includingSimulatorCode: Bool) {
        self.includingSimulatorCode = includingSimulatorCode
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let condition = node.condition { rewrite(Syntax(condition)) }
        return .visitChildren
    }

    private func rewrite(_ node: Syntax) {
        if let call = node.as(FunctionCallExprSyntax.self),
           let function = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           call.arguments.count == 1, let argument = call.arguments.first, argument.label == nil,
           let platform = argument.expression.as(DeclReferenceExprSyntax.self)?.baseName.text {
            let value: String
            switch (function, platform) {
            case ("os", "iOS"): value = "true"
            case ("os", "macOS"), ("os", "OSX"): value = "false"
            case ("targetEnvironment", "simulator") where includingSimulatorCode: value = "true"
            default: return
            }
            let lineBreaks = call.trimmedDescription.filter(\.isNewline)
            // Keep a multiline condition inside parentheses so the next operator
            // still belongs to the same condition and source line numbers stay intact.
            let replacement = lineBreaks.isEmpty ? value : "(\(value)\(lineBreaks))"
            edits.append(Edit(start: call.positionAfterSkippingLeadingTrivia.utf8Offset,
                              end: call.endPositionBeforeTrailingTrivia.utf8Offset,
                              text: replacement, seq: 0))
            return
        }
        for child in node.children(viewMode: .sourceAccurate) { rewrite(child) }
    }
}

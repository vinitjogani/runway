// The Cassowary linear-arithmetic constraint solver (Badros, Borning and
// Stuckey), as the kiwi implementation structures it: an incremental dual
// simplex over a tableau of rows, with required constraints as hard
// equalities and non-required ones as weighted error terms minimized in
// the objective. Auto Layout is built on it.
//
// Iteration is in symbol order, so solutions are deterministic.

import Foundation

final class CassowarySolver {
    enum SolverError: Error { case unsatisfiable, duplicate, unknownConstraint, unknownEditVariable, duplicateEditVariable, internalError(String) }

    /// A variable the caller solves for.
    final class Variable: CustomStringConvertible {
        let name: String
        var value: Double = 0
        init(_ name: String) { self.name = name }
        var description: String { "\(name)=\(value)" }
    }

    struct Term { var variable: Variable; var coefficient: Double }

    /// Σ coefficient·variable + constant.
    struct Expression {
        var terms: [Term] = []
        var constant: Double = 0
        init(_ terms: [Term] = [], _ constant: Double = 0) { self.terms = terms; self.constant = constant }
        static func + (l: Expression, r: Expression) -> Expression { Expression(l.terms + r.terms, l.constant + r.constant) }
        static func - (l: Expression, r: Expression) -> Expression { l + r * -1 }
        static func * (l: Expression, k: Double) -> Expression { Expression(l.terms.map { Term(variable: $0.variable, coefficient: $0.coefficient * k) }, l.constant * k) }
        static func + (l: Expression, k: Double) -> Expression { Expression(l.terms, l.constant + k) }
    }

    enum Relation { case lessOrEqual, equal, greaterOrEqual }

    /// `expression relation 0` at `strength` (≥ `required` is required).
    final class Constraint {
        let expression: Expression
        let relation: Relation
        let strength: Double
        init(_ e: Expression, _ r: Relation, strength: Double) {
            // Merge duplicate variables.
            var merged: [ObjectIdentifier: Term] = [:]
            var order: [ObjectIdentifier] = []
            for t in e.terms {
                let id = ObjectIdentifier(t.variable)
                if merged[id] == nil { order.append(id); merged[id] = t } else { merged[id]!.coefficient += t.coefficient }
            }
            expression = Expression(order.map { merged[$0]! }, e.constant)
            relation = r
            self.strength = min(max(0, strength), CassowarySolver.required)
        }
        var isRequired: Bool { strength >= CassowarySolver.required }
    }

    static let required: Double = 1_001_001_000

    private enum SymbolKind { case invalid, external, slack, error, dummy }
    private struct Symbol: Hashable, Comparable {
        let id: Int
        let kind: SymbolKind
        static let invalid = Symbol(id: 0, kind: .invalid)
        static func < (a: Symbol, b: Symbol) -> Bool { a.id < b.id }
        static func == (a: Symbol, b: Symbol) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private final class Row {
        var constant: Double
        var cells: [Symbol: Double] = [:]
        init(_ c: Double = 0) { constant = c }
        init(copy r: Row) { constant = r.constant; cells = r.cells }
        var sortedSymbols: [Symbol] { cells.keys.sorted() }
        @discardableResult func add(_ v: Double) -> Double { constant += v; return constant }
        func insert(_ s: Symbol, _ c: Double = 1) {
            let v = (cells[s] ?? 0) + c
            if nearZero(v) { cells.removeValue(forKey: s) } else { cells[s] = v }
        }
        func insert(_ r: Row, _ c: Double = 1) {
            constant += r.constant * c
            for (s, v) in r.cells { insert(s, v * c) }
        }
        func remove(_ s: Symbol) { cells.removeValue(forKey: s) }
        func reverseSign() { constant = -constant; for k in cells.keys { cells[k] = -cells[k]! } }
        func solve(for s: Symbol) {
            let coeff = -1.0 / cells[s]!
            cells.removeValue(forKey: s)
            constant *= coeff
            for k in cells.keys { cells[k] = cells[k]! * coeff }
        }
        func solve(_ lhs: Symbol, _ rhs: Symbol) { insert(lhs, -1); solve(for: rhs) }
        func coefficient(for s: Symbol) -> Double { cells[s] ?? 0 }
        func substitute(_ s: Symbol, _ r: Row) {
            if let c = cells.removeValue(forKey: s) { insert(r, c) }
        }
    }

    private struct Tag { var marker: Symbol; var other: Symbol }
    private struct EditInfo { var tag: Tag; var constraint: Constraint; var constant: Double }

    private var constraints: [ObjectIdentifier: (Constraint, Tag)] = [:]
    private var rows: [Symbol: Row] = [:]
    private var vars: [ObjectIdentifier: (Variable, Symbol)] = [:]
    private var edits: [ObjectIdentifier: EditInfo] = [:]
    private var infeasible: [Symbol] = []
    private let objective = Row()
    private var artificial: Row?
    private var nextID = 1

    private func symbol(_ kind: SymbolKind) -> Symbol { nextID += 1; return Symbol(id: nextID, kind: kind) }

    static func nearZero(_ v: Double) -> Bool { abs(v) < 1e-8 }

    var constraintCount: Int { constraints.count }
    func has(_ c: Constraint) -> Bool { constraints[ObjectIdentifier(c)] != nil }

    // MARK: Constraints

    func add(_ c: Constraint) throws {
        guard constraints[ObjectIdentifier(c)] == nil else { throw SolverError.duplicate }
        var tag = Tag(marker: .invalid, other: .invalid)
        let row = createRow(c, &tag)
        var subject = chooseSubject(row, tag)
        if subject.kind == .invalid, allDummies(row) {
            guard Self.nearZero(row.constant) else { throw SolverError.unsatisfiable }
            subject = tag.marker
        }
        if subject.kind == .invalid {
            guard try addWithArtificialVariable(row) else { throw SolverError.unsatisfiable }
        } else {
            row.solve(for: subject)
            substitute(subject, row)
            rows[subject] = row
        }
        constraints[ObjectIdentifier(c)] = (c, tag)
        try optimize(objective)
    }

    func remove(_ c: Constraint) throws {
        guard let (_, tag) = constraints.removeValue(forKey: ObjectIdentifier(c)) else { throw SolverError.unknownConstraint }
        removeEffects(c, tag)
        if rows.removeValue(forKey: tag.marker) == nil {
            guard let leaving = markerLeavingSymbol(tag.marker), let row = rows.removeValue(forKey: leaving) else {
                throw SolverError.internalError("failed to find leaving row")
            }
            row.solve(leaving, tag.marker)
            substitute(tag.marker, row)
        }
        try optimize(objective)
    }

    // MARK: Edit variables

    func addEditVariable(_ v: Variable, strength: Double) throws {
        guard edits[ObjectIdentifier(v)] == nil else { throw SolverError.duplicateEditVariable }
        let s = min(strength, Self.required - 1)
        let c = Constraint(Expression([Term(variable: v, coefficient: 1)]), .equal, strength: s)
        try add(c)
        edits[ObjectIdentifier(v)] = EditInfo(tag: constraints[ObjectIdentifier(c)]!.1, constraint: c, constant: 0)
    }

    func removeEditVariable(_ v: Variable) throws {
        guard let info = edits.removeValue(forKey: ObjectIdentifier(v)) else { throw SolverError.unknownEditVariable }
        try remove(info.constraint)
    }

    func hasEditVariable(_ v: Variable) -> Bool { edits[ObjectIdentifier(v)] != nil }

    func suggest(_ v: Variable, _ value: Double) throws {
        guard var info = edits[ObjectIdentifier(v)] else { throw SolverError.unknownEditVariable }
        let delta = value - info.constant
        info.constant = value
        edits[ObjectIdentifier(v)] = info
        defer { try? dualOptimize() }
        if let row = rows[info.tag.marker] {
            if row.add(-delta) < 0 { infeasible.append(info.tag.marker) }
            return
        }
        if let row = rows[info.tag.other] {
            if row.add(delta) < 0 { infeasible.append(info.tag.other) }
            return
        }
        for s in rows.keys.sorted() {
            let row = rows[s]!
            let c = row.coefficient(for: info.tag.marker)
            if c != 0, row.add(delta * c) < 0, s.kind != .external { infeasible.append(s) }
        }
    }

    /// Writes the solution into each variable.
    func updateVariables() {
        for (v, s) in vars.values { v.value = rows[s]?.constant ?? 0 }
    }

    // MARK: Internals

    private func varSymbol(_ v: Variable) -> Symbol {
        if let (_, s) = vars[ObjectIdentifier(v)] { return s }
        let s = symbol(.external)
        vars[ObjectIdentifier(v)] = (v, s)
        return s
    }

    private func createRow(_ c: Constraint, _ tag: inout Tag) -> Row {
        let row = Row(c.expression.constant)
        for t in c.expression.terms where !Self.nearZero(t.coefficient) {
            let s = varSymbol(t.variable)
            if let other = rows[s] { row.insert(other, t.coefficient) } else { row.insert(s, t.coefficient) }
        }
        switch c.relation {
        case .lessOrEqual, .greaterOrEqual:
            let coeff: Double = c.relation == .lessOrEqual ? 1 : -1
            let slack = symbol(.slack)
            tag.marker = slack
            row.insert(slack, coeff)
            if !c.isRequired {
                let err = symbol(.error)
                tag.other = err
                row.insert(err, -coeff)
                objective.insert(err, c.strength)
            }
        case .equal:
            if !c.isRequired {
                let plus = symbol(.error), minus = symbol(.error)
                tag.marker = plus
                tag.other = minus
                row.insert(plus, -1)
                row.insert(minus, 1)
                objective.insert(plus, c.strength)
                objective.insert(minus, c.strength)
            } else {
                let dummy = symbol(.dummy)
                tag.marker = dummy
                row.insert(dummy)
            }
        }
        if row.constant < 0 { row.reverseSign() }
        return row
    }

    private func chooseSubject(_ row: Row, _ tag: Tag) -> Symbol {
        for s in row.sortedSymbols where s.kind == .external { return s }
        if tag.marker.kind == .slack || tag.marker.kind == .error, row.coefficient(for: tag.marker) < 0 { return tag.marker }
        if tag.other.kind == .slack || tag.other.kind == .error, row.coefficient(for: tag.other) < 0 { return tag.other }
        return .invalid
    }

    private func allDummies(_ row: Row) -> Bool { row.cells.keys.allSatisfy { $0.kind == .dummy } }

    private func addWithArtificialVariable(_ row: Row) throws -> Bool {
        let art = symbol(.slack)
        rows[art] = Row(copy: row)
        artificial = Row(copy: row)
        try optimize(artificial!)
        let success = Self.nearZero(artificial!.constant)
        artificial = nil
        if let r = rows.removeValue(forKey: art) {
            if r.cells.isEmpty { return success }
            let entering = r.sortedSymbols.first { $0.kind == .slack || $0.kind == .error } ?? .invalid
            if entering.kind == .invalid { return false }
            r.solve(art, entering)
            substitute(entering, r)
            rows[entering] = r
        }
        for r in rows.values { r.remove(art) }
        objective.remove(art)
        return success
    }

    private func substitute(_ s: Symbol, _ row: Row) {
        for key in rows.keys.sorted() {
            let r = rows[key]!
            r.substitute(s, row)
            if key.kind != .external, r.constant < 0 { infeasible.append(key) }
        }
        objective.substitute(s, row)
        artificial?.substitute(s, row)
    }

    private func optimize(_ obj: Row) throws {
        var guardCount = 0
        while guardCount < 100_000 {
            guardCount += 1
            // Strengths span nine orders of magnitude, so sums that should
            // cancel can leave rounding residue (~1e-7) in the objective: a
            // symbol whose cost is that close to zero and that no row bounds
            // is noise, not an unbounded objective.
            var entering: Symbol?, leaving: Symbol?
            for s in obj.sortedSymbols where s.kind != .dummy && obj.cells[s]! < 0 {
                var ratio = Double.greatestFiniteMagnitude
                var best: Symbol?
                for key in rows.keys.sorted() where key.kind != .external {
                    let r = rows[key]!
                    let c = r.coefficient(for: s)
                    if c < 0 {
                        let t = -r.constant / c
                        if t < ratio { ratio = t; best = key }
                    }
                }
                if let best { entering = s; leaving = best; break }
                if obj.cells[s]! < -1e-4 { throw SolverError.internalError("objective is unbounded") }
            }
            guard let entering, let leaving, let row = rows.removeValue(forKey: leaving) else { return }
            row.solve(leaving, entering)
            substitute(entering, row)
            rows[entering] = row
        }
    }

    private func dualOptimize() throws {
        while let leaving = infeasible.popLast() {
            guard let row = rows[leaving], row.constant < 0 else { continue }
            var ratio = Double.greatestFiniteMagnitude
            var entering: Symbol?
            for s in row.sortedSymbols where s.kind != .dummy {
                let c = row.cells[s]!
                if c > 0 {
                    let r = objective.coefficient(for: s) / c
                    if r < ratio { ratio = r; entering = s }
                }
            }
            guard let entering else { throw SolverError.internalError("dual optimize failed") }
            rows.removeValue(forKey: leaving)
            row.solve(leaving, entering)
            substitute(entering, row)
            rows[entering] = row
        }
    }

    private func removeEffects(_ c: Constraint, _ tag: Tag) {
        if tag.marker.kind == .error { removeMarkerEffects(tag.marker, c.strength) }
        if tag.other.kind == .error { removeMarkerEffects(tag.other, c.strength) }
    }
    private func removeMarkerEffects(_ marker: Symbol, _ strength: Double) {
        if let r = rows[marker] { objective.insert(r, -strength) } else { objective.insert(marker, -strength) }
    }

    private func markerLeavingSymbol(_ marker: Symbol) -> Symbol? {
        var r1 = Double.greatestFiniteMagnitude, r2 = Double.greatestFiniteMagnitude
        var first: Symbol?, second: Symbol?, third: Symbol?
        for key in rows.keys.sorted() {
            let row = rows[key]!
            let c = row.coefficient(for: marker)
            if c == 0 { continue }
            if key.kind == .external {
                third = key
            } else if c < 0 {
                let r = -row.constant / c
                if r < r1 { r1 = r; first = key }
            } else {
                let r = row.constant / c
                if r < r2 { r2 = r; second = key }
            }
        }
        return first ?? second ?? third
    }
}

private func nearZero(_ v: Double) -> Bool { CassowarySolver.nearZero(v) }

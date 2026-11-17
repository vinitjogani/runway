// SwiftData: models, containers, contexts and fetches.
//
// `@Model` is a macro on Apple platforms; `runway` stages a model class as
// `@Observable` with a generated `PersistentModel` conformance that lists
// its relationships (and their inverses and delete rules), and drops the
// property macros (@Attribute, @Relationship; @Transient becomes
// @ObservationIgnored). Contexts then work on a store of live objects:
// insert (with related models), delete (cascading where the model says so),
// fetch and fetchCount with #Predicate, sort descriptors, offsets and
// limits, transactions. The store is kept in memory for the life of the
// container: models aren't written to disk yet, so a container configured
// with a URL starts empty each launch.

@_exported import Foundation
@_exported import Observation
import SwiftUI

// MARK: Models

public struct PersistentIdentifier: Hashable, Comparable, Codable, Sendable {
    public let entityName: String
    let number: Int
    public var storeIdentifier: String? { nil }
    public static func < (a: Self, b: Self) -> Bool { (a.entityName, a.number) < (b.entityName, b.number) }
}

/// A relationship as the stager describes it: how to read the related
/// models of an instance, set the inverse on them, and whether deleting the
/// owner deletes them.
public struct _RunwayRelationship: @unchecked Sendable {
    let related: (AnyObject) -> [AnyObject]
    let setInverse: ((AnyObject, AnyObject) -> Void)?
    let cascade: Bool

    public static func toMany<P: AnyObject, C: AnyObject>(_ kp: KeyPath<P, [C]>, inverse: ReferenceWritableKeyPath<C, P?>? = nil,
                                                         cascade: Bool = false) -> _RunwayRelationship {
        _RunwayRelationship(related: { ($0 as? P).map { $0[keyPath: kp] } ?? [] },
                            setInverse: inverse.map { inv in { child, parent in (child as? C)?[keyPath: inv] = parent as? P } },
                            cascade: cascade)
    }
    public static func toOne<P: AnyObject, C: AnyObject>(_ kp: KeyPath<P, C?>, inverse: ReferenceWritableKeyPath<C, [P]>? = nil,
                                                        cascade: Bool = false) -> _RunwayRelationship {
        _RunwayRelationship(related: { ($0 as? P)?[keyPath: kp].map { [$0] } ?? [] },
                            setInverse: inverse.map { inv in { child, parent in
                                guard let c = child as? C, let p = parent as? P, !c[keyPath: inv].contains(where: { $0 === p }) else { return }
                                c[keyPath: inv].append(p)
                            } },
                            cascade: cascade)
    }
    public static func toOne<P: AnyObject, C: AnyObject>(_ kp: KeyPath<P, C?>, inverseOne: ReferenceWritableKeyPath<C, P?>,
                                                        cascade: Bool = false) -> _RunwayRelationship {
        _RunwayRelationship(related: { ($0 as? P)?[keyPath: kp].map { [$0] } ?? [] },
                            setInverse: { child, parent in (child as? C)?[keyPath: inverseOne] = parent as? P },
                            cascade: cascade)
    }
}

public protocol PersistentModel: AnyObject, Observable, Hashable, Identifiable {
    static var _runwayRelationships: [_RunwayRelationship] { get }
}

extension PersistentModel {
    public static var _runwayRelationships: [_RunwayRelationship] { [] }
    public var persistentModelID: PersistentIdentifier {
        PersistentIdentifier(entityName: String(describing: Self.self), number: ObjectIdentifier(self).hashValue)
    }
    public var id: PersistentIdentifier { persistentModelID }
    public var modelContext: ModelContext? { ModelContext.owner(of: self) }
    public var hasChanges: Bool { false }
    public var isDeleted: Bool { modelContext == nil }
    public static func == (a: Self, b: Self) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// What @Attribute/@Relationship options name (accepted; staging drops the macros).
public struct _SchemaOption: Sendable {
    public static let unique = Self(), externalStorage = Self(), allowsCloudEncryption = Self(), preserveValueOnDeletion = Self(),
                      spotlight = Self(), transformable = Self(), ephemeral = Self()
}

public enum DeleteRule: Sendable { case cascade, deny, noAction, nullify }

public struct Schema: Sendable {
    public let entities: [String]
    public init(_ types: [any PersistentModel.Type], version: Schema.Version = Schema.Version(1, 0, 0)) {
        entities = types.map { String(describing: $0) }
    }
    public init(_ types: any PersistentModel.Type...) { entities = types.map { String(describing: $0) } }
    public struct Version: Sendable, Hashable {
        public let major: Int, minor: Int, patch: Int
        public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    }
}

public protocol VersionedSchema {
    static var versionIdentifier: Schema.Version { get }
    static var models: [any PersistentModel.Type] { get }
}

public protocol SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { get }
    static var stages: [MigrationStage] { get }
}

public enum MigrationStage: Sendable {
    case lightweight(fromVersion: any VersionedSchema.Type, toVersion: any VersionedSchema.Type)
}

public struct ModelConfiguration: Hashable, Sendable {
    public var name: String
    public var url: URL
    public var isStoredInMemoryOnly: Bool
    public var allowsSave: Bool
    public init(_ name: String? = nil, schema: Schema? = nil, isStoredInMemoryOnly: Bool = false, allowsSave: Bool = true,
                groupContainer: GroupContainer = .automatic, cloudKitDatabase: CloudKitDatabase = .automatic) {
        self.name = name ?? "default"
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(self.name).store")
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
    }
    public init(_ name: String? = nil, schema: Schema? = nil, url: URL, allowsSave: Bool = true, cloudKitDatabase: CloudKitDatabase = .automatic) {
        self.name = name ?? url.deletingPathExtension().lastPathComponent
        self.url = url
        isStoredInMemoryOnly = false
        self.allowsSave = allowsSave
    }
    public struct GroupContainer: Hashable, Sendable {
        public static let automatic = Self(), none = Self()
        public static func identifier(_ id: String) -> Self { Self() }
    }
    public struct CloudKitDatabase: Hashable, Sendable {
        public static let automatic = Self(), none = Self()
        public static func `private`(_ id: String) -> Self { Self() }
    }
}

public enum SwiftDataError: Error, Sendable { case loadIssueModelContainer, unsupportedPredicate, unknownSchema }

// MARK: Container and context

public final class ModelContainer: @unchecked Sendable {
    public let schema: Schema
    public let configurations: [ModelConfiguration]
    final class Store {
        var models: [String: [AnyObject]] = [:]
        var counter = 0
    }
    let store = Store()

    public init(for forTypes: any PersistentModel.Type..., migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
                configurations: ModelConfiguration...) throws {
        schema = Schema(forTypes)
        self.configurations = configurations
    }
    public init(for givenSchema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)? = nil, configurations: [ModelConfiguration] = []) throws {
        schema = givenSchema
        self.configurations = configurations
    }
    public convenience init(for givenSchema: Schema, migrationPlan: (any SchemaMigrationPlan.Type)? = nil, configurations: ModelConfiguration...) throws {
        try self.init(for: givenSchema, migrationPlan: migrationPlan, configurations: configurations)
    }

    @preconcurrency @MainActor public lazy var mainContext: ModelContext = ModelContext(self)
    public func deleteAllData() { store.models.removeAll() }
}

public final class ModelContext: @unchecked Sendable {
    public let container: ModelContainer
    public var autosaveEnabled = true
    public private(set) var hasChanges = false
    public static let willSave = Notification.Name("ModelContextWillSave")
    public static let didSave = Notification.Name("ModelContextDidSave")
    nonisolated(unsafe) static var owners: [ObjectIdentifier: (model: AnyObject?, context: ModelContext)] = [:]

    public init(_ container: ModelContainer) { self.container = container }

    static func owner(of model: AnyObject) -> ModelContext? {
        guard let e = owners[ObjectIdentifier(model)], e.model === model else { return nil }
        return e.context
    }

    private func key(_ t: Any.Type) -> String { String(describing: t) }

    public func insert<T: PersistentModel>(_ model: T) { insertAny(model, type(of: model)) }

    private func insertAny(_ model: AnyObject, _ t: any PersistentModel.Type) {
        if Self.owner(of: model) === self { linkRelated(model, t); return }
        container.store.models[key(t), default: []].append(model)
        Self.owners[ObjectIdentifier(model)] = (model, self)
        hasChanges = true
        linkRelated(model, t)
    }

    /// Related models are inserted with their owner, and inverses set.
    private func linkRelated(_ model: AnyObject, _ t: any PersistentModel.Type) {
        for r in t._runwayRelationships {
            for child in r.related(model) {
                r.setInverse?(child, model)
                if Self.owner(of: child) !== self, let ct = type(of: child) as? any PersistentModel.Type { insertAny(child, ct) }
            }
        }
    }

    public func delete<T: PersistentModel>(_ model: T) { deleteAny(model, type(of: model)) }

    private func deleteAny(_ model: AnyObject, _ t: any PersistentModel.Type) {
        guard Self.owner(of: model) === self else { return }
        container.store.models[key(t)]?.removeAll { $0 === model }
        Self.owners[ObjectIdentifier(model)] = nil
        hasChanges = true
        for r in t._runwayRelationships where r.cascade {
            for child in r.related(model) { if let ct = type(of: child) as? any PersistentModel.Type { deleteAny(child, ct) } }
        }
    }

    public func delete<T: PersistentModel>(model: T.Type, where predicate: Predicate<T>? = nil, includeSubclasses: Bool = true) throws {
        let all = (container.store.models[key(T.self)] ?? []).compactMap { $0 as? T }
        for m in all where try predicate?.evaluate(m) ?? true { delete(m) }
    }

    /// Models of this type registered with the store, in insertion order.
    func all<T: PersistentModel>(_ t: T.Type) -> [T] {
        // Relationships added since insertion bring their models in.
        for m in (container.store.models.values.flatMap { $0 }) {
            if let mt = type(of: m) as? any PersistentModel.Type { linkRelated(m, mt) }
        }
        return (container.store.models[key(T.self)] ?? []).compactMap { $0 as? T }
    }

    public func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        var out = try all(T.self).filter { try descriptor.predicate?.evaluate($0) ?? true }
        if !descriptor.sortBy.isEmpty { out.sort(using: descriptor.sortBy) }
        if let o = descriptor.fetchOffset { out = Array(out.dropFirst(o)) }
        if let l = descriptor.fetchLimit { out = Array(out.prefix(l)) }
        return out
    }

    public func fetchCount<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> Int { try fetch(descriptor).count }

    public func fetchIdentifiers<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [PersistentIdentifier] {
        try fetch(descriptor).map(\.persistentModelID)
    }

    public func enumerate<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, batchSize: Int = 5000, allowEscapingMutations: Bool = false,
                                             block: (T) throws -> Void) throws {
        for m in try fetch(descriptor) { try block(m) }
    }

    public func registeredModel<T: PersistentModel>(for id: PersistentIdentifier) -> T? {
        all(T.self).first { $0.persistentModelID == id }
    }

    public func model(for id: PersistentIdentifier) -> any PersistentModel {
        for list in container.store.models.values {
            for m in list { if let p = m as? any PersistentModel, p.persistentModelID == id { return p } }
        }
        fatalError("No model with identifier \(id)")
    }

    public func save() throws {
        NotificationCenter.default.post(name: Self.willSave, object: self)
        hasChanges = false
        NotificationCenter.default.post(name: Self.didSave, object: self)
    }
    public func rollback() { hasChanges = false }
    public func processPendingChanges() {}
    public func transaction(block: () throws -> Void) throws {
        try block()
        try save()
    }
    public var insertedModelsArray: [any PersistentModel] { [] }
    public var changedModelsArray: [any PersistentModel] { [] }
    public var deletedModelsArray: [any PersistentModel] { [] }
}

public struct FetchDescriptor<T: PersistentModel> {
    public var predicate: Predicate<T>?
    public var sortBy: [SortDescriptor<T>]
    public var fetchLimit: Int?
    public var fetchOffset: Int?
    public var includePendingChanges = true
    public var propertiesToFetch: [PartialKeyPath<T>] = []
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<T>] = []
    public init(predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

// MARK: SwiftUI

struct ModelContextKey: EnvironmentKey {
    static var defaultValue: ModelContext? { nil }
}

extension EnvironmentValues {
    public var modelContext: ModelContext {
        get {
            if let c = self[ModelContextKey.self] { return c }
            return MainActor.assumeIsolated { ModelContext.fallback }
        }
        set { self[ModelContextKey.self] = newValue }
    }
}

extension ModelContext {
    /// The context views get without a `.modelContainer` above them.
    @MainActor static let fallback: ModelContext = {
        let c = try! ModelContainer(for: Schema([]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return c.mainContext
    }()
}

extension View {
    @preconcurrency @MainActor public func modelContainer(_ container: ModelContainer) -> some View {
        environment(\.modelContext, container.mainContext)
    }
    @preconcurrency @MainActor public func modelContainer(for modelType: any PersistentModel.Type, inMemory: Bool = false, isAutosaveEnabled: Bool = true,
                                          isUndoEnabled: Bool = false, onSetup: @escaping (Result<ModelContainer, Error>) -> Void = { _ in }) -> some View {
        let c = try! ModelContainer(for: modelType, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        onSetup(.success(c))
        return modelContainer(c)
    }
    public func modelContext(_ context: ModelContext) -> some View { environment(\.modelContext, context) }
}

extension Scene {
    @preconcurrency @MainActor public func modelContainer(_ container: ModelContainer) -> some Scene { self }
    @preconcurrency @MainActor public func modelContainer(for modelType: any PersistentModel.Type, inMemory: Bool = false) -> some Scene { self }
}

/// `@Query var items: [Item]`: the context's models of that type, fetched
/// each time the view reads them.
@propertyWrapper
public struct Query<Element: PersistentModel, Result>: DynamicProperty {
    let descriptor: FetchDescriptor<Element>
    @Environment(\.modelContext) var context

    public init(_ descriptor: FetchDescriptor<Element> = FetchDescriptor(), animation: Animation? = nil) where Result == [Element] {
        self.descriptor = descriptor
    }
    public init(filter: Predicate<Element>? = nil, sort: [SortDescriptor<Element>] = [], animation: Animation? = nil) where Result == [Element] {
        descriptor = FetchDescriptor(predicate: filter, sortBy: sort)
    }
    public init<V: Comparable>(filter: Predicate<Element>? = nil, sort keyPath: KeyPath<Element, V>, order: SortOrder = .forward,
                               animation: Animation? = nil) where Result == [Element] {
        descriptor = FetchDescriptor(predicate: filter, sortBy: [SortDescriptor(keyPath, order: order)])
    }
    public var wrappedValue: [Element] { (try? context.fetch(descriptor)) ?? [] }
    public var modelContext: ModelContext { context }
}

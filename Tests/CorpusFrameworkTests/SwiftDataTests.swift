import XCTest
import SwiftData

// What `runway` stages a `@Model` pair as (see RunwayTranspiler's
// swiftDataAttribute): @Observable classes plus a PersistentModel
// conformance listing relationships.
@Observable final class SDItem {
    var title = ""
    var pin: String?
    var contents: [SDContent] = []
    init(title: String, contents: [SDContent] = []) { self.title = title; self.contents = contents }
}
extension SDItem: SwiftData.PersistentModel {
    static var _runwayRelationships: [SwiftData._RunwayRelationship] { [.toMany(\SDItem.contents, inverse: \SDContent.item, cascade: true)] }
}
@Observable final class SDContent {
    var type = ""
    var item: SDItem?
    init(type: String) { self.type = type }
}
extension SDContent: SwiftData.PersistentModel {
    static var _runwayRelationships: [SwiftData._RunwayRelationship] { [.toOne(\SDContent.item, cascade: false)] }
}

final class SwiftDataTests: XCTestCase {
    @MainActor func testInsertFetchDeleteCascade() throws {
        let container = try ModelContainer(for: SDItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let a = SDItem(title: "b", contents: [SDContent(type: "text"), SDContent(type: "html")])
        context.insert(a)
        context.insert(SDItem(title: "a"))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SDItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SDContent>()), 2, "related models come in with their owner")
        XCTAssertTrue(a.contents.allSatisfy { $0.item === a }, "inverses are set")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SDContent>(predicate: #Predicate { $0.item == nil })), 0)

        let sorted = try context.fetch(FetchDescriptor<SDItem>(sortBy: [SortDescriptor(\SDItem.title)]))
        XCTAssertEqual(sorted.map(\.title), ["a", "b"])
        let limited = try context.fetch(FetchDescriptor<SDItem>(predicate: #Predicate { $0.title == "b" }))
        XCTAssertEqual(limited.count, 1)

        context.delete(a)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SDContent>()), 0, "cascade")
        try context.delete(model: SDItem.self, where: #Predicate { $0.pin == nil })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SDItem>()), 0)
    }
}

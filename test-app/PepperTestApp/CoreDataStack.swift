import CoreData
import Foundation

/// Minimal Core Data stack seeded at launch for `db` command testing.
/// Uses SQLite store at Library/Application Support/PepperCoreData.sqlite.
/// Entity: Item (title: String, count: Int32, value: Double, createdAt: Date)
enum CoreDataStack {
    static let storeFilename = "PepperCoreData.sqlite"

    /// Shared container for SwiftUI `@FetchRequest` and CRUD operations.
    static let shared: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "PepperCoreData", managedObjectModel: buildModel())
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fatalError("Missing Application Support directory")
        }
        let storeURL = appSupport.appendingPathComponent(storeFilename)
        let description = NSPersistentStoreDescription(url: storeURL)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { print("[PepperTest] Core Data load error: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }()

    static func seedIfNeeded() {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let storeURL = appSupport.appendingPathComponent(storeFilename)
        guard !FileManager.default.fileExists(atPath: storeURL.path) else {
            print("[PepperTest] Core Data store already seeded")
            return
        }

        let model = buildModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        do {
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: nil
            )
        } catch {
            print("[PepperTest] Core Data store error: \(error)")
            return
        }

        let ctx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        ctx.persistentStoreCoordinator = coordinator
        ctx.performAndWait {
            seedItems(in: ctx)
            try? ctx.save()
        }
        print("[PepperTest] Seeded Core Data store at \(storeFilename)")
    }

    // MARK: - Private

    private static func buildModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "Item"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let titleAttr = NSAttributeDescription()
        titleAttr.name = "title"
        titleAttr.attributeType = .stringAttributeType
        titleAttr.isOptional = true

        let countAttr = NSAttributeDescription()
        countAttr.name = "count"
        countAttr.attributeType = .integer32AttributeType
        countAttr.defaultValue = 0

        let valueAttr = NSAttributeDescription()
        valueAttr.name = "value"
        valueAttr.attributeType = .doubleAttributeType
        valueAttr.defaultValue = 0.0

        let createdAtAttr = NSAttributeDescription()
        createdAtAttr.name = "createdAt"
        createdAtAttr.attributeType = .dateAttributeType
        createdAtAttr.isOptional = true

        entity.properties = [titleAttr, countAttr, valueAttr, createdAtAttr]
        model.entities = [entity]
        return model
    }

    private static func seedItems(in ctx: NSManagedObjectContext) {
        guard let entity = ctx.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Item"] else {
            return
        }
        let items: [(String, Int32, Double)] = [
            ("Alpha", 10, 1.5),
            ("Beta", 20, 2.75),
            ("Gamma", 5, 0.5),
            ("Delta", 42, 9.9),
            ("Epsilon", 7, 3.14),
            ("Zeta", 99, 100.0),
            ("Eta", 3, 0.01),
            ("Theta", 55, 55.5),
            ("Iota", 1, 1.0),
            ("Kappa", 0, 0.0),
        ]
        for (title, count, value) in items {
            let obj = NSManagedObject(entity: entity, insertInto: ctx)
            obj.setValue(title, forKey: "title")
            obj.setValue(count, forKey: "count")
            obj.setValue(value, forKey: "value")
            obj.setValue(Date(), forKey: "createdAt")
        }
    }
}

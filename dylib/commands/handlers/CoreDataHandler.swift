import CoreData
import Foundation
import UIKit

/// Handles {"cmd": "coredata"} commands for Core Data schema inspection.
///
/// Discovers the app's Core Data stack via common singleton patterns and
/// returns the managed object model schema — entities, attributes, and relationships.
///
/// Actions:
///   - "entities": List all entities with their attributes and relationships.
///                 Returns: { available, store, entities: [{ name, attributes, relationships }] }
struct CoreDataHandler: PepperHandler {
    let commandName = "coredata"
    let timeout: TimeInterval = 20.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "entities"

        switch action {
        case "entities":
            return handleEntities(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown coredata action '\(action)'. Use: entities")
        }
    }

    // MARK: - Entities

    private func handleEntities(_ command: PepperCommand) -> PepperResponse {
        guard let container = findPersistentContainer() else {
            return .ok(
                id: command.id,
                data: [
                    "available": AnyCodable(false),
                    "message": AnyCodable("No Core Data stack found in this app."),
                ])
        }

        let model = container.managedObjectModel
        var entities: [[String: AnyCodable]] = []

        for entity in model.entities.sorted(by: { $0.name ?? "" < $1.name ?? "" }) {
            guard let name = entity.name else { continue }
            let attributes = entity.attributesByName.keys.sorted()
            let relationships = entity.relationshipsByName.keys.sorted()

            entities.append([
                "name": AnyCodable(name),
                "attributes": AnyCodable(attributes.map { AnyCodable($0) }),
                "relationships": AnyCodable(relationships.map { AnyCodable($0) }),
            ])
        }

        return .ok(
            id: command.id,
            data: [
                "available": AnyCodable(true),
                "store": AnyCodable(container.name),
                "entities": AnyCodable(entities),
            ])
    }

    // MARK: - Container Discovery

    /// Find the app's NSPersistentContainer by trying common singleton patterns.
    /// Checks AppDelegate, then well-known controller class names.
    private func findPersistentContainer() -> NSPersistentContainer? {
        // Try AppDelegate.persistentContainer (most common UIKit pattern)
        if let appDelegate = UIApplication.shared.delegate {
            let sel = NSSelectorFromString("persistentContainer")
            if appDelegate.responds(to: sel) {
                if let container = appDelegate.perform(sel)?.takeUnretainedValue()
                    as? NSPersistentContainer
                {
                    return container
                }
            }
        }

        // Try common controller class names with .shared.container / .shared.persistentContainer
        let commonClassNames = [
            "PersistenceController",
            "CoreDataStack",
            "CoreDataManager",
            "DataController",
            "DatabaseManager",
        ]
        let containerSelectors = [
            NSSelectorFromString("container"),
            NSSelectorFromString("persistentContainer"),
        ]
        let sharedSel = NSSelectorFromString("shared")

        for className in commonClassNames {
            guard let cls = NSClassFromString(className) else { continue }
            guard class_getClassMethod(cls, sharedSel) != nil else { continue }
            guard let shared = (cls as AnyObject).perform(sharedSel)?.takeUnretainedValue()
            else { continue }

            for containerSel in containerSelectors {
                if shared.responds(to: containerSel) {
                    if let container = shared.perform(containerSel)?.takeUnretainedValue()
                        as? NSPersistentContainer
                    {
                        return container
                    }
                }
            }
        }

        return nil
    }
}

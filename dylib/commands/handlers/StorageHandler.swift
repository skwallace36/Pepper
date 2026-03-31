import CoreData
import Foundation
import Security
import UIKit

/// Handles {"cmd": "storage"} commands for unified persistence inspection.
///
/// Actions:
///   - "summary":  Overview of UserDefaults, Keychain, and Core Data counts/sizes.
///   - "defaults":  Proxy to the defaults handler (list/get/set/delete).
///   - "keychain":  Proxy to the keychain handler (list/get/set/delete/clear).
///   - "coredata": List Core Data entities and row counts. Params: entity (optional).
///   - "clear":    Reset a storage layer. Params: type (defaults/keychain/coredata).
struct StorageHandler: PepperHandler {
    let commandName = "storage"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "summary"

        switch action {
        case "summary":
            return handleSummary(command)
        case "coredata":
            return handleCoreData(command)
        case "clear":
            return handleClear(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown storage action '\(action)'. Use summary/coredata/clear.")
        }
    }

    // MARK: - Summary

    private func handleSummary(_ command: PepperCommand) -> PepperResponse {
        var sections: [String: AnyCodable] = [:]

        // UserDefaults
        let ud = UserDefaults.standard
        let udDict = ud.dictionaryRepresentation()
        sections["defaults"] = AnyCodable([
            "count": AnyCodable(udDict.count)
        ])

        // Keychain
        let keychainCount = countKeychainItems()
        sections["keychain"] = AnyCodable([
            "count": AnyCodable(keychainCount)
        ])

        // Core Data
        let cdInfo = coreDataSummary()
        sections["coredata"] = AnyCodable(cdInfo)

        return .ok(id: command.id, data: sections)
    }

    // MARK: - Core Data

    private func handleCoreData(_ command: PepperCommand) -> PepperResponse {
        let entityFilter = command.params?["entity"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? 50

        guard let container = findPersistentContainer() else {
            return .ok(
                id: command.id,
                data: [
                    "available": AnyCodable(false),
                    "message": AnyCodable("No Core Data stack found in this app."),
                ])
        }

        let context = container.viewContext
        let model = container.managedObjectModel

        if let entityFilter = entityFilter {
            // Show rows for a specific entity
            return entityDetail(
                context: context, model: model, entityName: entityFilter, limit: limit, command: command)
        }

        // List all entities with row counts
        var entities: [[String: AnyCodable]] = []
        for entity in model.entities.sorted(by: { $0.name ?? "" < $1.name ?? "" }) {
            guard let name = entity.name else { continue }
            let count = fetchCount(context: context, entityName: name)
            let attrs = entity.attributesByName.keys.sorted()

            entities.append([
                "entity": AnyCodable(name),
                "count": AnyCodable(count),
                "attributes": AnyCodable(attrs.map { AnyCodable($0) }),
            ])
        }

        return .ok(
            id: command.id,
            data: [
                "available": AnyCodable(true),
                "store": AnyCodable(container.name),
                "entity_count": AnyCodable(entities.count),
                "entities": AnyCodable(entities),
            ])
    }

    private func entityDetail(
        context: NSManagedObjectContext, model: NSManagedObjectModel,
        entityName: String, limit: Int, command: PepperCommand
    ) -> PepperResponse {
        guard let entity = model.entitiesByName[entityName] else {
            let available = model.entities.compactMap { $0.name }.sorted()
            return .error(
                id: command.id,
                message: "Entity '\(entityName)' not found. Available: \(available.joined(separator: ", "))")
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.fetchLimit = limit

        do {
            let results = try context.fetch(request)
            let attrNames = entity.attributesByName.keys.sorted()
            var rows: [[String: AnyCodable]] = []

            for obj in results {
                var row: [String: AnyCodable] = [:]
                for attr in attrNames {
                    if let val = obj.value(forKey: attr) {
                        row[attr] = AnyCodable(summarizeValue(val))
                    } else {
                        row[attr] = AnyCodable("nil")
                    }
                }
                rows.append(row)
            }

            return .ok(
                id: command.id,
                data: [
                    "entity": AnyCodable(entityName),
                    "total": AnyCodable(fetchCount(context: context, entityName: entityName)),
                    "fetched": AnyCodable(rows.count),
                    "attributes": AnyCodable(attrNames.map { AnyCodable($0) }),
                    "rows": AnyCodable(rows),
                ])
        } catch {
            return .error(id: command.id, message: "Core Data fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear

    private func handleClear(_ command: PepperCommand) -> PepperResponse {
        guard let type = command.params?["type"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'type' param. Use defaults/keychain/coredata.")
        }

        switch type {
        case "defaults":
            return clearDefaults(command)
        case "keychain":
            return clearKeychain(command)
        case "coredata":
            return clearCoreData(command)
        default:
            return .error(id: command.id, message: "Unknown storage type '\(type)'. Use defaults/keychain/coredata.")
        }
    }

    private func clearDefaults(_ command: PepperCommand) -> PepperResponse {
        let ud = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ""
        ud.removePersistentDomain(forName: domain)
        ud.synchronize()
        return .ok(
            id: command.id,
            data: [
                "ok": AnyCodable(true),
                "cleared": AnyCodable("defaults"),
                "domain": AnyCodable(domain),
            ])
    }

    private func clearKeychain(_ command: PepperCommand) -> PepperResponse {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        let status = SecItemDelete(query as CFDictionary)
        return .ok(
            id: command.id,
            data: [
                "ok": AnyCodable(true),
                "cleared": AnyCodable("keychain"),
                "status": AnyCodable(status == errSecSuccess ? "cleared" : "nothing_to_clear"),
            ])
    }

    private func clearCoreData(_ command: PepperCommand) -> PepperResponse {
        let entityFilter = command.params?["entity"]?.stringValue

        guard let container = findPersistentContainer() else {
            return .error(id: command.id, message: "No Core Data stack found.")
        }

        let context = container.viewContext
        let model = container.managedObjectModel
        var cleared: [String: AnyCodable] = [:]

        let entitiesToClear: [NSEntityDescription]
        if let entityFilter = entityFilter {
            guard let entity = model.entitiesByName[entityFilter] else {
                return .error(id: command.id, message: "Entity '\(entityFilter)' not found.")
            }
            entitiesToClear = [entity]
        } else {
            entitiesToClear = model.entities
        }

        for entity in entitiesToClear {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            do {
                try context.execute(deleteRequest)
                cleared[name] = AnyCodable(true)
            } catch {
                cleared[name] = AnyCodable("error: \(error.localizedDescription)")
            }
        }

        do {
            try context.save()
        } catch {
            pepperLog.warning("context.save() failed after clearing CoreData: \(error)", category: .commands)
        }

        return .ok(
            id: command.id,
            data: [
                "ok": AnyCodable(true),
                "cleared": AnyCodable("coredata"),
                "entities": AnyCodable(cleared),
            ])
    }

    // MARK: - Helpers

    private func countKeychainItems() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            return items.count
        }
        return 0
    }

    private func coreDataSummary() -> [String: AnyCodable] {
        guard let container = findPersistentContainer() else {
            return [
                "available": AnyCodable(false)
            ]
        }
        let model = container.managedObjectModel
        let context = container.viewContext
        var totalRows = 0
        for entity in model.entities {
            guard let name = entity.name else { continue }
            totalRows += fetchCount(context: context, entityName: name)
        }
        return [
            "available": AnyCodable(true),
            "store": AnyCodable(container.name),
            "entity_count": AnyCodable(model.entities.count),
            "total_rows": AnyCodable(totalRows),
        ]
    }

    private func findPersistentContainer() -> NSPersistentContainer? {
        // Strategy: scan the heap for NSPersistentContainer instances.
        // This mirrors how HeapHandler finds objects — iterate known classes.
        // For efficiency, we check the most common container types first.
        var containerClass: AnyClass? = NSClassFromString("NSPersistentContainer")
        if containerClass == nil {
            containerClass = NSClassFromString("NSPersistentCloudKitContainer")
        }
        guard containerClass != nil else { return nil }

        // Use ObjC runtime to find instances. Walk the heap via malloc zone enumeration.
        // Simpler approach: check if app has a known singleton pattern.
        // Many apps expose their container via a shared/default property.

        // Try common patterns apps use to expose their Core Data stack
        if let appDelegate = UIApplication.shared.delegate {
            // Check if the app delegate has a persistentContainer property
            let sel = NSSelectorFromString("persistentContainer")
            if appDelegate.responds(to: sel) {
                if let container = appDelegate.perform(sel)?.takeUnretainedValue() as? NSPersistentContainer {
                    return container
                }
            }
        }

        // Try SwiftUI-style: check for shared container on common class names
        let commonClassNames = [
            "PersistenceController",
            "CoreDataStack",
            "CoreDataManager",
            "DataController",
            "DatabaseManager",
        ]
        for className in commonClassNames {
            if let cls = NSClassFromString(className) {
                // Try .shared.container pattern
                let sharedSel = NSSelectorFromString("shared")
                if cls.responds(to: sharedSel) {
                    if let shared = (cls as AnyObject).perform(sharedSel)?.takeUnretainedValue() {
                        let containerSel = NSSelectorFromString("container")
                        if shared.responds(to: containerSel) {
                            if let container = shared.perform(containerSel)?.takeUnretainedValue()
                                as? NSPersistentContainer
                            {
                                return container
                            }
                        }
                        let pcSel = NSSelectorFromString("persistentContainer")
                        if shared.responds(to: pcSel) {
                            if let container = shared.perform(pcSel)?.takeUnretainedValue()
                                as? NSPersistentContainer
                            {
                                return container
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    private func fetchCount(context: NSManagedObjectContext, entityName: String) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        do {
            return try context.count(for: request)
        } catch {
            pepperLog.debug("count(for:) failed for \(entityName): \(error)", category: .commands)
            return 0
        }
    }

    private func summarizeValue(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s.count > 200 ? String(s.prefix(200)) + "..." : s
        case let d as Data:
            if d.count > 0, d.count <= 1_048_576,
                let obj = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)
            {
                let s = String(describing: obj)
                return s.count > 200 ? String(s.prefix(200)) + "..." : s
            }
            return "<\(d.count) bytes>"
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let num as NSNumber:
            return num.stringValue
        default:
            let s = String(describing: value)
            return s.count > 200 ? String(s.prefix(200)) + "..." : s
        }
    }
}

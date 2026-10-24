// PersistenceController.swift — AutoDay · Data layer
// Core Data stack. The managed object model is built in code (see Models/CoreDataModel.swift),
// so there is no .xcdatamodeld to keep in sync. Data lives in the app's sandbox.

import Foundation
import CoreData

final class PersistenceController {

    static let shared = PersistenceController()

    let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "AutoDay", managedObjectModel: CoreDataModel.shared)
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error { print("⚠️ Core Data failed to load: \(error)") }
        }
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Load

    struct Snapshot {
        var tasks: [AppTask] = []
        var schedule: [TaskSchedule] = []
        var events: [TaskEvent] = []
        var preferences: UserPreferences?
    }

    func load() -> Snapshot {
        var snap = Snapshot()
        snap.tasks    = fetch(CoreDataModel.task).compactMap(Mapper.task)
        snap.schedule = fetch(CoreDataModel.schedule).compactMap(Mapper.schedule)
        snap.events   = fetch(CoreDataModel.event).compactMap(Mapper.event)
        snap.preferences = fetch(CoreDataModel.preferences).compactMap(Mapper.preferences).first
        return snap
    }

    private func fetch(_ entity: String) -> [NSManagedObject] {
        let req = NSFetchRequest<NSManagedObject>(entityName: entity)
        return (try? context.fetch(req)) ?? []
    }

    // MARK: - Save (write-through)

    /// Upserts by id and deletes whatever no longer exists. The data set is small, so this is cheap.
    func save(tasks: [AppTask], schedule: [TaskSchedule], events: [TaskEvent], preferences: UserPreferences) {
        sync(CoreDataModel.task, items: tasks, key: { $0.id.uuidString }, write: { Mapper.write($0, $1) })
        sync(CoreDataModel.schedule, items: schedule, key: { $0.id }, write: { Mapper.write($0, $1) })
        sync(CoreDataModel.event, items: events, key: { $0.id.uuidString }, write: { Mapper.write($0, $1) })
        sync(CoreDataModel.preferences, items: [preferences], key: { $0.id.uuidString }, write: { Mapper.write($0, $1) })
        if context.hasChanges {
            do { try context.save() } catch { print("⚠️ Core Data save failed: \(error)") }
        }
    }

    private func sync<T>(_ entity: String, items: [T], key: (T) -> String,
                         write: (T, NSManagedObject) -> Void) {
        var existing: [String: NSManagedObject] = [:]
        for o in fetch(entity) {
            guard let k = o.value(forKey: "key") as? String else { context.delete(o); continue }
            if existing[k] != nil { context.delete(o) } else { existing[k] = o }
        }
        var keep = Set<String>()
        for item in items {
            let k = key(item)
            keep.insert(k)
            let obj = existing[k] ?? NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
            obj.setValue(k, forKey: "key")
            write(item, obj)
        }
        for (k, o) in existing where !keep.contains(k) { context.delete(o) }
    }
}

// MARK: - Domain struct <-> managed object

enum Mapper {

    // Task
    static func write(_ t: AppTask, _ o: NSManagedObject) {
        o.setValue(t.id, forKey: "id")
        o.setValue(t.title, forKey: "title")
        o.setValue(Int64(t.duration), forKey: "duration")
        o.setValue(Int64(t.priority.rawValue), forKey: "priority")
        o.setValue(t.deadline, forKey: "deadline")
        o.setValue(t.isFixed, forKey: "isFixed")
        o.setValue(t.fixedStart, forKey: "fixedStart")
        o.setValue(t.splittableOverride.map { NSNumber(value: $0) }, forKey: "splittableOverride")
        o.setValue(t.repeatRule?.rawValue, forKey: "repeatRule")
        o.setValue(t.windowStart.map { NSNumber(value: $0) }, forKey: "windowStart")
        o.setValue(t.windowEnd.map { NSNumber(value: $0) }, forKey: "windowEnd")
        o.setValue(Int64(t.rescheduleCount), forKey: "rescheduleCount")
        o.setValue(t.status.rawValue, forKey: "status")
        o.setValue(t.dateCreated, forKey: "dateCreated")
        o.setValue(t.snoozedUntil, forKey: "snoozedUntil")
        o.setValue(t.isManuallyPlaced, forKey: "isManuallyPlaced")
        o.setValue(t.templateId, forKey: "templateId")
        o.setValue(t.instanceDate, forKey: "instanceDate")
        o.setValue(Int64(t.colorIndex), forKey: "colorIndex")
        o.setValue(t.isUnscheduled, forKey: "isUnscheduled")
    }

    static func task(_ o: NSManagedObject) -> AppTask? {
        guard let id = o.value(forKey: "id") as? UUID,
              let title = o.value(forKey: "title") as? String else { return nil }
        var t = AppTask(title: title, duration: Int(o.i("duration")))
        t.id = id
        t.priority = TaskPriority(rawValue: Int(o.i("priority"))) ?? .medium
        t.deadline = o.value(forKey: "deadline") as? Date
        t.isFixed = o.value(forKey: "isFixed") as? Bool ?? false
        t.fixedStart = o.value(forKey: "fixedStart") as? Date
        t.splittableOverride = (o.value(forKey: "splittableOverride") as? NSNumber)?.boolValue
        t.repeatRule = (o.value(forKey: "repeatRule") as? String).flatMap(RepeatRule.init(rawValue:))
        t.windowStart = (o.value(forKey: "windowStart") as? NSNumber)?.intValue
        t.windowEnd = (o.value(forKey: "windowEnd") as? NSNumber)?.intValue
        t.rescheduleCount = Int(o.i("rescheduleCount"))
        t.status = (o.value(forKey: "status") as? String).flatMap(TaskStatus.init(rawValue:)) ?? .pending
        t.dateCreated = o.value(forKey: "dateCreated") as? Date ?? Date()
        t.snoozedUntil = o.value(forKey: "snoozedUntil") as? Date
        t.isManuallyPlaced = o.value(forKey: "isManuallyPlaced") as? Bool ?? false
        t.templateId = o.value(forKey: "templateId") as? UUID
        t.instanceDate = o.value(forKey: "instanceDate") as? Date
        t.colorIndex = Int(o.i("colorIndex"))
        t.isUnscheduled = o.value(forKey: "isUnscheduled") as? Bool ?? false
        return t
    }

    // Schedule row
    static func write(_ r: TaskSchedule, _ o: NSManagedObject) {
        o.setValue(r.taskId, forKey: "taskId")
        o.setValue(r.start, forKey: "start")
        o.setValue(r.end, forKey: "end")
        o.setValue(Int64(r.chunkIndex), forKey: "chunkIndex")
        o.setValue(r.windowPenalty, forKey: "windowPenalty")
        o.setValue(r.isMissed, forKey: "isMissed")
    }

    static func schedule(_ o: NSManagedObject) -> TaskSchedule? {
        guard let id = o.value(forKey: "taskId") as? UUID,
              let s = o.value(forKey: "start") as? Date,
              let e = o.value(forKey: "end") as? Date else { return nil }
        return TaskSchedule(taskId: id, start: s, end: e,
                            chunkIndex: Int(o.i("chunkIndex")),
                            windowPenalty: o.value(forKey: "windowPenalty") as? Bool ?? false,
                            isMissed: o.value(forKey: "isMissed") as? Bool ?? false)
    }

    // Event
    static func write(_ e: TaskEvent, _ o: NSManagedObject) {
        o.setValue(e.id, forKey: "id")
        o.setValue(e.taskId, forKey: "taskId")
        o.setValue(e.kind.rawValue, forKey: "kind")
        o.setValue(e.date, forKey: "date")
        o.setValue(Int64(e.minutes), forKey: "minutes")
    }

    static func event(_ o: NSManagedObject) -> TaskEvent? {
        guard let id = o.value(forKey: "id") as? UUID,
              let tid = o.value(forKey: "taskId") as? UUID,
              let k = (o.value(forKey: "kind") as? String).flatMap(TaskEventKind.init(rawValue:)) else { return nil }
        return TaskEvent(id: id, taskId: tid, kind: k,
                         date: o.value(forKey: "date") as? Date ?? Date(),
                         minutes: Int(o.i("minutes")))
    }

    // Preferences
    static func write(_ p: UserPreferences, _ o: NSManagedObject) {
        o.setValue(p.id, forKey: "id")
        o.setValue(Int64(p.wakeMinutes), forKey: "wakeMinutes")
        o.setValue(Int64(p.sleepMinutes), forKey: "sleepMinutes")
    }

    static func preferences(_ o: NSManagedObject) -> UserPreferences? {
        guard let id = o.value(forKey: "id") as? UUID else { return nil }
        var p = UserPreferences()
        p.id = id
        p.wakeMinutes = Int(o.i("wakeMinutes"))
        p.sleepMinutes = Int(o.i("sleepMinutes"))
        return p
    }
}

private extension NSManagedObject {
    func i(_ key: String) -> Int64 { (value(forKey: key) as? NSNumber)?.int64Value ?? 0 }
}

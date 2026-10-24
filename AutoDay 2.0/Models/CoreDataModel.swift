// CoreDataModel.swift — AutoDay · Models
// The Core Data schema, declared in code. Entities mirror the domain structs
// (AppTask, TaskSchedule, TaskEvent, UserPreferences). Add an attribute here and
// in Data/PersistenceController.swift's Mapper to persist a new field.

import CoreData

enum CoreDataModel {

    static let task        = "TaskEntity"
    static let schedule    = "ScheduleEntity"
    static let event       = "EventEntity"
    static let preferences = "PreferencesEntity"

    static let shared: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        model.entities = [
            entity(task, [
                ("id", .UUIDAttributeType, false), ("title", .stringAttributeType, false),
                ("duration", .integer64AttributeType, false), ("priority", .integer64AttributeType, false),
                ("deadline", .dateAttributeType, true), ("isFixed", .booleanAttributeType, false),
                ("fixedStart", .dateAttributeType, true),
                ("splittableOverride", .booleanAttributeType, true),
                ("repeatRule", .stringAttributeType, true),
                ("windowStart", .integer64AttributeType, true), ("windowEnd", .integer64AttributeType, true),
                ("rescheduleCount", .integer64AttributeType, false), ("status", .stringAttributeType, false),
                ("dateCreated", .dateAttributeType, false), ("snoozedUntil", .dateAttributeType, true),
                ("isManuallyPlaced", .booleanAttributeType, false),
                ("templateId", .UUIDAttributeType, true), ("instanceDate", .dateAttributeType, true),
                ("colorIndex", .integer64AttributeType, false), ("isUnscheduled", .booleanAttributeType, false),
            ]),
            entity(schedule, [
                ("taskId", .UUIDAttributeType, false), ("start", .dateAttributeType, false),
                ("end", .dateAttributeType, false), ("chunkIndex", .integer64AttributeType, false),
                ("windowPenalty", .booleanAttributeType, false), ("isMissed", .booleanAttributeType, false),
            ]),
            entity(event, [
                ("id", .UUIDAttributeType, false), ("taskId", .UUIDAttributeType, false),
                ("kind", .stringAttributeType, false), ("date", .dateAttributeType, false),
                ("minutes", .integer64AttributeType, false),
            ]),
            entity(preferences, [
                ("id", .UUIDAttributeType, false), ("wakeMinutes", .integer64AttributeType, false),
                ("sleepMinutes", .integer64AttributeType, false),
            ]),
        ]
        return model
    }()

    /// Every entity also carries a string `key` (the domain id) used for upserts.
    private static func entity(_ name: String,
                               _ attrs: [(String, NSAttributeType, Bool)]) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = "NSManagedObject"
        var props: [NSAttributeDescription] = []
        for (n, t, optional) in attrs + [("key", .stringAttributeType, true)] {
            let a = NSAttributeDescription()
            a.name = n
            a.attributeType = t
            a.isOptional = optional || n == "key"
            props.append(a)
        }
        e.properties = props
        return e
    }
}

//
//  ExternalDragSupport.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 05/11/26.
//
//  Manual mode: dragging a row out of the Tasks sheet onto the day timeline.
//  Rebuilt from how TimelineView and DragTimelineView call it, so check the drop feels right.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop delegate

/// Receives the drag of a Tasks-sheet row (payload: the task's UUID string) over the timeline.
/// `location` is in the coordinate space of the view the delegate is attached to (the timeline ScrollView).
struct ExternalDropDelegate: DropDelegate {
    static let types: [UTType] = [.plainText]

    let onMove: (CGPoint) -> Void
    let onLeave: () -> Void
    let onDrop: (CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.types)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onMove(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onLeave()
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop(info.location)
    }
}

// MARK: - Timeline side

extension TimelineView {

    /// Finger moved over the timeline while a Tasks-sheet row is dragged:
    /// highlight the slot it would land in and auto-scroll near the top and bottom edges.
    func updateExternalDrag(at location: CGPoint, frame: CGRect) {
        guard let u = externalDragTask else { return }
        let dur = u.durationMinutes
        let start = externalProposedStart(at: location, duration: dur)
        let placement = resolvePlacement(plans: externalPlans, proposedStart: start,
                                         duration: dur, tolerance: 24 * 60)
        if placement?.id != externalActive?.id {
            withAnimation(.snappy(duration: 0.15)) { externalActive = placement }
            if placement != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
        // `location` is local to the ScrollView; auto-scroll expects a global y.
        updateAutoScroll(globalY: frame.minY + location.y, frame: frame)
    }
}

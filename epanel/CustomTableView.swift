//
//  CustomTableView.swift
//  epanel
//
//  Created by Al Biheiri on 1/4/24.
//

// This is to override the tableview to provide a custom context menu

import Cocoa

class CustomTableView: NSTableView {

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = self.convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)

        if row >= 0 && row < self.numberOfRows {
            self.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        return super.menu(for: event)
    }

}


//  DataStore.swift
import Foundation
import AppKit


struct Entry: Identifiable, Equatable, Hashable {
    let id = UUID()
    var text: String
    var date: Date
}

class DataStore: ObservableObject {
    static let shared = DataStore()
    
    @Published var entries: [Entry] = []
    @Published var showAlert = false
    @Published var alertMessage = ""
    
    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    init() {
        loadEntries()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.saveEntries()
        }
    }
    
    func loadEntries() {
        let fileURL = getDocumentsDirectory().appendingPathComponent("epanel.csv")
        do {
            let data = try String(contentsOf: fileURL)
            entries = data.components(separatedBy: .newlines).compactMap { line in
                let parts = line.components(separatedBy: ",")
                guard parts.count == 2 else { return nil }
                guard let date = dateFormatter.date(from: parts[1]) else { return nil }
                return Entry(text: parts[0], date: date)
            }
        } catch {}
    }
    
    func saveEntries() {
        let csvString = entries.map {
            "\($0.text),\(dateFormatter.string(from: $0.date))"
        }.joined(separator: "\n")
        
        do {
            try csvString.write(to: getDocumentsDirectory().appendingPathComponent("epanel.csv"), atomically: true, encoding: .utf8)
        } catch {
            showAlert(message: "Failed to save entries")
        }
    }
    
    func importEntries(from url: URL) {
        do {
            let data = try String(contentsOf: url)
            entries = data.components(separatedBy: .newlines).compactMap { line in
                let parts = line.components(separatedBy: ",")
                guard parts.count == 2, let date = dateFormatter.date(from: parts[1]) else { return nil }
                return Entry(text: parts[0], date: date)
            }
        } catch {
            showAlert(message: "Invalid file format")
        }
    }
    
    func exportEntries(to url: URL) {
        let csvString = entries.map {
            "\($0.text),\(dateFormatter.string(from: $0.date))"
        }.joined(separator: "\n")
        
        do {
            try csvString.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showAlert(message: "Export failed")
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
}

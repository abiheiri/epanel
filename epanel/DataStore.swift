// DataStore.swift
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
    @Published var notesText = "" {
        didSet {
            debouncedSaveNotes()
        }
    }
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var saveNotesWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.epanel.save", qos: .utility)

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    init() {
        loadEntries()
        loadNotes()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.saveAll()
        }
    }
    
    func loadEntries() {
        let fileURL = getDocumentsDirectory().appendingPathComponent("epanel.csv")
        do {
            let data = try String(contentsOf: fileURL)
            entries = parseCSV(data)
        } catch {}
    }

    private func parseCSV(_ data: String) -> [Entry] {
        data.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: ",")
            guard parts.count == 2,
                  let date = dateFormatter.date(from: parts[1]) else { return nil }
            return Entry(text: parts[0], date: date)
        }
    }
    
    func loadNotes() {
        let fileURL = getDocumentsDirectory().appendingPathComponent("epanel.txt")
        do {
            notesText = try String(contentsOf: fileURL)
        } catch {
            notesText = ""
        }
    }
    
    func saveAll() {
        saveEntries()
        saveNotes()
    }
    
    func saveEntries() {
        let entriesToSave = entries
        let formatter = dateFormatter
        saveQueue.async {
            let csvString = entriesToSave.map {
                "\($0.text),\(formatter.string(from: $0.date))"
            }.joined(separator: "\n")

            do {
                try csvString.write(to: self.getDocumentsDirectory().appendingPathComponent("epanel.csv"), atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(message: "Failed to save entries")
                }
            }
        }
    }
    
    func saveNotes() {
        let textToSave = notesText
        let fileURL = getDocumentsDirectory().appendingPathComponent("epanel.txt")
        saveQueue.async {
            do {
                try textToSave.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(message: "Failed to save notes")
                }
            }
        }
    }

    private func debouncedSaveNotes() {
        saveNotesWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveNotes()
        }
        saveNotesWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
    
    func importEntries(from url: URL) {
        do {
            let data = try String(contentsOf: url)
            entries = parseCSV(data)
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

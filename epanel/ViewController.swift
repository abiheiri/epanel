import Cocoa
import UniformTypeIdentifiers

class ViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    
    public var resultArray = [String]()
    private var filteredArray = [String]()

    @IBOutlet var urlText: NSTextField!
    @IBOutlet var tableView: NSTableView!

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(handleDoubleClick)

        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: NSTextField.textDidChangeNotification, object: urlText)

        loadInitialData()
        filteredArray = resultArray
        
        // Add context menu to the table view
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Go", action: #selector(handleGoAction(_:)), keyEquivalent: ""))
        // Add a separator
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteItem(_:)), keyEquivalent: ""))
        tableView.menu = menu
    }

    /** Method to load data from file **/
    private func loadInitialData(from fileURL: URL? = nil) {
        var result = ""
        let fileURL = fileURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("epanel.txt")
        
        guard let url = fileURL else {
            // Handle the error - the URL was nil
            return
        }
        
        do {
            result = try String(contentsOf: url, encoding: .utf8)
            let scrubbed = result.components(separatedBy: .whitespacesAndNewlines).joined()
            resultArray = scrubbed.components(separatedBy: ",")
            filteredArray = resultArray // Update the filtered array as well

            DispatchQueue.main.async { [weak self] in
                self?.tableView.reloadData() // Reload the table view on the main thread
            }
        } catch {
            // Handle the error, such as showing an alert to the user
            print("Error reading from file URL: \(error)")
        }
    }

    /** Text change observer method **/
    @objc func textDidChange(_ notification: Notification) {
        filterContentForSearchText(urlText.stringValue)
    }

    /** Filter method **/
    func filterContentForSearchText(_ searchText: String) {
        filteredArray = searchText.isEmpty ? resultArray : resultArray.filter { $0.lowercased().contains(searchText.lowercased()) }
        tableView.reloadData()
    }

    /** TableView Data Source Methods **/
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredArray.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        self.tableView.headerView = nil

        if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "Url") {
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "urlCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.stringValue = filteredArray[row]
            return cellView
        }
        return nil
    }
    
    /** Update urlText if left-click on tableView**/
    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        if selectedRow != -1 {
            urlText.stringValue = filteredArray[selectedRow]
        } else {
            urlText.stringValue = ""
        }
    }

    /** Add Button Action **/
    @IBAction func addButtonTapped(_ sender: Any) {
        let textField = urlText.stringValue
        if !textField.isEmpty {
            resultArray.append(textField)
            filterContentForSearchText("") // Update filteredArray using the current search text
            urlText.stringValue = ""
        }

        tableView?.reloadData()
        saveData()
    }

    /** Delete Item Action **/
    @IBAction func deleteItem(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0 && selectedRow < filteredArray.count {
            // Remove the item from the resultArray based on the filteredArray index
            let itemToDelete = filteredArray[selectedRow]
            if let indexInResultArray = resultArray.firstIndex(of: itemToDelete) {
                resultArray.remove(at: indexInResultArray)
            }
            filterContentForSearchText(urlText.stringValue)
            tableView.reloadData() // Reload table data after deletion
            saveData()
        }
    }


    /** Combined method for Double Click and Go action **/
    private func openURLFromTableView(at index: Int) {
        guard index >= 0, index < filteredArray.count else {
            print("Invalid index")
            return
        }

        let rawPath = filteredArray[index]

        // First, attempt to treat the input as a URL
        if let url = URL(string: rawPath), url.scheme != nil {
            // It's a URL with a scheme, attempt to open it as an application or webpage
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } else {
            // Treat as a local file path
            let url = URL(fileURLWithPath: rawPath)
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            
            // Check if the path exists and if it's a directory
            if fileManager.fileExists(atPath: rawPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    // It's a directory, open it in Finder
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    // It's a file, open it with its default application
                    NSWorkspace.shared.open(url)
                }
            } else {
                // The path might be incorrect or the application doesn't have access
                // print("Path does not exist or is not accessible: \(rawPath)")
            }
        }
    }


    @objc func handleDoubleClick() {
        openURLFromTableView(at: tableView.clickedRow)
    }
    
    @objc func handleGoAction(_ sender: Any) {
        openURLFromTableView(at: tableView.clickedRow)
    }
    
    /** Save Data Method **/
    func saveData(to url: URL? = nil) {
        let joined = resultArray.joined(separator: ",")
        let destinationURL = url ?? getDocumentsDirectory().appendingPathComponent("epanel.txt")

        do {
            try joined.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving file: \(error)")
        }
    }

    @IBAction func exportMenuItemClicked(_ sender: NSMenuItem) {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Data"
        savePanel.message = "Choose a location to export the data"
        savePanel.allowedContentTypes = [UTType.plainText]

        savePanel.begin { [weak self] (result) in
            if result == .OK, let url = savePanel.url {
                self?.saveData(to: url)
            }
        }
    }
    
    @IBAction func openMenuItemClicked(_ sender: NSMenuItem) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open File"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [UTType.plainText]

        openPanel.begin { [weak self] (result) in
            if result == .OK, let url = openPanel.url {
                do {
                    try self?.loadDataFromFile(url: url)
                    // Data loaded successfully, proceed to save
                    self?.saveData()
                } catch {
                    // Handle error - data was not loaded
                    print("Error loading data: \(error)")
                    // Optionally, inform the user with a dialog
                }
            }
        }
    }
    
    func loadDataFromFile(url: URL) throws {
        let result = try String(contentsOf: url, encoding: .utf8)
        let scrubbed = result.components(separatedBy: .whitespacesAndNewlines).joined()
        resultArray = scrubbed.components(separatedBy: ",")
        filteredArray = resultArray // Update the filtered array as well

        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData() // Reload the table view on the main thread
        }
    }
    
    /** Helper to get documents directory **/
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
}

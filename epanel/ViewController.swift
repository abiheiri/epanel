import Cocoa

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

    /** Method to load initial data from file **/
    private func loadInitialData() {
        var result = ""
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent("epanel.txt")
         
            do {
                result = try String(contentsOf: fileURL, encoding: .utf8)
                let scrubbed = result.components(separatedBy: .whitespacesAndNewlines).joined()
                resultArray = scrubbed.components(separatedBy: ",")
            }
            catch {/* handle if there are any errors */}
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
            urlText.stringValue = resultArray[selectedRow]
        } else {
            urlText.stringValue = ""
        }
    }

    /** Add Button Action **/
    @IBAction func addButtonTapped(_ sender: Any) {
        let textField = urlText.stringValue
        if !textField.isEmpty {
            resultArray.append(textField)
            filteredArray = resultArray
            urlText.stringValue = ""
        }
        
        tableView?.reloadData()
        saveData()
    }

    /** Delete Item Action **/
    @IBAction func deleteItem(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0 && selectedRow < resultArray.count {
            resultArray.remove(at: selectedRow)
            filteredArray = resultArray
            let indexSet = IndexSet(integer: selectedRow)
            tableView.removeRows(at: indexSet, withAnimation: .effectFade)
            saveData()
        }
    }

    /** Combined method for Double Click and Go action **/
    private func openURLFromTableView(at index: Int) {
        guard index >= 0, index < filteredArray.count,
              let url = URL(string: filteredArray[index]) else {
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    @objc func handleDoubleClick() {
        openURLFromTableView(at: tableView.clickedRow)
    }
    
    @objc func handleGoAction(_ sender: Any) {
        openURLFromTableView(at: tableView.clickedRow)
    }
    
    /** Save Data Method **/
    func saveData() {
        let joined = resultArray.joined(separator: ",")
        do {
            let filename = getDocumentsDirectory().appendingPathComponent("epanel.txt")
            try joined.write(to: filename, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving file")
        }
    }

    /** Helper to get documents directory **/
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
}

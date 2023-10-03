//
//  ViewController.swift
//  epanel
//
//  Created by Al on 11/17/22.
//

import Cocoa

class ViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    
    public var resultArray = [String]()

    @IBOutlet var urlText: NSTextField!
        
    @IBOutlet var tableView: NSTableView!
    
    /**SAVE data to txt**/
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    func saveData(){
        let joined = resultArray.joined(separator: ",")

        do {
            let filename = getDocumentsDirectory().appendingPathComponent("epanel.txt")
            try joined.write(to: filename, atomically: true, encoding: .utf8)
        } catch {
            print("error creating file")
        }
    }
    
    @objc func handleDoubleClick() {
        let clickedRow = tableView.clickedRow

        if clickedRow >= 0 {
            guard let url = URL(string: resultArray[clickedRow]) else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }
    
//  Delete menu item
    @IBAction func deleteItem(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        resultArray.remove(at: selectedRow)
        let indexSet = IndexSet(integer:selectedRow)
        tableView.removeRows(at:indexSet, withAnimation:.effectFade)
        saveData()
    }
    

    
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(handleDoubleClick)

        /*** Read from project txt file ***/
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
//        print(type(of: resultArray))
//        print(resultArray, terminator: "")
//        print(resultArray)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return resultArray.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Hide the header bar that is blank and taking up space ("Table Header View")
        self.tableView.headerView = nil;

        if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "Url"){
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "urlCell")
            //if contents are not nil, load cellView constant
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else {return nil}
            cellView.textField?.stringValue = resultArray[row]
            return cellView
        }
        return nil
        
    }
        
    @IBAction func addButtonTapped(_ sender: Any) {
        let textField = urlText.stringValue
        if !textField.isEmpty {
            resultArray.append(textField)
            urlText.stringValue = ""
        }
        
        tableView?.reloadData()
        saveData()
    }
    

}


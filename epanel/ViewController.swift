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
    
    @objc func handleDoubleClick() {
        let clickedRow = tableView.clickedRow
        
        if clickedRow >= 0 {
            guard let url = URL(string: resultArray[clickedRow]) else { return }
            if resultArray[clickedRow].contains("http://") {
                NSWorkspace.shared.open(url)
            }
            else {
                guard let addHTTP = URL(string: "http://" + resultArray[clickedRow]) else { return }
                NSWorkspace.shared.open(addHTTP)
            }

        }

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
//                for items in trimmed {
//                    print(items)
//                }
                resultArray = scrubbed.components(separatedBy: ",")

            }
            catch {/* handle if there are any errors */}
        }
//        print(type(of: resultArray))
//        print(resultArray, terminator: "")
          print(resultArray)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
//        print (resultArray.count)
        return resultArray.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
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
//            print (resultArray.count)
            urlText.stringValue = ""
        }
        
        tableView?.reloadData()
        
        
        let path = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0].appendingPathComponent("epanel.txt")
        let newLine = ","
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile() // moving pointer to the end
            try? handle.write(contentsOf: newLine.data(using: .utf8)!)
            try? handle.write(contentsOf: textField.data(using: .utf8)!)
            handle.closeFile() // closing the file
        }
    }
    
}


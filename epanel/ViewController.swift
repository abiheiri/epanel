//
//  ViewController.swift
//  epanel
//
//  Created by Al on 11/17/22.
//

import Cocoa

class ViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {

    @IBOutlet var urlText: NSTextField!
        
    @IBOutlet var tableView: NSTableView!
    
    @objc func handleDoubleClick() {
        let clickedRow = tableView.clickedRow
        
        if clickedRow >= 0 {
//            print ("CLICKED!")
            guard let url = URL(string: "https://stackoverflow.com") else { return }
            NSWorkspace.shared.open(url)
        }

    }
    
    public var resultArray = [String]()
    
    
     
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        
        tableView.doubleAction = #selector(handleDoubleClick)

        

        /*** Read from project txt file ***/
        
        var result = ""
        
        //if you get access to the directory
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
         
            //prepare file url
            let fileURL = dir.appendingPathComponent("epanel.txt")
         
            do {
                result = try String(contentsOf: fileURL, encoding: .utf8)
                resultArray = result.components(separatedBy: ",")
            }
            catch {/* handle if there are any errors */}
        }
//        print(GlobalVariables.resultArray)
//        print(type(of: GlobalVariables.resultArray))
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
//        print(sample.count)
//        print (GlobalVariables.resultArray.count)
//        return sample.count
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

        let newName = urlText.stringValue
        
        if !newName.isEmpty {
            resultArray.append(newName)
        }
        else {

        }
        
        tableView?.reloadData()
        
        
        let path = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0].appendingPathComponent("epanel.txt")
        let newLine = ","
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile() // moving pointer to the end
            try? handle.write(contentsOf: newName.data(using: .utf8)!)
            try? handle.write(contentsOf: newLine.data(using: .utf8)!)
            handle.closeFile() // closing the file
        }
    }
    
}


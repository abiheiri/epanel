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
    
    var sample = Urls.getSampleData()
    

     
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return sample.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "Url"){
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "urlCell")
            
            //if contents are not nil, load cellView constant
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else {return nil}
            
            cellView.textField?.stringValue = sample[row].name
            return cellView
        }
        return nil
    }
        
    @IBAction func addButtonTapped(_ sender: Any) {
        let newName = urlText.stringValue
        sample.append(Urls.init(name: newName))
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


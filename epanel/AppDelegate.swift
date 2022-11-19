//
//  AppDelegate.swift
//  epanel
//
//  Created by Al on 11/17/22.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    
    struct GlobalVariables {
        static var resultArray = [String]()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        /*** Read from project txt file ***/
        
        var result = ""

        //if you get access to the directory
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
         
            //prepare file url
            let fileURL = dir.appendingPathComponent("epanel.txt")
         
            do {
                result = try String(contentsOf: fileURL, encoding: .utf8)
                GlobalVariables.resultArray = result.components(separatedBy: ",")
            }
            catch {/* handle if there are any errors */}
        }
        print(GlobalVariables.resultArray)
        print(type(of: GlobalVariables.resultArray))
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        

    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}


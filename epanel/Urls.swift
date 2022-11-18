//
//  Person.swift
//  epanel
//
//  Created by Al on 11/17/22.
//

import Foundation


struct Urls {
    
    var name : String
    
    init (name: String) {
        self.name = name
    }
    
    static func getSampleData() -> [Urls] {
        let p1 = Urls(name: "http://www.abiheiri.com"),
            p2 = Urls(name: "www.github.com"),
            p3 = Urls(name: "www.duckduckgo.com"),
            p4 = Urls(name: "news.google.com")
        return [p1,p2,p3,p4]
    }
}

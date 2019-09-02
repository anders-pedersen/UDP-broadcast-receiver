//
//  ViewController.swift
//  UDP receiver
//
//  Created by Anders Pedersen on 16/03/2019.
//  Copyright © 2019 Anders Pedersen. All rights reserved.
//

import UIKit
import CocoaAsyncSocket

class ViewController: UIViewController, GCDAsyncUdpSocketDelegate {

    var address = "255.255.255.255"
    var port:UInt16 = 5556
    var socket:GCDAsyncUdpSocket!
    var socketReceive:GCDAsyncUdpSocket!
    var error : NSError?
    var output = ""
    @IBOutlet weak var textarea: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        socket = GCDAsyncUdpSocket(delegate: self, delegateQueue: DispatchQueue.main)
        textarea.isEditable = false
        
        do {
            try socket.bind(toPort: port)
        } catch {
            print(error)
        }
        
        do {
            try socket.enableBroadcast(true)
        } catch {
            print(error)
        }
        
        do {
            try socket.beginReceiving()
        } catch {
            print(error)
        }
        
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didConnectToAddress address: Data) {
        print("didConnectToAddress");
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotConnect error: Error?) {
        print("didNotConnect \(String(describing: error))")
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {
        print("didSendDataWithTag")
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        print("didNotSendDataWithTag")
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        var host: NSString?
        var port1: UInt16 = 0
        GCDAsyncUdpSocket.getHost(&host, port: &port1, fromAddress: address)
        let gotdata: NSString = NSString(data: data, encoding: String.Encoding.utf8.rawValue)!
        if !(host!.contains("ffff")) {
            updateTextarea("\(host!): \(gotdata)")
        }
    }
    
    func updateTextarea(_ data: String) {
        let timestamp = DateFormatter.localizedString(from: Date() , dateStyle: .none, timeStyle: .medium)
        output = output + timestamp + " - " + data + "\n"
        textarea.text = output
        if textarea.text.count > 0 {
            let location = textarea.text.count - 1
            let bottom = NSMakeRange(location, 1)
            textarea.scrollRangeToVisible(bottom)
        }
    }

}


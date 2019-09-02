//
//  UDPBroadcastConnection.swift
//  UDPBroadcast
//
//  Created by Gunter Hager on 10.02.16.
//  Copyright © 2016 Gunter Hager. All rights reserved.
//

import Foundation
import Darwin

// Addresses

let INADDR_ANY = in_addr(s_addr: 0)
let INADDR_BROADCAST = in_addr(s_addr: 0xffffffff)


/// An object representing the UDP broadcast connection. Uses a dispatch source to handle the incoming traffic on the UDP socket.
open class UDPBroadcastConnection {
    
    // MARK: Properties
    
    /// The address of the UDP socket.
    var address: sockaddr_in
    
    /// Closure that handles incoming UDP packets.
    var handler: ((_ ipAddress: String, _ port: Int, _ response: [UInt8]) -> Void)?
    
    /// A dispatch source for reading data from the UDP socket.
    var responseSource: DispatchSourceRead?
    
    /// The dispatch queue to run responseSource & reconnection on
    var dispatchQueue: DispatchQueue = DispatchQueue.main
    
    /// Bind to port to start listening without first sending a message
    var shouldBeBound: Bool = false
    
    // MARK: Initializers
    
    /**
     Initializes the UDP connection with the correct port address. Note: this doesn't open a socket! The socket is opened transparently as needed when sending broadcast messages.
     
     - parameter port: Number of the UDP port to use.
     
     - returns: Returns an initialized UDP broadcast connection.
     */
    public init(port: UInt16, bindIt: Bool = false, handler: ((_ ipAddress: String, _ port: Int, _ response: [UInt8]) -> Void)?) {
        self.address = sockaddr_in(
            sin_len:    __uint8_t(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port:   UDPBroadcastConnection.htonsPort(port: port),
            sin_addr:   INADDR_BROADCAST,
            sin_zero:   ( 0, 0, 0, 0, 0, 0, 0, 0 )
        )
        
        self.handler = handler
        self.shouldBeBound = bindIt
        if bindIt {
            _ = createSocket()
        }
    }
    
    deinit {
        if responseSource != nil {
            responseSource!.cancel()
        }
    }
    
    // MARK: Interface
    
    
    /**
     Create a UDP socket for broadcasting and set up cancel and event handlers
     
     - returns: Returns true if the socket was created successfully.
     */
    fileprivate func createSocket() -> Bool {
        
        // Create new socket
        let newSocket: Int32 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard newSocket > 0 else { return false }
        
        // Enable broadcast on socket
        var broadcastEnable = Int32(1);
        let ret = setsockopt(newSocket, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<UInt32>.size));
        if ret == -1 {
            debugPrint("Couldn't enable broadcast on socket")
            close(newSocket)
            return false
        }
        
        if shouldBeBound {
            var saddr = sockaddr(sa_len: 0, sa_family: 0,
                                 sa_data: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            self.address.sin_addr = INADDR_ANY
            memcpy(&saddr, &self.address, MemoryLayout<sockaddr_in>.size)
            self.address.sin_addr = INADDR_BROADCAST
            let isBound = bind(newSocket, &saddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            if isBound == -1 {
                debugPrint("Couldn't bind socket")
                close(newSocket)
                return false
            }
        }
        
        // Disable global SIGPIPE handler so that the app doesn't crash
        setNoSigPipe(socket: newSocket)
        
        // Set up a dispatch source
        let newResponseSource = DispatchSource.makeReadSource(fileDescriptor: newSocket, queue: dispatchQueue)
        
        // Set up cancel handler
        newResponseSource.setCancelHandler {
            debugPrint("Closing UDP socket")
            let UDPSocket = Int32(newResponseSource.handle)
            shutdown(UDPSocket, SHUT_RDWR)
            close(UDPSocket)
        }
        
        // Set up event handler (gets called when data arrives at the UDP socket)
        newResponseSource.setEventHandler { [unowned self] in
            guard let source = self.responseSource else { return }
            
            var socketAddress = sockaddr_storage()
            var socketAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let response = [UInt8](repeating: 0, count: 4096)
            let UDPSocket = Int32(source.handle)
            
            let bytesRead = withUnsafeMutablePointer(to: &socketAddress) {
                recvfrom(UDPSocket, UnsafeMutableRawPointer(mutating: response), response.count, 0, UnsafeMutableRawPointer($0).bindMemory(to: sockaddr.self, capacity: 1), &socketAddressLength)
            }
            
            guard bytesRead >= 0 else {
                if let errorString = String(validatingUTF8: strerror(errno)) {
                    debugPrint("recvfrom failed: \(errorString)")
                }
                self.closeConnection()
                return
            }
            
            guard bytesRead > 0 else {
                debugPrint("recvfrom returned EOF")
                self.closeConnection()
                return
            }
            
            guard let endpoint = withUnsafePointer(to: &socketAddress, { self.getEndpointFromSocketAddress(socketAddressPointer: UnsafeRawPointer($0).bindMemory(to: sockaddr.self, capacity: 1)) })
                else {
                    debugPrint("Failed to get the address and port from the socket address received from recvfrom")
                    self.closeConnection()
                    return
            }
            
            debugPrint("UDP connection received \(bytesRead) bytes from \(endpoint.host):\(endpoint.port)")
            
            // Handle response
            self.handler?(endpoint.host, endpoint.port, response)
        }
        
        newResponseSource.resume()
        responseSource = newResponseSource
        
        return true
    }
    
    /**
     Send broadcast message.
     
     - parameter message: Message to send via broadcast.
     */
    open func sendBroadcast(_ message: String) {
        
        guard let data = message.data(using: .utf8) else { return }
        sendBroadcast(data)
    }
    
    /// Send broadcast data.
    ///
    /// - Parameter data: Data to send via broadcast.
    open func sendBroadcast(_ data: Data) {
        if responseSource == nil {
            guard createSocket() else {
                debugPrint("UDP ServerConnection initialization failed.")
                return
            }
        }
        
        guard let source = responseSource else { return }
        let UDPSocket = Int32(source.handle)
        let socketLength = socklen_t(address.sin_len)
        data.withUnsafeBytes { (broadcastMessage: UnsafePointer<Int8>) in
            let broadcastMessageLength = data.count
            let sent = withUnsafeMutablePointer(to: &address) { pointer -> Int in
                let memory = UnsafeRawPointer(pointer).bindMemory(to: sockaddr.self, capacity: 1)
                return sendto(UDPSocket, broadcastMessage, broadcastMessageLength, 0, memory, socketLength)
            }
            
            guard sent > 0 else {
                if let errorString = String(validatingUTF8: strerror(errno)) {
                    debugPrint("UDP connection failed to send data: \(errorString)")
                }
                closeConnection()
                return
            }
            
            if sent == broadcastMessageLength {
                // Success
                debugPrint("UDP connection sent \(broadcastMessageLength) bytes")
            }
        }
    }
    
    /**
     Close the connection.
     */
    open func closeConnection(_ reopen: Bool = true) {
        if let source = responseSource {
            source.cancel()
            responseSource = nil
        }
        if shouldBeBound && reopen {
            dispatchQueue.async {
                _ = self.createSocket()
            }
        }
    }
    
    // MARK: - Helper
    
    /**
     Convert a sockaddr structure into an IP address string and port.
     
     - parameter socketAddressPointer: Pointer to a socket address.
     
     - returns: Returns a tuple of the host IP address and the port in the socket address given.
     */
    func getEndpointFromSocketAddress(socketAddressPointer: UnsafePointer<sockaddr>) -> (host: String, port: Int)? {
        let socketAddress = UnsafePointer<sockaddr>(socketAddressPointer).pointee
        
        switch Int32(socketAddress.sa_family) {
        case AF_INET:
            var socketAddressInet = UnsafeRawPointer(socketAddressPointer).load(as: sockaddr_in.self)
            let length = Int(INET_ADDRSTRLEN) + 2
            var buffer = [CChar](repeating: 0, count: length)
            let hostCString = inet_ntop(AF_INET, &socketAddressInet.sin_addr, &buffer, socklen_t(length))
            let port = Int(UInt16(socketAddressInet.sin_port).byteSwapped)
            return (String(cString: hostCString!), port)
            
        case AF_INET6:
            var socketAddressInet6 = UnsafeRawPointer(socketAddressPointer).load(as: sockaddr_in6.self)
            let length = Int(INET6_ADDRSTRLEN) + 2
            var buffer = [CChar](repeating: 0, count: length)
            let hostCString = inet_ntop(AF_INET6, &socketAddressInet6.sin6_addr, &buffer, socklen_t(length))
            let port = Int(UInt16(socketAddressInet6.sin6_port).byteSwapped)
            return (String(cString: hostCString!), port)
            
        default:
            return nil
        }
    }
    
    
    // MARK: - Private
    
    fileprivate func setNoSigPipe(socket: CInt) {
        // prevents crashes when blocking calls are pending and the app is paused ( via Home button )
        var no_sig_pipe: Int32 = 1;
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sig_pipe, socklen_t(MemoryLayout<Int32>.size));
    }
    
    fileprivate class func htonsPort(port: in_port_t) -> in_port_t {
        let isLittleEndian = Int(OSHostByteOrder()) == OSLittleEndian
        return isLittleEndian ? _OSSwapInt16(port) : port
    }
    
    fileprivate class func ntohs(value: CUnsignedShort) -> CUnsignedShort {
        return (value << 8) + (value >> 8)
    }
    
}




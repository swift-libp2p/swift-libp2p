//
//  Client+SingleRequest.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIOCore
import Foundation

extension Application {
    // We need a method on libp2p that acts as a request / response mechanism for streams
    /// ex: newRequest(to, forProtocol:, withRequest: ) -> EventLoopFuture<Response>
    /// the stream is negotiated, the data sent, the response buffered and provided once ready, then the stream is closed...
    public func newRequest(to ma:Multiaddr, forProtocol proto:String, withRequest request:Data, style:SingleRequest.Style = .responseExpected, withHandlers handlers:HandlerConfig = .rawHandlers([]), andMiddleware middleware:MiddlewareConfig = .custom(nil), withTimeout timeout:TimeAmount = .seconds(3)) -> EventLoopFuture<Data> {
        let promise = self.eventLoopGroup.next().makePromise(of: Data.self)
        //let singleRequest =
        promise.completeWith( SingleRequest(to: ma, overProtocol: proto, withRequest: request, withHandlers: handlers, andMiddleware: middleware, on: self.eventLoopGroup.next(), host: self, withTimeout: timeout).resume(style: style) )
        return promise.futureResult
    }
    
    public func newRequest(to peer:PeerID, forProtocol proto:String, withRequest request:Data, style:SingleRequest.Style = .responseExpected, withHandlers handlers:HandlerConfig = .rawHandlers([]), andMiddleware middleware:MiddlewareConfig = .custom(nil), withTimeout timeout:TimeAmount = .seconds(3)) -> EventLoopFuture<Data> {
        let el = self.eventLoopGroup.next()
        
        return self.peers.getAddresses(forPeer: peer, on: el).flatMap { addresses -> EventLoopFuture<Data> in
            guard addresses.count > 0 else { return el.makeFailedFuture( Errors.noKnownAddressesForPeer )  }
            
            // Check to see if we have a transport thats capable of dialing any of these addresses...
            // - TODO: Maybe instead of just returning the first transport found, we return the best transport (like one that's already muxed, or with low latency, or recently interacted with)
            return self.transports.canDialAny(addresses, on: el).flatMap { match -> EventLoopFuture<Data> in
                let singleRequest = SingleRequest(to: match, overProtocol: proto, withRequest: request, withHandlers: handlers, andMiddleware: middleware, on: self.eventLoopGroup.next(), host: self, withTimeout: timeout)
                return singleRequest.resume(style: style)
            }
        }
    }
    
    public class SingleRequest {
        let eventloop:EventLoop
        let promise:EventLoopPromise<Data>
        let multiaddr:Multiaddr
        let proto:String
        let request:Data
        let handlers:HandlerConfig
        let middleware:MiddlewareConfig
        
        weak var host:Application?
        
        var hasBegun:Bool = false
        var hasCompleted:Bool = false
        let timeout:TimeAmount
        var timeoutTask:Scheduled<Void>? = nil
        
        enum Errors:Error {
            case NoHost
            case FailedToOpenStream
            case TimedOut
        }
        
        public enum Style {
            case responseExpected
            case noResponseExpected
        }
        
        init(to ma:Multiaddr, overProtocol proto:String, withRequest request:Data, withHandlers handlers:HandlerConfig = .rawHandlers([]), andMiddleware middleware: MiddlewareConfig = .custom(nil), on el:EventLoop, host:Application, withTimeout timeout:TimeAmount = .seconds(3)) {
            self.eventloop = el
            self.host = host
            self.multiaddr = ma
            self.proto = proto
            self.request = request
            self.handlers = handlers
            self.middleware = middleware
            self.timeout = timeout
            self.promise = self.eventloop.makePromise(of: Data.self)
        }
        
        deinit {
            print("Single Request Deinitialized")
        }
        
        func resume(style:Style = .responseExpected) -> EventLoopFuture<Data> {
            guard !hasBegun, let host = host else { return self.eventloop.makeFailedFuture(Errors.NoHost) }
            hasBegun = true
            
            do {
                try host.newStream(to: self.multiaddr, forProtocol: self.proto, withHandlers: handlers, andMiddleware: middleware) { req -> EventLoopFuture<Response> in
                    switch req.event {
                    case .ready:
                        // If the stream is ready and we have data to send... let's send it...
                        return req.eventLoop.makeSucceededFuture(Response(payload: req.allocator.buffer(bytes: self.request.bytes))).always { _ in
                            if style == .noResponseExpected {
                                self.hasCompleted = true
                                req.shouldClose()
                                self.timeoutTask?.cancel()
                                self.promise.succeed(Data())
                            }
                        }
                        
                    case .data(let response):
                        self.hasCompleted = true
                        req.shouldClose()
                        self.timeoutTask?.cancel()
                        self.promise.succeed(Data(response.readableBytesView))
                        
                        
                    case .closed:
                        if !self.hasCompleted {
                            self.hasCompleted = true
                            req.logger.error("Stream Closed before we got our response")
                            self.promise.fail(Errors.FailedToOpenStream)
                        }
                        self.timeoutTask?.cancel()
                        req.shouldClose()
                        
                    case .error(let error):
                        self.hasCompleted = true
                        req.logger.error("Stream Error - \(error)")
                        self.promise.fail(error)
                        self.timeoutTask?.cancel()
                        req.shouldClose()
                    }
                    
                    return req.eventLoop.makeSucceededFuture(Response(payload: req.allocator.buffer(bytes: [])))
                }
                
                /// Enforce a 3 second timeout on the request...
                self.timeoutTask = self.eventloop.scheduleTask(in: self.timeout) { [weak self] in
                    guard let self = self, self.hasBegun && !self.hasCompleted else { return }
                    self.hasCompleted = true
                    self.promise.fail(Errors.TimedOut)
                }
                
            } catch {
                self.eventloop.execute {
                    self.promise.fail(error)
                }
            }
            
            return promise.futureResult
        }
    }
}

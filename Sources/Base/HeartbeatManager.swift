//
//  BeatManager.swift
//  Pods
//
//  Created by Marcel Dittmann on 23.04.16.
//
//

import Foundation
import Gloss
import Alamofire

public enum BridgeHeartbeatConnectionStatusNotification: String {
    
    case localConnection, notAuthenticated, nolocalConnection
}

public enum HeartbeatBridgeResourceType: String {
    case lights, groups, scenes, sensors, rules, config, schedules
}

public protocol HeartbeatProcessor {
    
    func processJSON(_ json: JSON, forResourceType resourceType: HeartbeatBridgeResourceType)
}

public class HeartbeatManager {
    
    private let bridgeAccesssConfig: BridgeAccessConfig;
    private var localHeartbeatTimers = [HeartbeatBridgeResourceType: Timer]()
    private var localHeartbeatTimerIntervals = [HeartbeatBridgeResourceType: TimeInterval]()
    private var heartbeatProcessors: [HeartbeatProcessor];
    
    private var lastLocalConnectionNotificationPostTime: TimeInterval?
    private var lastNoLocalConnectionNotificationPostTime: TimeInterval?

    public init(bridgeAccesssConfig: BridgeAccessConfig, heartbeatProcessors: [HeartbeatProcessor]) {
        self.bridgeAccesssConfig = bridgeAccesssConfig
        self.heartbeatProcessors = heartbeatProcessors;
    }
    
    internal func setLocalHeartbeatInterval(_ interval: TimeInterval, forResourceType resourceType: HeartbeatBridgeResourceType) {
        
        localHeartbeatTimerIntervals[resourceType] = interval
    }
    
    internal func removeLocalHeartbeat(forResourceType resourceType: HeartbeatBridgeResourceType) {
        
        if let timer = localHeartbeatTimers.removeValue(forKey: resourceType) {
            
            timer.invalidate()
        }
    }
    
    internal func startHeartbeat() {
       
        for (resourceType, timerInterval) in localHeartbeatTimerIntervals {
            
            // Do Initial Request
            doRequestForResourceType(resourceType)
            
            // Create Timer
            let timer = Timer(timeInterval: timerInterval, target: self, selector: #selector(HeartbeatManager.timerAction), userInfo: resourceType.rawValue, repeats: true);
            
            // Store timer
            localHeartbeatTimers[resourceType] = timer;
            
            // Add Timer to RunLoop
            RunLoop.current.add(timer, forMode: RunLoop.Mode.default)
        }
    }
    
    internal func stopHeartbeat() {
        
        for (resourceType, timer) in localHeartbeatTimers {
            
            timer.invalidate()
            localHeartbeatTimers.removeValue(forKey: resourceType)
        }
    }
    
    @objc func timerAction(_ timer: Timer) {
        
        let resourceType: HeartbeatBridgeResourceType = HeartbeatBridgeResourceType(rawValue: timer.userInfo! as! String)!
        doRequestForResourceType(resourceType)
    }
    
    private func doRequestForResourceType(_ resourceType: HeartbeatBridgeResourceType) {

        let url = "http://\(bridgeAccesssConfig.ipAddress)/api/\(bridgeAccesssConfig.username)/\(resourceType.rawValue.lowercased())"

        print("Heartbeat Request", "\(url)")
        
        AF.request(url).responseJSON { response in // method
            
            switch response.result {
            case .success:
                self.handleSuccessResponseResult(response.result, resourceType: resourceType)
                self.notifyAboutLocalConnection()
                
            case .failure(let error):
                
                self.notifyAboutNoLocalConnection()
                print("Heartbeat Request Error: ", error)
            }
            
        }
    }
    
    // MARK: Timer Action Response Handling
    
    private func handleSuccessResponseResult(_ result: Result<Any, AFError>, resourceType: HeartbeatBridgeResourceType) {
        
        print("Heartbeat Response for Resource Type \(resourceType.rawValue.lowercased()) received")
        //Log.trace("Heartbeat Response: \(resourceType.rawValue.lowercaseString): ", result.value)
        
        if case .success(let data) = result {
            if responseResultIsPhilipsAPIErrorType(result: result, resourceType: resourceType) {
                
                
                if let resultValueJSONArray = data as? [JSON] {
                    
                    self.handleErrors(resultValueJSONArray)
                }
        } else {
            
            if let resultValueJSON = data as? JSON {
                
                for heartbeatProcessor in self.heartbeatProcessors {
                    heartbeatProcessor.processJSON(resultValueJSON, forResourceType: resourceType)
                }
                
                self.notifyAboutLocalConnection()
                
            }
        }
    }
}
    
    private func responseResultIsPhilipsAPIErrorType(result: Result<Any, AFError>, resourceType: HeartbeatBridgeResourceType) -> Bool {
        if case .success(let data) = result {
            switch resourceType {
            
            case .config:
                
                if let resultValueJSON = data as? JSON {
                    
                    return resultValueJSON.count <= 8 // HUE API gives always a respond for config request, but it only contains 8 Elements if no authorized user is used
                }
                
            default:
                
                return data as? [JSON] != nil // Errros are delivered as Array
            }
        }
        
        return false
    }
    
    private func handleErrors(_ jsonErrorArray: [JSON]) {
        
        for jsonError in jsonErrorArray {
            
            print("Hearbeat received Error Result", jsonError)
            let error = HueError(json: jsonError)
            if let error = error {
                self.notifyAboutError(error)
            }
        }
    }
    
    // MARK: Notification
    
    private func notifyAboutLocalConnection() {
        
        if lastLocalConnectionNotificationPostTime == nil || Date().timeIntervalSince1970 - lastLocalConnectionNotificationPostTime! > 10 {
            
            let notification = BridgeHeartbeatConnectionStatusNotification(rawValue: "localConnection")!
            print("Post Notification:", notification.rawValue)
            NotificationCenter.default.post(name: Notification.Name(rawValue: notification.rawValue), object: nil)
            
            self.lastLocalConnectionNotificationPostTime = Date().timeIntervalSince1970;
            
            // Make sure we instant notify about losing connection
            self.lastNoLocalConnectionNotificationPostTime = nil;
        }
    }
    
    private func notifyAboutNoLocalConnection() {
        
        if lastNoLocalConnectionNotificationPostTime == nil || Date().timeIntervalSince1970 - lastNoLocalConnectionNotificationPostTime! > 10 {
            
            let notification = BridgeHeartbeatConnectionStatusNotification(rawValue: "nolocalConnection")!
            print("Post Notification:", notification.rawValue)
            NotificationCenter.default.post(name: Notification.Name(rawValue: notification.rawValue), object: nil)
            
            self.lastNoLocalConnectionNotificationPostTime = Date().timeIntervalSince1970;
            
            // Make sure we instant notify about getting connection
            self.lastLocalConnectionNotificationPostTime = nil;
        }
    }
    
    private func notifyAboutError(_ error: HueError) {
        
        var notification: BridgeHeartbeatConnectionStatusNotification?;
        
        switch(error.type) {
            
        case .unauthorizedUser:
            notification = BridgeHeartbeatConnectionStatusNotification(rawValue: "notAuthenticated")
        default:
            break;
        }
        
        if let notification = notification {
            
            print("Post Notification: ", notification.rawValue)
            NotificationCenter.default.post(name: Notification.Name(rawValue: notification.rawValue), object: nil)
        }
    }
}
//
////
////  Result.swift
////
////  Copyright (c) 2014-2016 Alamofire Software Foundation (http://alamofire.org/)
////
////  Permission is hereby granted, free of charge, to any person obtaining a copy
////  of this software and associated documentation files (the "Software"), to deal
////  in the Software without restriction, including without limitation the rights
////  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
////  copies of the Software, and to permit persons to whom the Software is
////  furnished to do so, subject to the following conditions:
////
////  The above copyright notice and this permission notice shall be included in
////  all copies or substantial portions of the Software.
////
////  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
////  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
////  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
////  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
////  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
////  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
////  THE SOFTWARE.
////
//
///// Used to represent whether a request was successful or encountered an error.
/////
///// - success: The request and all post processing operations were successful resulting in the serialization of the
/////            provided associated value.
/////
///// - failure: The request encountered an error resulting in a failure. The associated values are the original data
/////            provided by the server as well as the error that caused the failure.
//public enum Result<Value> {
//    case success(Value)
//    case failure(Error)
//
//    /// Returns `true` if the result is a success, `false` otherwise.
//    public var isSuccess: Bool {
//        switch self {
//        case .success:
//            return true
//        case .failure:
//            return false
//        }
//    }
//
//    /// Returns `true` if the result is a failure, `false` otherwise.
//    public var isFailure: Bool {
//        return !isSuccess
//    }
//
//    /// Returns the associated value if the result is a success, `nil` otherwise.
//    public var value: Value? {
//        switch self {
//        case .success(let value):
//            return value
//        case .failure:
//            return nil
//        }
//    }
//
//    /// Returns the associated error value if the result is a failure, `nil` otherwise.
//    public var error: Error? {
//        switch self {
//        case .success:
//            return nil
//        case .failure(let error):
//            return error
//        }
//    }
//}
//
//// MARK: - CustomStringConvertible
//extension Result: CustomStringConvertible {
//    /// The textual representation used when written to an output stream, which includes whether the result was a
//    /// success or failure.
//    public var description: String {
//        switch self {
//        case .success:
//            return "SUCCESS"
//        case .failure:
//            return "FAILURE"
//        }
//    }
//}
//
//// MARK: - CustomDebugStringConvertible
//extension Result: CustomDebugStringConvertible {
//    /// The debug textual representation used when written to an output stream, which includes whether the result was a
//    /// success or failure in addition to the value or error.
//    public var debugDescription: String {
//        switch self {
//        case .success(let value):
//            return "SUCCESS: \(value)"
//        case .failure(let error):
//            return "FAILURE: \(error)"
//        }
//    }
//}

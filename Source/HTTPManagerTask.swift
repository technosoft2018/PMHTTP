//
//  HTTPManagerTask.swift
//  PostmatesNetworking
//
//  Created by Kevin Ballard on 1/4/16.
//  Copyright © 2016 Postmates. All rights reserved.
//

import Foundation
import PMHTTPPrivate

/// An initiated HTTP operation.
public final class HTTPManagerTask: NSObject {
    public typealias State = HTTPManagerTaskState
    
    /// The underlying `NSURLSessionTask`.
    public let networkTask: NSURLSessionTask
    
    /// The `NSURLCredential` used to authenticate the request, if any.
    public let credential: NSURLCredential?
    
    /// The current state of the task.
    /// - Note: This property is thread-safe and may be accessed concurrently.
    /// - Note: This property supports KVO. The KVO notifications will execute
    ///   on an arbitrary thread.
    public var state: State {
        return State(_stateBox.state)
    }
    
    @objc private static let automaticallyNotifiesObserversOfState: Bool = false
    
    /// Cancels the operation, if it hasn't already completed.
    ///
    /// If the operation is still talking to the network, the underlying network
    /// task is canceled. If the operation is processing the results, the
    /// results processor is canceled at the earliest opportunity.
    ///
    /// Calling this on a task that's already moved to `.Completed` is a no-op.
    public func cancel() {
        willChangeValueForKey("state")
        defer { didChangeValueForKey("state") }
        let result = _stateBox.transitionStateTo(.Canceled)
        if result.completed && result.oldState != .Canceled {
            networkTask.cancel()
        }
    }
    
    internal let userInitiated: Bool
    internal let followRedirects: Bool
    internal let defaultResponseCacheStoragePolicy: NSURLCacheStoragePolicy
    #if os(iOS)
    internal let trackingNetworkActivity: Bool
    #endif
    
    internal init(networkTask: NSURLSessionTask, request: HTTPManagerRequest) {
        self.networkTask = networkTask
        self.credential = request.credential
        self.userInitiated = request.userInitiated
        self.followRedirects = request.shouldFollowRedirects
        self.defaultResponseCacheStoragePolicy = request.defaultResponseCacheStoragePolicy
        #if os(iOS)
            self.trackingNetworkActivity = request.affectsNetworkActivityIndicator
        #endif
        super.init()
    }
    
    internal func transitionStateTo(newState: State) -> (ok: Bool, oldState: State) {
        willChangeValueForKey("state")
        defer { didChangeValueForKey("state") }
        let result = _stateBox.transitionStateTo(newState.boxState)
        return (result.completed, State(result.oldState))
    }
    
    private let _stateBox = PMHTTPManagerTaskStateBox(state: State.Running.boxState)
}

extension HTTPManagerTask : CustomDebugStringConvertible {
    // NSObject already conforms to CustomStringConvertible
    
    public override var description: String {
        return getDescription(false)
    }
    
    public override var debugDescription: String {
        return getDescription(true)
    }
    
    private func getDescription(debug: Bool) -> String {
        var s = "<HTTPManagerTask: 0x\(String(unsafeBitCast(unsafeAddressOf(self), UInt.self), radix: 16)) (\(state))"
        if let user = credential?.user {
            s += " user=\(String(reflecting: user))"
        }
        if userInitiated {
            s += " userInitiated"
        }
        if followRedirects {
            s += " followRedirects"
        }
        #if os(iOS)
            if trackingNetworkActivity {
                s += " trackingNetworkActivity"
            }
        #endif
        if debug {
            s += " networkTask=\(networkTask)"
        }
        s += ">"
        return s
    }
}

// MARK: HTTPManagerTaskState

/// The state of an `HTTPManagerTask`.
@objc public enum HTTPManagerTaskState: CUnsignedChar, CustomStringConvertible {
    // Important: The constants here must match those defined in PMHTTPManagerTaskStateBoxState
    
    /// The task is currently running.
    case Running = 0
    /// The task is processing results (e.g. parsing JSON).
    case Processing = 1
    /// The task has been canceled. The completion handler may or may not
    /// have been invoked yet.
    case Canceled = 2
    /// The task has completed. The completion handler may or may not have
    /// been invoked yet.
    case Completed = 3
    
    public var description: String {
        switch self {
        case .Running: return "Running"
        case .Processing: return "Processing"
        case .Canceled: return "Canceled"
        case .Completed: return "Completed"
        }
    }
    
    private init(_ boxState: PMHTTPManagerTaskStateBoxState) {
        self = unsafeBitCast(boxState, HTTPManagerTaskState.self)
    }
    
    private var boxState: PMHTTPManagerTaskStateBoxState {
        return unsafeBitCast(self, PMHTTPManagerTaskStateBoxState.self)
    }
}

// MARK: - HTTPManagerTaskResult

/// The results of an HTTP request.
public enum HTTPManagerTaskResult<Value> {
    /// The task finished successfully.
    case Success(NSURLResponse, Value)
    /// An error occurred, either during networking or while processing the
    /// data.
    ///
    /// The `ErrorType` may be `NSError` for errors returned by `NSURLSession`,
    /// `HTTPManagerError` for errors returned by this class, or any error type
    /// thrown by a parse handler (including JSON errors returned by `PMJSON`).
    case Error(NSURLResponse?, ErrorType)
    /// The task was canceled before it completed.
    case Canceled
    
    /// Returns the `Value` from a successful task result, otherwise returns `nil`.
    public var success: Value? {
        switch self {
        case .Success(_, let value): return value
        default: return nil
        }
    }
    
    /// Returns the `NSURLResponse` from a successful task result. For errored results,
    /// if the error includes a response, the response is returned. Otherwise,
    /// returns `nil`.
    public var URLResponse: NSURLResponse? {
        switch self {
        case .Success(let response, _): return response
        case .Error(let response, _): return response
        case .Canceled: return nil
        }
    }
    
    /// Returns the `ErrorType` from an errored task result, otherwise returns `nil`.
    public var error: ErrorType? {
        switch self {
        case .Error(_, let error): return error
        default: return nil
        }
    }
    
    /// Returns `true` iff `self` is `.Success`.
    public var isSuccess: Bool {
        switch self {
        case .Success: return true
        default: return false
        }
    }
    
    /// Returns `true` iff `self` is `.Error`.
    public var isError: Bool {
        switch self {
        case .Error: return true
        default: return false
        }
    }
    
    /// Returns `true` iff `self` is `.Canceled`.
    public var isCanceled: Bool {
        switch self {
        case .Canceled: return true
        default: return false
        }
    }
    
    /// Maps a successful task result through the given block.
    /// Errored and canceled results are returned as they are.
    public func map<T>(@noescape f: (NSURLResponse, Value) throws -> T) rethrows -> HTTPManagerTaskResult<T> {
        switch self {
        case let .Success(response, value): return .Success(response, try f(response, value))
        case let .Error(response, type): return .Error(response, type)
        case .Canceled: return .Canceled
        }
    }
    
    /// Maps a successful task result through the given block.
    /// Errored and canceled results are returned as they are.
    /// Errors thrown by the block are caught and turned into `.Error` results.
    public func map<T>(@noescape `try` f: (NSURLResponse, Value) throws -> T) -> HTTPManagerTaskResult<T> {
        switch self {
        case let .Success(response, value):
            do {
                return .Success(response, try f(response, value))
            } catch {
                return .Error(response, error)
            }
        case let .Error(response, type): return .Error(response, type)
        case .Canceled: return .Canceled
        }
    }
    
    /// Maps a successful task result through the given block.
    /// Errored and canceled results are returned as they are.
    public func andThen<T>(@noescape f: (NSURLResponse, Value) throws -> HTTPManagerTaskResult<T>) rethrows -> HTTPManagerTaskResult<T> {
        switch self {
        case let .Success(response, value): return try f(response, value)
        case let .Error(response, type): return .Error(response, type)
        case .Canceled: return .Canceled
        }
    }
    
    /// Maps a successful task result through the given block.
    /// Errored and canceled results are returned as they are.
    /// Errors thrown by the block are caught and turned into `.Error` results.
    public func andThen<T>(@noescape `try` f: (NSURLResponse, Value) throws -> HTTPManagerTaskResult<T>) -> HTTPManagerTaskResult<T> {
        switch self {
        case let .Success(response, value):
            do {
                return try f(response, value)
            } catch {
                return .Error(response, error)
            }
        case let .Error(response, type): return .Error(response, type)
        case .Canceled: return .Canceled
        }
    }
}

extension HTTPManagerTaskResult : CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .Success(response, value):
            return "Success(\(response), \(String(reflecting: value)))"
        case let .Error(response, error):
            return "Error(\(response), \(String(reflecting: error)))"
        case .Canceled:
            return "Canceled"
        }
    }
}

public func ??<Value>(result: HTTPManagerTaskResult<Value>, @autoclosure defaultValue: () throws -> HTTPManagerTaskResult<Value>) rethrows -> HTTPManagerTaskResult<Value> {
    switch result {
    case .Success: return result
    default: return try defaultValue()
    }
}

public func ??<Value>(result: HTTPManagerTaskResult<Value>, @autoclosure defaultValue: () throws -> Value) rethrows -> Value {
    switch result {
    case .Success(_, let value): return value
    default: return try defaultValue()
    }
}
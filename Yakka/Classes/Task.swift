//
//  Task.swift
//  Pods
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation

public class Task: NSObject {
    
    
    // MARK: - Types
    
    public enum State {
        
        // Running cases
        case notStarted, running, cancelling
        
        // Finished cases
        case successful, cancelled, failed
    }
    
    public typealias FinishHandler = (_ state: State)->()
    public typealias ProgressHandler = (_ percent: Float)->()
    public typealias TaskFinishBlock = (_ state: State)->()
    public typealias TaskWorkBlock = (_ progress: @escaping ProgressHandler, _ finish: @escaping TaskFinishBlock)->()
    
    
    
    // MARK: - Properties
    
    public final private(set) var identifier = UUID().uuidString
    public final var queueForWork: DispatchQueue = DispatchQueue(label: "YakkaWorkQueue", attributes: .concurrent)
    public final var queueForFeedback = DispatchQueue.main
    public final private(set) var currentState = State.notStarted
    
    private let _internalQueue = DispatchQueue(label: "YakkaTaskInternal")
    private var _workToDo: TaskWorkBlock?
    private var _startHandlers = Array<(()->())>()
    private var _progressHandlers = Array<ProgressHandler>()
    private var _finishHandlers = Array<FinishHandler>()
    
    static private var _cachedTasks = Dictionary<String, Task>()
    
    
    
    // MARK: - Lifecycle
    
    public override init() {
        super.init()
        setupTask(workBlock: nil)
    }
    
    public final class func with(ID identifier: String) -> Task? {
        return _cachedTasks[identifier]
    }
    
    public init(withWork workBlock: @escaping TaskWorkBlock) {
        super.init()
        setupTask(workBlock: workBlock)
    }
    
    private func setupTask(workBlock: TaskWorkBlock?) {
        if let work = workBlock {
            workToDo(workBlock: work)
        }
    }
    
    public final func workToDo(workBlock: @escaping TaskWorkBlock) {
        _internalQueue.async {
            self._workToDo = workBlock
        }
    }
    
    
    
    // MARK: - Control
    
    public final func start(finishHandler: FinishHandler? = nil) {
        
        // Pass on the finish handler
        if let handler = finishHandler {
            onFinish(handler)
        }
        
        // Get on the safe queue to change our state and get started via helper
        _internalQueue.async {
            self.doStart()
        }
    }
    
    public final func start(afterTask task: Task, finishesWith allowedOutcomes: [State] = [], finishHandler: FinishHandler? = nil) {
        
        // (where empty means any state)
        
        // Just attach to the dependent task's finish
        task.onFinish { (outcome) in
            
            // Start us if the state falls within one of our options
            if allowedOutcomes.isEmpty || allowedOutcomes.contains(outcome) {
                self.start(finishHandler: finishHandler)
            }
                
                // Otherwise finish by passing on the dependent's outcome
            else {
                self.finish(withFinalState: outcome)
            }
        }
    }
    
    public final func cancel() {
        _internalQueue.async { [weak self] in
            guard let selfRef = self else { return }
            if selfRef.currentState == .running {
                selfRef.currentState = .cancelling
            }
        }
    }
    
    
    
    // MARK: - Feedback
    
    public final func onStart(_ handler: @escaping ()->()) {
        _internalQueue.async { [weak self] in
            self?._startHandlers.append(handler)
        }
    }
    
    public final func onProgress(_ handler: @escaping ProgressHandler) {
        _internalQueue.async { [weak self] in
            self?._progressHandlers.append(handler)
        }
    }
    
    public final func onFinish(_ handler: @escaping FinishHandler) {
        _internalQueue.async { [weak self] in
            self?._finishHandlers.append(handler)
        }
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    private func doStart() {
        
        // Only allowed to do this if we haven't been run yet
        guard currentState == .notStarted else { return }
        
        // Retain ourself and cache for retrieval later
        Task._cachedTasks[identifier] = self
        
        // Ensure we actually have work to do, fail otherwise
        guard let work = _workToDo else {
            finish(withFinalState: .failed)
            return
        }
        
        // Change the state to running just before we do anything
        self.currentState = .running
        
        // Actually start the work on the worker queue
        self.queueForWork.sync {
            work({ (percent) in
                if self._progressHandlers.count > 0 {
                    self.queueForFeedback.async {
                        for feedback in self._progressHandlers {
                            feedback(percent)
                        }
                    }
                }
            }, { (outcome) in
                self.finish(withFinalState: outcome)
            })
        }
        
        // If needed, provide feedback about the fact we've started
        if self._startHandlers.count > 0 {
            queueForFeedback.async {
                for feedback in self._startHandlers {
                    feedback()
                }
            }
        }
    }
    
    private func doFinish(withFinalState state: State) {
        
        // Don't do anything if we've already finished
        guard currentState != .successful, currentState != .failed, currentState != .cancelled else { return }
        
        // Change the state
        self.currentState = state
        
        // Now get on the feedback queue to finish up
        if self._finishHandlers.count > 0 {
            self.queueForFeedback.sync {
                for feedback in self._finishHandlers {
                    feedback(self.currentState)
                }
            }
        }
        
        // Remove ourself from the cache / stop retaining self
        Task._cachedTasks[identifier] = nil
    }
    
    
    
    // MARK: - Private (ON ANY)
    
    private func finish(withFinalState state: State) {
        
        // Get on the safe queue and change the state
        _internalQueue.async {
            self.doFinish(withFinalState: state)
        }
    }
    
    // TODO: Add autoretry capabilities
}

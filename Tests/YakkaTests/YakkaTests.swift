//
//  YakkaTests.swift
//  Yakka
//
//  Created by Kieran Harper on 30/4/17.
//
//

import Foundation
import Dispatch
import Quick
import Nimble
import Yakka

class YakkaSpec: QuickSpec {
        
    private func suceedingTask() -> Task {
        let task = Task { (process) in
            let delay: TimeInterval = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                process.succeed()
            }
        }
        return task
    }
    
    private func failingTask() -> Task {
        let task = Task { (process) in
            let delay: TimeInterval = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                process.fail()
            }
        }
        return task
    }
    
    private func processAwareSucceedingTask() -> Task {
        let task = Task { (process) in
            let step: TimeInterval = 0.5
            DelayableForLoop.loop(throughItems: [1, 2, 3, 4], delayBetweenLoops: step, itemHandler: { (item) in
                if process.shouldCancel { process.cancel(); return; }
                process.progress(Float(item) / 4.0)
            }, completionHandler: {
                process.succeed()
            })
        }
        return task
    }
    
    private func processAwareEventuallySucceedingTask() -> Task {
        var count = 0
        let task = Task() { (process) in
            let step: TimeInterval = 0.25
            DelayableForLoop.loop(throughItems: [1, 2, 3, 4], delayBetweenLoops: step, itemHandler: { (item) in
                if process.shouldCancel { process.cancel(); return; }
                process.progress(Float(item) / 4.0)
            }, completionHandler: {
                count = count + 1
                if count < 3 { // third time's the charm
                    process.fail()
                } else {
                    process.succeed()
                }
            })
        }
        task.retryWaitTimeline = [0.5, 1.0, 1.5]
        return task
    }
    
    private func setOfSuccedingTasks() -> [Task] {
        var tasks = [Task]()
        for _ in 0...4 {
            let t = Task { (process) in
                let delay: TimeInterval = 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    process.succeed()
                }
            }
            tasks.append(t)
        }
        return tasks
    }
    
    override func spec() {
        
        describe("any task") {

            var task: Task!
            let waitTime: TimeInterval = 3.0
            let line = Line()

            beforeEach {
                task = self.suceedingTask()
            }

            it("should begin in 'not started' state") {
                expect(task.currentState).to(equal(Task.State.notStarted))
            }

            it("should transition to 'running' state when it actually starts to run") {
                waitUntil(timeout: waitTime) { (done) in
                    task.onStart {
                        expect(task.currentState).to(equal(Task.State.running))
                        done()
                    }
                    line.addTask(task)
                }
            }

            it("should not be able to run again if already been run") {
                waitUntil(timeout: waitTime) { (done) in
                    let toSucceed = self.suceedingTask()
                    toSucceed.onFinish { (_) in
                        expect(toSucceed.currentState).to(equal(Task.State.successful))
                        line.addTask(toSucceed)
                        expect(toSucceed.currentState).to(equal(Task.State.successful))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            expect(toSucceed.currentState).to(equal(Task.State.successful))
                            done()
                        }
                    }
                    line.addTask(toSucceed)
                }

                waitUntil(timeout: waitTime) { (done) in
                    let toFail = self.failingTask()
                    toFail.onFinish { (_) in
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        line.addTask(toFail)
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            expect(toFail.currentState).to(equal(Task.State.failed))
                            done()
                        }
                    }
                    line.addTask(toFail)
                }
            }

            it("should never finish if the work doesn't") {
                var hit = false
                let hangingTask = Task { (process) in
                    // do nothing...
                }
                hangingTask.onFinish { (_) in
                    hit = true // never gets here
                }
                line.addTask(hangingTask)
                expect(hit).toEventually(equal(false))
            }


            it("should fail if no work is provided") {
                waitUntil(timeout: waitTime) { (done) in
                    let toFail = Task()
                    toFail.onFinish { (_) in
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        done()
                    }
                    line.addTask(toFail)
                }
            }

            it("should allow the work to be specified any time before being started") {
                let toConfigure = Task()
                var hit = false
                toConfigure.workToDo { (process) in
                    hit = true
                    process.succeed()
                }
                line.addTask(toConfigure)
                expect(hit).toEventually(equal(true))
            }

            it("should be retrievable by ID, but only while running") {

                waitUntil(timeout: waitTime) { (done) in

                    // Before running
                    var possibleTask: Task? = nil
                    possibleTask = Task.find(withID: task.identifier)
                    expect(possibleTask).to(beNil())

                    // While running
                    task.onStart {
                        possibleTask = Task.find(withID: task.identifier)
                        expect(possibleTask).notTo(beNil())
                    }

                    // After running
                    task.onFinish { (outcome) in
                        possibleTask = Task.find(withID: task.identifier)
                        expect(possibleTask).to(beNil())
                        done()
                    }

                    // Before it actually starts
                    line.addTask(task)
                    possibleTask = Task.find(withID: task.identifier)
                    expect(possibleTask).to(beNil())
                }
            }

            it("should transition to 'cancelling' even if it isn't cancel-aware") {
                waitUntil(timeout: waitTime) { (done) in
                    line.addTask(task)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        task.cancel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            expect(task.currentState).to(equal(Task.State.cancelling))
                            done()
                        }
                    }
                }
            }

            it("should run notification handlers on the main queue by default") {
                waitUntil(timeout: 10.0) { (done) in
                    let task = self.processAwareEventuallySucceedingTask()
                    let queue = DispatchQueue.main
                    let mainKey = DispatchSpecificKey<String>()
                    let mainFlag = "main"
                    queue.setSpecific(key: mainKey, value: mainFlag)
                    var started = false
                    var progressed = false
                    var retried = false
                    task.onStart {
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainFlag))
                        }
                        started = true
                    }
                    task.onProgress { (percent) in
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainFlag))
                        }
                        progressed = true
                    }
                    task.onRetry {
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainFlag))
                        }
                        retried = true
                    }
                    task.onFinish { (outcome) in
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainFlag))
                        }

                        expect(started).to(beTrue())
                        expect(progressed).to(beTrue())
                        expect(retried).to(beTrue())
                        done()
                    }
                    line.addTask(task)
                }
            }

            it("should use queues that are specified for each type of notification") {
                waitUntil(timeout: 10.0) { (done) in
                    let task = self.processAwareEventuallySucceedingTask()

                    let startQueueFlag = "start"
                    let progressQueueFlag = "progress"
                    let retryQueueFlag = "retry"
                    let finishQueueFlag = "finish"

                    let startQueue = DispatchQueue(label: startQueueFlag)
                    let progressQueue = DispatchQueue(label: progressQueueFlag)
                    let retryQueue = DispatchQueue(label: retryQueueFlag)
                    let finishQueue = DispatchQueue(label: finishQueueFlag)

                    let startKey = DispatchSpecificKey<String>()
                    let progressKey = DispatchSpecificKey<String>()
                    let retryKey = DispatchSpecificKey<String>()
                    let finishKey = DispatchSpecificKey<String>()

                    startQueue.setSpecific(key: startKey, value: startQueueFlag)
                    progressQueue.setSpecific(key: progressKey, value: progressQueueFlag)
                    retryQueue.setSpecific(key: retryKey, value: retryQueueFlag)
                    finishQueue.setSpecific(key: finishKey, value: finishQueueFlag)

                    var started = false
                    var progressed = false
                    var retried = false

                    task.queueForStartFeedback = startQueue
                    task.queueForRetryFeedback = retryQueue
                    task.queueForProgressFeedback = progressQueue
                    task.queueForFinishFeedback = finishQueue

                    task.onStart {
                        let maybeFlag = DispatchQueue.getSpecific(key: startKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(startQueueFlag))
                        }
                        DispatchQueue.main.async {
                            started = true
                        }
                    }
                    task.onProgress { (percent) in
                        let maybeFlag = DispatchQueue.getSpecific(key: progressKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(progressQueueFlag))
                        }
                        DispatchQueue.main.async {
                            progressed = true
                        }
                    }
                    task.onRetry {
                        let maybeFlag = DispatchQueue.getSpecific(key: retryKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(retryQueueFlag))
                        }
                        DispatchQueue.main.async {
                            retried = true
                        }
                    }
                    task.onFinish { (outcome) in
                        let maybeFlag = DispatchQueue.getSpecific(key: finishKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(finishQueueFlag))
                        }

                        DispatchQueue.main.async {
                            expect(started).to(beTrue())
                            expect(progressed).to(beTrue())
                            expect(retried).to(beTrue())
                            done()
                        }
                    }
                    line.addTask(task)
                }
            }

            it("should use queues that are specified for individual handlers") {
                waitUntil(timeout: 10.0) { (done) in
                    let task = self.processAwareEventuallySucceedingTask()

                    let mainQueueFlag = "main"
                    let startQueueFlag = "start"
                    let progressQueueFlag = "progress"
                    let retryQueueFlag = "retry"
                    let finishQueueFlag = "finish"

                    let startQueue = DispatchQueue(label: startQueueFlag)
                    let progressQueue = DispatchQueue(label: progressQueueFlag)
                    let retryQueue = DispatchQueue(label: retryQueueFlag)
                    let finishQueue = DispatchQueue(label: finishQueueFlag)

                    let mainKey = DispatchSpecificKey<String>()
                    let startKey = DispatchSpecificKey<String>()
                    let progressKey = DispatchSpecificKey<String>()
                    let retryKey = DispatchSpecificKey<String>()
                    let finishKey = DispatchSpecificKey<String>()

                    DispatchQueue.main.setSpecific(key: mainKey, value: mainQueueFlag)
                    startQueue.setSpecific(key: startKey, value: startQueueFlag)
                    progressQueue.setSpecific(key: progressKey, value: progressQueueFlag)
                    retryQueue.setSpecific(key: retryKey, value: retryQueueFlag)
                    finishQueue.setSpecific(key: finishKey, value: finishQueueFlag)

                    var startedMain = false
                    var startedBackground = false
                    var progressedMain = false
                    var progressedBackground = false
                    var retriedMain = false
                    var retriedBackground = false

                    task.onStart {
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainQueueFlag))
                        }
                        startedMain = true
                    }
                    task.onStart(via: startQueue) {
                        let maybeFlag = DispatchQueue.getSpecific(key: startKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(startQueueFlag))
                        }
                        DispatchQueue.main.async {
                            startedBackground = true
                        }
                    }
                    task.onProgress { (outcome) in
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainQueueFlag))
                        }
                        progressedMain = true
                    }
                    task.onProgress(via: progressQueue) { (percent) in
                        let maybeFlag = DispatchQueue.getSpecific(key: progressKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(progressQueueFlag))
                        }
                        DispatchQueue.main.async {
                            progressedBackground = true
                        }
                    }
                    task.onRetry {
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainQueueFlag))
                        }
                        retriedMain = true
                    }
                    task.onRetry(via: retryQueue) {
                        let maybeFlag = DispatchQueue.getSpecific(key: retryKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(retryQueueFlag))
                        }
                        DispatchQueue.main.async {
                            retriedBackground = true
                        }
                    }
                    task.onFinish { (outcome) in
                        let maybeFlag = DispatchQueue.getSpecific(key: mainKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(mainQueueFlag))
                        }
                    }
                    task.onFinish(via: finishQueue) { (outcome) in
                        let maybeFlag = DispatchQueue.getSpecific(key: finishKey)
                        expect(maybeFlag).toNot(beNil())
                        if let flag = maybeFlag {
                            expect(flag).to(equal(finishQueueFlag))
                        }

                        DispatchQueue.main.async {
                            expect(startedMain).to(beTrue())
                            expect(startedBackground).to(beTrue())
                            expect(progressedMain).to(beTrue())
                            expect(progressedBackground).to(beTrue())
                            expect(retriedMain).to(beTrue())
                            expect(retriedBackground).to(beTrue())

                            done()
                        }
                    }
                    line.addTask(task)
                }
            }
        }

        describe("a successful task") {

            var task: Task!
            let waitTime: TimeInterval = 3.0
            let line = Line()

            beforeEach {
                task = self.suceedingTask()
            }

            it("should run the finish handler with 'success'") {

                waitUntil(timeout: waitTime) { (done) in
                    task.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(task)
                }
            }

            it("should be able to succeed eventually after N retries") {
                waitUntil(timeout: 10.0) { (done) in
                    let eventuallySucceed = self.processAwareEventuallySucceedingTask()
                    eventuallySucceed.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(eventuallySucceed)
                }
            }
        }

        describe("a failing task") {

            var task: Task!
            let waitTime: TimeInterval = 3.0
            let line = Line()

            beforeEach {
                task = self.failingTask()
            }

            it("should run the finish handler with 'failure'") {

                waitUntil(timeout: waitTime) { (done) in
                    task.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.failure))
                        done()
                    }
                    line.addTask(task)
                }
            }

            it("should retry N times before giving up") {
                waitUntil(timeout: 10.0) { (done) in
                    var hit = false
                    task.retryWaitTimeline = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: 3, startingAt: 0)
                    task.onRetry {
                        hit = true
                    }
                    task.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.failure))
                        expect(hit).to(equal(true))
                        done()
                    }
                    line.addTask(task)
                }
            }
        }

        describe("a process-aware task") {

            var task: Task!
            let waitTime: TimeInterval = 5.0
            let line = Line()

            beforeEach {
                task = self.processAwareSucceedingTask()
            }

            it("should finish with 'cancelled' if asked to cancel while running") {
                waitUntil(timeout: waitTime) { (done) in
                    task.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.cancelled))
                        done()
                    }
                    line.addTask(task)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        task.cancel()
                    }
                }
            }

            it("should generate notifications about progress") {
                waitUntil(timeout: waitTime) { (done) in
                    var hit = false
                    task.onProgress { (percent) in
                        hit = true
                    }
                    task.onFinish { (outcome) in
                        expect(hit).to(equal(true))
                        done()
                    }
                    line.addTask(task)
                }
            }

            it("should be able to provide progress via the polling approach") {
                let task = Task { (process) in
                    let step: TimeInterval = 0.5
                    var percent: Float = 0.0
                    process.progress(every: 0.1) { () -> Float in
                        return percent
                    }
                    DelayableForLoop.loop(throughItems: [1, 2, 3, 4], delayBetweenLoops: step, itemHandler: { (item) in
                        percent = Float(item) / 4.0
                    }, completionHandler: {
                        process.succeed()
                    })
                }
                waitUntil(timeout: waitTime) { (done) in
                    var hit = false
                    task.onProgress { (percent) in
                        hit = true
                    }
                    task.onFinish { (outcome) in
                        expect(hit).to(equal(true))
                        done()
                    }
                    line.addTask(task)
                }
            }

            it("should be able to respond to cancellation without polling") {
                let t = Task { (process) in
                    process.onShouldCancel {
                        process.cancel()
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        process.succeed()
                    }
                }
                waitUntil(timeout: waitTime) { (done) in
                    t.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.cancelled))
                        done()
                    }
                    line.addTask(t)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        t.cancel()
                    }
                }
            }
        }

        describe("a multi task") {

            let line = Line()

            it("should provide overall progress") {
                var progress: Float = 0.0
                var tasks = [Task]()
                for _ in 0...10 {
                    let t = self.processAwareSucceedingTask()
                    tasks.append(t)
                }

                waitUntil(timeout: 5.0) { (done) in
                    let parallel = ParallelTask(involving: tasks)
                    parallel.onProgress { (percent) in
                        progress = percent
                        expect(percent).to(beGreaterThanOrEqualTo(0.0))
                        expect(percent).to(beLessThanOrEqualTo(1.0))
                    }
                    parallel.onFinish { (outcome) in
                        expect(progress).to(equal(1.0))
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(parallel)
                }
            }
            
            it("can provide overall progress regardless of task's support for progress") {
                var progress: Float = 0.0
                var tasks = [Task]()
                for _ in 0...10 {
                    let t = self.suceedingTask()
                    tasks.append(t)
                }
                
                waitUntil(timeout: 5.0) { (done) in
                    let parallel = ParallelTask(involving: tasks)
                    parallel.onProgress { (percent) in
                        progress = percent
                        expect(percent).to(beGreaterThanOrEqualTo(0.0))
                        expect(percent).to(beLessThanOrEqualTo(1.0))
                    }
                    parallel.onFinish { (outcome) in
                        expect(progress).to(equal(1.0))
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(parallel)
                }
            }

            it("should allow subtasks to fail without overall failure (by default)") {
                var tasks = [Task]()
                for ii in 0...5 {
                    if ii == 3 {
                        tasks.append(self.failingTask())
                    } else {
                        tasks.append(self.suceedingTask())
                    }
                }

                waitUntil(timeout: 10.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(serial)
                }
            }

            it("should be configurable to fail overall if any subtask fails") {
                var tasks = [Task]()
                for ii in 0...5 {
                    if ii == 3 {
                        tasks.append(self.failingTask())
                    } else {
                        tasks.append(self.suceedingTask())
                    }
                }

                waitUntil(timeout: 10.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.requireSuccessFromSubtasks = true
                    serial.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.failure))
                        done()
                    }
                    line.addTask(serial)
                }
            }

            it("should prevent pending subtasks from starting when canceling") {
                var startFlags = [Int]()
                let numTasks = 5
                var tasks = [Task]()
                for ii in 0..<numTasks {
                    let t = self.processAwareSucceedingTask()
                    t.onStart {
                        startFlags.append(ii)
                    }
                    tasks.append(t)
                }

                waitUntil(timeout: 10.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.cancelled))
                        expect(startFlags.count).to(beLessThan(numTasks))
                        done()
                    }
                    line.addTask(serial)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        serial.cancel()
                    }
                }
            }
        }

        describe("a serial task") {

            let line = Line()

            it("should run tasks to completion in the right order") {

                let expectedOrder: [Int] = [0, 1, 2, 3, 4]
                var flags = [Int]()
                var tasks = [Task]()
                for ii in expectedOrder {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            flags.append(ii)
                        }
                    }
                    tasks.append(t)
                }

                waitUntil(timeout: 3.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        expect(flags).to(equal(expectedOrder))
                        done()
                    }
                    line.addTask(serial)
                }
            }

            it("can be constructed using an operator") {

                let expectedOrder: [Int] = [0, 1, 2, 3, 4]
                var flags = [Int]()
                var tasks = [Task]()
                for ii in expectedOrder {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            flags.append(ii)
                        }
                    }
                    tasks.append(t)
                }

                waitUntil(timeout: 3.0) { (done) in
                    let serial = tasks[0] --> tasks[1] --> tasks[2] --> tasks[3] --> tasks[4]
                    serial.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        expect(flags).to(equal(expectedOrder))
                        done()
                    }
                    line.addTask(serial)
                }
            }
        }

        describe("a parallel task") {

            let line = Line()

            it("should start no more than the specified max at a time") {
                let maxTasks = 4
                var startFlags = [Int]()
                var tasks = [Task]()
                for ii in 0...10 {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            startFlags.append(ii)
                            expect(startFlags.count).to(beLessThanOrEqualTo(maxTasks))
                        }
                    }
                    t.onFinish(handler: { (_) in
                        DispatchQueue.main.async {
                            startFlags.removeLast()
                        }
                    })
                    tasks.append(t)
                }

                waitUntil(timeout: 5.0) { (done) in
                    let parallel = ParallelTask(involving: tasks)
                    parallel.maxConcurrentTasks = maxTasks
                    parallel.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(parallel)
                }
            }

            it("can be constructed using an operator") {

                let maxTasks = 4
                var startFlags = [Int]()
                var tasks = [Task]()
                for ii in 0...10 {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            startFlags.append(ii)
                            expect(startFlags.count).to(beLessThanOrEqualTo(maxTasks))
                        }
                    }
                    t.onFinish(handler: { (_) in
                        DispatchQueue.main.async {
                            startFlags.removeLast()
                        }
                    })
                    tasks.append(t)
                }

                waitUntil(timeout: 5.0) { (done) in
                    let parallel = tasks[0] ||| tasks[1] ||| tasks[2] ||| tasks[3] ||| tasks[4] ||| tasks[5] ||| tasks[6] ||| tasks[7] ||| tasks[8] ||| tasks[9]
                    parallel.maxConcurrentTasks = maxTasks
                    parallel.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(parallel)
                }
            }

            it("supports tasks that are already involved in other parallel tasks") {

                let maxTasks = 2
                var tasks = [Task]()
                for _ in 0...9 {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    tasks.append(t)
                }

                let group1 = ParallelTask(involving: [tasks[0], tasks[1], tasks[2], tasks[3]])
                let group2 = ParallelTask(involving: [tasks[4], tasks[5], tasks[6], tasks[7]])
                let group3 = ParallelTask(involving: [tasks[8], tasks[9], tasks[2], tasks[3]])
                let group4 = ParallelTask(involving: [tasks[4], tasks[5], tasks[0], tasks[1]])
                let group5 = ParallelTask(involving: [tasks[7], tasks[0], tasks[5], tasks[4]])
                let group6 = ParallelTask(involving: [tasks[2], tasks[6], tasks[9], tasks[1]])
                group1.maxConcurrentTasks = maxTasks
                group2.maxConcurrentTasks = maxTasks
                group3.maxConcurrentTasks = maxTasks
                group4.maxConcurrentTasks = maxTasks
                group5.maxConcurrentTasks = maxTasks
                group6.maxConcurrentTasks = maxTasks

                waitUntil(timeout: 5.0) { (done) in
                    let parallel = ParallelTask(involving: [group1, group2, group3, group4, group5, group6])
                    parallel.onFinish { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                    line.addTask(parallel)
                }
            }
        }

        describe("exponential backoff") {

            var a: [TimeInterval]!
            var b: [TimeInterval]!
            var c: [TimeInterval]!
            var d: [TimeInterval]!
            var e: [TimeInterval]!

            beforeEach {
                let numRetries = 5
                a = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 0.0)
                b = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: -10.0)
                c = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 0.5)
                d = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 1.0)
                e = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 3.0)
            }

            it("should start with initial value (when positive)") {
                expect(a[0]).to(equal(0.0))
                expect(b[0]).to(equal(0.0))
                expect(c[0]).to(equal(0.5))
                expect(d[0]).to(equal(1.0))
                expect(e[0]).to(equal(3.0))
            }

            it("should always increase exponentially from the initial value") {
                func checkTimeline(_ timeline: [TimeInterval]) {
                    for ii in 1..<timeline.count {
                        if ii == 1 {
                            expect(timeline[ii]).to(beGreaterThan(0.0))
                        } else {
                            expect(timeline[ii]).to(equal(2.0 * timeline[ii - 1]))
                        }
                    }
                }
                checkTimeline(a)
                checkTimeline(b)
                checkTimeline(c)
                checkTimeline(d)
                checkTimeline(e)
            }
        }

        describe("a yakka line") {

            var line: Line!

            beforeEach {
                line = Line()
            }

            it("should begin in 'running' state") {
                expect(line.isRunning).to(equal(true))
            }

            it("should run tasks that are queued before it starts") {
                line.stop()
                let multiple = self.setOfSuccedingTasks()
                var startCount = 0
                var set1 = [Task]()
                var set2 = [Task]()
                for task in multiple {
                    task.onStart {
                        startCount = startCount + 1
                    }
                    if set1.count > 2 {
                        set2.append(task)
                    } else {
                        set1.append(task)
                    }
                }

                // Deliberately exercise both add methods
                line.addTasks(set1)
                for task in set2 {
                    line.addTask(task)
                }

                // Start
                line.start()
                expect(startCount).toEventually(equal(multiple.count))
            }

            it("should run tasks that are queued after it starts") {

                // Create tasks
                let multiple = self.setOfSuccedingTasks()
                var startCount = 0
                var set1 = [Task]()
                var set2 = [Task]()
                for task in multiple {
                    task.onStart {
                        startCount = startCount + 1
                    }
                    if set1.count > 2 {
                        set2.append(task)
                    } else {
                        set1.append(task)
                    }
                }

                // Deliberately exercise both add methods
                line.addTasks(set1)
                for task in set2 {
                    line.addTask(task)
                }

                // Wait
                expect(startCount).toEventually(equal(multiple.count))
            }

            it("lets you provide a task via closures") {
                waitUntil(timeout: 3.0) { (done) in
                    line.add {
                        let task = self.suceedingTask()
                        task.onFinish { _ in
                            done()
                        }
                        return task
                    }
                }
            }

            it("should limit the maximum number of tasks when asked") {
                let maxTasks = 4
                var startFlags = [Int]()
                var tasks = [Task]()
                var finishCount = 0
                for ii in 0...10 {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            startFlags.append(ii)
                            expect(startFlags.count).to(beLessThanOrEqualTo(maxTasks))
                        }
                    }
                    t.onFinish(handler: { (_) in
                        DispatchQueue.main.async {
                            startFlags.removeLast()
                            finishCount = finishCount + 1
                        }
                    })
                    tasks.append(t)
                }

                line.maxConcurrentTasks = maxTasks
                line.addTasks(tasks)
                expect(finishCount).toEventually(equal(tasks.count), timeout: 5.0)
            }

            it("should be stoppable without affecting running tasks") {
                let tasks = self.setOfSuccedingTasks()
                var startCount = 0
                var finishCount = 0
                for task in tasks {
                    task.onStart {
                        DispatchQueue.main.async {
                            startCount = startCount + 1
                            if startCount == tasks.count {
                                line.stop()
                            }
                        }
                    }
                    task.onFinish(handler: { (outcome) in
                        DispatchQueue.main.async {
                            if outcome == .success {
                                finishCount = finishCount + 1
                            }
                        }
                    })
                }
                line.addTasks(tasks)
                expect(startCount).toEventually(equal(tasks.count))
                expect(finishCount).toEventually(equal(tasks.count))
                expect(line.isRunning).toEventually(equal(false))
                expect((startCount == tasks.count) && !line.isRunning).toEventually(equal(true))
            }

            it("should let you easily ask all running tasks to cancel") {
                var tasks = [Task]()
                var cancelledCount = 0
                var startedCount = 0
                let tasksCount = 5
                for _ in 0..<tasksCount {
                    let task = self.processAwareSucceedingTask()
                    tasks.append(task)
                    task.onFinish(handler: { (outcome) in
                        DispatchQueue.main.async {
                            if outcome == .cancelled {
                                cancelledCount = cancelledCount + 1
                            }
                        }
                    })
                    task.onStart {
                        startedCount = startedCount + 1
                        if startedCount == tasksCount {
                            line.cancelTasks()
                        }
                    }
                }
                line.addTasks(tasks)
                expect(line.isRunning).toEventually(equal(true))
                expect(cancelledCount).toEventually(equal(tasksCount))
            }

            it("should let you stop and cancel in one go") {
                var tasks = [Task]()
                var cancelledCount = 0
                var startedCount = 0
                let tasksCount = 5
                for _ in 0..<tasksCount {
                    let task = self.processAwareSucceedingTask()
                    tasks.append(task)
                    task.onStart {
                        DispatchQueue.main.async {
                            startedCount = startedCount + 1
                            if startedCount == tasksCount {
                                line.stopAndCancel()
                            }
                        }
                    }
                    task.onFinish(handler: { (outcome) in
                        DispatchQueue.main.async {
                            if outcome == .cancelled {
                                cancelledCount = cancelledCount + 1
                            }
                        }
                    })
                }
                line.addTasks(tasks)
                line.start()
                expect(cancelledCount).toEventually(equal(tasksCount))
                expect((startedCount == tasksCount) && !line.isRunning).toEventually(equal(true))
            }

            it("should be useful in throwaway scope") {
                waitUntil(timeout: 3.0) { (done) in
                    var tasks = [Task]()
                    var finishedCount = 0
                    let tasksCount = 5
                    for _ in 0..<tasksCount {
                        let task = self.processAwareSucceedingTask()
                        tasks.append(task)
                        task.onFinish(handler: { (outcome) in
                            DispatchQueue.main.async {
                                finishedCount = finishedCount + 1
                                if finishedCount == tasksCount {
                                    expect(finishedCount).to(equal(tasksCount))
                                    done()
                                }
                            }
                        })
                    }
                    if tasksCount >= 5 { // just create throwaway scope...
                        let line = Line()
                        line.addTasks(tasks)
                    }
                }
            }

            it("notifies when it becomes empty") {
                waitUntil(timeout: 3.0) { (done) in
                    line.onBecameEmpty {
                        done()
                    }
                    line.maxConcurrentTasks = 2
                    line.addTasks(self.setOfSuccedingTasks())
                }
            }

            it("notifies when it starts tasks") {
                waitUntil(timeout: 3.0) { (done) in
                    let tasks = self.setOfSuccedingTasks()
                    let taskCount = tasks.count
                    var startedSoFar = 0
                    line.onNextTaskStarted { (t) in
                        startedSoFar = startedSoFar + 1
                        if startedSoFar == taskCount {
                            done()
                        }
                    }
                    line.maxConcurrentTasks = 2
                    line.addTasks(tasks)
                }
            }
        }
    }
}







private class DelayableForLoop: NSObject {
    
    override private init() { super.init() }
    
    public class func loop<T>(throughItems items: Array<T>, delayBetweenLoops: TimeInterval, initialDelay: TimeInterval = 0, itemHandler: @escaping (T)->(), completionHandler: @escaping ()->()) {
        
        // Create instance to do the work
        let worker = DelayableForLoop()
        
        // Begin the work after any provided start delay
        worker.processNext(inItems: items, afterDelay: initialDelay, delayToUseNext: delayBetweenLoops, itemHandler: itemHandler, completionHandler: completionHandler)
    }
    
    private func processNext<T>(inItems items: Array<T>, afterDelay delay: TimeInterval, delayToUseNext: TimeInterval, itemHandler: @escaping (T)->(), completionHandler: @escaping ()->()) {
        
        // Get the next item if there is one, otherwise finish immediately
        var workingItems = items
        guard let nextItem = workingItems.first else {
            completionHandler()
            return
        }
        
        // Wait the delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            
            // Do the work and proceed
            itemHandler(nextItem)
            workingItems.remove(at: 0)
            self.processNext(inItems: workingItems, afterDelay: delayToUseNext, delayToUseNext: delayToUseNext, itemHandler: itemHandler, completionHandler: completionHandler)
        }
    }
}

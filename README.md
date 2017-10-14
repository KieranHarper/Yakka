# Yakka
[![Build Status](https://travis-ci.org/KieranHarper/Yakka.svg?branch=master)](https://travis-ci.org/KieranHarper/Yakka?branch=master)
[![Version](https://img.shields.io/cocoapods/v/Yakka.svg?style=flat)](http://cocoapods.org/pods/Yakka)
[![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)
[![SwiftPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg?style=flat)](https://swift.org/package-manager)
[![Platform](https://img.shields.io/cocoapods/p/Yakka.svg?style=flat)](http://cocoapods.org/pods/Yakka)
[![License](https://img.shields.io/cocoapods/l/Yakka.svg?style=flat)](http://cocoapods.org/pods/Yakka)

## Features

Yakka is a toolkit for coordinating the doing of stuff. Here's what it does:
- Makes it trivial to do arbitrary work of an asynchronous nature in the background and know when it finishes.
- Lets you easily group and/or chain independent chunks of background work to form trackable processes.
- Allows any number of interested parties to listen/track the progress and outcome of background work.
- Gives fine control over the GCD execution queues involved if required.

Yakka can be used for throwaway code you just need run asynchronously in the background, or it can be leveraged to coordinate reusable components in a complex system. There are many different ways of tackling this kind of thing – hopefully this one works for you!

## The basics

There's 3 main things involved in Yakka:
1. Task objects - these encapsulate work that needs doing.
1. Line objects - these control the starting of tasks.
1. Process objects - a task's in-work companion, used to report progress and finish.

You can create a task in place using a closure, or you can create a subclass and provide the work closure in there. Depends whether you want the work to be reusable in other places.

Lines can be created in place as well if you simply want to make a task start. Alternatively they can be held onto and used to control the number of things happening at once (this is their main purpose).

If you want to group otherwise independent tasks into a dependent group so that you can wait on their combined completion, you can do so using SerialTask or ParallelTask. These are also just Task subclasses, so you can create them easily, add an onFinish handler, and send them down a line.

GCD is used internally in the following ways:
- Task work execution happens on a workQueue (accessible via Process object if/when task needs a queue along the way). This is assigned by the Line when it starts the task.
- Lines define the workQueue as a global concurrent background queue unless you give it a specific one upon initialization.
- Feedback handlers will execute on main unless you provide an alternative queue. Objects which provide feedback can be given a default queue to use (ie override main in all cases), and/or can be given a queue to use for a specific feedback handler.

In most cases you can use Yakka without caring about GCD.

## Examples

### Trivial work
```swift
let work = Task { process in
    print("working...")
    process.succeed()
}
Line().addTask(work).onFinish { outcome in
    print("finished!")
}
```
Note that synchronous and asynchronous workloads are supported, so long as you tell the process object when it finishes.

### Less trivial work
```swift
let work = Task { process in
    
    // do something here...
    
    // a "process-aware task" would implement the following:
    
    // if you can, report progress periodically like this:
    process.progress(0.5) // percent 0..1
    
    // or if you have to, provide progress via polling like this:
    process.progress {
        return someMethodWhichDeterminesPercentComplete()
    }
    
    // where it makes sense, check for cancellation and bail
    if process.shouldCancel {
        process.cancel()
        return
    }
    
    // or if it's easier, respond to cancellation as needed
    process.onShouldCancel {
        process.cancel()
    }
    
    // finish up at some point with success or fail:
    process.fail()
    process.succeed()
}
work.onProgress { percent in
    // update your UI etc
}
work.onStart {
    // update your UI etc
}
work.onFinish { outcome in
    // outcome is one of .successful, .failed, .cancelled)
}
Line().addTask(work)
```

### Trivial parallel grouping
```swift
var tasks = [Task]()
for ii in 0...4 {
    let t = Task { (process) in
        print(ii)
        process.succeed()
    }
    tasks.append(t)
}
Line().addTask(ParallelTask(involving: tasks)).onFinish { (outcome) in
    print("all tasks have finished")
}
```

### Trivial serial grouping
```swift
var tasks = [Task]()
for ii in 0...4 {
    let t = Task { (process) in
        print(ii)
        process.succeed()
    }
    tasks.append(t)
}
let group = SerialTask(involving: tasks)
Line().addTask(group).onFinish { (outcome) in
    print("all tasks have finished")
}
```

### Reusable tasks
```swift
class DigMassiveHole: Task {
    
    let diameter: Float
    let depth: Float
    var numEmployees = 1
    
    init(diameter: Float, depth: Float) {
        
        // Some config
        self.diameter = diameter
        self.depth = depth
        super.init()
        
        // Define what this task does
        workToDo { (process) in
            
            print("doing some digging...")
            process.succeed()
        }
    }
}

let dig = DigMassiveHole(diameter: 30, depth: 100)
dig.numEmployees = 5
Line().addTask(dig).onFinish { (outcome) in
    print("finished digging!")
}
```

### Long lived lines
```swift
// Create a line which we'll keep around
let uploadLine = Line(maxConcurrentTasks: 5)

// Receive events of interest
uploadLine.onBecameEmpty {
    print("upload line isn't busy")
}
uploadLine.onNextTaskStarted { task in
    print("upload line started another task")
}

// Create some upload tasks
let first = Task { (process) in
    print("first upload")
    process.fail()
}
let second = Task { (process) in
    print("second upload")
    process.succeed()
}
let third = Task { (process) in
    print("third upload")
    process.succeed()
}

// Run a task now
uploadLine.addTask(first)

// Later... run some more!
uploadLine.addTasks([second, third])
uploadLine.add { () -> Task in
    return someMethodWhichCreatesATask()
}

// Anytime later...
uploadLine.stop() // or
uploadLine.stopAndCancel()
```

### Chaining using operators
```swift
let someProcess = task1 --> task2 --> task3 // serial
let anotherProcess = taskA --> taskB --> taskC // serial
let overall = someProcess ||| anotherProcess // parallel

overall.onFinish { outcome in
    print("all tasks finished")
}

Line().addTask(overall)
```

These examples all complete their work by the end of the work closure (they're synchronous), but you can check out the tests file for a few more examples where work completes at arbitrary later times.

#### Lifecycle of a Yakka Task:
1. Not Started
1. Running
1. Cancelling
1. Successful | Cancelled | Failed

Some points about that:
- Flows downward and never back up.
- Cancelling only leads to Cancelled if task is cancel-aware and bails out.
- If a task never moves into Running, no handlers will ever be called.
- Tasks retain themselves only while Running and Cancelling.
- Because it never flows backwards, tasks cannot be restarted, even if cancelled.

#### Other details:
- Tasks retain themselves after starting, until the finish closure is called.
- The Process object given to a Task's work closure is safe to interact with from any thread.
- Provide progress either by push or pull (polling) or not at all, depending on your work.
- Detect and support cancellation requests either by push or pull or not at all, depending on your work.
- Task instances are single shot – they can't be run again after they finish.

#### A note on memory management:
Tasks retain themselves while running, which is done deliberately to make them easier to work with. The working queue used by the task is also retained while running. All you gotta do is make sure your work eventually finishes by calling one of the methods on the process object, and that the process object isn't strongly retained beyond that point.

SerialTask and ParallelTask both retain the tasks you give to them regardless of whether or not they are started. They retain themselves while running because they're also just Tasks.

Lines do not retain themselves and in throwaway situations they will be deallocated as they fall out of scope, but they are not needed for tasks to continue running.

Event closures onStart and onFinish are fine to retain the task within them, as they will be let go of after those events occur. However onProgress and onRetry closures are retained during the lifetime of the task, so you do not want to strongly capture the task within those event closures.


## Yakka?
As in Hard Yakka – classic Aussie slang for work. It's derived from 'yaga', which is a term from the Yagara language spoken by indigenous peoples of the region now known as Brisbane.

## Requirements & Platforms

- Swift 4.0
- iOS
- macOS
- watchOS
- tvOS
- Linux

## Installation

### Cocoapods
Yakka is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod "Yakka"
```

### Carthage
Yakka can be installed using [Carthage](https://github.com/Carthage/Carthage). Add the following to your Cartfile:

```
github "KieranHarper/Yakka" ~> 2.0
```

### Swift Package Manager
Installation through the [Swift Package Manager](https://swift.org/package-manager/) is also supported. Add the following to your Package file:

```swift
dependencies: [
    .Package(url: "https://github.com/KieranHarper/Yakka.git", majorVersion: 2)
]
```

### Manually
Just drag the files in from the Sources directory and you're good to go!

## Author

Kieran Harper, kieranjharper@gmail.com, [@KieranTheTwit](https://twitter.com/KieranTheTwit)

## License

Yakka is available under the MIT license. See the LICENSE file for more info.

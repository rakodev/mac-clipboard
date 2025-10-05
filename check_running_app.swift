#!/usr/bin/env swift

import Foundation
import ApplicationServices

// Get the running MacClipboard process
let task = Process()
task.launchPath = "/bin/ps"
task.arguments = ["aux"]

let pipe = Pipe()
task.standardOutput = pipe
task.launch()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
let output = String(data: data, encoding: .utf8) ?? ""

// Find MacClipboard process
for line in output.components(separatedBy: .newlines) {
    if line.contains("MacClipboard.app/Contents/MacOS/MacClipboard") && !line.contains("grep") {
        // Extract the path
        if let pathStart = line.range(of: "/Users/") {
            let path = String(line[pathStart.lowerBound...])
            print("Found running MacClipboard at: \(path)")
            
            // Check if this exact binary has accessibility
            // We can't easily do this from a script, but we can suggest checking
            print("\nThis is the binary that needs accessibility permission.")
            print("The issue might be that a different MacClipboard binary was granted permission.")
            break
        }
    }
}

print("\nDebugging steps:")
print("1. Remove MacClipboard from System Settings > Accessibility")
print("2. Restart the MacClipboard app")
print("3. When prompted, grant permission again")
print("4. This will ensure the currently running binary gets permission")
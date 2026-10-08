import Foundation
import JavaScriptCore
let context=JSContext()!
var failed=false
context.exceptionHandler={_,error in failed=true;print("JS ERROR: \(error?.toString() ?? "unknown")")}
for path in CommandLine.arguments.dropFirst() {context.evaluateScript(try String(contentsOfFile:path,encoding:.utf8))}
if failed {exit(1)}
if let result=context.objectForKeyedSubscript("resultJSON")?.toString(){print(result)}

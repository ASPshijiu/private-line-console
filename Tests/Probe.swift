import Foundation
let url=URL(string:CommandLine.arguments.dropFirst().first ?? "https://www.baidu.com")!
let session=URLSession(configuration:.ephemeral)
var finished=false
let task=session.dataTask(with:url) { data,response,error in
    var result:[String:Any] = ["http":(response as? HTTPURLResponse)?.statusCode ?? 0,"ok":error == nil]
    if let data, let text=String(data:data,encoding:.utf8), let line=text.split(separator:"\n").first(where:{$0.hasPrefix("ip=")}) { result["ip"]=String(line.dropFirst(3)) }
    print(String(decoding:try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    fflush(stdout);finished=true
}
task.resume()
let deadline=Date().addingTimeInterval(18)
while !finished && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
RunLoop.current.run(until:Date().addingTimeInterval(8))
session.invalidateAndCancel()

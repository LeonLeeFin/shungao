import Foundation
import CryptoKit

final class MockModelProtocol:URLProtocol {
    static var mode="normal"
    static let bytes=Data(repeating:17,count:262144)
    static var requests=[String]()
    static let lock=NSLock()
    private var stopped=false
    private let stopLock=NSLock()
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let range=request.value(forHTTPHeaderField:"Range") ?? ""
        Self.lock.lock();Self.requests.append(range);let mode=Self.mode;Self.lock.unlock()
        var offset=0
        if range.hasPrefix("bytes="),let value=Int(range.dropFirst(6).dropLast()) { offset=value }
        let body=mode=="bad-hash" ? Data(repeating:120,count:Self.bytes.count) : Self.bytes
        let suffix=body.dropFirst(offset)
        let headers=offset>0 ? ["Content-Range":"bytes \(offset)-\(body.count-1)/\(body.count)","Content-Length":"\(suffix.count)"] : ["Content-Length":"\(body.count)"]
        let response=HTTPURLResponse(url:request.url!,statusCode:offset>0 ? 206 : 200,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if mode=="interrupt" {
            client?.urlProtocol(self,didLoad:Data(suffix.prefix(65536)))
            DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { self.client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)) };return
        }
        if mode=="cancel" {
            client?.urlProtocol(self,didLoad:Data(suffix.prefix(65536)))
            DispatchQueue.global().asyncAfter(deadline:.now()+0.5) {
                self.stopLock.lock();let stopped=self.stopped;self.stopLock.unlock()
                if !stopped { self.client?.urlProtocol(self,didLoad:Data(suffix.dropFirst(65536)));self.client?.urlProtocolDidFinishLoading(self) }
            }
            return
        }
        client?.urlProtocol(self,didLoad:Data(suffix));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopLock.lock();stopped=true;stopLock.unlock() }
}
@main struct ModelManagerTestRunner {
    static func main() async throws {
        let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let sha=SHA256.hash(data:MockModelProtocol.bytes).map { String(format:"%02x",$0) }.joined()
        let spec=ModelSpec(id:"sensevoice",folder:"SenseVoiceSmall",repository:"mlx-community/SenseVoiceSmall",revision:String(repeating:"a",count:40),license:"test",licenseURL:"https://example.invalid",licenseFile:"fixture-license.txt",bytes:Int64(MockModelProtocol.bytes.count),formatLabel:"fixture data",files:[ModelFile(name:"model.safetensors",size:Int64(MockModelProtocol.bytes.count),sha256:sha)])
        var checks=[[String:Any]]()
        func check(_ name:String,_ passed:Bool) { checks.append(["name":name,"passed":passed]) }
        func transfer(_ storage:URL,mode:String) async -> Result<URL,Error> {
            MockModelProtocol.lock.withLock { MockModelProtocol.mode=mode }
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[MockModelProtocol.self]
            let download=ModelDownload(spec:spec,storage:storage,licenses:root,configuration:configuration)
            return await withCheckedContinuation { continuation in
                download.update={ state,_,received in if mode=="cancel" && received>=65536 && state=="downloading" { download.cancel() } }
                download.completion={ result in continuation.resume(returning:result) };download.begin()
            }
        }
        let normal=root.appendingPathComponent("normal")
        let result=await transfer(normal,mode:"normal")
        if case .success(let destination)=result {
            check("下载所有文件校验后原子提交",(try? fileSHA256(destination.appendingPathComponent("model.safetensors")))==sha)
            check("完成记录包含固定修订",(try? String(contentsOf:destination.appendingPathComponent("installation.json"),encoding:.utf8))?.contains(spec.revision)==true)
            check("提交后暂存目录不存在",!fm.fileExists(atPath:normal.appendingPathComponent(".shungao-downloads/\(spec.folder)-\(spec.revision)").path))
        } else { check("下载所有文件校验后原子提交",false) }
        let resume=root.appendingPathComponent("resume")
        let interruption=await transfer(resume,mode:"interrupt");print("Interruption:",interruption)
        if case .failure=interruption { check("断网返回失败而非安装成功",true) } else { check("断网返回失败而非安装成功",false) }
        let part=resume.appendingPathComponent(".shungao-downloads/\(spec.folder)-\(spec.revision)/model.safetensors.part")
        print("Partial attributes:",(try? fm.attributesOfItem(atPath:part.path)) ?? [:]);check("断网保留完整接收的部分文件",(try? Data(contentsOf:part))==MockModelProtocol.bytes.prefix(65536))
        check("未完成模型不出现在正式目录",!fm.fileExists(atPath:resume.appendingPathComponent(spec.relativeDirectory).path))
        let resumed=await transfer(resume,mode:"normal")
        let ranges=MockModelProtocol.lock.withLock { MockModelProtocol.requests }
        check("重试发送准确的 Range 续传请求",ranges.contains("bytes=65536-"))
        if case .success=resumed { check("续传后的全文件校验通过",true) } else { check("续传后的全文件校验通过",false) }
        let cancelled=root.appendingPathComponent("cancel")
        let cancellation=await transfer(cancelled,mode:"cancel")
        if case .failure=cancellation { check("取消停止下载并返回明确失败状态",true) } else { check("取消停止下载并返回明确失败状态",false) }
        check("取消不提交正式模型目录",!fm.fileExists(atPath:cancelled.appendingPathComponent(spec.relativeDirectory).path))
        let bad=root.appendingPathComponent("bad")
        let badResult=await transfer(bad,mode:"bad-hash")
        if case .failure=badResult { check("SHA不符拒绝安装",true) } else { check("SHA不符拒绝安装",false) }
        check("SHA不符丢弃损坏分片且保留目标空缺",!fm.fileExists(atPath:bad.appendingPathComponent(spec.relativeDirectory).path) && !fm.fileExists(atPath:bad.appendingPathComponent(".shungao-downloads/\(spec.folder)-\(spec.revision)/model.safetensors.part").path))
        let symlinkRoot=root.appendingPathComponent("symlink"),outside=root.appendingPathComponent("outside")
        try fm.createDirectory(at:symlinkRoot,withIntermediateDirectories:true);try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:symlinkRoot.appendingPathComponent(".shungao-downloads"),withDestinationURL:outside)
        let symlinkResult=await transfer(symlinkRoot,mode:"normal")
        if case .failure=symlinkResult { check("拒绝暂存目录的越界符号链接",true) } else { check("拒绝暂存目录的越界符号链接",false) }
        check("越界目标目录没有写入文件",(try fm.contentsOfDirectory(atPath:outside.path)).isEmpty)
        let policy=ModelDownload(spec:spec,storage:root.appendingPathComponent("policy"),licenses:root)
        var allowed:URLRequest?
        policy.urlSession(policy.session,task:policy.session.dataTask(with:URL(string:"https://huggingface.co")!),willPerformHTTPRedirection:HTTPURLResponse(url:URL(string:"https://huggingface.co")!,statusCode:302,httpVersion:nil,headerFields:nil)!,newRequest:URLRequest(url:URL(string:"https://untrusted.example/model")!),completionHandler:{ allowed=$0 })
        check("拒绝不在白名单的重定向",allowed==nil && policy.failure != nil);policy.session.invalidateAndCancel()
        let snapshot=root.appendingPathComponent("snapshot"),blob=root.appendingPathComponent("blob")
        try fm.createDirectory(at:snapshot,withIntermediateDirectories:true);try MockModelProtocol.bytes.write(to:blob)
        try fm.createSymbolicLink(at:snapshot.appendingPathComponent("model.safetensors"),withDestinationURL:blob)
        check("已有HF式snapshot符号链接只验证不复制",(try? validateModel(spec,at:snapshot)) != nil && (try? snapshot.appendingPathComponent("model.safetensors").resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true)
        let catalog=root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ModelCatalog(version:1,models:[spec])).write(to:catalog)
        let manager=try ModelManager(catalog:catalog,config:root.appendingPathComponent("config.json"),licenses:root,defaultStorage:root.appendingPathComponent("shared"))
        manager.references[spec.id]=snapshot;manager.verified[spec.id]=try validateModel(spec,at:snapshot)
        let beforeRequests=MockModelProtocol.requests.count;manager.start(spec.id)
        check("引用已有验证模型不重复请求网络",manager.download==nil && MockModelProtocol.requests.count==beforeRequests)
        let report:[String:Any]=["networkUsed":false,"modelExecuted":false,"checks":checks,"fixtureBytes":MockModelProtocol.bytes.count]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:root.deletingLastPathComponent().appendingPathComponent("model-manager-results.json"))
        print("\(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count) model data management checks passed; fake data only.")
        if checks.contains(where:{$0["passed"] as? Bool == false}) { exit(1) }
    }
}

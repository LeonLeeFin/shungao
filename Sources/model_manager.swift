import Foundation
import CryptoKit

struct ModelFile: Codable {
    let name: String
    let size: Int64
    let sha256: String
}
struct ModelSpec: Codable {
    let id: String
    let folder: String
    let repository: String
    let revision: String
    let license: String
    let licenseURL: String
    let licenseFile: String
    let bytes: Int64
    let formatLabel: String
    let files: [ModelFile]
    var relativeDirectory: String { id == "qwen" ? "MLX/Qwen3-ASR-1.7B/8bit/\(revision)" : "MLX/SenseVoiceSmall/F32/\(revision)" }
    var format: String { formatLabel }
}
struct ModelCatalog: Codable { let version: Int; let models: [ModelSpec] }
func modelError(_ message: String) -> NSError { NSError(domain:"ShunGaoModels",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
func fileSHA256(_ url: URL) throws -> String {
    let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() }
    var hash=SHA256()
    while let data=try handle.read(upToCount:4*1024*1024),!data.isEmpty { hash.update(data:data) }
    return hash.finalize().map { String(format:"%02x",$0) }.joined()
}
func modelFileValid(_ url:URL,_ file:ModelFile) throws -> Bool {
    let attributes=try FileManager.default.attributesOfItem(atPath:url.resolvingSymlinksInPath().path)
    guard (attributes[.size] as? NSNumber)?.int64Value == file.size else { return false }
    return try fileSHA256(url) == file.sha256
}
func validateModel(_ spec:ModelSpec,at directory:URL) throws -> [String:String] {
    let fm=FileManager.default
    let contents=try fm.contentsOfDirectory(atPath:directory.path)
    guard !contents.contains(where:{$0.lowercased().hasSuffix(".py")}) else { throw modelError("模型目录含 Python 代码，无法使用") }
    var stamps=[String:String]()
    for file in spec.files {
        guard !file.name.contains("/") && !file.name.contains("\\") && file.name != "." && file.name != ".." else { throw modelError("文件清单无效") }
        let url=directory.appendingPathComponent(file.name)
        let before=try fm.attributesOfItem(atPath:url.resolvingSymlinksInPath().path)
        guard try modelFileValid(url,file) else { throw modelError("\(file.name) 完整性校验失败；需要与固定修订匹配的完整 MLX 文件") }
        let after=try fm.attributesOfItem(atPath:url.resolvingSymlinksInPath().path)
        guard (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else { throw modelError("校验期间文件发生变化，请重试") }
        stamps[file.name]="\(file.size):\((after[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    return stamps
}

final class ModelManager {
    let specs:[ModelSpec]
    let configURL:URL
    let licenseRoot:URL
    var storageRoot:URL
    var references=[String:URL]()
    var verified=[String:[String:String]]()
    var rows=[String:[String:Any]]()
    var download:ModelDownload?
    var checking=Set<String>()
    var onUpdate:(([String:Any])->Void)?
    init(catalog:URL,config:URL,licenses:URL,defaultStorage:URL) throws {
        specs=try JSONDecoder().decode(ModelCatalog.self,from:Data(contentsOf:catalog)).models
        configURL=config;licenseRoot=licenses;storageRoot=defaultStorage
        if let data=try? Data(contentsOf:config),let c=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            if let root=c["storageRoot"] as? String { storageRoot=URL(fileURLWithPath:root,isDirectory:true) }
            if let refs=c["references"] as? [String:String] { references=refs.mapValues { URL(fileURLWithPath:$0,isDirectory:true) } }
        }
        for spec in specs {
            if references[spec.id] == nil { references[spec.id]=storageRoot.appendingPathComponent(spec.relativeDirectory,isDirectory:true) }
            rows[spec.id]=["state":"unchecked","message":"尚未校验"]
        }
    }
    func save() throws {
        let value:[String:Any]=["storageRoot":storageRoot.path,"references":references.mapValues(\.path)]
        let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:configURL,options:.atomic)
    }
    func publish() {
        let entries=specs.map { spec -> [String:Any] in
            var row=rows[spec.id] ?? [:]
            row.merge(["id":spec.id,"name":spec.folder,"repository":spec.repository,"revision":spec.revision,"license":spec.license,"licenseURL":spec.licenseURL,"bytes":spec.bytes,"format":spec.format,"path":references[spec.id]?.path ?? "","source":"https://huggingface.co/\(spec.repository)/tree/\(spec.revision)"]) { _,new in new }
            return row
        }
        onUpdate?(["type":"models","storageRoot":storageRoot.path,"models":entries,"busy":download != nil])
    }
    func isVerified(_ id:String)->Bool {
        guard let stamps=verified[id],let spec=specs.first(where:{$0.id==id}),let directory=references[id] else { return false }
        for file in spec.files {
            guard let attributes=try? FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(file.name).resolvingSymlinksInPath().path) else { return false }
            let stamp="\((attributes[.size] as? NSNumber)?.int64Value ?? -1):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if stamps[file.name] != stamp { return false }
        }
        return true
    }
    func check(_ id:String) {
        guard let spec=specs.first(where:{$0.id==id}),let directory=references[id],!checking.contains(id) else { return }
        guard FileManager.default.fileExists(atPath:directory.path) else { rows[id]=["state":"missing","message":"尚未安装，可下载或选择已有目录"];verified[id]=nil;publish();return }
        checking.insert(id);rows[id]=["state":"checking","message":"正在逐文件校验 SHA-256（不加载模型）"];publish()
        DispatchQueue.global(qos:.utility).async {
            let result=Result { try validateModel(spec,at:directory) }
            DispatchQueue.main.async {
                self.checking.remove(id)
                guard self.references[id] == directory else { return }
                switch result {
                case .success(let stamps):self.verified[id]=stamps;self.rows[id]=["state":"installed","message":"完整性已校验，可供兼容此 MLX 版本的软件引用"]
                case .failure(let error):self.verified[id]=nil;self.rows[id]=["state":"invalid","message":error.localizedDescription]
                }
                self.publish()
            }
        }
    }
    func refresh() { for spec in specs { check(spec.id) } }
    func reference(_ id:String,directory:URL) throws {
        guard download == nil,let spec=specs.first(where:{$0.id==id}) else { throw modelError("请先取消当前下载") }
        let nested=directory.appendingPathComponent(spec.folder,isDirectory:true)
        let selected=FileManager.default.fileExists(atPath:directory.appendingPathComponent("model.safetensors").path) ? directory : nested
        references[id]=selected;verified[id]=nil;try save();check(id)
    }
    func changeStorage(_ directory:URL) throws {
        guard download == nil else { throw modelError("请先取消当前下载") }
        storageRoot=directory;try save();publish()
    }
    func start(_ id:String) {
        guard download == nil,!checking.contains(id),let spec=specs.first(where:{$0.id==id}) else { return }
        if isVerified(id) { rows[id]=["state":"installed","message":"已有完整兼容模型，无需重复下载"];publish();return }
        let destination=storageRoot.appendingPathComponent(spec.relativeDirectory,isDirectory:true)
        // Prefer an already installed shared revision before requesting the network.
        if FileManager.default.fileExists(atPath:destination.path) {
            references[id]=destination;try? save();check(id);return
        }
        let transfer=ModelDownload(spec:spec,storage:storageRoot,licenses:licenseRoot)
        download=transfer
        transfer.update={ [weak self] state,message,received in
            DispatchQueue.main.async {
                guard let self=self,self.download === transfer else { return }
                self.rows[id]=["state":state,"message":message,"received":received];self.publish()
            }
        }
        transfer.completion={ [weak self] result in
            DispatchQueue.main.async {
                guard let self=self,self.download === transfer else { return }
                self.download=nil
                switch result {
                case .success(let directory):
                    self.references[id]=directory
                    do { try self.save();self.check(id) } catch { self.rows[id]=["state":"failed","message":"模型已完整提交，但引用保存失败：\(error.localizedDescription)"];self.publish() }
                case .failure(let error):self.rows[id]=["state":transfer.cancelled ? "cancelled" : "failed","message":error.localizedDescription,"received":transfer.totalReceived];self.publish()
                }
            }
        }
        transfer.begin();publish()
    }
    func cancel() { download?.cancel() }
}

final class ModelDownload:NSObject,URLSessionDataDelegate {
    let spec:ModelSpec
    let storage:URL
    let licenses:URL
    let staging:URL
    let destination:URL
    let queue=OperationQueue()
    var session:URLSession!
    var task:URLSessionDataTask?
    var handle:FileHandle?
    var index=0
    var received:Int64=0
    var completedBytes:Int64=0
    var totalReceived:Int64 { completedBytes+received }
    private let cancellationLock=NSLock()
    private var cancellationValue=false
    var cancelled:Bool { get { cancellationLock.lock();defer { cancellationLock.unlock() };return cancellationValue } set { cancellationLock.lock();cancellationValue=newValue;cancellationLock.unlock() } }
    var finished=false
    var failure:Error?
    var lastProgress=Date.distantPast
    var update:((String,String,Int64)->Void)?
    var completion:((Result<URL,Error>)->Void)?
    static let permittedHosts:Set<String>=["huggingface.co","cdn-lfs.huggingface.co","cdn-lfs-us-1.huggingface.co","cdn-lfs.hf.co","cas-bridge.xethub.hf.co","us.aws.cdn.hf.co","eu.aws.cdn.hf.co"]
    init(spec:ModelSpec,storage:URL,licenses:URL,configuration:URLSessionConfiguration?=nil) {
        self.spec=spec;self.storage=storage;self.licenses=licenses
        staging=storage.appendingPathComponent(".shungao-downloads/\(spec.folder)-\(spec.revision)",isDirectory:true)
        destination=storage.appendingPathComponent(spec.relativeDirectory,isDirectory:true)
        super.init()
        queue.maxConcurrentOperationCount=1
        let config=configuration ?? .ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=7200;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session=URLSession(configuration:config,delegate:self,delegateQueue:queue)
    }
    func begin() { queue.addOperation { self.next() } }
    func cancel() { cancelled=true;queue.addOperation {self.task?.cancel();if self.task == nil { self.finish(.failure(modelError("已取消；已下载数据保留，重试将安全续传"))) } } }
    func finish(_ result:Result<URL,Error>) {
        guard !finished else { return };finished=true;try? handle?.close();handle=nil;task=nil;session.invalidateAndCancel();let callback=completion;completion=nil;update=nil;callback?(result)
    }
    func next() {
        guard !finished else { return }
        if cancelled { finish(.failure(modelError("已取消；已下载数据保留，重试将安全续传")));return }
        do {
            let fm=FileManager.default
            // Only signed-in catalog identifiers and simple filenames are accepted; never unpack archives.
            guard spec.revision.count==40,spec.revision.allSatisfy({$0.isHexDigit}),["mlx-community/SenseVoiceSmall","mlx-community/Qwen3-ASR-1.7B-8bit"].contains(spec.repository),!spec.folder.contains("/"),!spec.folder.contains("..") else { throw modelError("模型清单无效") }
            let downloadsRoot=storage.appendingPathComponent(".shungao-downloads",isDirectory:true)
            guard (try? downloadsRoot.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,staging.resolvingSymlinksInPath().path.hasPrefix(storage.resolvingSymlinksInPath().path+"/") else { throw modelError("下载目录存在越界符号链接") }
            try fm.createDirectory(at:staging,withIntermediateDirectories:true)
            guard staging.resolvingSymlinksInPath().path.hasPrefix(storage.resolvingSymlinksInPath().path+"/") else { throw modelError("下载目录存在越界符号链接") }
            if index == spec.files.count {
                update?("checking","正在最终校验；完成前不可加载",spec.bytes)
                _=try validateModel(spec,at:staging)
                let license=licenses.appendingPathComponent(spec.licenseFile)
                if fm.fileExists(atPath:license.path) { try Data(contentsOf:license).write(to:staging.appendingPathComponent(spec.licenseFile),options:.atomic) }
                let marker:[String:Any]=["repository":spec.repository,"revision":spec.revision,"files":spec.files.map { ["name":$0.name,"sha256":$0.sha256,"size":$0.size] as [String:Any] },"managedBy":"顺稿","completed":true]
                try JSONSerialization.data(withJSONObject:marker,options:[.prettyPrinted,.sortedKeys]).write(to:staging.appendingPathComponent("installation.json"),options:.atomic)
                try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                guard !fm.fileExists(atPath:destination.path) else { throw modelError("目标目录已存在；为保护已有模型，未覆盖。请选择该目录验证或换共享目录") }
                guard !cancelled else { throw modelError("已取消；已下载数据保留") }
                guard destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(storage.resolvingSymlinksInPath().path+"/") else { throw modelError("目标目录存在越界符号链接") }
                try fm.moveItem(at:staging,to:destination)
                finish(.success(destination));return
            }
            let file=spec.files[index]
            guard !file.name.contains("/"),!file.name.contains("\\"),!file.name.contains(".."),file.sha256.count==64,file.size>0 else { throw modelError("模型文件清单无效") }
            let complete=staging.appendingPathComponent(file.name)
            let partial=staging.appendingPathComponent(file.name+".part")
            for candidate in [complete,partial] { if (try? fm.attributesOfItem(atPath:candidate.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw modelError("下载文件存在符号链接，未写入") } }
            if fm.fileExists(atPath:complete.path),(try? modelFileValid(complete,file)) == true { completedBytes+=file.size;index+=1;next();return }
            if fm.fileExists(atPath:partial.path) { received=(try fm.attributesOfItem(atPath:partial.path)[.size] as? NSNumber)?.int64Value ?? 0 }
            else { guard fm.createFile(atPath:partial.path,contents:nil) else { throw modelError("无法创建下载文件") };received=0 }
            handle=try FileHandle(forWritingTo:partial)
            if received>file.size { try handle?.truncate(atOffset:0);received=0 }
            if received==file.size { try completeCurrentFile();return }
            try handle?.seekToEnd()
            let url=URL(string:"https://huggingface.co/\(spec.repository)/resolve/\(spec.revision)/\(file.name)")!
            var request=URLRequest(url:url);request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            if received>0 { request.setValue("bytes=\(received)-",forHTTPHeaderField:"Range") }
            update?("downloading",received>0 ? "续传 \(file.name)" : "下载 \(file.name)",totalReceived)
            task=session.dataTask(with:request);task?.resume()
        } catch { finish(.failure(error)) }
    }
    func completeCurrentFile() throws {
        let fm=FileManager.default,file=spec.files[index]
        try handle?.synchronize();try handle?.close();handle=nil
        let partial=staging.appendingPathComponent(file.name+".part")
        update?("checking","校验 \(file.name)",totalReceived)
        guard try modelFileValid(partial,file) else {
            // This owned partial is the only object removed after a checksum mismatch.
            try fm.removeItem(at:partial);throw modelError("\(file.name) SHA-256 不符；该分片已丢弃，重试将重新下载此文件")
        }
        guard !cancelled else { throw modelError("已取消；完整分片保留，可重试") }
        let complete=staging.appendingPathComponent(file.name)
        if fm.fileExists(atPath:complete.path) { try fm.removeItem(at:complete) }
        try fm.moveItem(at:partial,to:complete)
        completedBytes+=file.size;received=0;index+=1;task=nil;next()
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        if request.url?.scheme == "https",let host=request.url?.host,Self.permittedHosts.contains(host) { completionHandler(request) }
        else { failure=modelError("下载重定向不在可信域名清单内");completionHandler(nil) }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        do {
            guard let http=response as? HTTPURLResponse,let host=http.url?.host,Self.permittedHosts.contains(host),http.url?.scheme=="https" else { throw modelError("下载响应来源无效") }
            let file=spec.files[index]
            if http.statusCode==200 {
                if received>0 { try handle?.truncate(atOffset:0);try handle?.seek(toOffset:0);received=0 }
            } else if http.statusCode==206 {
                let range=http.value(forHTTPHeaderField:"Content-Range") ?? ""
                guard range.hasPrefix("bytes \(received)-"),range.hasSuffix("/\(file.size)") else { throw modelError("续传范围不符，未写入响应") }
            } else { throw modelError("下载失败 HTTP \(http.statusCode)；可重试，已有数据保留") }
            completionHandler(.allow)
        } catch { failure=error;completionHandler(.cancel) }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        guard !cancelled,failure == nil else { return }
        do {
            guard received+Int64(data.count)<=spec.files[index].size else { throw modelError("下载数据超过固定文件大小") }
            try handle?.write(contentsOf:data);received+=Int64(data.count)
            if Date().timeIntervalSince(lastProgress) > 0.1 { lastProgress=Date();update?("downloading","下载 \(spec.files[index].name)",totalReceived) }
        } catch { failure=error;dataTask.cancel() }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        self.task=nil
        if cancelled { finish(.failure(modelError("已取消；已下载数据保留，重试将安全续传")));return }
        if let error=failure ?? error { finish(.failure(error));return }
        do { guard received==spec.files[index].size else { throw modelError("文件未下载完整；可重试续传") };try completeCurrentFile() }
        catch { finish(.failure(error)) }
    }
}

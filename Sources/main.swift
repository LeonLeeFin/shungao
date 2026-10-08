import AppKit
import WebKit
import AVFoundation
import UniformTypeIdentifiers

let buildID = "20261008.9"
let bundleResources = Bundle.main.resourceURL!
let projectRoot = Bundle.main.bundleURL.deletingLastPathComponent()
let reopenStage = CommandLine.arguments.first(where:{$0.hasPrefix("--reopen-test=")})?.split(separator:"=").last.map(String.init)
let startupProbe = CommandLine.arguments.first(where:{$0.hasPrefix("--startup-probe=")})?.split(separator:"=").last.map(String.init)
let initialModel = CommandLine.arguments.first(where:{$0.hasPrefix("--load-model=")})?.split(separator:"=").last.map(String.init)
let motionTestMode = CommandLine.arguments.contains("--motion-test")
let trajectoryTestMode = CommandLine.arguments.contains("--v8-test")
let experienceTestMode = CommandLine.arguments.contains("--experience-test")
let uiTestMode = CommandLine.arguments.contains("--ui-test") || motionTestMode || experienceTestMode || trajectoryTestMode
let applicationSupport = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("顺稿",isDirectory:true)
let stateDir = ProcessInfo.processInfo.environment["SHUNGAO_STATE_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? ((reopenStage != nil || uiTestMode) ? projectRoot.appendingPathComponent(reopenStage != nil ? "tests/reopen-state" : "tests/ui-state") : applicationSupport)
let runtimeRoot = bundleResources.appendingPathComponent("runtime/Python.framework/Versions/3.10",isDirectory:true)
let python = runtimeRoot.appendingPathComponent("Resources/Python.app/Contents/MacOS/Python").path
let promptType = UTType(exportedAs:"local.leon.shungao.recovery.document",conformingTo:.json)

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var worker: Process?
    var input: FileHandle?
    var outputBuffer = Data()
    var currentURL: URL?
    var session: [String: Any] = [:]
    var documentLibrary:DocumentLibrary?
    var libraryStartupError:String?
    var epoch = 0
    var model = "sensevoice"
    var modelManager:ModelManager?
    var ready = false
    var quitting = false
    let testing = uiTestMode
    var testsDone = false
    var terminationPending = false
    var lastAutosaveError = ""
    var nativeTestEvents: [[String:Any]]?
    var frameTimer: Timer?
    var frameInFlight = false
    var playActivity: NSObjectProtocol?
    var deviceTimer:Timer?
    var deviceSnapshot=""
    var restoreModelPending:String?
    var lastSuccessfulModel:String?
    var probeEvents=[[String:Any]]()
    var probeFinished=false
    var modelLoadedOnce=false


    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: stateDir.appendingPathComponent("session.json")), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { session = s }
        do {
            documentLibrary=try DocumentLibrary(url:stateDir.appendingPathComponent("library.json"),legacy:session,legacyURL:stateDir.appendingPathComponent("session.json"))
            session=documentLibrary!.activeSession()
        } catch { libraryStartupError="文稿库未能打开，原文件已保留：\(error.localizedDescription)" }
        if let d=try? Data(contentsOf:stateDir.appendingPathComponent("engine-preferences.json")),let p=try? JSONSerialization.jsonObject(with:d) as? [String:Any],let name=p["lastSuccessfulModel"] as? String,["sensevoice","qwen"].contains(name) { lastSuccessfulModel=name }
        do {
            modelManager=try ModelManager(catalog:bundleResources.appendingPathComponent("model-catalog.json"),config:stateDir.appendingPathComponent("model-config.json"),licenses:bundleResources.appendingPathComponent("licenses"),defaultStorage:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models",isDirectory:true))
            modelManager?.onUpdate={ [weak self] update in self?.event(update);self?.tryRestoreModel(update) }
        } catch { NSLog("模型目录清单读取失败：%@",error.localizedDescription) }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "host")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed=false // Swift owns the window through shutdown/timer callbacks.
        window.title = "顺稿"
        window.appearance=NSAppearance(named:.aqua)
        window.minSize = NSSize(width: 820, height: 620)
        window.contentView = web
        window.delegate = self
        if !testing && startupProbe == nil { window.setFrameAutosaveName("ShunGaoRecoveryWindow") }
        window.center()
        menu()
        web.loadFileURL(bundleResources.appendingPathComponent("ui.html"), allowingReadAccessTo: bundleResources)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        frameTimer=Timer(timeInterval:1.0/30.0,repeats:true) { [weak self] _ in
            guard let self=self, !self.frameInFlight else { return }
            self.frameInFlight=true
            let hidden = !self.window.isVisible || self.window.isMiniaturized
            self.web.evaluateJavaScript("if(typeof nativeTick==='function')nativeTick(performance.now(),\(hidden ? "true" : "false"))") { _,_ in self.frameInFlight=false }
        }
        RunLoop.main.add(frameTimer!,forMode:.common)
        deviceTimer=Timer(timeInterval:2,repeats:true) { [weak self] _ in self?.publishDevices() }
        RunLoop.main.add(deviceTimer!,forMode:.common)
        if startupProbe != nil {
            DispatchQueue.main.asyncAfter(deadline:.now()+55) { self.finishStartupProbe(error:"真实启动检查超过55秒") }
        }
        if testing || reopenStage != nil {
            DispatchQueue.main.asyncAfter(deadline:.now()+30) {
                if !self.testsDone {
                    self.writeTestReport(["build":buildID,"error":"WebKit 界面测试超过 30 秒未完成","result":NSNull()])
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func menuItem(_ title: String, _ key: String, _ action: Selector, _ flags: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = flags
        return item
    }
    func menu() {
        let bar = NSMenu()
        let app = NSMenu(); app.addItem(menuItem("关于顺稿", "", #selector(about))); app.addItem(.separator()); app.addItem(menuItem("退出顺稿", "q", #selector(quit)))
        let a = NSMenuItem(); a.submenu = app; bar.addItem(a)
        let file = NSMenu(title: "文稿")
        file.addItem(menuItem("新建文稿", "n", #selector(newDocument)))
        file.addItem(menuItem("文稿库…", "", #selector(showLibrary)))
        file.addItem(menuItem("导入文稿…", "o", #selector(openScript)))
        file.addItem(menuItem("保存文稿", "s", #selector(saveScript)))
        file.addItem(menuItem("另存为…", "s", #selector(saveAs), [.command, .shift]))
        file.addItem(menuItem("编辑文稿", "e", #selector(edit)))
        file.addItem(menuItem("模型管理…", "", #selector(showModels)))
        let f = NSMenuItem(title: "文稿", action: nil, keyEquivalent: ""); f.submenu=file; bar.addItem(f)
        let view = NSMenu(title: "提词")
        view.addItem(menuItem("暂停 / 继续", "p", #selector(toggle), [.command,.shift]))
        view.addItem(menuItem("水平镜像", "m", #selector(mirror)))
        view.addItem(menuItem("进入 / 退出全屏", "f", #selector(fullscreen), [.command,.control]))
        view.addItem(menuItem("窗口置顶", "t", #selector(pin)))
        let v=NSMenuItem(title: "提词", action:nil,keyEquivalent: ""); v.submenu=view; bar.addItem(v)
        // Standard editing commands are necessary inside the script editor.
        let editing=NSMenu(title:"编辑")
        for (title,key,selector) in [("撤销","z","undo:"),("剪切","x","cut:"),("复制","c","copy:"),("粘贴","v","paste:"),("全选","a","selectAll:")] { editing.addItem(NSMenuItem(title:title,action:NSSelectorFromString(selector),keyEquivalent:key)) }
        let e=NSMenuItem(title:"编辑",action:nil,keyEquivalent:""); e.submenu=editing; bar.addItem(e)
        NSApp.mainMenu=bar
    }
    @objc func about() { let a=NSAlert(); a.messageText="顺稿 1.0"; a.informativeText="构建 \(buildID)\n本地 MLX 语音识别 · 文稿与音频不上传\nApple Silicon 开发构建，未进行 Developer ID 签名或公证。"; a.runModal() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func newDocument() { js("libraryAction('new')") }
    @objc func showLibrary() { js("showLibrary()") }
    @objc func edit() { js("editScript()") }
    @objc func toggle() { js("togglePlay()") }
    @objc func mirror() { js("toggleMirror()") }
    @objc func fullscreen() { window.toggleFullScreen(nil) }
    @objc func pin() { window.level = window.level == .floating ? .normal : .floating; event(["type":"pinned","value":window.level == .floating]) }
    func setPlayActivity(_ active:Bool) {
        if active && playActivity == nil { playActivity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"顺稿提词或倒计时") }
        else if !active, let activity=playActivity { ProcessInfo.processInfo.endActivity(activity);playActivity=nil }
    }
    func js(_ code: String) { web.evaluateJavaScript(code, completionHandler:nil) }
    func event(_ object: [String: Any]) {
        if startupProbe != nil { probeEvents.append(object) }
        if nativeTestEvents != nil { nativeTestEvents!.append(object);return }
        guard let d=try? JSONSerialization.data(withJSONObject:object), let s=String(data:d,encoding:.utf8) else { return }
        js("receive(\(s))")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        event(["type":"restore","session":session,"build":buildID])
        if let library=documentLibrary { event(library.metadata()) }
        if let error=libraryStartupError { event(["type":"libraryError","message":error]) }
        publishDevices(force:true)
        if !testing && reopenStage == nil {
            restoreModelPending=initialModel ?? lastSuccessfulModel
            if let name=restoreModelPending { event(["type":"engineState","state":"loading","model":name,"message":"正在后台校验并加载上次模型…"]) }
        }
        modelManager?.publish();modelManager?.refresh()
        if startupProbe == "devices" {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                self.web.evaluateJavaScript("if($('device').options.length>1){$('device').selectedIndex=1;changeDevice()}") { _,_ in
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.8) { self.finishStartupProbe() }
                }
            }
        }
        if testing {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { if trajectoryTestMode { self.runV8Tests() } else if experienceTestMode { self.runExperienceTests() } else if motionTestMode { self.runMotionTests() } else { self.runUITests() } }
        } else if let stage=reopenStage {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.runReopenTest(stage) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m=message.body as? [String:Any], let type=m["type"] as? String else { return }
        switch type {
        case "open": openScript()
        case "libraryAction": handleLibraryAction(m)
        case "copyDocumentBody":
            do {
                let id=m["id"] as? String ?? "",current=m["session"] as? [String:Any] ?? [:]
                let body:String
                if id==documentLibrary?.activeID,let text=current["text"] as? String { body=text }
                else { guard let library=documentLibrary else { throw libraryError("文稿库未打开") };body=try library.document(id)["text"] as? String ?? "" }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(body,forType:.string) else { throw libraryError("无法写入剪贴板，文稿未改变") }
                event(["type":"copiedBody"])
            } catch { event(["type":"libraryError","message":error.localizedDescription]) }
        case "followDiagnostics":
            if let data=try? JSONSerialization.data(withJSONObject:m,options:[.sortedKeys]) { try? data.write(to:stateDir.appendingPathComponent("follow-diagnostics.json"),options:.atomic) }
        case "libraryTestFailure":
            if testing { documentLibrary?.forcedWriteFailure=m["value"] as? Bool == true;event(["type":"libraryTestAck","value":m["value"] ?? false]) }
        case "chooseModels": chooseExistingModel(m["id"] as? String ?? model)
        case "modelsUI": showModels()
        case "refreshModels": modelManager?.refresh()
        case "chooseStorage": chooseStorage()
        case "downloadModel":
            guard !testing && reopenStage == nil else { event(["type":"warning","message":"自动验收模式禁止真实下载"]);return }
            modelManager?.start(m["id"] as? String ?? "sensevoice")
        case "cancelDownload": modelManager?.cancel()
        case "copyModelSource":
            if let id=m["id"] as? String,let spec=modelManager?.specs.first(where:{$0.id==id}) { NSPasteboard.general.clearContents();NSPasteboard.general.setString("https://huggingface.co/\(spec.repository)/tree/\(spec.revision)",forType:.string) }
        case "modelLicense":
            if let id=m["id"] as? String,let spec=modelManager?.specs.first(where:{$0.id==id}),let text=try? String(contentsOf:bundleResources.appendingPathComponent("licenses/"+spec.licenseFile),encoding:.utf8) { event(["type":"modelLicense","text":text]) }
        case "copyModelPath":
            if let id=m["id"] as? String,let path=modelManager?.references[id]?.path { NSPasteboard.general.clearContents();NSPasteboard.general.setString(path,forType:.string) }
        case "save": saveScript()
        case "saveAs": saveAs()
        case "fullscreen": fullscreen()
        case "exitFullscreen": if window.styleMask.contains(.fullScreen) { fullscreen() }
        case "pin": pin()
        case "playState": setPlayActivity(m["value"] as? Bool == true)
        case "session":
            session=m["session"] as? [String:Any] ?? [:]
            persist()
        case "selectModel": restoreModelPending=nil;stopWorker();model=m["model"] as? String ?? "sensevoice"
        case "loadEngine":
            guard !testing && reopenStage == nil else { event(["type":"error","message":"自动验收模式禁止加载模型"]);return }
            restoreModelPending=nil;startWorker(m["model"] as? String ?? "sensevoice")
        case "start":
            epoch=m["epoch"] as? Int ?? epoch+1
            guard ready else { event(["type":"error","message":"请先加载本地识别模型"]); return }
            AVCaptureDevice.requestAccess(for:.audio) { allowed in
                DispatchQueue.main.async {
                    guard self.epoch == (m["epoch"] as? Int) else { return }
                    if allowed {
                        var command=m
                        let devices=AudioInputs.list(),uid=m["deviceUID"] as? String ?? ""
                        let selected=devices.first(where:{$0.uid==uid}) ?? devices.first(where:{$0.id==AudioInputs.defaultID()})
                        if !uid.isEmpty && !devices.contains(where:{$0.uid==uid}) { self.publishDevices(force:true);self.event(["type":"warning","message":"所选输入已断开，已回退系统输入"]) }
                        guard let selected=selected else { self.event(["type":"error","message":"系统目前没有可用输入设备"]);return }
                        command["deviceUID"]=selected.uid;command["deviceName"]=selected.name;command["coreAudioID"]=Int(selected.id)
                        self.send(command)
                    }
                    else { self.event(["type":"error","message":"麦克风权限被拒绝。请在系统设置 → 隐私与安全性 → 麦克风中允许顺稿，然后重新开始。定速模式仍可使用。"]); self.send(["type":"pause","epoch":self.epoch,"paused":true]) }
                }
            }
        case "devices": publishDevices(force:true)
        case "script", "locate", "pause", "stop", "gate": epoch=m["epoch"] as? Int ?? epoch; send(m)
        default: break
        }
    }
    func writeSession(_ value:[String:Any], to url:URL) throws {
        let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:url,options:.atomic)
    }
    @discardableResult func persist(to destination:URL? = nil) -> Bool {
        do {
            if let destination=destination { try writeSession(session,to:destination) }
            else if let library=documentLibrary { try library.save(session);session=library.activeSession();event(library.metadata()) }
            else { throw libraryError(libraryStartupError ?? "文稿库不可用") }
            lastAutosaveError="";return true
        } catch {
            let message="自动保存失败，文稿仍保留在窗口中；切换已停止，请另存为到可写位置：\(error.localizedDescription)"
            if lastAutosaveError != message { lastAutosaveError=message;event(["type":"libraryError","message":message]) }
            return false
        }
    }
    func handleLibraryAction(_ message:[String:Any]) {
        guard let library=documentLibrary else { event(["type":"libraryError","message":libraryStartupError ?? "文稿库未打开，当前文稿已保留"]);return }
        do {
            let current=message["session"] as? [String:Any] ?? session
            try library.save(current) // A failed save never selects or creates another document.
            switch message["action"] as? String {
            case "new": try library.create()
            case "switch":try library.select(message["id"] as? String ?? "")
            case "rename":try library.rename(message["id"] as? String ?? library.activeID,message["title"] as? String ?? "")
            case "duplicate":try library.duplicate(message["id"] as? String ?? library.activeID)
            case "trash":try library.moveToTrash(message["id"] as? String ?? library.activeID)
            case "restoreTrash":try library.restoreFromTrash(message["id"] as? String ?? "")
            case "undoTrash":
                guard let id=library.trash.last?["id"] as? String else { throw libraryError("没有可撤销的删除") }
                try library.restoreFromTrash(id)
            case "paste":
                guard let body=NSPasteboard.general.string(forType:.string),!body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw libraryError("剪贴板没有可粘贴的正文，当前篇已保留") }
                try library.create(["text":body,"offset":0])
            default:throw libraryError("文稿操作无效，当前篇已保留")
            }
            session=library.activeSession();currentURL=nil
            event(["type":"restore","session":session,"build":buildID]);event(library.metadata());publishDevices(force:true)
            if message["action"] as? String == "new" { js("editScript()") }
        } catch { event(["type":"libraryError","message":"保存/切换失败，当前文稿和草稿仍保留：\(error.localizedDescription)"]) }
    }
    func send(_ m:[String:Any]) {
        guard let data=try? JSONSerialization.data(withJSONObject:m), let handle=input else { return }
        do { try handle.write(contentsOf:data+Data([10])) } catch { event(["type":"error","message":"识别进程已结束，请重新加载模型"]); ready=false }
    }
    func stopWorker() {
        ready=false
        input?.closeFile(); input=nil
        if let p=worker, p.isRunning { p.terminate() }
        worker=nil; outputBuffer=Data()
    }
    func publishDevices(force:Bool=false) {
        let devices=AudioInputs.list(),defaultID=AudioInputs.defaultID()
        let fingerprint=devices.map { "\($0.id):\($0.uid):\($0.name)" }.joined(separator:"|")+":\(defaultID)"
        guard force || fingerprint != deviceSnapshot else { return }
        deviceSnapshot=fingerprint
        event(["type":"devices","devices":devices.map(\.json),"defaultUID":devices.first(where:{$0.id==defaultID})?.uid ?? "","defaultName":devices.first(where:{$0.id==defaultID})?.name ?? "无可用设备"])
    }
    func tryRestoreModel(_ update:[String:Any]) {
        guard let name=restoreModelPending,let rows=update["models"] as? [[String:Any]],let row=rows.first(where:{$0["id"] as? String == name}),let state=row["state"] as? String else { return }
        if state == "installed",modelManager?.isVerified(name) == true { restoreModelPending=nil;startWorker(name) }
        else if ["missing","invalid","failed"].contains(state) {
            restoreModelPending=nil
            event(["type":"engineState","state":"failed","model":name,"message":"上次模型缺失或校验失败，请在模型管理中检查已有目录；不会自动下载"])
            if startupProbe != nil { finishStartupProbe(error:"本地模型缺失或校验失败") }
        }
    }
    func finishStartupProbe(error:String?=nil) {
        guard !probeFinished else { return };probeFinished=true
        web.evaluateJavaScript("getSession()") { value,_ in
            let report:[String:Any]=["build":buildID,"stage":startupProbe ?? "","ready":self.ready,"model":self.model,"lastSuccessfulModel":self.lastSuccessfulModel ?? "","workerStarted":self.worker != nil,"events":self.probeEvents,"session":value ?? [:],"error":error ?? ""]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:stateDir.appendingPathComponent("startup-\(startupProbe ?? "unknown").json"),options:.atomic) }
            NSApp.terminate(nil)
        }
    }
    func startWorker(_ name:String) {
        stopWorker(); model=name
        guard FileManager.default.isExecutableFile(atPath:python) else { event(["type":"engineState","state":"failed","message":"应用内的识别运行时缺失，请重新安装完整顺稿 App；定速模式仍可使用"]);return }
        guard modelManager?.isVerified(name) == true,let folder=modelManager?.references[name] else { event(["type":"engineState","state":"failed","message":"所选模型尚未通过完整性校验。请打开「模型管理」选择已有兼容目录；不会自动下载"]);return }
        let process=Process(), stdin=Pipe(), stdout=Pipe(), stderr=Pipe()
        process.executableURL=URL(fileURLWithPath:python)
        process.arguments=["-B","-s","-u", bundleResources.appendingPathComponent("engine/worker.py").path,"--model",name]
        var env=ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"]="1"; env["TRANSFORMERS_OFFLINE"]="1"; env["HF_HUB_DISABLE_TELEMETRY"]="1"; env["PYTHONDONTWRITEBYTECODE"]="1"
        env["PYTHONHOME"]=runtimeRoot.path;env["PYTHONNOUSERSITE"]="1";env["PYTHONPATH"]=nil;env["PYTHONEXECUTABLE"]=nil
        env["SHUNGAO_MODEL_DIR"]=folder.path
        process.environment=env
        process.currentDirectoryURL=bundleResources
        process.standardInput=stdin; process.standardOutput=stdout; process.standardError=stderr
        stdout.fileHandleForReading.readabilityHandler={ [weak self, weak process] h in
            let data=h.availableData,receivedAt=ProcessInfo.processInfo.systemUptime
            if data.isEmpty { h.readabilityHandler=nil; return }
            DispatchQueue.main.async {
                guard let self=self, self.worker === process else { return }
                self.outputBuffer.append(data)
                while let range=self.outputBuffer.range(of:Data([10])) {
                    let line=self.outputBuffer.subdata(in:0..<range.lowerBound)
                    self.outputBuffer.removeSubrange(0...range.lowerBound)
                    if var object=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] {
                        object["nativeQueueSeconds"]=max(0,ProcessInfo.processInfo.systemUptime-receivedAt)
                        if object["type"] as? String == "ready" {
                            self.ready=true
                            self.modelLoadedOnce=true;self.lastSuccessfulModel=name
                            do { try self.writeSession(["lastSuccessfulModel":name],to:stateDir.appendingPathComponent("engine-preferences.json")) }
                            catch { self.event(["type":"warning","message":"模型已就绪，但无法保存上次成功模型：\(error.localizedDescription)"]) }
                            if startupProbe != nil { DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.finishStartupProbe() } }
                        }
                        if object["type"] as? String == "error",!self.ready { self.event(["type":"engineState","state":"failed","message":object["message"] ?? "模型加载失败"]) }
                        else { self.event(object) }
                    }
                }
            }
        }
        // Keep only local diagnostics; no raw audio is stored by the app.
        stderr.fileHandleForReading.readabilityHandler={ h in
            let d=h.availableData
            if d.isEmpty { h.readabilityHandler=nil; return }
            if let f=try? FileHandle(forWritingTo:stateDir.appendingPathComponent("engine.log")) { f.seekToEndOfFile(); f.write(d); f.closeFile() }
            else { try? d.write(to:stateDir.appendingPathComponent("engine.log")) }
        }
        process.terminationHandler={ [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self=self, self.worker === process, !self.quitting else { return }
                self.ready=false
                self.event(["type":"engineState","state":"failed","message":"本地识别进程已结束，可重新加载模型；定速模式仍可使用"]);self.event(["type":"engineStopped","message":"本地识别进程已结束，可重新加载模型；定速模式仍可使用"])
            }
        }
        do {
            worker=process; input=stdin.fileHandleForWriting; try process.run(); event(["type":"engineState","state":"loading","model":name,"message":"正在后台加载本地模型…"])
            DispatchQueue.main.asyncAfter(deadline:.now()+45) { [weak self, weak process] in
                guard let self=self, self.worker === process, !self.ready else { return }
                self.stopWorker()
                self.event(["type":"engineState","state":"failed","message":"本地环境启动超过45秒，请检查已有模型后重试；编辑与输入设备选择仍可使用"])
            }
        }
        catch { stopWorker(); event(["type":"engineState","state":"failed","message":"无法打开本地 Python 环境：\(error.localizedDescription)"] ) }
    }
    @objc func showModels() { js("showModelManager()");modelManager?.refresh() }
    func chooseExistingModel(_ id:String) {
        js("pausePlay()");stopWorker()
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="选择该模型的完整 MLX 文件目录，或包含模型子目录的文件夹。只验证并引用，不复制或移动。HF snapshot 目录也可选择。"
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url=panel.url else { return }
            do { try self.modelManager?.reference(id,directory:url);self.event(["type":"engineStopped","message":"正在验证已有模型目录；验证成功后可加载"])}
            catch { self.event(["type":"error","message":error.localizedDescription]) }
        }
    }
    @objc func chooseStorage() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false;panel.message="选择共用模型的存储根目录。已有模型不会移动，卸载 App 不删除此目录。"
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url=panel.url else { return }
            do { try self.modelManager?.changeStorage(url) } catch { self.event(["type":"warning","message":error.localizedDescription]) }
        }
    }
    @objc func openScript() {
        js("pausePlay()")
        web.evaluateJavaScript("getSession()") { value,_ in
            if let value=value as? [String:Any] { self.session=value }
            guard self.persist() else { return }
            self.presentImportPanel()
        }
    }
    func presentImportPanel() {
        let p=NSOpenPanel(); p.allowedContentTypes=[.plainText, UTType(filenameExtension:"md") ?? .plainText,promptType,.json]; p.allowsMultipleSelection=false
        p.beginSheetModal(for:window) { response in
            if response == .OK, let url=p.url { self.readScript(url) }
        }
    }
    func readScript(_ url:URL) {
        do {
            let d=try Data(contentsOf:url)
            let message=try decodeDocument(d, extension:url.pathExtension)
            guard let library=documentLibrary else { throw libraryError("文稿库尚未打开，无法导入；原稿已保留") }
            let imported=message["session"] as? [String:Any] ?? ["text":message["text"] ?? "","offset":0]
            try library.save(session);try library.create(imported)
            session=library.activeSession();currentURL=nil
            event(["type":"restore","session":session,"build":buildID]);event(library.metadata());publishDevices(force:true)
        } catch { event(["type":"error","message":"打开失败：\(error.localizedDescription)"]) }
    }
    func decodeDocument(_ data:Data, extension ext:String) throws -> [String:Any] {
        if ["sgprompt","json"].contains(ext.lowercased()) {
            guard let s=try JSONSerialization.jsonObject(with:data) as? [String:Any], s["text"] is String else {
                throw NSError(domain:"document",code:1,userInfo:[NSLocalizedDescriptionKey:"提词文稿格式无效，缺少文字内容"])
            }
            return ["type":"restore","session":s]
        }
        let gb=String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        var text=String(data:data,encoding:.utf8)
        if text == nil && (data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff])) { text=String(data:data,encoding:.utf16) }
        if text == nil { text=String(data:data,encoding:gb) }
        guard let text=text else { throw NSError(domain:"text",code:1,userInfo:[NSLocalizedDescriptionKey:"无法识别文稿编码，请另存为 UTF-8 TXT"]) }
        return ["type":"document","text":text.replacingOccurrences(of:"\u{feff}",with:"")]
    }
    @objc func saveScript() { collectSession { self.event(["type":"saved","filename":self.session["documentTitle"] ?? "文稿库"]) } }
    @objc func saveAs() {
        collectSession {
            let p=NSSavePanel(); p.nameFieldStringValue=self.currentURL?.lastPathComponent ?? "我的文稿.sgprompt"
            p.allowedContentTypes=[promptType,.plainText,UTType(filenameExtension:"md") ?? .plainText]; p.allowsOtherFileTypes=true
            p.beginSheetModal(for:self.window) { response in
                if response == .OK, let url=p.url { self.writeScript(url) }
            }
        }
    }
    func collectSession(_ completion:@escaping ()->Void) {
        web.evaluateJavaScript("prepareToSave()") { value,error in
            if let s=value as? [String:Any] { self.session=s;if self.persist() { completion() } }
            else { self.event(["type":"error","message":"无法读取当前文稿状态"] ) }
        }
    }
    @discardableResult func writeScript(_ url:URL) -> Bool {
        do {
            let data:Data
            if ["sgprompt","json"].contains(url.pathExtension.lowercased()) { data=try JSONSerialization.data(withJSONObject:session,options:[.prettyPrinted,.sortedKeys]) }
            else { data=(session["text"] as? String ?? "").data(using:.utf8)! }
            try data.write(to:url,options:.atomic); currentURL=url
            event(["type":"saved","filename":url.lastPathComponent])
            return true
        } catch { event(["type":"error","message":"保存失败，文稿仍保留在窗口中：\(error.localizedDescription)"]); return false }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if testing { return true }
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if testing { frameTimer?.invalidate();deviceTimer?.invalidate();setPlayActivity(false);return .terminateNow }
        terminationPending=true
        web.evaluateJavaScript("getSession()") { value,error in
            if let s=value as? [String:Any] { self.session=s }
            self.finishTermination()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            self.finishTermination()
        }
        return .terminateLater
    }
    func finishTermination() {
        guard terminationPending else { return }
        terminationPending=false
        if !persist() {
            let alert=NSAlert();alert.messageText="自动保存失败，取消退出可继续保留文稿"
            alert.informativeText="请取消退出后另存为到可写位置。选择仍然退出可能丢失未成功保存的内容。"
            alert.addButton(withTitle:"取消退出");alert.addButton(withTitle:"仍然退出")
            if alert.runModal() != .alertSecondButtonReturn { NSApp.reply(toApplicationShouldTerminate:false);return }
        }
        quitting=true;modelManager?.cancel();stopWorker();frameTimer?.invalidate();deviceTimer?.invalidate();setPlayActivity(false);NSApp.reply(toApplicationShouldTerminate:true)
    }
    func runV8Tests() {
        web.callAsyncJavaScript("return await runV8Tests()",arguments:[:],in:nil,in:.page) { result in
            var report:[String:Any]=["build":buildID,"modelUsed":false,"workerStarted":self.worker != nil,"recognitionEventsSimulated":true]
            switch result { case .success(let value):report["result"]=value;case .failure(let error):report["error"]=error.localizedDescription }
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:stateDir.appendingPathComponent("v8-results.json"),options:.atomic) }
            self.finishUITests()
        }
    }
    func runExperienceTests() {
        web.callAsyncJavaScript("return await runExperienceTests()",arguments:[:],in:nil,in:.page) { result in
            var report:[String:Any]=["build":buildID,"modelUsed":false,"workerStarted":self.worker != nil,"speechEventsSimulated":true,"nativeInputDevices":AudioInputs.list().map(\.json)]
            switch result { case .success(let value):report["result"]=value;case .failure(let error):report["error"]=error.localizedDescription }
            self.window.setContentSize(NSSize(width:820,height:620))
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
                self.web.evaluateJavaScript("probeLayout()") { value,_ in
                    report["smallWindowLayout"]=value ?? [:]
                    self.window.toggleFullScreen(nil)
                    DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                        self.web.evaluateJavaScript("probeLayout()") { value,_ in
                            report["fullScreenLayout"]=value ?? [:]
                            report["nativeFullScreen"]=self.window.styleMask.contains(.fullScreen)
                            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:stateDir.appendingPathComponent("experience-results.json"),options:.atomic) }
                            self.finishUITests()
                        }
                    }
                }
            }
        }
    }
    func runMotionTests() {
        web.callAsyncJavaScript("return await runMotionTests()",arguments:[:],in:nil,in:.page) { result in
            var report:[String:Any]=["build":buildID,"modelUsed":false,"workerStarted":self.worker != nil]
            switch result {
            case .success(let value):report["result"]=value
            case .failure(let error):report["error"]=error.localizedDescription
            }
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:projectRoot.appendingPathComponent("tests/motion-results.json"),options:.atomic) }
            self.finishUITests()
        }
    }
    func runUITests() {
        web.evaluateJavaScript("runUITests()") { value,error in
            let report:[String:Any]=["build":buildID,"result":value ?? NSNull(),"native":self.runNativeTests(),"error":error?.localizedDescription ?? "","windowWidth":self.window.frame.width,"windowHeight":self.window.frame.height,"microphoneAuthorization":AVCaptureDevice.authorizationStatus(for:.audio).rawValue]
            self.writeTestReport(report)
            guard error == nil else { self.finishUITests();return }
            self.web.callAsyncJavaScript("return await runInteractionTests()",arguments:[:],in:nil,in:.page) { result in
                var interactions:[String:Any]=["build":buildID,"modelUsed":false,"workerStarted":self.worker != nil]
                switch result {
                case .success(let value):interactions["result"]=value
                case .failure(let error):interactions["error"]=error.localizedDescription
                }
                if let data=try? JSONSerialization.data(withJSONObject:interactions,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:projectRoot.appendingPathComponent("tests/interaction-results.json"),options:.atomic) }
                self.runHiddenTests()
            }
        }
    }
    func runHiddenTests() {
            NSLog("non-model test: preparing hidden window")
            self.setPlayActivity(true)
            self.window.miniaturize(nil)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                NSLog("non-model test: calling actual timed tests")
                self.web.callAsyncJavaScript("return await runTimedTests()",arguments:[:],in:nil,in:.page) { result in
                    NSLog("non-model test: timed tests completed")
                    var timed:[String:Any]=["build":buildID,"modelUsed":false]
                    switch result {
                    case .success(let value):timed["result"]=value;timed["error"]=""
                    case .failure(let error):timed["error"]=error.localizedDescription
                    }
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                        timed["nativeChecks"]=[
                            ["name":"原生测试窗口已隐藏","passed":!self.window.isVisible || self.window.isMiniaturized],
                            ["name":"计时验收未启动识别子进程","passed":self.worker == nil],
                            ["name":"计时验收暂停后释放活动令牌","passed":self.playActivity == nil]]
                        if let data=try? JSONSerialization.data(withJSONObject:timed,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:projectRoot.appendingPathComponent("tests/timed-results.json"),options:.atomic) }
                        self.window.deminiaturize(nil)
                        self.finishUITests()
                    }
                }
            }
    }
    func finishUITests() {
        testsDone=true
        NSApp.terminate(nil)
    }
    func writeTestReport(_ report:[String:Any]) {
        if let d=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? d.write(to:projectRoot.appendingPathComponent("tests/ui-results.json"),options:.atomic) }
    }
    func runNativeTests() -> [[String:Any]] {
        var results=[[String:Any]]()
        let savedSession=session,savedURL=currentURL,savedAutosaveError=lastAutosaveError
        nativeTestEvents=[]
        defer { session=savedSession;currentURL=savedURL;lastAutosaveError=savedAutosaveError;nativeTestEvents=nil }
        func check(_ name:String,_ value:Bool) { results.append(["name":name,"passed":value]) }
        let declaredTypes=Bundle.main.object(forInfoDictionaryKey:"UTExportedTypeDeclarations") as? [[String:Any]] ?? []
        let declaredPrompt=declaredTypes.first(where:{$0["UTTypeIdentifier"] as? String == promptType.identifier})
        let tags=declaredPrompt?["UTTypeTagSpecification"] as? [String:Any]
        check("提词文件类型声明为 JSON",(declaredPrompt?["UTTypeConformsTo"] as? [String])?.contains(UTType.json.identifier) == true && (tags?["public.filename-extension"] as? [String])?.contains("sgprompt") == true)
        results[results.count-1]["runtimeConformsToJSON"]=promptType.conforms(to:.json)
        results[results.count-1]["declaration"]=declaredPrompt ?? [:]
        setPlayActivity(true);check("提词活动令牌可取得",playActivity != nil)
        setPlayActivity(false);check("暂停活动令牌可释放",playActivity == nil)
        let text="中文导入（保留注释）\n😀第二行。"
        for (name,encoding) in [("UTF-8",String.Encoding.utf8),("UTF-16",.utf16),("GB18030",String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))))] {
            if let data=text.data(using:encoding), let message=try? decodeDocument(data,extension:"txt") { check(name+" 文稿导入",message["text"] as? String == text) }
            else { check(name+" 文稿导入",false) }
        }
        let original:[String:Any]=["version":1,"text":text,"offset":7,"settings":["font":60,"line":2.2,"mirror":true]]
        do {
            let data=try JSONSerialization.data(withJSONObject:original,options:[.sortedKeys])
            let path=projectRoot.appendingPathComponent("tests/保存往返.sgprompt")
            try data.write(to:path,options:.atomic)
            let decoded=try decodeDocument(Data(contentsOf:path),extension:"sgprompt")
            let restored=decoded["session"] as? [String:Any]
            check("提词文稿磁盘保存与往返",restored?["text"] as? String == text && restored?["offset"] as? Int == 7)
            let json=try decodeDocument(data,extension:"json")
            check("JSON 保存文稿能重新导入",(json["session"] as? [String:Any])?["text"] as? String == text)
        } catch { check("提词文稿磁盘保存与往返",false) }
        do { _=try decodeDocument(Data("{\"settings\":{}}".utf8),extension:"sgprompt");check("无文字的损坏文稿被拒绝",false) }
        catch { check("无文字的损坏文稿被拒绝",true) }
        do {
            let folder=projectRoot.appendingPathComponent("tests/恢复模拟")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let oldFile=folder.appendingPathComponent("已有文稿.txt"),blocker=folder.appendingPathComponent("不是目录")
            try Data("已保存旧文稿".utf8).write(to:oldFile,options:.atomic)
            try Data("阻止作为父目录".utf8).write(to:blocker,options:.atomic)
            currentURL=oldFile
            session=["text":"编辑后尚未保存的中文文稿","offset":4,"settings":["font":52],"editorOpen":true,"editorDraft":"未应用的中文草稿"]
            let invalid=blocker.appendingPathComponent("失败.sgprompt")
            let failed=writeScript(invalid)
            let oldText=String(data:try Data(contentsOf:oldFile),encoding:.utf8)
            check("保存失败不丢稿且不更改原保存路径",!failed && session["text"] as? String == "编辑后尚未保存的中文文稿" && currentURL == oldFile && oldText == "已保存旧文稿")
            check("保存失败有明确提示",nativeTestEvents?.contains(where:{$0["type"] as? String == "error" && ($0["message"] as? String ?? "").contains("文稿仍保留")}) == true)
            check("自动保存失败可检测且不清空会话",!persist(to:invalid) && session["editorDraft"] as? String == "未应用的中文草稿")
            let restore=folder.appendingPathComponent("session.json")
            check("退出前写入恢复会话",persist(to:restore))
            let reloaded=try JSONSerialization.jsonObject(with:Data(contentsOf:restore)) as? [String:Any]
            check("磁盘重开保留正文、位置与编辑草稿",reloaded?["text"] as? String == session["text"] as? String && reloaded?["offset"] as? Int == 4 && reloaded?["editorDraft"] as? String == "未应用的中文草稿" && reloaded?["editorOpen"] as? Bool == true)
        } catch { check("保存失败与恢复会话检查",false) }
        pin();check("原生窗口置顶",window.level == .floating);pin();check("取消窗口置顶",window.level == .normal)
        check("全屏快捷键与窗口能力",window.styleMask.contains(.resizable) && NSApp.mainMenu?.items.contains(where:{$0.submenu?.items.contains(where:{$0.action == #selector(fullscreen) && $0.keyEquivalent == "f"}) == true}) == true)
        let selectors=[#selector(openScript),#selector(saveScript),#selector(saveAs),#selector(edit),#selector(toggle),#selector(mirror),#selector(fullscreen),#selector(pin)]
        let menuActions=NSApp.mainMenu?.items.flatMap({$0.submenu?.items ?? []}).compactMap({$0.action}) ?? []
        check("打开编辑保存镜像全屏置顶暂停菜单均已连接",selectors.allSatisfy({menuActions.contains($0)}))
        return results
    }
    func runReopenTest(_ stage:String) {
        let script="第一句：退出后重开应恢复正文。（保留注释）\n第二句：继续在原位置提词。"
        let draft="尚未应用的中文编辑草稿。（保留注释）\n第二行草稿。"
        if stage == "write" {
            let command="receive({type:'document',text:\(jsonString(script)),filename:'退出重开测试'});setMode('fixed');setting('font',52);setting('line',1.8);seek(7,false);editScript();$('editText').value=\(jsonString(draft));getSession()"
            web.evaluateJavaScript(command) { value,error in
                self.testsDone=true
                if let s=value as? [String:Any] { self.session=s }
                NSApp.terminate(nil)
            }
        } else {
            web.evaluateJavaScript("getSession()") { value,error in
                self.testsDone=true
                let s=value as? [String:Any] ?? [:],settings=s["settings"] as? [String:Any] ?? [:]
                let checks:[[String:Any]]=[
                    ["name":"真实退出重开恢复正文","passed":s["text"] as? String == script],
                    ["name":"真实退出重开恢复位置","passed":s["offset"] as? Int == 7],
                    ["name":"真实退出重开恢复模式与字号行距","passed":s["mode"] as? String == "fixed" && settings["font"] as? Int == 52 && settings["line"] as? Double == 1.8],
                    ["name":"真实退出重开保留未应用编辑草稿","passed":s["editorOpen"] as? Bool == true && s["editorDraft"] as? String == draft]]
                let report:[String:Any]=["build":buildID,"error":error?.localizedDescription ?? "","checks":checks,"statePath":stateDir.path,"modelUsed":false]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:projectRoot.appendingPathComponent("tests/reopen-results.json"),options:.atomic) }
                NSApp.terminate(nil)
            }
        }
    }
    func jsonString(_ value:String) -> String {
        let data=try! JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed)
        return String(data:data,encoding:.utf8)!
    }
}
let app=NSApplication.shared
let delegate=AppDelegate()
app.delegate=delegate
app.setActivationPolicy(.regular)
app.run()

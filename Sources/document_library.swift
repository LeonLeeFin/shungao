import Foundation

func libraryError(_ message:String)->NSError { NSError(domain:"ShunGaoLibrary",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
final class DocumentLibrary {
    let url:URL
    private(set) var state:[String:Any]
    var forcedWriteFailure=false // Only used by the isolated native regression.
    let globalKeys=["settings","mode","model","device","deviceName","deviceUID"]
    static func date()->String { let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:Date()) }
    static func title(_ text:String)->String {
        let line=text.components(separatedBy:.newlines).first(where:{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) ?? ""
        let clean=line.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"^#{1,6}\\s*",with:"",options:.regularExpression)
        let sentence=clean.components(separatedBy:CharacterSet(charactersIn:"。！？!?"))[0]
        let trimmed=sentence.trimmingCharacters(in:.whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名文稿" : String(trimmed.prefix(30))+(trimmed.count>30 ? "…" : "")
    }
    static func document(_ session:[String:Any],title:String?=nil)->[String:Any] {
        let text=session["text"] as? String ?? "",now=date()
        return ["id":UUID().uuidString,"title":title ?? self.title(text),"automaticTitle":title == nil,"text":text,"offset":session["offset"] as? Int ?? 0,"editorOpen":session["editorOpen"] as? Bool ?? false,"editorDraft":session["editorDraft"] as? String ?? "","createdAt":now,"modifiedAt":now]
    }
    init(url:URL,legacy:[String:Any],legacyURL:URL?=nil) throws {
        self.url=url
        if FileManager.default.fileExists(atPath:url.path) {
            guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],let rows=value["documents"] as? [[String:Any]],!rows.isEmpty,let active=value["activeID"] as? String,rows.contains(where:{$0["id"] as? String == active}),Set(rows.compactMap{$0["id"] as? String}).count==rows.count,rows.allSatisfy({$0["text"] is String && $0["title"] is String}) else { throw libraryError("文稿库格式异常，已保留原文件；请从备份恢复") }
            let deleted=value["trash"] as? [[String:Any]] ?? []
            guard (value["trash"] == nil || value["trash"] is [[String:Any]]),deleted.allSatisfy({$0["id"] is String && $0["text"] is String && $0["title"] is String}),Set((rows+deleted).compactMap{$0["id"] as? String}).count==rows.count+deleted.count else { throw libraryError("回收站格式异常，已保留文稿库原文件") }
            state=value
        } else {
            if let legacyURL=legacyURL,FileManager.default.fileExists(atPath:legacyURL.path) {
                let backup=url.deletingLastPathComponent().appendingPathComponent("session-before-library-migration.json")
                if !FileManager.default.fileExists(atPath:backup.path) { try FileManager.default.copyItem(at:legacyURL,to:backup) }
            }
            let document=Self.document(legacy),globals=legacy.filter { ["settings","mode","model","device","deviceName","deviceUID"].contains($0.key) }
            state=["version":1,"activeID":document["id"]!,"documents":[document],"globals":globals]
            try commit(state)
        }
    }
    var documents:[[String:Any]] { state["documents"] as? [[String:Any]] ?? [] }
    var activeID:String { state["activeID"] as? String ?? "" }
    func activeSession()->[String:Any] {
        var value=state["globals"] as? [String:Any] ?? [:]
        guard let document=documents.first(where:{$0["id"] as? String == activeID}) else { return value }
        for key in ["text","offset","editorOpen","editorDraft"] { value[key]=document[key] }
        value["version"]=2;value["documentID"]=activeID;value["documentTitle"]=document["title"];value["filename"]=document["title"];value["createdAt"]=document["createdAt"];value["modifiedAt"]=document["modifiedAt"]
        return value
    }
    func metadata()->[String:Any] { ["type":"libraryState","activeID":activeID,"timeZone":TimeZone.current.identifier,"documents":documents.map { row in row.filter { ["id","title","createdAt","modifiedAt"].contains($0.key) } },"trash":trash.map { row in row.filter { ["id","title","deletedAt"].contains($0.key) } }] }
    func commit(_ next:[String:Any]) throws {
        if forcedWriteFailure { throw libraryError("隔离回归模拟磁盘写入失败") }
        let data=try JSONSerialization.data(withJSONObject:next,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:url,options:.atomic)
        state=next // The in-memory active document changes only after disk success.
    }
    func save(_ session:[String:Any]) throws {
        if let id=session["documentID"] as? String,!id.isEmpty,id != activeID { throw libraryError("旧篇保存指令已过期，当前文稿未被覆盖") }
        var next=state,rows=documents
        guard let index=rows.firstIndex(where:{$0["id"] as? String == activeID}) else { throw libraryError("当前文稿不存在，已保留窗口内容") }
        var row=rows[index]
        let text=session["text"] as? String ?? row["text"] as? String ?? "",draft=session["editorDraft"] as? String ?? "",editor=session["editorOpen"] as? Bool ?? false
        let edited=text != row["text"] as? String || draft != row["editorDraft"] as? String
        row["text"]=text;row["offset"]=min(text.utf16.count,max(0,session["offset"] as? Int ?? 0));row["editorDraft"]=draft;row["editorOpen"]=editor
        if row["automaticTitle"] as? Bool == true { row["title"]=Self.title(text) }
        if edited { row["modifiedAt"]=Self.date() }
        rows[index]=row;next["documents"]=rows
        var globals=next["globals"] as? [String:Any] ?? [:];for key in globalKeys { if let value=session[key] { globals[key]=value } };next["globals"]=globals
        try commit(next)
    }
    func create(_ session:[String:Any]=[:],title:String?=nil) throws {
        let document=Self.document(session,title:title);var next=state,rows=documents;rows.append(document);next["documents"]=rows;next["activeID"]=document["id"];try commit(next)
    }
    func document(_ id:String) throws -> [String:Any] {
        guard let row=documents.first(where:{$0["id"] as? String == id}) else { throw libraryError("目标文稿不存在，当前篇已保留") }
        return row
    }
    var trash:[[String:Any]] { state["trash"] as? [[String:Any]] ?? [] }
    func duplicate(_ id:String) throws {
        var row=try document(id),next=state,rows=documents
        row["id"]=UUID().uuidString;row["title"]=(row["title"] as? String ?? "文稿")+" 副本";row["automaticTitle"]=false
        row["createdAt"]=Self.date();row["modifiedAt"]=row["createdAt"]
        rows.append(row);next["documents"]=rows;next["activeID"]=row["id"];try commit(next)
    }
    func moveToTrash(_ id:String) throws {
        var row=try document(id),next=state,rows=documents.filter{$0["id"] as? String != id},deleted=trash
        row["deletedAt"]=Self.date();deleted.append(row)
        if rows.isEmpty { rows.append(Self.document([:])) }
        next["documents"]=rows;next["trash"]=deleted
        if activeID==id { next["activeID"]=rows[0]["id"] }
        try commit(next)
    }
    func restoreFromTrash(_ id:String) throws {
        guard var row=trash.first(where:{$0["id"] as? String == id}) else { throw libraryError("回收站中未找到这篇文稿") }
        guard !documents.contains(where:{$0["id"] as? String == id}) else { throw libraryError("相同文稿已在列表中，回收站原稿已保留") }
        row.removeValue(forKey:"deletedAt");var next=state,rows=documents;rows.append(row)
        next["documents"]=rows;next["trash"]=trash.filter{$0["id"] as? String != id};next["activeID"]=id;try commit(next)
    }
    func select(_ id:String) throws {
        guard documents.contains(where:{$0["id"] as? String == id}) else { throw libraryError("目标文稿已不存在，当前文稿未被切走") }
        var next=state;next["activeID"]=id;try commit(next)
    }
    func rename(_ id:String,_ name:String) throws {
        let title=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { throw libraryError("文稿名称不能为空") }
        var next=state,rows=documents
        guard let index=rows.firstIndex(where:{$0["id"] as? String == id}) else { throw libraryError("目标文稿不存在") }
        rows[index]["title"]=String(title.prefix(120));rows[index]["automaticTitle"]=false;rows[index]["modifiedAt"]=Self.date();next["documents"]=rows;try commit(next)
    }
}

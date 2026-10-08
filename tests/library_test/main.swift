import Foundation
let root=FileManager.default.temporaryDirectory.appendingPathComponent("shungao-library-test-"+UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let url=root.appendingPathComponent("library.json")
if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
let legacy:[String:Any]=["text":"第一篇金融文稿。\n正文必须保留。","offset":5,"model":"qwen","deviceUID":"test-stable-device","settings":["font":74,"line":1.75]]
var results=[[String:Any]]()
func check(_ name:String,_ passed:Bool){results.append(["name":name,"passed":passed]);if !passed {print("FAIL: \(name)")}}
let library=try DocumentLibrary(url:url,legacy:legacy)
let first=library.activeID
check("迁移为独立第一篇，正文位置完整",library.documents.count==1&&library.activeSession()["text"] as? String == legacy["text"] as? String&&library.activeSession()["offset"] as? Int == 5)
try library.create(["text":"第二篇利率主题。","offset":3]);let second=library.activeID
check("新建ID独立，旧篇正文不覆盖",first != second&&library.documents.count==2&&library.documents[0]["text"] as? String == legacy["text"] as? String)
try library.rename(second,"可修改名称")
try library.select(first)
check("每篇位置恢复、模型设备全局",library.activeSession()["offset"] as? Int == 5&&library.activeSession()["model"] as? String == "qwen"&&library.activeSession()["deviceUID"] as? String == "test-stable-device")
var edited=library.activeSession();edited["text"]="编辑后的第一篇。";edited["editorOpen"]=true;edited["editorDraft"]="未应用的编辑草稿";try library.save(edited);try library.select(second)
let reopened=try DocumentLibrary(url:url,legacy:[:])
check("重启最近篇、名称与元数据保留",reopened.activeID==second&&reopened.activeSession()["documentTitle"] as? String == "可修改名称"&&reopened.documents.allSatisfy{$0["createdAt"] is String&&$0["modifiedAt"] is String})
try reopened.select(first)
check("重启保留每篇未应用草稿",reopened.activeSession()["editorDraft"] as? String == "未应用的编辑草稿")
let backup=root.appendingPathComponent("library-test-original.json")
if FileManager.default.fileExists(atPath:backup.path){try FileManager.default.removeItem(at:backup)}
try FileManager.default.moveItem(at:url,to:backup);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
var rejected=false;do {try reopened.select(second)}catch{rejected=true}
check("真实文件写入失败不更改活跃篇",rejected&&reopened.activeID==first)
try FileManager.default.removeItem(at:url);try FileManager.default.moveItem(at:backup,to:url)

let duplicateSource=try reopened.document(first),sourceText=duplicateSource["text"] as? String
try reopened.duplicate(first);let copyID=reopened.activeID
check("复制文稿独立ID与正文草稿完整",copyID != first && reopened.activeSession()["text"] as? String==sourceText && reopened.activeSession()["editorDraft"] as? String==duplicateSource["editorDraft"] as? String)
try reopened.moveToTrash(first)
check("删除非当前篇保留当前，原稿进回收站",reopened.activeID==copyID && !reopened.documents.contains{$0["id"] as? String==first} && reopened.trash.contains{$0["id"] as? String==first})
try reopened.restoreFromTrash(first)
check("恢复原UUID正文草稿与日期",reopened.activeID==first && reopened.activeSession()["text"] as? String==sourceText && reopened.activeSession()["editorDraft"] as? String==duplicateSource["editorDraft"] as? String && reopened.documents.first{$0["id"] as? String==first}?["createdAt"] as? String==duplicateSource["createdAt"] as? String)
try reopened.moveToTrash(first)
check("删除当前篇先安全选择另一篇",reopened.activeID != first && reopened.documents.contains{$0["id"] as? String==reopened.activeID})
let activeBeforeFailure=reopened.activeID,trashBeforeFailure=reopened.trash.count,bodyBeforeFailure=reopened.activeSession()["text"] as? String
reopened.forcedWriteFailure=true
var trashRejected=false;do {try reopened.moveToTrash(activeBeforeFailure)}catch{trashRejected=true}
check("删除写入失败保留当前正文与回收站",trashRejected && reopened.activeID==activeBeforeFailure && reopened.activeSession()["text"] as? String==bodyBeforeFailure && reopened.trash.count==trashBeforeFailure)
var restoreRejected=false;do {try reopened.restoreFromTrash(first)}catch{restoreRejected=true}
check("恢复写入失败不丢回收站文稿",restoreRejected && reopened.activeID==activeBeforeFailure && reopened.trash.contains{$0["id"] as? String==first})
var copyRejected=false;do {try reopened.duplicate(activeBeforeFailure)}catch{copyRejected=true}
check("复制写入失败不切走当前篇",copyRejected && reopened.activeID==activeBeforeFailure)
reopened.forcedWriteFailure=false
let allIDs=reopened.documents.compactMap{$0["id"] as? String}
for id in allIDs {try reopened.moveToTrash(id)}
check("最后一篇删除留下新空白且旧稿均可恢复",reopened.documents.count==1 && reopened.activeSession()["text"] as? String=="" && allIDs.allSatisfy{id in reopened.trash.contains{$0["id"] as? String==id}})
let undoID=reopened.trash.last!["id"] as! String;try reopened.restoreFromTrash(undoID)
check("撤销最近删除恢复完整原篇",reopened.activeID==undoID && !reopened.trash.contains{$0["id"] as? String==undoID})
let again=try DocumentLibrary(url:url,legacy:[:])
check("重开保留独立复制与回收站",again.activeID==undoID && again.trash.count==reopened.trash.count && again.documents.count==reopened.documents.count)
let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]);try data.write(to:root.appendingPathComponent("results.json"),options:.atomic)
let passedCount=results.filter{$0["passed"] as? Bool == true}.count
print("Native library checks: \(passedCount)/\(results.count)")

if passedCount != results.count { exit(1) }

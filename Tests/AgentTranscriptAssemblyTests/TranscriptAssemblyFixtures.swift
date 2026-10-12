import Foundation
import AgentRuntimeKit
import AgentTranscriptAssembly

func row(_ index:Int,kind:AgentChatItemKind = .assistant,text:String="answer",name:String?=nil,invocation:UUID?=nil,date:TimeInterval?=nil,result:String?=nil)->AgentChatItem {
    .init(id:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",index+100))!,timestamp:Date(timeIntervalSince1970:date ?? Double(index)),kind:kind,text:text,toolName:name,toolInvocationID:invocation,toolResultJSON:result,sequenceIndex:index)
}
func assembly(makeProcessor:(()->AgentTranscriptToolProcessor)?=nil, frozen:@escaping(AgentTranscriptTurn,[AgentTranscriptTurn])->Int?={_,_ in nil})->AgentTranscriptAssemblyService {
    .init(services:.init(makeToolProcessor:makeProcessor ?? {
        .init(execution:{item in
            guard item.kind == .toolCall || item.kind == .toolResult else{return nil}
            return .init(stableExecutionID:item.toolInvocationID?.uuidString ?? item.id.uuidString,toolName:item.toolName,invocationID:item.toolInvocationID,argsJSON:item.toolArgsJSON,resultJSON:item.toolResultJSON,toolIsError:item.toolIsError,status:item.kind == .toolCall ? .pending : .success)
        },normalizedName:{$0?.lowercased()},sealsBoundary:{item,_ in item.toolName == "seal"})
    },summarizeTurn:{_ in nil},summarizeSpan:{_,_ in nil},frozenTailLimit:frozen))
}
func fullRows(_ turn:AgentTranscriptTurn)->[AgentChatItem] {
    (turn.request.map{[$0.toItem()]} ?? [])+turn.allActivities.map{$0.toItem()}
}

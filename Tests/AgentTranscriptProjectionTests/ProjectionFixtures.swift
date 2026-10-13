import Foundation
import AgentRuntimeKit
import AgentTranscriptProjection
import AgentTranscriptAssembly

func projectionPorts()->AgentTranscriptProjectionServices {
    .init(makeToolProcessor:{ {item in
        guard item.kind == .toolCall || item.kind == .toolResult else{return nil}
        return .init(stableExecutionID:item.toolInvocationID?.uuidString ?? item.id.uuidString,toolName:item.toolName,invocationID:item.toolInvocationID,argsJSON:item.toolArgsJSON,resultJSON:item.toolResultJSON,toolIsError:item.toolIsError,status:item.kind == .toolCall ? .pending : .success,keyPaths:["file.swift"])
    } },normalizedToolName:{$0?.lowercased()},suppressActivity:{$0.toolExecution?.toolName == "hidden"},buildToolGroups:{names,counts in names.map{.init(icon:"tool",label:"\($0):\(counts[$0] ?? 0)")}},sanitizeGroupedSummary:{$0},groupedDisplay:{_ in nil},clusterDisplay:{_,_ in nil},sectionTitleAndIcon:{_,_ in ("section","tool")},clock:{0},diagnosticsEnabled:{false},log:{_ in},observeBuild:{_ in})
}
func projectionService()->AgentTranscriptProjectionService {.init(services:projectionPorts())}
func projectionRow(_ index:Int,kind:AgentChatItemKind = .assistant,text:String="answer",name:String?=nil,invocation:UUID?=nil)->AgentChatItem {
    .init(id:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",index+100))!,timestamp:Date(timeIntervalSince1970:Double(index)),kind:kind,text:text,toolName:name,toolInvocationID:invocation,sequenceIndex:index)
}
func projectionTurn(_ ordinal:Int=0,tools:Int=0,tier:AgentTranscriptRetentionTier = .full,completed:Bool=true,name:String="read",narration:Bool=false)->AgentTranscriptTurn {
    let base=ordinal*1000,request=projectionRow(base,kind:.user,text:"request \(ordinal)");var activities:[AgentTranscriptActivity]=[]
    for i in 0..<tools {
        let invocation=UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",base+i+500))!
        let call=projectionRow(base+i*3+1,kind:.toolCall,name:name,invocation:invocation),result=projectionRow(base+i*3+2,kind:.toolResult,text:"result",name:name,invocation:invocation)
        for item in [call,result] {
            let e=AgentTranscriptToolExecution(stableExecutionID:invocation.uuidString,toolName:name,invocationID:invocation,argsJSON:"args",resultJSON:item.kind == .toolResult ? "result":nil,toolIsError:false,status:item.kind == .toolCall ? .pending:.success,keyPaths:["file.swift"])
            activities.append(.init(from:item,toolExecution:e))
        }
        if narration {activities.append(.init(from:projectionRow(base+i*3+3,text:"narration \(i)")))}
    }
    let answer=projectionRow(base+tools*3+5,text:"final answer");activities.append(.init(from:answer))
    let summary=AgentTranscriptTurnSummary(middleSummaryItemID:AgentTranscriptIdentity.summaryID(for:request.id),requestText:request.text,conclusionText:answer.text,compactConclusionText:"compact answer",middleSummaryText:"summary",toolCount:tools,notableToolNames:[name],keyPaths:["file.swift"],compactedActivityCount:activities.count,hadWarning:false,hadError:false)
    return .init(id:request.id,request:.init(from:request),responseSpans:[.init(id:AgentTranscriptIdentity.spanID(turnID:request.id,ordinal:0),lifecycle:completed ? .completed:.open,startedAt:request.timestamp,activities:activities)],conclusionActivityID:answer.id,retentionTier:tier,summary:summary,terminalState:completed ? nil:.running,startedAt:request.timestamp,completedAt:completed ? answer.timestamp:nil)
}

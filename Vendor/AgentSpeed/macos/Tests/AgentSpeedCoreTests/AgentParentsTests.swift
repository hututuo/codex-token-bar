import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Agent parents")
struct AgentParentsTests {
    static func codex(_ id: String, thread: String?, parent: String?, created: Int64 = 0) -> AgentParents.Member {
        AgentParents.Member(id: id, family: .codex, thread: SessionThread(id: thread, parentId: parent, createdMs: created))
    }

    static func dsh(_ id: String, session: String?, parent: String?, created: Int64 = 0) -> AgentParents.Member {
        AgentParents.Member(id: id, family: .dsh, thread: SessionThread(id: session, parentId: parent, createdMs: created))
    }

    @Test func claudeSubagentsBelongToTheirSessionFile() {
        let parents = AgentParents.resolve([
            AgentParents.Member(id: "/p/-w-nova/s1.jsonl", family: .claude),
            AgentParents.Member(id: "/p/-w-nova/s1/subagents/agent-a.jsonl", family: .claude),
            AgentParents.Member(id: "/p/-w-nova/s2/subagents/agent-b.jsonl", family: .claude),
            AgentParents.Member(id: "/p/-w-nova/s1/other/agent-c.jsonl", family: .claude),
        ])
        #expect(parents == ["/p/-w-nova/s1/subagents/agent-a.jsonl": "/p/-w-nova/s1.jsonl"])
        #expect(AgentParents.claudeParentPath(of: "/subagents/agent.jsonl") == nil)
        #expect(AgentParents.claudeParentPath(of: "subagents/agent.jsonl") == nil)
        #expect(AgentParents.claudeParentPath(of: "/a//subagents/agent.jsonl") == nil)
    }

    @Test func codexParentIsTheEarliestFileOfTheThread() {
        let parents = AgentParents.resolve([
            Self.codex("/s/late.jsonl", thread: "main", parent: nil, created: 20),
            Self.codex("/s/b-early.jsonl", thread: "main", parent: nil, created: 10),
            Self.codex("/s/a-early.jsonl", thread: "main", parent: nil, created: 10),
            Self.codex("/s/worker.jsonl", thread: "worker", parent: "main", created: 30),
            Self.codex("/s/lost.jsonl", thread: "lost", parent: "missing", created: 30),
        ])
        #expect(parents == ["/s/worker.jsonl": "/s/a-early.jsonl"])
    }

    @Test func deepseekParentIsTheEarliestFileOfTheSession() {
        let parents = AgentParents.resolve([
            Self.dsh("/d/main-copy/session.v4.jsonl.zstd", session: "main", parent: nil, created: 50),
            Self.dsh("/d/main/session.v4.jsonl.zstd", session: "main", parent: nil, created: 10),
            Self.dsh("/d/sub/session.v4.jsonl.zstd", session: "sub", parent: "main", created: 60),
            Self.dsh("/d/self/session.v4.jsonl.zstd", session: "self", parent: "self", created: 60),
            Self.codex("/s/main.jsonl", thread: "main", parent: nil, created: 1),
            Self.codex("/s/worker.jsonl", thread: "worker", parent: "sub", created: 70),
        ])
        #expect(parents == ["/d/sub/session.v4.jsonl.zstd": "/d/main/session.v4.jsonl.zstd"])
    }

    @Test func selfReferencesAndCyclesHaveNoParent() {
        let parents = AgentParents.resolve([
            Self.codex("/s/self.jsonl", thread: "self", parent: "self"),
            Self.codex("/s/a.jsonl", thread: "a", parent: "b"),
            Self.codex("/s/b.jsonl", thread: "b", parent: "a"),
            Self.codex("/s/c.jsonl", thread: "c", parent: "b"),
        ])
        #expect(parents["/s/self.jsonl"] == nil)
        #expect(parents["/s/a.jsonl"] == nil)
        #expect(parents["/s/b.jsonl"] == "/s/a.jsonl")
        #expect(parents["/s/c.jsonl"] == "/s/b.jsonl")
    }

    @Test func codexSessionMetaNamesTheParentThread() {
        func meta(_ payload: String) -> CodexSessionMeta? {
            var line = #"{"timestamp":"2026-10-20T10:00:00Z","type":"session_meta","payload":\#(payload)}"#
            return line.withUTF8 { buffer in
                guard case .line(let decoded) = CodexLineExtractor.extract(UnsafeRawBufferPointer(buffer)),
                      case .sessionMeta(let meta) = decoded.kind else { return nil }
                return meta
            }
        }
        let spawn = #"{"subagent":{"thread_spawn":{"parent_thread_id":"spawner","depth":1}}}"#
        #expect(meta(#"{"id":"t","parent_thread_id":"direct","source":\#(spawn)}"#)?.parentThreadId == "direct")
        #expect(meta(#"{"id":"t","parent_thread_id":"","source":\#(spawn)}"#)?.parentThreadId == "spawner")
        #expect(meta(#"{"id":"t","source":\#(spawn)}"#)?.isSubagent == true)
        #expect(meta(#"{"id":"t","source":{"subagent":"review"}}"#)?.parentThreadId == nil)
        #expect(meta(#"{"id":"t","source":{"subagent":{"thread_spawn":7}}}"#)?.parentThreadId == nil)
        #expect(meta(#"{"id":"t","forked_from_id":"main","source":"cli"}"#)?.parentThreadId == nil)
    }
}

import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Codex JSON-RPC 與 JSONL")
struct CodexJSONRPCTests {
    @Test("請求不帶 jsonrpc 欄位，且 method 只能來自白名單 enum")
    func outboundRequestShape() throws {
        let data = try CodexJSONRPC.request(
            .initialize,
            id: 7,
            params: ["clientInfo": ["name": "agent_usage_bar"]]
        )
        let line = String(decoding: data, as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["method"] as? String == "initialize")
        #expect((object["id"] as? NSNumber)?.intValue == 7)
        #expect(object["jsonrpc"] == nil)

        let read = try CodexJSONRPC.request(.rateLimitsRead, id: 8)
        let readObject = try #require(
            JSONSerialization.jsonObject(with: read) as? [String: Any]
        )
        #expect(readObject["method"] as? String == "account/rateLimits/read")

        let usage = try CodexJSONRPC.request(.accountUsageRead, id: 9)
        let usageObject = try #require(
            JSONSerialization.jsonObject(with: usage) as? [String: Any]
        )
        #expect(usageObject["method"] as? String == "account/usage/read")
        #expect(usageObject["params"] == nil)
    }

    @Test("initialized 是沒有 id 的 notification")
    func initializedNotification() throws {
        let data = try CodexJSONRPC.notification(.initialized)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["method"] as? String == "initialized")
        #expect(object["id"] == nil)
        #expect(object["params"] is [String: Any])
    }

    @Test("response 依 request id 配對，notification 不會冒充 response")
    func inboundRouting() {
        let result = CodexJSONRPCParser.parse(
            Data(#"{"id":42,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}"#.utf8)
        )
        guard case .result(let id, let payload) = result else {
            Issue.record("預期 result，實得 \(result)")
            return
        }
        #expect(id == 42)
        #expect((try? JSONSerialization.jsonObject(with: payload)) != nil)

        let notification = CodexJSONRPCParser.parse(
            Data(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":31}}}}"#.utf8)
        )
        guard case .notification(let method, _) = notification else {
            Issue.record("預期 notification")
            return
        }
        #expect(method == "account/rateLimits/updated")
    }

    @Test("JSON-RPC error 保留 code 與訊息，不保留任意 data")
    func errorEnvelope() {
        let inbound = CodexJSONRPCParser.parse(
            Data(#"{"id":3,"error":{"code":-32601,"message":"Method not found","data":{"secret":"not retained"}}}"#.utf8)
        )
        #expect(inbound == .failure(id: 3, code: -32601, message: "Method not found"))
    }

    @Test("request id 與 error code 不接受會被截斷的小數")
    func nonIntegralEnvelopeNumbersAreIgnored() {
        let fractionalID = CodexJSONRPCParser.parse(
            Data(#"{"id":42.5,"result":{}}"#.utf8)
        )
        let fractionalCode = CodexJSONRPCParser.parse(
            Data(#"{"id":3,"error":{"code":-32601.5,"message":"bad code"}}"#.utf8)
        )

        #expect(fractionalID == .ignored)
        #expect(fractionalCode == .ignored)
    }

    @Test("JSONL 支援拆包、黏包、CRLF，壞行只隔離自己")
    func framingAndBadLineIsolation() throws {
        var buffer = CodexJSONLBuffer()
        #expect(try buffer.append(Data(#"{"id":1,"res"#.utf8)).isEmpty)

        let lines = try buffer.append(Data("ult\":{}}\r\nnot-json\n{\"id\":2,\"result\":{}}\n".utf8))
        #expect(lines.count == 3)
        #expect(CodexJSONRPCParser.parse(lines[0]) == .result(id: 1, payload: Data("{}".utf8)))
        #expect(CodexJSONRPCParser.parse(lines[1]) == .ignored)
        #expect(CodexJSONRPCParser.parse(lines[2]) == .result(id: 2, payload: Data("{}".utf8)))
    }

    @Test("stdout ingress is one ordered consumer and bounds queued bytes before JSONL")
    func stdoutIngressIsOrderedAndBounded() throws {
        let ingress = CodexOutputIngress(maximumQueuedBytes: 4)

        let first = ingress.enqueue(Data("a".utf8))
        let second = ingress.enqueue(Data("b".utf8))
        let third = ingress.enqueue(Data("c".utf8))
        let fourth = ingress.enqueue(Data("d".utf8))

        #expect(first == .init(startConsumer: true, stopReading: false))
        #expect(second == .init(startConsumer: false, stopReading: false))
        #expect(third == .init(startConsumer: false, stopReading: false))
        #expect(fourth == .init(startConsumer: false, stopReading: false))

        // The fifth one-byte callback must fail before another Task or retained chunk
        // can be added. Previously every callback already owned its Data in a new Task.
        let overflow = ingress.enqueue(Data("e".utf8))
        #expect(overflow == .init(startConsumer: false, stopReading: true))
        #expect(ingress.next() == .overflow)
        #expect(ingress.next() == .closed)
    }

    @Test("many tiny stdout callbacks coalesce behind only one consumer")
    func tinyCallbacksDoNotCreatePerCallbackConsumers() {
        let callbackCount = 100_000
        let ingress = CodexOutputIngress(maximumQueuedBytes: callbackCount)
        var consumerStarts = 0

        for _ in 0..<callbackCount {
            if ingress.enqueue(Data([0x61])).startConsumer {
                consumerStarts += 1
            }
        }

        #expect(consumerStarts == 1)
        guard case .chunk(let combined) = ingress.next() else {
            Issue.record("Expected one coalesced bounded stdout chunk")
            return
        }
        #expect(combined.count == callbackCount)
        #expect(ingress.next() == .empty)
    }

    @Test("stdout ingress preserves fragmented JSONL order and can schedule again")
    func stdoutIngressPreservesFragmentOrder() throws {
        let ingress = CodexOutputIngress(maximumQueuedBytes: 1024)
        #expect(ingress.enqueue(Data(#"{"id":1,"res"#.utf8)).startConsumer)
        #expect(!ingress.enqueue(Data("ult\":{}}\n".utf8)).startConsumer)

        var jsonl = CodexJSONLBuffer()
        guard case .chunk(let combined) = ingress.next() else {
            Issue.record("Expected the stdout fragments coalesced in FIFO order")
            return
        }
        let lines = try jsonl.append(combined)
        #expect(lines == [Data(#"{"id":1,"result":{}}"#.utf8)])
        #expect(ingress.next() == .empty)

        // Empty atomically releases ownership. A later callback starts one new
        // consumer instead of getting stranded without a wake-up.
        #expect(ingress.enqueue(Data("{}\n".utf8)).startConsumer)
    }

    @Test("closing stdout ingress discards queued data from the old generation")
    func closingIngressDiscardsQueuedData() {
        let ingress = CodexOutputIngress(maximumQueuedBytes: 1024)
        #expect(ingress.enqueue(Data("stale-result\n".utf8)).startConsumer)
        ingress.close()
        #expect(ingress.next() == .closed)
        #expect(ingress.enqueue(Data("late-callback\n".utf8)).stopReading)
    }

    @Test("JSONL rejects more than four megabytes without a newline")
    func jsonlRejectsOversizedUnterminatedLine() {
        var buffer = CodexJSONLBuffer()
        let oversized = Data(repeating: 0x61, count: 4 * 1024 * 1024 + 1)
        #expect(throws: UsageError.self) {
            _ = try buffer.append(oversized)
        }
    }

    @Test("JSONL checks each line rather than the temporary combined read size")
    func jsonlAllowsLargeCompletedLineFollowedByMoreLines() throws {
        var buffer = CodexJSONLBuffer()
        let partialLine = Data(repeating: 0x61, count: 3_500_000)
        #expect(try buffer.append(partialLine).isEmpty)

        var nextRead = Data([0x0A])
        for _ in 0..<250_000 {
            nextRead.append(contentsOf: [0x7B, 0x7D, 0x0A]) // "{}\n"
        }
        let lines = try buffer.append(nextRead)
        #expect(lines.count == 250_001)
        #expect(lines.first?.count == partialLine.count)
        #expect(lines.last == Data("{}".utf8))
    }
}

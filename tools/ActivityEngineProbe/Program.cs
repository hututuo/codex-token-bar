using System.Text.Json;
using AgentSpeed.Core;
using AgentSpeed.Core.Engine;
using AgentSpeed.Core.Parsing;

// Deterministic/offline cross-platform contract probe: no monitor, IO sources, credentials or transport.
if (args.Length != 1) throw new ArgumentException("Provide the shared activity-model-attribution fixture.");
using var document = JsonDocument.Parse(File.ReadAllBytes(args[0]));
const long epoch = 1_800_000_000_000;
static SourceKind Source(JsonElement item) => item.GetProperty("source").GetString() switch {
    "codex" => SourceKind.Codex, "claudeCode" => SourceKind.ClaudeCode,
    _ => throw new InvalidDataException("Unknown fixture source"),
};
static string? Model(JsonElement item) => item.GetProperty("model").GetString();
static void Equal(double value, double expected, string label) {
    if (Math.Abs(value - expected) > 1e-8) throw new InvalidDataException($"{label}: {value} != {expected}");
}
var cases = 0;
foreach (var item in document.RootElement.EnumerateArray()) {
    var engine = new SpeedEngine(epoch);
    foreach (var response in item.GetProperty("responses").EnumerateArray()) {
        engine.Upsert(new ParsedResponse(response.GetProperty("id").GetString()!, Source(response),
            response.GetProperty("agent").GetString()!, Model(response), epoch + response.GetProperty("start").GetInt64(),
            epoch + response.GetProperty("end").GetInt64(),
            new TokenCounts(Input:response.GetProperty("input").GetInt64(), Output:response.GetProperty("output").GetInt64()),
            Final: !response.TryGetProperty("final", out var final) || final.GetBoolean()), isCompletion:true, seeded:true);
    }
    foreach (var agent in item.GetProperty("agents").EnumerateArray()) {
        engine.UpdateAgent(new AgentInfo(agent.GetProperty("id").GetString()!, Source(agent), "fixture", Model(agent), false,
            AgentPhase.Generating, epoch + agent.GetProperty("start").GetInt64(), epoch + agent.GetProperty("last").GetInt64()));
    }
    var frame = engine.Compute(epoch + item.GetProperty("now").GetInt64(), epoch, observeLive:false);
    var expected = item.GetProperty("expected").EnumerateArray().ToArray();
    if (frame.LiveModels.Count != expected.Length) throw new InvalidDataException("Model attribution count mismatch");
    foreach (var row in expected) {
        var actual = frame.LiveModels.Single(value => value.Source == Source(row) && value.Model == Model(row));
        Equal(actual.Rate.Output, row.GetProperty("output").GetDouble(), "output");
        Equal(actual.Rate.Total, row.GetProperty("total").GetDouble(), "total");
    }
    Equal(frame.LiveModels.Sum(value => value.Rate.Output), frame.Live.Output, "total output conservation");
    Equal(frame.LiveModels.Sum(value => value.Rate.Total), frame.Live.Total, "total token conservation");
    foreach (var source in frame.LiveModels.Select(value => value.Source).Distinct())
        Equal(frame.LiveModels.Where(value => value.Source == source).Sum(value => value.Rate.Output), frame.SourceLive[(int)source].Output, "source conservation");
    Console.WriteLine("PASS " + item.GetProperty("name").GetString()); cases++;
}
Console.WriteLine($"{cases} shared activity-engine contracts passed.");

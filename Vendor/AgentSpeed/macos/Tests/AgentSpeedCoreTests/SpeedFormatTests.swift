import Testing
@testable import AgentSpeedCore

@Test(arguments: [
    (0.0, "0"), (4.24, "4.2"), (9.96, "10"), (128.4, "128"), (999.6, "1.00k"),
    (1284, "1.28k"), (9999, "10.0k"), (12_840, "12.8k"), (128_400, "128k"), (999_700, "1.00M"), (1_284_000, "1.28M"),
    (12_840_000, "12.8M"), (128_400_000, "128M"), (999_400_000, "999M"), (999_700_000, "1.00B"),
    (2_491_000_000, "2.49B"), (12_840_000_000, "12.8B"), (99_960_000_000, "100B"), (128_400_000_000, "128B"),
    (999_600_000_000, "1000B"), (1_234_000_000_000, "1234B"),
])
func speedFormatting(value: Double, expected: String) {
    #expect(SpeedFormat.speed(value) == expected)
}

@Test(arguments: [
    (0, "0"), (999, "999"), (1000, "1.00k"), (384_000, "384k"), (1_200_000, "1.20M"), (999_999_999, "1.00B"),
    (2_491_000_000, "2.49B"), (9_532_000_000, "9.53B"),
])
func tokenFormatting(value: Int, expected: String) {
    #expect(SpeedFormat.tokens(value) == expected)
}

/// Visibility suspends playback without discarding the user's play/pause choice.
struct LeaderboardMoviePlayback {
    enum Intent { case automatic, play, pause }
    var visible = false
    var intent: Intent = .automatic

    func shouldPlay(reducedMotion: Bool, lowPower: Bool) -> Bool {
        guard visible else { return false }
        switch intent {
        case .automatic: return !reducedMotion && !lowPower
        case .play: return true
        case .pause: return false
        }
    }
}

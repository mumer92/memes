
import Foundation
import Events
import Model
import Deck

class Game {
    enum State {
        case initialized
        case collecting(Meme)
        case freestyle(Meme)
        case choosing(Meme)
        case done
        case stopped
    }

    let id = GameID()
    
    private var host: Player?
    private let rounds: Int
    private let deck: Deck
    private let gameEndCompletion: (Game) -> Void

    private var players: [Player]
    private var history: [Meme] = []

    private var judgeIndex: Int = 0
    private let lock = Lock()

    private var state: State = .initialized {
        didSet {
            switch (oldValue, state) {
            case (.initialized, .collecting(let meme)):
                send(event: .collecting(meme))

            case (.choosing(let prev), .collecting(let next)):
                send(event: .chosen(prev))
                send(event: .collecting(next))

            case (.collecting, .freestyle(let meme)):
                send(event: .freestyle(meme))

            case (.freestyle, .choosing(let meme)):
                send(event: .choosing(meme))

            case (.collecting, .choosing(let meme)):
                send(event: .choosing(meme))

            case (.choosing(let meme), .done):
                if meme.winningCard != nil {
                    send(event: .chosen(meme))
                }
                fallthrough

            case (_, .done):
                send(event: .end(players: players))

            case (.done, .initialized):
                send(event: .playAgain)

            case (_, .stopped):
                gameEndCompletion(self)

            default:
                fatalError("Invalid State Change")
            }
        }
    }

    var emojis: Set<String> {
        return Set(players.map { $0.emoji })
    }

    var hasStarted: Bool {
        if case .initialized = state {
            return false
        } else {
            return true
        }
    }

    var hasEnded: Bool {
        if case .done = state {
            return true
        } else {
            return false
        }
    }

    var isRunning: Bool {
        switch state {
        case .initialized, .done:
            return false
        default:
            return true
        }
    }

    var hasStopped: Bool {
        if case .stopped = state {
            return true
        } else {
            return false
        }
    }

    var hasPlayers: Bool {
        return !players.isEmpty
    }

    init(rounds: Int, deck: Deck = StandardDeck.main, gameEndCompletion: @escaping (Game) -> Void) {
        self.rounds = rounds
        self.deck = deck
        self.gameEndCompletion = gameEndCompletion
        self.players = []
    }

    func join(player: Player) {
        lock.withLock {
            guard case .initialized = state else {
                player.send(event: .error(.gameAlreadyStarted))
                player.stop()
                return
            }
            if host == nil {
                host = player
                player.isHost = true
            }
            send(event: .playerJoined(player: player))
            if !players.isEmpty {
                player.send(event: .currentPlayers(players: players))
            }
            players.append(player)
            player.send(event: .successfullyJoined(player: player))
        }
    }

    func getOut(player: Player) {
        lock.withLock {
            guard players.contains(where: { $0.id == player.id }) else { return }
            players.removeAll { $0.id == player.id }
            if players.isEmpty {
                stop()
                return
            }

            if isRunning, players.count < 3 {
                send(event: .error(.tooManyPlayersDroppedOut))
                stop()
                return
            }

            if player.isHost, let newHost = players.first {
                newHost.isHost = true
                host = newHost
                send(event: .newHost(player: newHost))
            }

            if hasStarted {
                judgeIndex = judgeIndex % players.count
                switch state {
                case .choosing(let meme), .collecting(let meme):
                    if meme.judge.id == player.id {
                        meme.judge = players[judgeIndex]
                        meme.proposedLines.removeAll { $0.player.id == meme.judge.id }
                        send(event: .judgeChange(player: meme.judge))
                    }
                default:
                    break
                }
            }

            send(event: .playerLeft(player: player))
        }
    }

    func handle(event: ClientEvent, from player: Player) {
        lock.withLock {
            switch (state, event) {
            case (.initialized, .start):
                start(as: player)

            case (.collecting(let meme), .play(let card)):
                play(card: card, for: meme, as: player)

            case (.freestyle(let meme), .freestyle(let text)):
                play(text: text, for: meme, as: player)

            case (.choosing(let meme), .choose(let text)):
                choose(text: text, for: meme, as: player)

            case (.done, .playAgain):
                playAgain(as: player)

            case (_, .stop):
                guard player.isHost else {
                    player.send(event: .error(.onlyTheHostCanEnd))
                    return
                }
                stop()

            default:
                player.send(event: .error(.illegalEvent))
            }
        }
    }

    private func send(event: ServerSideEvent) {
        for player in players {
            player.send(event: event)
        }
    }

    private func start(as player: Player) {
        guard host?.id == player.id else {
            return player.send(event: .error(.onlyTheHostCanStart))
        }

        guard players.count > 2 else {
            return player.send(event: .error(.gameCanOnlyStartWithAMinimumOfThreePlayers))
        }

        players.shuffle()
        for player in players {
            for _ in 0..<7 {
                player.cards.append(deck.card())
            }
            player.send(event: .newCards(player.cards))
        }
        state = .collecting(deck.meme(for: players[judgeIndex]))
    }

    private func play(card: Card, for meme: Meme, as player: Player) {
        guard meme.judge.id != player.id else {
            return player.send(event: .error(.judgeCannotPlayACard))
        }

        guard player.cards.contains(card) else {
            return player.send(event: .error(.cannotPlayACardNotInTheHand))
        }

        guard !meme.proposedLines.contains(where: { $0.player.id == player.id }) else {
            return player.send(event: .error(.cannotPlayTwiceForTheSameCard))
        }

        player.cards.removeFirst(card)

        switch card {
        case .freestyle:
            meme.proposedLines = []
            state = .freestyle(meme)
        case .text(let text):
            play(text: text, for: meme, as: player)
        }

        let newCard = deck.card()
        player.cards.append(newCard)
        player.send(event: .newCards([newCard]))
    }

    private func play(text: String, for meme: Meme, as player: Player) {
        guard meme.judge.id != player.id else {
            return player.send(event: .error(.judgeCannotPlayACard))
        }

        guard !meme.proposedLines.contains(where: { $0.player.id == player.id }) else {
            return player.send(event: .error(.cannotPlayTwiceForTheSameCard))
        }

        meme.proposedLines.append(Proposal(player: player, text: text))
        send(event: .update(meme))

        if meme.proposedLines.count == players.count - 1 {
            state = .choosing(meme)
        }
    }

    private func choose(text: String, for meme: Meme, as player: Player) {
        guard meme.judge.id == player.id else {
            return player.send(event: .error(.onlyJudgeCanChoose))
        }

        guard let chosen = meme.proposedLines.first(where: { $0.text == text }) else {
            return player.send(event: .error(.cardWasNotPlayed))
        }

        history.append(meme)
        meme.winningCard = chosen
        chosen.player.winCount += 1
        judgeIndex = (judgeIndex + 1) % players.count
        if (judgeIndex == 0 && history.count >= rounds * players.count) {
            state = .done
        } else {
            state = .collecting(deck.meme(for: players[judgeIndex]))
        }
    }

    func playAgain(as player: Player) {
        guard player.isHost else { return player.send(event: .error(.onlyTheHostCanStart)) }
        history = []
        deck.reshuffle()
        for player in players {
            player.cards = []
            player.winCount = 0
        }
        players.shuffle()
        judgeIndex = 0
        state = .initialized
    }

    func stop() {
        self.state = .stopped
        for player in players {
            player.stop()
        }
    }
}

extension Deck {

    func meme(for judge: Player) -> Meme {
        return Meme(judge: judge, image: meme())
    }

}

/// Splits the editor's arguments field the way a shell splits a command line, minus every
/// expansion: whitespace separates, single and double quotes group, and nothing else is
/// interpreted — no `$VAR`, no `~`, no backslash escapes.
enum ArgumentTokenizer {
    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        // An argument the user wrote as `""` is empty but still an argument, which "is `current`
        // non-empty" cannot express.
        var hasToken = false
        var quote: Character?
        // A character *offset*, not a `String.Index`: an index is invalidated by mutating the
        // string it came from, and `current` keeps growing after the quote opens.
        var quoteOpenedAt: Int?

        func flush() {
            if hasToken { tokens.append(current) }
            current = ""
            hasToken = false
        }

        for ch in raw {
            if let openQuote = quote {
                if ch == openQuote {
                    quote = nil
                    quoteOpenedAt = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                quoteOpenedAt = current.count
                hasToken = true
                continue
            }
            if ch.isWhitespace {
                flush()
                continue
            }
            current.append(ch)
            hasToken = true
        }

        // A quote that never closes was not a quote. The commonest case is an apostrophe in a
        // path — `/Users/m/Morten's Docs` — and treating it as an opening quote silently deleted
        // it and glued the rest of the line into one argument, so the app was launched with
        // arguments the user never wrote and no escape syntax to work around it.
        if let openQuote = quote, let opened = quoteOpenedAt {
            let split = current.index(current.startIndex, offsetBy: opened)
            let literal = String(openQuote) + current[split...]
            current = String(current[..<split])
            let pieces = literal.split(whereSeparator: \.isWhitespace).map(String.init)
            if let first = pieces.first {
                current += first
                hasToken = true
            }
            flush()
            tokens.append(contentsOf: pieces.dropFirst())
            return tokens
        }

        flush()
        return tokens
    }
}
